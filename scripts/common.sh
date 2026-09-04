# shellcheck shell=bash
# Shared build helpers.
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

curl_strict() {
    curl --fail --silent --show-error --location \
        --retry 4 --retry-all-errors \
        --connect-timeout 30 --max-time 600 \
        --proto '=https' --tlsv1.2 \
        "$@"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "no SHA256 utility found (need sha256sum or shasum)"
    fi
}
