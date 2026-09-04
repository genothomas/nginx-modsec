#!/usr/bin/env bash
set -Eeuo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2154  # $? is bound to rc at trap entry by bash
trap 'rc=$?; printf "ERROR: command failed (rc=%d, line=%d): %s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

usage() {
    cat <<'EOF'
Usage:
  sudo ./install.sh /path/to/nginx-modsec-<version>-<channel>-linux-<arch>.tar.gz

Installs the custom NGINX build on a new Ubuntu/Debian-style system
(uses apt-get and dpkg; RHEL/Fedora/Arch not supported).

Existing /etc/nginx/nginx.conf is never overwritten. A starter config
(deploy/nginx.conf.default) is installed only when no config is present.
EOF
}

[[ $# -eq 1 ]] || { usage; exit 2; }

ARCHIVE="$1"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="$SCRIPT_DIR/nginx.service"
LOGROTATE_FILE="$SCRIPT_DIR/nginx.logrotate"
CONF_DEFAULT="$SCRIPT_DIR/nginx.conf.default"
SITE_DEFAULT="$SCRIPT_DIR/00-default.conf"

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

for f in "$SERVICE_FILE" "$LOGROTATE_FILE" "$CONF_DEFAULT" "$SITE_DEFAULT"; do
    [[ -f "$f" ]] || die "Missing deploy file: $f"
done

EXPECTED_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$EXPECTED_ARCH" in
    amd64|arm64) ;;
    *) die "Unsupported host architecture: $EXPECTED_ARCH" ;;
esac

[[ "$ARCHIVE_NAME" == *"linux-${EXPECTED_ARCH}.tar.gz" ]] ||
    die "Archive architecture does not match host: expected ${EXPECTED_ARCH}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

printf '==> Extracting %s\n' "$ARCHIVE_NAME"

# Defense-in-depth: refuse archives with absolute paths or .. components
# (path-traversal). Archives are built by trusted CI, but cheap to verify.
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

printf '==> Installing runtime dependencies\n'

apt-get update
apt-get install -y --no-install-recommends \
    libcurl4 liblmdb0 libmaxminddb0 libxml2 libyajl2 zlib1g

printf '==> Creating nginx user/group\n'

getent group nginx >/dev/null || groupadd --system nginx

if ! id nginx >/dev/null 2>&1; then
    useradd --system --gid nginx --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin nginx
fi

printf '==> Creating required runtime directories\n'

for dir in /etc/nginx /etc/nginx/conf.d /etc/nginx/modsec \
    /usr/lib/nginx/modules /usr/local/modsecurity/lib /var/log/nginx
do
    install -d -o root -g root -m 0755 "$dir"
done
install -d -o nginx -g nginx -m 0750 /var/cache/nginx
install -d -o nginx -g nginx -m 0750 /var/log/nginx/modsec

printf '==> Installing NGINX runtime\n'

install -m 0755 "$TMPDIR/usr/sbin/nginx" /usr/sbin/nginx
cp -a "$TMPDIR/usr/lib/nginx/modules/." /usr/lib/nginx/modules/
cp -a "$TMPDIR/usr/local/modsecurity/lib/." /usr/local/modsecurity/lib/

# unicode.mapping + CRS config tree.
if [[ -f "$TMPDIR/usr/local/modsecurity/unicode.mapping" ]]; then
    install -m 0644 "$TMPDIR/usr/local/modsecurity/unicode.mapping" \
        /usr/local/modsecurity/unicode.mapping
fi
if [[ -d "$TMPDIR/etc/nginx/modsec" ]]; then
    cp -a "$TMPDIR/etc/nginx/modsec/." /etc/nginx/modsec/
fi

printf '==> Installing NGINX support files\n'

for file in "${SUPPORT_FILES[@]}"; do
    [[ -f "$TMPDIR/etc/nginx/$file" ]] || continue
    install -m 0644 "$TMPDIR/etc/nginx/$file" "/etc/nginx/$file"
done

printf '==> Installing logrotate config\n'

install -m 0644 "$LOGROTATE_FILE" /etc/logrotate.d/nginx

printf '==> Installing starter nginx.conf (if missing)\n'

if [[ ! -e /etc/nginx/nginx.conf ]]; then
    install -m 0644 "$CONF_DEFAULT" /etc/nginx/nginx.conf
    printf '    installed starter config — review and customize before exposing to traffic\n'
else
    printf '    /etc/nginx/nginx.conf already exists; leaving untouched\n'
fi

printf '==> Installing default site (if conf.d is empty)\n'

if [[ -z "$(ls /etc/nginx/conf.d/*.conf 2>/dev/null)" ]]; then
    install -m 0644 "$SITE_DEFAULT" /etc/nginx/conf.d/00-default.conf
    printf '    installed default-reject on :80/:443 — replace before exposing traffic\n'
else
    printf '    /etc/nginx/conf.d/ already populated; skipping default site\n'
fi

printf '==> Installing systemd service\n'

install -m 0644 "$SERVICE_FILE" /usr/lib/systemd/system/nginx.service
systemctl daemon-reload

printf '==> Checking installed binary and configuration\n'

/usr/sbin/nginx -V
/usr/sbin/nginx -t

printf '==> Enabling and starting NGINX\n'

systemctl enable nginx
systemctl start nginx

printf '\nNGINX installation completed successfully.\n'
systemctl --no-pager --full status nginx
