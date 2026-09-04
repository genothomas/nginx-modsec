# Contributing

## Publishing a release

CI builds and verifies, but does not publish automatically. A maintainer
explicitly publishes the verified artifacts.

This separation keeps the release artifact identical to what the build
verified.

Requires the `gh` CLI authenticated against the repository.

### Mainline releases

After a successful `workflow_dispatch` run with `nginx_channel: mainline`,
download the architecture-specific artifacts and create the release.

Download the artifacts:

```bash
RUN_ID=$(gh run list --workflow=build.yml --json databaseId --jq '.[0].databaseId')

gh run download "$RUN_ID" --name nginx-modsec-mainline-amd64 --dir release-assets/amd64
gh run download "$RUN_ID" --name nginx-modsec-mainline-arm64 --dir release-assets/arm64
```

Create the combined checksum file:

```bash
cd release-assets
sha256sum amd64/nginx-modsec-mainline-*.tar.gz \
          arm64/nginx-modsec-mainline-*.tar.gz \
    > SHA256SUMS
```

Generate release notes from `build/versions.env`:

```bash
source build/versions.env

cat > release-notes.md <<EOF
NGINX: ${NGINX_MAINLINE_VERSION}
Channel: mainline

Linux amd64 and arm64 tarballs are provided.

Versions:
- NGINX: ${NGINX_MAINLINE_VERSION}
- OpenSSL: ${OPENSSL_VERSION}
- PCRE2: ${PCRE2_VERSION}
- libModSecurity: ${LIBMODSECURITY_VERSION}
- ModSecurity-nginx: ${MODSECURITY_NGINX_VERSION}
- GeoIP2 nginx module: ${GEOIP2_MODULE_VERSION}
- Headers-More: ${HEADERS_MORE_VERSION}
- OWASP CRS: ${CRS_VERSION}

Included:
- HTTP/2
- HTTP/3
- PCRE2 JIT
- ModSecurity
- GeoIP2
- Headers-More

Verify downloads with SHA256SUMS.
EOF
```

Publish:

```bash
VERSION="${NGINX_MAINLINE_VERSION}"

gh release create "v${VERSION}-mainline" \
    release-assets/amd64/nginx-modsec-mainline-*.tar.gz \
    release-assets/arm64/nginx-modsec-mainline-*.tar.gz \
    release-assets/SHA256SUMS \
    --title "NGINX ${VERSION} (mainline)" \
    --notes-file release-notes.md
```

### Stable releases

Tag a commit with `v<NGINX_STABLE_VERSION>` and push. The release job in the
build workflow runs automatically on tag push and publishes the release.

The release job validates that the tag matches `NGINX_STABLE_VERSION` from
`build/versions.env` and fails otherwise.
