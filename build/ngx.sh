#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/build/versions.env"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

NGINX_CHANNEL="${NGINX_CHANNEL:-stable}"
: "${TARGET_ARCH:?TARGET_ARCH must be set (amd64 or arm64)}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] ||
    die "BUILD_JOBS must be a positive integer"
export MAKEFLAGS="-j${BUILD_JOBS}"
export TZ=UTC LC_ALL=C

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    SOURCE_DATE_EPOCH="$(
        git -C "$ROOT" show -s --format=%ct HEAD 2>/dev/null
    )" || die "SOURCE_DATE_EPOCH is unset and Git HEAD timestamp is unavailable"
fi

[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] ||
    die "SOURCE_DATE_EPOCH must be a Unix timestamp"

export SOURCE_DATE_EPOCH

case "$NGINX_CHANNEL" in
    stable)   NGINX_VERSION="$NGINX_STABLE_VERSION"   NGINX_SHA256="$NGINX_STABLE_SHA256" ;;
    mainline) NGINX_VERSION="$NGINX_MAINLINE_VERSION" NGINX_SHA256="$NGINX_MAINLINE_SHA256" ;;
    *) die "unsupported NGINX_CHANNEL=$NGINX_CHANNEL" ;;
esac

case "$TARGET_ARCH" in
    amd64|x86_64)  MACHINE_ARCH=amd64 ;;
    arm64|aarch64) MACHINE_ARCH=arm64 ;;
    *) die "unsupported TARGET_ARCH=$TARGET_ARCH" ;;
esac

# /opt/nginx keeps absolute paths baked into artifacts out of any developer's home dir.
BUILD_ROOT="${BUILD_ROOT:-/opt/nginx}"
mkdir -p "$BUILD_ROOT"

WORK="$BUILD_ROOT/src/${NGINX_CHANNEL}-${MACHINE_ARCH}"
SRC="$WORK"
STAGE="$BUILD_ROOT/stage/${NGINX_CHANNEL}-${MACHINE_ARCH}"
DIST="$BUILD_ROOT/dist/${NGINX_CHANNEL}/${MACHINE_ARCH}"
PCRE2_PREFIX="$WORK/pcre2"
MODSECURITY_PREFIX="$WORK/modsecurity"
MODSECURITY_RUNTIME_PREFIX="/usr/local/modsecurity"
MODSECURITY_RUNTIME_LIB="$MODSECURITY_RUNTIME_PREFIX/lib"

export BUILD_ROOT WORK SRC STAGE DIST PCRE2_PREFIX MODSECURITY_PREFIX \
    MODSECURITY_RUNTIME_PREFIX MODSECURITY_RUNTIME_LIB

# ERR names the failing command and line; EXIT points at partial artifacts.
# shellcheck disable=SC2154  # $? is bound to rc at trap entry by bash
trap 'rc=$?; printf "ERROR: command failed (rc=%d, line=%d): %s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR
trap 'rc=$?; (( rc == 0 )) || printf "Build failed (exit %d). Partial artifacts kept at:\n  WORK : %s\n  STAGE: %s\nInspect or remove with: rm -rf %s %s\n" "$rc" "$WORK" "$STAGE" "$WORK" "$STAGE" >&2' EXIT

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

install_deps() {
    [[ "${SKIP_APT:-0}" == "1" ]] && return

    log "Installing build dependencies"

    run_root apt-get update
    run_root apt-get install -y --no-install-recommends \
        autoconf automake build-essential ca-certificates curl git libtool \
        libcurl4-openssl-dev libmaxminddb-dev libxml2-dev libyajl-dev \
        patchelf pkg-config zlib1g-dev
}


# STRICT_SOURCE_VERIFY=0 is a dev escape hatch (warn instead of die). Default
# is fail-closed: every pin must be a valid 64-char hex SHA256.
# Optional $3 = friendly label; defaults to basename of $file.
verify_sha256() {
    local file="$1" expected="$2"
    local name="${3:-$(basename "$file")}" got

    [[ -f "$file" ]] || die "verify_sha256: file not found: $file"

    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        if [[ "${STRICT_SOURCE_VERIFY:-1}" == "1" ]]; then
            die "missing or invalid SHA256 pin for $name"
        fi
        printf 'WARNING: SHA256 not verified for %s\n' "$name" >&2
        return 0
    fi

    got="$(sha256_of "$file")"
    [[ "$got" == "$expected" ]] ||
        die "sha256 mismatch: $name (got $got, want $expected)"

    log "sha256 OK: $name"
}

