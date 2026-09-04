# Contributing

## Publishing a release

CI builds and verifies artifacts but does not publish automatically. A
maintainer publishes the verified artifacts so the release matches what CI
verified.

Requires the `gh` CLI authenticated against the repository.

### Mainline releases

Trigger a `workflow_dispatch` run with `nginx_channel: mainline`. After it
succeeds:

```bash
RUN_ID=$(gh run list --workflow=build.yml --json databaseId --jq '.[0].databaseId')

gh run download "$RUN_ID" --name nginx-modsec-mainline-amd64 --dir release-assets/amd64
gh run download "$RUN_ID" --name nginx-modsec-mainline-arm64 --dir release-assets/arm64

(cd release-assets && \
    sha256sum amd64/nginx-modsec-mainline-*.tar.gz \
              arm64/nginx-modsec-mainline-*.tar.gz \
        > SHA256SUMS)

source build/versions.env
cat > release-notes.md <<EOF
## NGINX ${NGINX_MAINLINE_VERSION} — Mainline

Prebuilt NGINX Open Source binaries for Linux \`amd64\` and \`arm64\`.

### Included

- NGINX ${NGINX_MAINLINE_VERSION}
- OpenSSL ${OPENSSL_VERSION} (static)
- PCRE2 ${PCRE2_VERSION} with JIT
- ModSecurity v3 ${LIBMODSECURITY_VERSION}
- OWASP CRS ${CRS_VERSION}
- ModSecurity-nginx ${MODSECURITY_NGINX_VERSION}
- GeoIP2 nginx module ${GEOIP2_MODULE_VERSION}
- Headers-More ${HEADERS_MORE_VERSION}
- HTTP/2 and HTTP/3
EOF

VERSION="${NGINX_MAINLINE_VERSION}"
gh release create "v${VERSION}-mainline" \
    release-assets/amd64/nginx-modsec-mainline-*.tar.gz \
    release-assets/arm64/nginx-modsec-mainline-*.tar.gz \
    release-assets/SHA256SUMS \
    --title "NGINX ${VERSION} — Mainline" \
    --notes-file release-notes.md
```

### Stable releases

Tag a commit with `v<NGINX_STABLE_VERSION>` and push. The release job in
build.yml validates against `NGINX_STABLE_VERSION` from `build/versions.env`
and publishes the release.