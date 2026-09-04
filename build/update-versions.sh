#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="$ROOT/build/versions.env"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

log "Resolving upstream versions..."

TMP="$(mktemp -d)"
TMP_VERSIONS="$(mktemp "${VERSIONS}.tmp.XXXXXX")"
trap 'rm -rf "$TMP"; rm -f "$TMP_VERSIONS"' EXIT

# Newest non-prerelease tag, or nothing.
latest_tag() {
    local repo="$1" tag=""

    tag="$(
        git ls-remote --refs --tags "https://github.com/${repo}.git" |
        awk '{print $2}' |
        sed 's#refs/tags/##' |
        grep -E '^[vV]?[0-9]+(\.[0-9]+){1,3}([.-][0-9A-Za-z]+)*$' |
        grep -Ev '(^|[.-])(alpha|beta|rc|dev|devel|pre|test)([.-]|$)' |
        sort -V | tail -1
    )"

    [[ -n "$tag" ]] || return 1
    printf '%s\n' "$tag"
}

# validate_override <override-var> <pattern>: fail loud on malformed operator input.
# Catches typos before any network calls.
validate_override() {
    local override_var="$1" pattern="$2"
    local value="${!override_var:-}"

    [[ -z "$value" ]] && return 0
    [[ "$value" =~ $pattern ]] ||
        die "${override_var}='${value}' does not match expected pattern: ${pattern}"
}

# resolve <override-var> <repo>: prefer $override_var, else query latest tag.
# Strips optional leading v/V so URL templates can hardcode the prefix.
resolve() {
    local override_var="$1" repo="$2"
    local tag=""

    if [[ -n "${!override_var:-}" ]]; then
        tag="${!override_var}"
    else
        tag="$(latest_tag "$repo")" ||
            die "could not resolve tag for $repo (set ${override_var} to override)"
    fi

    printf '%s\n' "${tag#[vV]}"
}

latest_in_series() {
    local repo="$1" pattern="$2" strip_prefix="$3" tag=""

    tag="$(
        git ls-remote --refs --tags "https://github.com/${repo}.git" |
            awk '{print $2}' |
            sed 's#refs/tags/##' |
            grep -E "$pattern" |
            sort -V | tail -1
    )"

    [[ -n "$tag" ]] || return 1
    printf '%s\n' "${tag#"$strip_prefix"}"
}

compute_sha256() {
    local url="$1"
    local file
    file="$TMP/$(basename "$url")"

    curl_strict "$url" > "$file" || die "compute_sha256: download failed: $url"
    [[ -s "$file" ]] || die "compute_sha256: empty body for: $url"

    sha256_of "$file"
}

emit_labeled() {
    printf '%-18s %s\n' "$1" "$2"
}

# Fail loud on malformed operator input before any network calls.
validate_override NGINX_STABLE_VERSION_OVERRIDE '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_override NGINX_MAINLINE_VERSION_OVERRIDE '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_override OPENSSL_VERSION_OVERRIDE '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_override MODSECURITY_VERSION_OVERRIDE '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_override MODSECURITY_NGINX_VERSION_OVERRIDE '^[0-9]+\.[0-9]+\.[0-9]+$'
validate_override GEOIP2_MODULE_VERSION_OVERRIDE '^[0-9]+\.[0-9]+$'
validate_override HEADERS_MORE_VERSION_OVERRIDE '^[0-9]+\.[0-9]+$'
validate_override PCRE2_VERSION_OVERRIDE '^[0-9]+\.[0-9]+$'
validate_override CRS_VERSION_OVERRIDE '^[0-9]+\.[0-9]+\.[0-9]+$'