# $2 = hex SHA256 pin from versions.env.
# $4 = upstream tarball name (e.g. "headers-more-nginx-module-v0.40.tar.gz");
# defaults to basename of $dest when omitted.
fetch_module_tarball() {
    local url="$1" sha="$2" dest="$3" label="${4:-}"
    local tarball workdir src_dir
    label="${label:-$(basename "$dest")}"
    tarball="$SRC/$(basename "$url")"
    workdir="$SRC/.extract-$BASHPID"

    curl_strict -o "$tarball" "$url"
    verify_sha256 "$tarball" "$sha" "$label"

    rm -rf "$workdir"
    mkdir -p "$workdir"
    tar -xzf "$tarball" -C "$workdir"

    src_dir="$(find "$workdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$src_dir" ]] || die "tarball did not contain a top-level directory: $url"

    rm -rf "$dest"
    mv "$src_dir" "$dest"
    rm -rf "$workdir" "$tarball"
}

prepare_dirs() {
    rm -rf "$WORK" "$STAGE" "$DIST"
    mkdir -p "$SRC" "$STAGE" "$DIST"
}

fetch_sources() {
    log "Fetching sources"

    curl_strict -o "$SRC/nginx.tar.gz" \
        "https://github.com/nginx/nginx/releases/download/release-${NGINX_VERSION}/nginx-${NGINX_VERSION}.tar.gz"
    verify_sha256 "$SRC/nginx.tar.gz" "$NGINX_SHA256" "nginx-${NGINX_VERSION}.tar.gz"
    tar -xzf "$SRC/nginx.tar.gz" -C "$SRC"

    local base="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
    curl_strict -o "$SRC/openssl.tar.gz" "$base"
    verify_sha256 "$SRC/openssl.tar.gz" "$OPENSSL_SHA256" "openssl-${OPENSSL_VERSION}.tar.gz"
    tar -xzf "$SRC/openssl.tar.gz" -C "$SRC"

    curl_strict -o "$SRC/pcre2.tar.gz" \
        "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
    verify_sha256 "$SRC/pcre2.tar.gz" "$PCRE2_SHA256" "pcre2-${PCRE2_VERSION}.tar.gz"
    mkdir -p "$SRC/pcre2-src"
    tar -xzf "$SRC/pcre2.tar.gz" --strip-components=1 -C "$SRC/pcre2-src"

    fetch_module_tarball \
        "https://github.com/owasp-modsecurity/ModSecurity-nginx/releases/download/v${MODSECURITY_NGINX_VERSION}/ModSecurity-nginx-v${MODSECURITY_NGINX_VERSION}.tar.gz" \
        "$MODSECURITY_NGINX_SHA256" \
        "$SRC/ModSecurity-nginx" \
        "ModSecurity-nginx-v${MODSECURITY_NGINX_VERSION}.tar.gz"

    fetch_module_tarball \
        "https://github.com/leev/ngx_http_geoip2_module/archive/refs/tags/${GEOIP2_MODULE_VERSION}.tar.gz" \
        "$GEOIP2_MODULE_SHA256" \
        "$SRC/ngx_http_geoip2_module" \
        "ngx_http_geoip2_module-${GEOIP2_MODULE_VERSION}.tar.gz"

    fetch_module_tarball \
        "https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v${HEADERS_MORE_VERSION}.tar.gz" \
        "$HEADERS_MORE_SHA256" \
        "$SRC/headers-more-nginx-module" \
        "headers-more-nginx-module-v${HEADERS_MORE_VERSION}.tar.gz"

    fetch_module_tarball \
        "https://github.com/owasp-modsecurity/ModSecurity/releases/download/v${LIBMODSECURITY_VERSION}/modsecurity-v${LIBMODSECURITY_VERSION}.tar.gz" \
        "$LIBMODSECURITY_SHA256" \
        "$SRC/ModSecurity" \
        "modsecurity-v${LIBMODSECURITY_VERSION}.tar.gz"

    # OWASP CRS — separate pin from NGINX cycle. Minimal tarball excludes
    # tests/docs to keep the artifact small.
    curl_strict -o "$SRC/crs.tar.gz" \
        "https://github.com/coreruleset/coreruleset/releases/download/v${CRS_VERSION}/coreruleset-${CRS_VERSION}-minimal.tar.gz"
    verify_sha256 "$SRC/crs.tar.gz" "$CRS_SHA256" "coreruleset-${CRS_VERSION}-minimal.tar.gz"
    rm -rf "$SRC/crs-src"
    mkdir -p "$SRC/crs-src"
    tar -xzf "$SRC/crs.tar.gz" --strip-components=1 -C "$SRC/crs-src"
}

