# nginx-modsec

[![Build NGINX + ModSecurity](https://github.com/genothomas/nginx-modsec/actions/workflows/build.yml/badge.svg)](https://github.com/genothomas/nginx-modsec/actions/workflows/build.yml)

Independent third-party NGINX Open Source builds with OWASP ModSecurity v3 and OWASP CRS.

Not affiliated with, sponsored by, or endorsed by F5, NGINX, or OWASP.
"NGINX" is a registered trademark of F5.

## What's included

- NGINX Open Source
- ModSecurity v3 and OWASP CRS
- Static OpenSSL and PCRE2 with PCRE2 JIT
- HTTP/2 and HTTP/3
- GeoIP2 and Headers-More modules
- Hardened build flags
- Reproducible tarballs with SHA256 checksums
- `amd64` and `arm64`
- Stable and mainline releases

## Build

```bash
sudo mkdir -p /opt/nginx
sudo chown "$USER:$USER" /opt/nginx

NGINX_CHANNEL=stable ./scripts/build-local.sh
```

Set `NGINX_CHANNEL=mainline` to build the mainline release.

Builds are placed under:

```text
/opt/nginx/dist/<channel>/<arch>/
```

## Install

```bash
sudo ./deploy/install.sh /opt/nginx/dist/stable/*/nginx-modsec-*.tar.gz
```

The installer preserves an existing NGINX configuration. On a fresh install, it
provides a minimal config and a default catch-all that rejects unmatched
HTTP and HTTPS requests.

The release tarball does not include `nginx.conf`; deployment owns the main
NGINX configuration.

## ModSecurity

ModSecurity and CRS are installed and ready to use, but are not enabled
globally by default.

Enable them where needed:

```nginx
modsecurity on;
modsecurity_rules_file /etc/nginx/modsec/main.conf;
```

CRS is configured in `DetectionOnly` by default, so you can review and tune
the rules before switching to blocking.

## Upgrade

```bash
sudo ./deploy/upgrade.sh /path/to/nginx-modsec-*.tar.gz
```

The upgrader verifies the checksum, backs up the current runtime, checks the
new configuration, and validates the new runtime and gracefully reloads NGINX.

## Updating versions

```bash
./build/update-versions.sh
```

GitHub Actions can automatically update pinned upstream versions and SHA256
checksums in a pull request.

## Build workspace

```text
/opt/nginx/
├── src/
│   └── <channel>-<arch>/
├── stage/
│   └── <channel>-<arch>/
├── dist/
│   └── <channel>/
│       └── <arch>/
└── openssl/
```

See `NOTICE` for upstream copyright and license information.

## License

BSD 2-Clause License. See `LICENSE`.

## Contributing

See `CONTRIBUTING.md` for maintainer operations including publishing releases.

## Requirements

- Ubuntu/Debian with systemd
- `/opt/nginx` writable by the build user
- `sudo` for dependency installation (set `SKIP_APT=1` to skip)
