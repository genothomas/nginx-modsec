#!/usr/bin/env bash
# Print a friendly before→after diff of build/versions.env for the
# upstream-update PR body. Skips keys that did not change. Output is
# grouped by component category. Output format is "old → new".
#
# Usage: diff-versions.sh <before.env> <after.env>
#   before.env: snapshot from BEFORE the update (older pins)
#   after.env:  snapshot from AFTER the update (newer pins)
#   Convention: pass the older file first, newer file second.
#   Inverted args will print "newer → older" which reads backwards.

set -Eeuo pipefail

usage() {
    printf 'Usage: %s <before.env> <after.env>\n' "${0##*/}" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage

before="$1"
after="$2"

[[ -f "$before" ]] || { printf 'ERROR: file not found: %s\n' "$before" >&2; exit 1; }
[[ -f "$after"  ]] || { printf 'ERROR: file not found: %s\n' "$after"  >&2; exit 1; }

get() {
    local file="$1" key="$2" value

    value="$(
        awk -F= -v key="$key" '
            $1 == key {
                value = $0
                sub(/^[^=]+=/, "", value)
                gsub(/^"|"$/, "", value)
                print value
                found = 1
                exit
            }
            END { if (!found) exit 1 }
        ' "$file"
    )" || { printf 'ERROR: missing key %s in %s\n' "$key" "$file" >&2; exit 1; }

    printf '%s\n' "$value"
}

emit() {
    local heading="$1"
    shift

    local first=1 label key old new

    while [[ $# -ge 2 ]]; do
        label="$1"
        key="$2"
        shift 2

        old="$(get "$before" "$key")"
        new="$(get "$after"  "$key")"

        [[ "$old" == "$new" ]] && continue
        [[ -n "$new" ]] || continue

        if (( first )); then
            printf '%s:\n' "$heading"
            first=0
        fi

        if [[ -n "$label" ]]; then
            printf '  %s: %s → %s\n' "$label" "$old" "$new"
        else
            printf '  %s → %s\n' "$old" "$new"
        fi
    done

    if [[ $first -eq 0 ]]; then printf '\n'; fi
}

emit "NGINX" \
    "stable"   "NGINX_STABLE_VERSION" \
    "mainline" "NGINX_MAINLINE_VERSION"

emit "OpenSSL" \
    "" "OPENSSL_VERSION"

emit "PCRE2" \
    "" "PCRE2_VERSION"

emit "ModSecurity" \
    "libModSecurity"              "LIBMODSECURITY_VERSION" \
    "ModSecurity-nginx connector" "MODSECURITY_NGINX_VERSION"

emit "OWASP CRS" \
    "" "CRS_VERSION"

emit "Dynamic modules" \
    "GeoIP2"       "GEOIP2_MODULE_VERSION" \
    "headers-more" "HEADERS_MORE_VERSION"
