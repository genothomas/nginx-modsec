#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/build/versions.env"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

channel="${NGINX_CHANNEL:-stable}"
arch="${TARGET_ARCH:?TARGET_ARCH must be amd64 or arm64}"

case "$channel" in
    stable) version="$NGINX_STABLE_VERSION" ;;
    mainline) version="$NGINX_MAINLINE_VERSION" ;;
    *) die "invalid channel: $channel" ;;
esac

case "$arch" in
    amd64|arm64) ;;
    *) die "invalid architecture: $arch" ;;
esac

BUILD_ROOT="${BUILD_ROOT:-/opt/nginx}"
dist="$BUILD_ROOT/dist/$channel/$arch"
archive="$dist/nginx-modsec-${version}-${channel}-linux-${arch}.tar.gz"
sums="$dist/SHA256SUMS"

modules=(
    ngx_http_modsecurity_module.so
    ngx_http_geoip2_module.so
    ngx_http_headers_more_filter_module.so
)

# Build-tree / CI workspace paths must not leak into shipped artifacts.
# Checked against readelf output, strings output, and nginx -V output.
FORBIDDEN_PATHS=(
    /home/
    /workspace/
    /work/runner/
    /opt/nginx/src/
    /opt/nginx/stage/
    /opt/nginx/dist/
)

[[ -s "$archive" ]] || die "missing artifact: $archive"
[[ -s "$sums" ]] || die "missing checksum file: $sums"

echo "Verifying SHA256"
(cd "$dist" && sha256sum --strict -c SHA256SUMS)

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Extracting archive"
tar -xzf "$archive" -C "$tmpdir" --no-same-owner

[[ -x "$tmpdir/usr/sbin/nginx" ]] || die "missing /usr/sbin/nginx"

for module in "${modules[@]}"; do
    [[ -f "$tmpdir/usr/lib/nginx/modules/$module" ]] || die "missing module: $module"
done

[[ -f "$tmpdir/usr/local/modsecurity/lib/libmodsecurity.so.3" ]] ||
    die "missing libmodsecurity.so.3"

# Deployment-owned configuration must not be included.
[[ ! -e "$tmpdir/etc/nginx/nginx.conf" ]] ||
    die "forbidden artifact: /etc/nginx/nginx.conf"

modsec_dir="$tmpdir/etc/nginx/modsec"
[[ -d "$modsec_dir/rules" ]] || die "missing CRS rules dir"
[[ -s "$modsec_dir/main.conf" ]] || die "missing ModSecurity main.conf"
[[ -s "$modsec_dir/modsecurity.conf" ]] || die "missing ModSecurity modsecurity.conf"
[[ -s "$modsec_dir/crs-setup.conf.example" ]] || die "missing crs-setup.conf.example"
[[ -n "$(find "$modsec_dir/rules" -maxdepth 1 -name '*.conf' -print -quit)" ]] ||
    die "CRS rules dir is empty"
[[ -s "$tmpdir/usr/local/modsecurity/unicode.mapping" ]] ||
    die "missing unicode.mapping"

# Smoke test: actually load every dynamic module + parse a config that
# includes the staged CRS rules. Catches ABI mismatch, broken directives,
# and CRS load regressions that file-existence checks miss.
smoke="$tmpdir/smoke"
mkdir -p "$smoke/etc/nginx/modsec/rules" \
         "$smoke/tmp/client_body" "$smoke/tmp/proxy" \
         "$smoke/tmp/fastcgi" "$smoke/tmp/uwsgi" "$smoke/tmp/scgi"

cp -a "$modsec_dir/rules/." "$smoke/etc/nginx/modsec/rules/"
cp -a "$modsec_dir/crs-setup.conf.example" "$smoke/etc/nginx/modsec/"

cat > "$smoke/etc/nginx/modsec/modsecurity.conf" <<EOF
SecRuleEngine DetectionOnly
SecRequestBodyAccess On
SecResponseBodyAccess Off
SecAuditEngine Off
SecUnicodeMapFile $tmpdir/usr/local/modsecurity/unicode.mapping 20127
EOF