build_openssl() {
    local dir="$SRC/openssl-${OPENSSL_VERSION}" target lib

    log "Building OpenSSL ${OPENSSL_VERSION}"

    case "$MACHINE_ARCH" in
        amd64) target=linux-x86_64 ;;
        arm64) target=linux-aarch64 ;;
        *) die "no OpenSSL target for arch: $MACHINE_ARCH" ;;
    esac

    pushd "$dir" >/dev/null
    ./Configure "$target" \
        --prefix="$BUILD_ROOT/openssl" \
        --openssldir=/etc/ssl \
        --libdir=lib \
        no-shared \
        no-tests
    popd >/dev/null

    make -C "$dir"
    make -C "$dir" install_sw

    for lib in libssl.a libcrypto.a; do
        [[ -f "$BUILD_ROOT/openssl/lib/$lib" ]] ||
            die "OpenSSL installation incomplete ($lib missing)"
    done
}

build_pcre2() {
    local dir="$SRC/pcre2-src"

    log "Building PCRE2 ${PCRE2_VERSION}"

    pushd "$dir" >/dev/null
    ./configure --prefix="$PCRE2_PREFIX" --enable-jit --disable-shared
    popd >/dev/null

    make -C "$dir"
    make -C "$dir" install

    [[ -f "$PCRE2_PREFIX/lib/pkgconfig/libpcre2-8.pc" ]] ||
        die "PCRE2 installation incomplete"
}

build_modsecurity() {
    local dir="$SRC/ModSecurity"

    log "Building libModSecurity ${LIBMODSECURITY_VERSION}"

    [[ -d "$dir" ]] || die "ModSecurity source tree missing — fetch_sources failed?"

    pushd "$dir" >/dev/null
    ./build.sh

    export PKG_CONFIG_PATH="$PCRE2_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        CPPFLAGS="-I$PCRE2_PREFIX/include" \
        LDFLAGS="-L$PCRE2_PREFIX/lib -Wl,-z,relro,-z,now,-z,noexecstack -Wl,--as-needed"

    ./configure \
        --prefix="$MODSECURITY_PREFIX" \
        --with-pcre2 \
        --disable-static \
        --disable-dependency-tracking
    popd >/dev/null

    make -C "$dir"
    make -C "$dir" install

    [[ -f "$MODSECURITY_PREFIX/lib/libmodsecurity.so" ]] ||
        die "libModSecurity installation incomplete"
    [[ -f "$MODSECURITY_PREFIX/lib/libmodsecurity.so.3" ]] ||
        die "libModSecurity SONAME symlink missing"
    [[ -f "$dir/unicode.mapping" ]] ||
        die "ModSecurity unicode.mapping missing"
}

