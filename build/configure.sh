#!/usr/bin/env bash
set -Eeuo pipefail

: "${NGINX_SRC:?}"
: "${BUILD_ROOT:?}"
: "${PCRE2_PATH:?}"
: "${MODSECURITY_NGINX_PATH:?}"
: "${GEOIP2_PATH:?}"
: "${HEADERS_MORE_PATH:?}"

cd "$NGINX_SRC"

./configure \
  --prefix=/etc/nginx \
  --sbin-path=/usr/sbin/nginx \
  --modules-path=/usr/lib/nginx/modules \
  --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log \
  --http-log-path=/var/log/nginx/access.log \
  --pid-path=/run/nginx.pid \
  --lock-path=/run/nginx.lock \
  --http-client-body-temp-path=/var/cache/nginx/client_temp \
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
  --user=nginx \
  --group=nginx \
  --build="${NGINX_CHANNEL}" \
  --with-compat \
  --with-threads \
  --with-pcre="$PCRE2_PATH" \
  --with-pcre-jit \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_v3_module \
  --with-http_realip_module \
  --with-http_auth_request_module \
  --with-http_secure_link_module \
  --with-http_gzip_static_module \
  --with-http_gunzip_module \
  --with-http_sub_module \
  --with-http_stub_status_module \
  --add-dynamic-module="$MODSECURITY_NGINX_PATH" \
  --add-dynamic-module="$GEOIP2_PATH" \
  --add-dynamic-module="$HEADERS_MORE_PATH" \
  --with-cc-opt="-O2 -fstack-protector-strong -fPIE -fPIC -Wformat -Werror=format-security -I$BUILD_ROOT/openssl/include" \
  --with-ld-opt="-Wl,-z,relro,-z,now,-z,noexecstack -Wl,--as-needed -pie -L$BUILD_ROOT/openssl/lib -Wl,-Bstatic -lssl -lcrypto -Wl,-Bdynamic -ldl -lpthread"
