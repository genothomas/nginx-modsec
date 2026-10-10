#!/usr/bin/env bash
set -Eeuo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2154  # $? is bound to rc at trap entry by bash
trap 'rc=$?; printf "ERROR: command failed (rc=%d, line=%d): %s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

usage() {
    cat <<'EOF'
Usage:
  sudo ./upgrade.sh /path/to/nginx-modsec-<version>-<channel>-linux-<arch>.tar.gz

Upgrades the custom NGINX runtime while preserving:
  /etc/nginx/nginx.conf
  /etc/nginx/conf.d/
  /etc/nginx/modsec/

Requires a SHA256SUMS file in the same directory as the archive
(same format as the one shipped with the GitHub release assets).
Uses apt-get and dpkg; RHEL/Fedora/Arch not supported.
EOF
}

[[ $# -eq 1 ]] || { usage; exit 2; }

ARCHIVE="$1"
ARCHIVE_DIR="$(dirname "$ARCHIVE")"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
MODSEC_MODULE="usr/lib/nginx/modules/ngx_http_modsecurity_module.so"

MODULES=(
    ngx_http_modsecurity_module.so
    ngx_http_geoip2_module.so
    ngx_http_headers_more_filter_module.so
)

SUPPORT_FILES=(
    fastcgi.conf fastcgi.conf.default fastcgi_params fastcgi_params.default
    mime.types mime.types.default scgi_params scgi_params.default
    uwsgi_params uwsgi_params.default koi-utf koi-win win-utf
)

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 <archive>"
[[ -f "$ARCHIVE" ]] || die "Archive not found: $ARCHIVE"

EXPECTED_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$EXPECTED_ARCH" in
    amd64|arm64) ;;
    *) die "Unsupported host architecture: $EXPECTED_ARCH" ;;
esac

[[ "$ARCHIVE_NAME" == *"linux-${EXPECTED_ARCH}.tar.gz" ]] ||
    die "Archive architecture does not match host: expected ${EXPECTED_ARCH}"

TMPDIR="$(mktemp -d)"
BACKUP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR" "$BACKUP_DIR"' EXIT

printf '==> Verifying SHA256\n'

[[ -f "$ARCHIVE_DIR/SHA256SUMS" ]] ||
    die "SHA256SUMS not found at $ARCHIVE_DIR/SHA256SUMS (required alongside the archive)"

(cd "$ARCHIVE_DIR" && grep -F "  $ARCHIVE_NAME" SHA256SUMS | sha256sum -c -) ||
    die "SHA256 verification failed for $ARCHIVE_NAME"

printf '==> Extracting %s\n' "$ARCHIVE_NAME"

# Defense-in-depth: refuse archives with absolute paths or .. components.
if tar -tzf "$ARCHIVE" | grep -qE '(^/|\.\./)'; then
    die "archive contains unsafe paths (absolute or .. components)"
fi

tar -xzf "$ARCHIVE" -C "$TMPDIR" --no-same-owner --no-same-permissions

[[ -x "$TMPDIR/usr/sbin/nginx" ]] || die "NGINX binary missing"
[[ -f "$TMPDIR/usr/local/modsecurity/lib/libmodsecurity.so.3" ]] ||
    die "libmodsecurity.so.3 missing"

for module in "${MODULES[@]}"; do
    [[ -f "$TMPDIR/usr/lib/nginx/modules/$module" ]] || die "Module missing: $module"
done

printf '==> Validating new NGINX binary\n'

"$TMPDIR/usr/sbin/nginx" -V

printf '==> Checking ModSecurity linkage\n'

modsec_dyn="$(readelf -d "$TMPDIR/$MODSEC_MODULE")"
grep -Fq 'Library runpath: [/usr/local/modsecurity/lib]' <<< "$modsec_dyn" ||
    die "Invalid ModSecurity RUNPATH"
grep -Fq 'Shared library: [libmodsecurity.so.3]' <<< "$modsec_dyn" ||
    die "Missing libmodsecurity.so.3 dependency"

printf '==> Backing up current binary, modules and libModSecurity\n'