build_nginx() {
    log "Building NGINX ${NGINX_VERSION} for ${MACHINE_ARCH}"

    export NGINX_SRC="$WORK/nginx-${NGINX_VERSION}"

    # NGX_IGNORE_RPATH skips modsec's baked-in $WORK RPATH; patchelf sets the runtime RUNPATH below.
    # ModSecurity → installed PCRE2; NGINX → source-tree PCRE2 (no separate linker search needed).
    export MODSECURITY_INC="$MODSECURITY_PREFIX/include" \
        MODSECURITY_LIB="$MODSECURITY_PREFIX/lib" \
        NGX_IGNORE_RPATH=YES \
        PKG_CONFIG_PATH="$MODSECURITY_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        CPPFLAGS="-I../modsecurity/include" \
        LDFLAGS="-L../modsecurity/lib"

    # Relative paths so nginx -V does not expose the absolute work directory.
    export NGINX_VERSION NGINX_CHANNEL \
        PCRE2_PATH="../pcre2-src" \
        MODSECURITY_NGINX_PATH="../ModSecurity-nginx" \
        GEOIP2_PATH="../ngx_http_geoip2_module" \
        HEADERS_MORE_PATH="../headers-more-nginx-module"

    "$ROOT/build/configure.sh"

    make -C "$NGINX_SRC"
    make -C "$NGINX_SRC" install DESTDIR="$STAGE"

    # Keep stock support files (mime.types, etc.); drop stock nginx.conf — deployment owns it.
    rm -f "$STAGE/etc/nginx/nginx.conf"
}

stage_files() {
    local lib_dir="$STAGE$MODSECURITY_RUNTIME_PREFIX/lib"
    local modsec_dir="$STAGE/etc/nginx/modsec"
    local modsecurity_so
    local unicode_src
    local module

    log "Staging runtime files"

    install -d -m 0755 \
        "$STAGE/usr/lib/nginx/modules" \
        "$STAGE$MODSECURITY_RUNTIME_PREFIX" \
        "$lib_dir" \
        "$modsec_dir/rules"

    # libModSecurity runtime library: versioned .so + SONAME + dev symlink.
    # Discover the versioned filename rather than assume a naming scheme.
    modsecurity_so="$(find "$MODSECURITY_PREFIX/lib" -maxdepth 1 \
        -name 'libmodsecurity.so.*.*.*' -print -quit)"
    [[ -n "$modsecurity_so" ]] ||
        die "versioned libmodsecurity.so not found in $MODSECURITY_PREFIX/lib"

    install -m 0755 "$modsecurity_so" "$lib_dir/$(basename "$modsecurity_so")"

    ln -sfn "$(basename "$modsecurity_so")" "$lib_dir/libmodsecurity.so.3"
    ln -sfn "libmodsecurity.so.3" "$lib_dir/libmodsecurity.so"

    # ModSecurity's install doesn't ship unicode.mapping; it lives in the
    # source tree. Probe $SRC (maxdepth 2 covers root + subdirs).
    unicode_src="$(find "$SRC/ModSecurity" -maxdepth 2 \
        -name unicode.mapping -print -quit)"
    [[ -n "$unicode_src" ]] ||
        die "ModSecurity unicode.mapping missing (build_modsecurity failed?)"

    install -m 0644 \
        "$unicode_src" \
        "$STAGE$MODSECURITY_RUNTIME_PREFIX/unicode.mapping"

    # /etc/nginx/modsec/
    install -m 0644 \
        "$ROOT/deploy/modsec/modsecurity.conf" \
        "$modsec_dir/modsecurity.conf"

    install -m 0644 \
        "$ROOT/deploy/modsec/main.conf" \
        "$modsec_dir/main.conf"

    install -m 0644 \
        "$ROOT/deploy/modsec/override.conf.example" \
        "$modsec_dir/override.conf.example"

    # Ship an active CRS setup file because main.conf includes crs-setup.conf.
    install -m 0644 \
        "$SRC/crs-src/crs-setup.conf.example" \
        "$modsec_dir/crs-setup.conf"

    # CRS rules.
    cp -a \
        "$SRC/crs-src/rules/." \
        "$modsec_dir/rules/"

    # Normalize CRS permissions for deterministic runtime packaging.
    find "$modsec_dir/rules" -type d -exec chmod 0755 {} +
    find "$modsec_dir/rules" -type f -exec chmod 0644 {} +

    # NGINX dynamic modules.
    for module in \
        ngx_http_modsecurity_module.so \
        ngx_http_geoip2_module.so \
        ngx_http_headers_more_filter_module.so
    do
        [[ -f "$NGINX_SRC/objs/$module" ]] ||
            die "missing dynamic module: $module"

        install -m 0755 \
            "$NGINX_SRC/objs/$module" \
            "$STAGE/usr/lib/nginx/modules/$module"
    done
}