# Only releases with a .tar.gz asset count (some tags are pushed without one).
mapfile -t nginx_versions < <(
    curl_strict "https://api.github.com/repos/nginx/nginx/releases?per_page=100" |
        jq -r '.[] | select(.assets[]?.name | endswith(".tar.gz")) | .tag_name' |
        sed -nE 's#^release-([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' |
        sort -V -u
)
(( ${#nginx_versions[@]} > 0 )) || die "no NGINX releases found"

stable="${NGINX_STABLE_VERSION_OVERRIDE:-$(printf '%s\n' "${nginx_versions[@]}" | awk -F. '$1 == 1 && $2 % 2 == 0' | tail -1)}"
mainline="${NGINX_MAINLINE_VERSION_OVERRIDE:-$(printf '%s\n' "${nginx_versions[@]}" | awk -F. '$1 == 1 && $2 % 2 == 1' | tail -1)}"

# Auto-track OpenSSL 3.5.x LTS; OPENSSL_VERSION_OVERRIDE escapes.
openssl="${OPENSSL_VERSION_OVERRIDE:-$(latest_in_series openssl/openssl '^openssl-3\.5\.[0-9]+$' openssl- || die "could not resolve OpenSSL 3.5.x LTS (set OPENSSL_VERSION_OVERRIDE to override)")}"

[[ -n "$stable" ]] || die "could not resolve NGINX stable version"
[[ -n "$mainline" ]] || die "could not resolve NGINX mainline version"

modsec="$(resolve MODSECURITY_VERSION_OVERRIDE owasp-modsecurity/ModSecurity)"
modsec_nginx="$(resolve MODSECURITY_NGINX_VERSION_OVERRIDE owasp-modsecurity/ModSecurity-nginx)"
geoip="$(resolve GEOIP2_MODULE_VERSION_OVERRIDE leev/ngx_http_geoip2_module)"
headers="$(resolve HEADERS_MORE_VERSION_OVERRIDE openresty/headers-more-nginx-module)"
pcre2="${PCRE2_VERSION_OVERRIDE:-$(latest_in_series PCRE2Project/pcre2 '^pcre2-[0-9]+\.[0-9]+$' pcre2- || die "could not resolve PCRE2 tag (set PCRE2_VERSION_OVERRIDE to override)")}"
# Auto-track OWASP CRS 4.25.x LTS; CRS_VERSION_OVERRIDE escapes.
crs="${CRS_VERSION_OVERRIDE:-$(latest_in_series coreruleset/coreruleset '^v?4\.25\.[0-9]+$' v || die "could not resolve CRS 4.25.x LTS (set CRS_VERSION_OVERRIDE to override)")}"

printf '\n'
emit_labeled "NGINX stable:"      "$stable"
emit_labeled "NGINX mainline:"    "$mainline"
emit_labeled "OpenSSL:"           "$openssl"
emit_labeled "PCRE2:"             "$pcre2"
emit_labeled "ModSecurity:"       "$modsec"
emit_labeled "ModSecurity-nginx:" "$modsec_nginx"
emit_labeled "GeoIP2:"            "$geoip"
emit_labeled "Headers-More:"      "$headers"
emit_labeled "OWASP CRS:"         "$crs"

log "Calculating source checksums..."

NGINX_STABLE_SHA256="$(compute_sha256 "https://github.com/nginx/nginx/releases/download/release-${stable}/nginx-${stable}.tar.gz")"
NGINX_MAINLINE_SHA256="$(compute_sha256 "https://github.com/nginx/nginx/releases/download/release-${mainline}/nginx-${mainline}.tar.gz")"
OPENSSL_SHA256="$(compute_sha256 "https://github.com/openssl/openssl/releases/download/openssl-${openssl}/openssl-${openssl}.tar.gz")"
PCRE2_SHA256="$(compute_sha256 "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre2}/pcre2-${pcre2}.tar.gz")"
HEADERS_MORE_SHA256="$(compute_sha256 "https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v${headers}.tar.gz")"
GEOIP2_MODULE_SHA256="$(compute_sha256 "https://github.com/leev/ngx_http_geoip2_module/archive/refs/tags/${geoip}.tar.gz")"
LIBMODSECURITY_SHA256="$(compute_sha256 "https://github.com/owasp-modsecurity/ModSecurity/releases/download/v${modsec}/modsecurity-v${modsec}.tar.gz")"
MODSECURITY_NGINX_SHA256="$(compute_sha256 "https://github.com/owasp-modsecurity/ModSecurity-nginx/releases/download/v${modsec_nginx}/ModSecurity-nginx-v${modsec_nginx}.tar.gz")"
CRS_SHA256="$(compute_sha256 "https://github.com/coreruleset/coreruleset/releases/download/v${crs}/coreruleset-${crs}-minimal.tar.gz")"

for hash in \
    "$NGINX_STABLE_SHA256" "$NGINX_MAINLINE_SHA256" \
    "$OPENSSL_SHA256" "$PCRE2_SHA256" \
    "$HEADERS_MORE_SHA256" "$GEOIP2_MODULE_SHA256" \
    "$LIBMODSECURITY_SHA256" "$MODSECURITY_NGINX_SHA256" \
    "$CRS_SHA256"
do
    [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] ||
        die "invalid SHA256 generated by updater: $hash"
done

python3 - "$VERSIONS" "$TMP_VERSIONS" "$stable" "$openssl" "$mainline" "$modsec" "$modsec_nginx" \
    "$geoip" "$headers" "$pcre2" "$crs" "$NGINX_STABLE_SHA256" "$NGINX_MAINLINE_SHA256" \
    "$OPENSSL_SHA256" "$PCRE2_SHA256" "$HEADERS_MORE_SHA256" "$GEOIP2_MODULE_SHA256" \
    "$LIBMODSECURITY_SHA256" "$MODSECURITY_NGINX_SHA256" "$CRS_SHA256" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(sys.argv[2])

values = {
    "NGINX_STABLE_VERSION": sys.argv[3],
    "OPENSSL_VERSION": sys.argv[4].removeprefix("openssl-"),
    "NGINX_MAINLINE_VERSION": sys.argv[5],
    "LIBMODSECURITY_VERSION": sys.argv[6].removeprefix("v"),
    "MODSECURITY_NGINX_VERSION": sys.argv[7].removeprefix("v"),
    "GEOIP2_MODULE_VERSION": sys.argv[8].removeprefix("v"),
    "HEADERS_MORE_VERSION": sys.argv[9].removeprefix("v"),
    "PCRE2_VERSION": sys.argv[10].removeprefix("v"),
    "CRS_VERSION": sys.argv[11].removeprefix("v"),
    "NGINX_STABLE_SHA256": sys.argv[12],
    "NGINX_MAINLINE_SHA256": sys.argv[13],
    "OPENSSL_SHA256": sys.argv[14],
    "PCRE2_SHA256": sys.argv[15],
    "HEADERS_MORE_SHA256": sys.argv[16],
    "GEOIP2_MODULE_SHA256": sys.argv[17],
    "LIBMODSECURITY_SHA256": sys.argv[18],
    "MODSECURITY_NGINX_SHA256": sys.argv[19],
    "CRS_SHA256": sys.argv[20],
}

text = path.read_text(encoding="utf-8")

for key, value in values.items():
    text, count = re.subn(
        rf"^{re.escape(key)}=\"[^\"]*\"$",
        f'{key}="{value}"',
        text,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise SystemExit(f"ERROR: expected exactly one {key}=... in {path}, found {count}")

tmp.write_text(text, encoding="utf-8")
PY

if [[ "${VERBOSE:-0}" == "1" ]]; then
    log "Source checksums:"
    emit_labeled "NGINX stable:"      "$NGINX_STABLE_SHA256"
    emit_labeled "NGINX mainline:"    "$NGINX_MAINLINE_SHA256"
    emit_labeled "OpenSSL:"           "$OPENSSL_SHA256"
    emit_labeled "PCRE2:"             "$PCRE2_SHA256"
    emit_labeled "ModSecurity:"       "$LIBMODSECURITY_SHA256"
    emit_labeled "ModSecurity-nginx:" "$MODSECURITY_NGINX_SHA256"
    emit_labeled "GeoIP2:"            "$GEOIP2_MODULE_SHA256"
    emit_labeled "Headers-More:"      "$HEADERS_MORE_SHA256"
    emit_labeled "OWASP CRS:"         "$CRS_SHA256"
fi

if cmp -s "$VERSIONS" "$TMP_VERSIONS"; then
    rm -f "$TMP_VERSIONS"
    log "No changes."
    exit 0
fi

log "Updating ${VERSIONS#"$ROOT"/}..."
mv "$TMP_VERSIONS" "$VERSIONS"
log "Updated."