cat > "$smoke/etc/nginx/modsec/main.conf" <<EOF
Include $smoke/etc/nginx/modsec/modsecurity.conf
Include $smoke/etc/nginx/modsec/crs-setup.conf.example
Include $smoke/etc/nginx/modsec/rules/*.conf
EOF

cat > "$smoke/nginx.conf" <<EOF
pid $smoke/nginx.pid;
load_module $tmpdir/usr/lib/nginx/modules/ngx_http_modsecurity_module.so;
load_module $tmpdir/usr/lib/nginx/modules/ngx_http_geoip2_module.so;
load_module $tmpdir/usr/lib/nginx/modules/ngx_http_headers_more_filter_module.so;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $smoke/tmp/client_body;
    proxy_temp_path $smoke/tmp/proxy;
    fastcgi_temp_path $smoke/tmp/fastcgi;
    uwsgi_temp_path $smoke/tmp/uwsgi;
    scgi_temp_path $smoke/tmp/scgi;
    server {
        listen 127.0.0.1:18080;
        modsecurity on;
        modsecurity_rules_file $smoke/etc/nginx/modsec/main.conf;
        location / { return 200 "ok"; }
    }
}
EOF

LD_LIBRARY_PATH="$tmpdir/usr/local/modsecurity/lib" \
    "$tmpdir/usr/sbin/nginx" \
    -e stderr \
    -t -q -c "$smoke/nginx.conf" \
    || die "nginx -t failed"

# ELF hardening: PIE, RELRO, BIND_NOW, NX stack, no RPATH, no build-tree
# paths. Applied to every shipped binary and module.
verify_runtime_elf() {
    local file="$1" name="$2"
    local hdr dyns segments stack
    [[ -f "$file" ]] || die "$name: file not found: $file"

    hdr="$(readelf -h "$file")"
    dyns="$(readelf -d "$file")"
    segments="$(readelf -lW "$file")"

    grep -Eq 'Type:.*DYN' <<< "$hdr" ||
        die "$name: unexpected ELF type; expected ET_DYN"
    grep -Fq 'GNU_RELRO' <<< "$segments" ||
        die "$name: missing GNU_RELRO"
    grep -Eq 'BIND_NOW' <<< "$dyns" ||
        die "$name: missing BIND_NOW"

    stack="$(grep 'GNU_STACK' <<< "$segments" || true)"
    [[ -n "$stack" ]] || die "$name: no GNU_STACK segment"
    ! grep -Fq ' E ' <<< "$stack" || die "$name: executable stack"

    ! grep -Eq 'RPATH\b' <<< "$dyns" || die "$name: deprecated RPATH set"

    for forbidden in "${FORBIDDEN_PATHS[@]}"; do
        if grep -Fq "$forbidden" <<< "$dyns"; then
            die "$name: build-tree path in dynamic section: $forbidden"
        fi
    done
}

verify_runtime_elf "$tmpdir/usr/sbin/nginx" "nginx"
verify_runtime_elf "$tmpdir/usr/local/modsecurity/lib/libmodsecurity.so.3" "libmodsecurity"
verify_runtime_elf "$tmpdir/usr/lib/nginx/modules/ngx_http_modsecurity_module.so" "modsecurity_module"
verify_runtime_elf "$tmpdir/usr/lib/nginx/modules/ngx_http_geoip2_module.so" "geoip2_module"
verify_runtime_elf "$tmpdir/usr/lib/nginx/modules/ngx_http_headers_more_filter_module.so" "headers_more_module"

# strings scan catches paths embedded in .debug_info / .comment / .rodata,
# not just the dynamic section that verify_runtime_elf inspects.
check_no_path_leak() {
    local file="$1" forbidden strings_output
    [[ -f "$file" ]] || return 0
    strings_output="$(strings "$file")"
    for forbidden in "${FORBIDDEN_PATHS[@]}"; do
        if grep -Fq "$forbidden" <<< "$strings_output"; then
            die "build path leak in $(basename "$file"): $forbidden"
        fi
    done
}

check_no_path_leak "$tmpdir/usr/sbin/nginx"
check_no_path_leak "$tmpdir/usr/local/modsecurity/lib/libmodsecurity.so.3"
for module in "${modules[@]}"; do
    check_no_path_leak "$tmpdir/usr/lib/nginx/modules/$module"
done

# modsec_module requires explicit RUNPATH for libmodsecurity.so discovery.
modsec_dyn="$(readelf -d "$tmpdir/usr/lib/nginx/modules/ngx_http_modsecurity_module.so")"
grep -Fq 'Library runpath: [/usr/local/modsecurity/lib]' <<< "$modsec_dyn" ||
    die "modsecurity_module: RUNPATH must be [/usr/local/modsecurity/lib]:" \
        "$(grep -E 'NEEDED|RPATH|RUNPATH' <<< "$modsec_dyn" || true)"
grep -Fq 'Shared library: [libmodsecurity.so.3]' <<< "$modsec_dyn" ||
    die "modsecurity_module: NEEDED libmodsecurity.so.3 missing"

grep -Fq 'libmaxminddb' <<< \
    "$(readelf -d "$tmpdir/usr/lib/nginx/modules/ngx_http_geoip2_module.so")" ||
    die "geoip2_module: NEEDED libmaxminddb missing"

if grep -Eq 'libssl|libcrypto|libpcre2' <<< \
    "$(readelf -d "$tmpdir/usr/sbin/nginx")"; then
    die "nginx: dynamic link to libssl/libcrypto/libpcre2 not allowed (must be statically linked)"
fi

nginx_v_output="$("$tmpdir/usr/sbin/nginx" -V 2>&1)"

grep -Eq -- '--with-pcre=\.\./[^[:space:]]+' <<< "$nginx_v_output" ||
    die "NGINX PCRE2 path is not relative"

for flag in "-I$BUILD_ROOT/openssl/include" "-L$BUILD_ROOT/openssl/lib"; do
    grep -Fq -- "$flag" <<< "$nginx_v_output" || die "NGINX OpenSSL flag missing: $flag"
done

for forbidden in "${FORBIDDEN_PATHS[@]}"; do
    if grep -Fq "$forbidden" <<< "$nginx_v_output"; then
        die "absolute CI/workspace path in nginx -V: $forbidden"
    fi
done

echo "Verified $channel/$arch: $archive"