# Whitelist: only the runtime lib path is allowed. `|| true` swallows grep's
# exit 1 when the module has zero RPATH/RUNPATH lines.
assert_no_rpath_leak() {
    local so="$1" bad
    bad="$(readelf -d "$so" | grep -E 'Library (RPATH|RUNPATH)' | grep -v -F "[$MODSECURITY_RUNTIME_LIB]" || true)"
    [[ -z "$bad" ]] || die "build-tree RPATH/RUNPATH in $(basename "$so"): $bad"
}

fix_modsecurity_rpath() {
    local module="$STAGE/usr/lib/nginx/modules/ngx_http_modsecurity_module.so"

    log "Setting ModSecurity runtime RUNPATH"

    [[ -f "$module" ]] || die "staged ModSecurity module missing"

    patchelf --set-rpath "$MODSECURITY_RUNTIME_LIB" "$module"

    readelf -d "$module" | grep -qF "Library runpath: [$MODSECURITY_RUNTIME_LIB]" ||
        die "expected ModSecurity RUNPATH not found:" \
            "$(readelf -d "$module" | grep -E 'NEEDED|RPATH|RUNPATH' || true)"

    assert_no_rpath_leak "$module"

    readelf -d "$module" | grep -qF 'Shared library: [libmodsecurity.so.3]' ||
        die "libmodsecurity.so.3 dependency missing"
}

strip_binaries() {
    log "Stripping binaries"

    [[ -x "$STAGE/usr/sbin/nginx" ]] || die "strip_binaries: nginx binary missing"

    strip --strip-all "$STAGE/usr/sbin/nginx"

    find "$STAGE/usr/lib/nginx/modules" -type f -name '*.so' \
        -exec strip --strip-unneeded {} +
    find "$STAGE$MODSECURITY_RUNTIME_PREFIX/lib" -type f -name '*.so*' \
        -exec strip --strip-unneeded {} +
}

verify_runtime_elf() {
    local nginx_bin="$STAGE/usr/sbin/nginx"
    local modsec_mod="$STAGE/usr/lib/nginx/modules/ngx_http_modsecurity_module.so"
    local needed

    log "Verify ELF hardening and runtime linkage"

    needed="$(readelf -d "$nginx_bin" | grep -cF 'NEEDED' || true)"
    (( needed >= 1 )) || die "strip removed DT_NEEDED entries from nginx binary"

    readelf -d "$modsec_mod" | grep -qF 'Shared library: [libmodsecurity.so.3]' ||
        die "strip broke ModSecurity DT_NEEDED"
    readelf -d "$modsec_mod" | grep -qF "Library runpath: [$MODSECURITY_RUNTIME_LIB]" ||
        die "strip broke ModSecurity DT_RUNPATH"

    assert_no_rpath_leak "$modsec_mod"
}

package() {
    local archive="$DIST/nginx-modsec-${NGINX_VERSION}-${NGINX_CHANNEL}-linux-${MACHINE_ARCH}.tar.gz"

    log "Packaging"

    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        -C "$STAGE" -czf "$archive" .

    (cd "$DIST" && sha256sum "$(basename "$archive")" > SHA256SUMS)

    printf 'Artifact: %s\n' "$archive"
}

main() {
    install_deps
    prepare_dirs
    fetch_sources
    build_openssl
    build_pcre2
    build_modsecurity
    build_nginx
    stage_files
    fix_modsecurity_rpath
    strip_binaries
    verify_runtime_elf
    package

    log "Build completed successfully"
    printf 'Channel      : %s\nNGINX        : %s\nArchitecture : %s\nOutput       : %s\n' \
        "$NGINX_CHANNEL" "$NGINX_VERSION" "$MACHINE_ARCH" "$DIST"

    if [[ "${CLEAN_BUILD_TREE:-0}" == "1" ]]; then
        log "Cleaning source tree (unset CLEAN_BUILD_TREE to retain for debugging)"
        rm -rf "$WORK"
    fi
}

main "$@"
