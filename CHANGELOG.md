# Changelog

## 0.4.0

**Build pipeline:**
- Migrate workdir `/build` → `/opt/nginx`
- Rename `build.sh` → `ngx.sh`; consolidate shared curl wrapper
- `scripts/curl.sh` → `scripts/common.sh` with shared `log`/`die`; drop the
  per-script copies
- PCRE2 version masking via `--strip-components=1` into `pcre2-src/`
- `STRICT_SOURCE_VERIFY=1` fail-closed for empty + empty-input-sentinel pins
- ERR + EXIT traps with line/command context
- Whitelist-based RPATH/RUNPATH leak detection
- `make -C` for build/install (no cwd dependence)
- Timeout-minutes on build (25), release (10), update (10)
- Backup + restore `versions.env` on update failures

**Deploy:**
- `install.sh` + `upgrade.sh` with logrotate, SHA256 verify, ERR trap,
  reload-or-restart, starter config + default site auto-install
- Backup modules + libModSecurity for rollback in `upgrade.sh`

**Repository:**
- Trim `lib/` → `scripts/`; drop dead `build/modules.json` and `config/`
- `.gitignore`, `README.md`, `CHANGELOG.md` cleaned

## 0.3.0

- Build native amd64 and arm64 artifacts.
- Use GitHub-hosted `ubuntu-24.04` for amd64 and `ubuntu-24.04-arm` for arm64.
- Add channel x architecture matrix to the build workflow.
- Separate artifacts by NGINX channel and architecture.
- Make PCRE2 an explicit source dependency and enable PCRE JIT.
- Keep Brotli omitted.
- Keep NGINX stream omitted for HAProxy-based L4.
- Add weekly/manual upstream PR workflow.
- Keep OpenSSL independently reviewed rather than blindly auto-bumped.