[[ ! -x /usr/sbin/nginx ]] || cp -a /usr/sbin/nginx "$BACKUP_DIR/nginx"

for module in "${MODULES[@]}"; do
    [[ -f "/usr/lib/nginx/modules/$module" ]] || continue
    cp -a "/usr/lib/nginx/modules/$module" "$BACKUP_DIR/"
done

for lib in /usr/local/modsecurity/lib/libmodsecurity.so*; do
    [[ -f "$lib" ]] || continue
    cp -a "$lib" "$BACKUP_DIR/"
done

# Back up user modsec config; ship-provided config is regenerated.
if [[ -d /etc/nginx/modsec ]]; then
    cp -a /etc/nginx/modsec "$BACKUP_DIR/modsec"
fi

printf '==> Testing new NGINX binary against current configuration\n'

install -m 0755 "$TMPDIR/usr/sbin/nginx" /usr/sbin/nginx.new

# Dry-run: validate current config with new binary before swap.
if ! /usr/sbin/nginx.new -t; then
    rm -f /usr/sbin/nginx.new
    die "New NGINX binary failed configuration test; current installation left untouched"
fi

printf '==> Installing new NGINX binary\n'

mv -f /usr/sbin/nginx.new /usr/sbin/nginx

printf '==> Updating dynamic modules\n'

install -d -o root -g root -m 0755 /usr/lib/nginx/modules

for module in "${MODULES[@]}"; do
    install -m 0755 "$TMPDIR/usr/lib/nginx/modules/$module" \
        "/usr/lib/nginx/modules/$module"
done

# Standard nginx packaging convention: configs reference
# /etc/nginx/modules; symlink to the real module dir.
ln -sfn /usr/lib/nginx/modules /etc/nginx/modules

printf '==> Updating libModSecurity\n'

install -d -o root -g root -m 0755 /usr/local/modsecurity/lib
modsecurity_so="$(find "$TMPDIR/usr/local/modsecurity/lib" -maxdepth 1 \
    -name 'libmodsecurity.so.*.*.*' -print -quit)"
[[ -n "$modsecurity_so" ]] ||
    die "versioned libmodsecurity.so missing from archive"
install -m 0755 "$modsecurity_so" "/usr/local/modsecurity/lib/$(basename "$modsecurity_so")"
ln -sfn "$(basename "$modsecurity_so")" /usr/local/modsecurity/lib/libmodsecurity.so.3
ln -sfn libmodsecurity.so.3 /usr/local/modsecurity/lib/libmodsecurity.so

if [[ -f "$TMPDIR/usr/local/modsecurity/unicode.mapping" ]]; then
    install -m 0644 "$TMPDIR/usr/local/modsecurity/unicode.mapping" \
        /usr/local/modsecurity/unicode.mapping
fi

printf '==> Updating ModSecurity + OWASP CRS configuration\n'

# Preserve user override.conf across upgrade.
user_override=""
if [[ -f /etc/nginx/modsec/override.conf ]]; then
    user_override="$(mktemp)"
    cp -a /etc/nginx/modsec/override.conf "$user_override"
fi

if [[ -d "$TMPDIR/etc/nginx/modsec" ]]; then
    install -d -o root -g root -m 0755 /etc/nginx/modsec
    cp -a "$TMPDIR/etc/nginx/modsec/." /etc/nginx/modsec/
fi

if [[ -n "$user_override" ]]; then
    install -m 0644 "$user_override" /etc/nginx/modsec/override.conf
    rm -f "$user_override"
fi

printf '==> Updating NGINX support files\n'

for file in "${SUPPORT_FILES[@]}"; do
    [[ -f "$TMPDIR/etc/nginx/$file" ]] || continue
    install -m 0644 "$TMPDIR/etc/nginx/$file" "/etc/nginx/$file"
done

printf '==> Final configuration test\n'

/usr/sbin/nginx -t

printf '==> Reloading NGINX\n'

systemctl reload-or-restart nginx

printf '\nNGINX upgrade completed successfully.\n'
/usr/sbin/nginx -V
