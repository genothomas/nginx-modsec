#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_CHANNEL="${NGINX_CHANNEL:-stable}"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
export NGINX_CHANNEL TARGET_ARCH
exec "$ROOT/build/ngx.sh"
