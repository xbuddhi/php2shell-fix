# php2shell-fix

Find every PHP installation on a Linux server and fix **CVE-2026-109618** and
**CVE-2026-109619** ("php2shell"), two critical unauthenticated remote code execution bugs
in PHP core disclosed on 2026-10-21.

It's built for servers where PHP comes from more than one place, such as a VPS with a
control panel that compiles its own PHP next to the distro's packages. Panels like aaPanel
compile PHP from source, so `apt`/`yum` updates never reach those copies.

**This project contains no security code of its own.** It only applies fixes published by
the PHP project and by your OS vendor.

## What it does with each install

| Install type | Examples | Fix |
|---|---|---|
| Package (`dpkg`/`rpm` owns the binary) | Ubuntu/Debian, ondrej/sury, RHEL/Alma/Rocky, remi, cPanel EA-PHP, Plesk, LiteSpeed `lsphp`, CloudLinux alt-php | `apt-get install --only-upgrade` / `dnf upgrade` of the installed PHP packages |
| Source build, PHP 8.2–8.5 | aaPanel / BT Panel `/www/server/php/NN`, DirectAdmin `/usr/local/phpNN`, `/opt/php*` | Rebuilt as 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 from php.net |
| Source build, PHP 7.4 / 8.0 / 8.1 (EOL) | same | Rebuilt as 7.4.33 / 8.0.30 / 8.1.34 + the PHP security team's official backport (`patches/`) |
| PHP 7.0 – 7.3, 5.x | any | **Reported only. No official fix exists.** Move those sites to PHP 8.2+. |

Installs are found from `PATH`, the usual panel and vendor locations under `/opt`,
`/usr/local` and `/www/server`, and from running processes. Only root-owned binaries are
inspected.

A package counts as fixed if its version is at least the fixed upstream release, or its
changelog mentions the CVEs. Distro backports such as Ubuntu ESM keep the old version
number, so the changelog check is what catches them.

## Usage

```bash
git clone https://github.com/xbuddhi/php2shell-fix.git
cd php2shell-fix
sudo ./php2shell-fix.sh                 # report only, changes nothing
sudo ./php2shell-fix.sh --apply         # fix everything it can
sudo ./php2shell-fix.sh --apply --only 7.4,/www/server/php/83   # by branch or install path
sudo ./php2shell-fix.sh --apply --no-restart   # install now, restart services yourself
```

The exit code is 0 only when every PHP found is fixed, so you can run it from config management.

### Source rebuilds, step by step

1. Download the release tarball from php.net and check its pinned sha256.
2. For EOL branches, check the bundled patch's sha256 and apply it.
3. Run `configure` with the install's own `php-config --configure-options`, then `make`.
4. Copy the whole install to `<prefix>.bak-<version>-<timestamp>`.
5. Run `make install`. Rebuild any shared extensions that ship with PHP (`mbstring.so`, `zip.so`, …).
   Third-party extensions (redis, imagick, …) are left alone, since the ABI is unchanged.
6. Check the FPM config with `php-fpm -t`, restart the systemd units running that install,
   and confirm they come back up.

If anything fails after the backup, the backup is restored and the services restarted.
A rebuild takes ~10–20 minutes per version on 2 cores and needs ~3 GB of free disk
(`WORK=/path` picks the build directory).

The script only rebuilds a prefix dedicated to PHP: its path contains `php` and it has a
`php-config`. A PHP built straight into `/usr/local` is reported, not touched.

### Restarts

After upgrading or rebuilding, the script looks for processes still running a replaced PHP
binary or `libphp*.so` (php-fpm, php-cgi, lsphp, Apache mod_php, long-running PHP workers).
It restarts the systemd unit each one belongs to. Processes outside systemd are listed for
you to restart.

**php-fpm is reloaded rather than restarted.** The master re-executes the new binary and
keeps its listening socket, so new requests wait instead of getting a 502. Requests already
running get `process_control_timeout` to finish; the default is 0, so set it (e.g. `10s`)
for a fully graceful swap. If an FPM is still on the old binary 30 s after the reload, it
gets a full restart.

Only the php-fpm path has been exercised on a real server so far. The php-cgi, lsphp and
mod_php paths use the same detection but are untested.

## Things to know

- **Session upload progress is disabled** by the EOL backports, whatever
  `session.upload_progress.enabled` says. This is upstream's choice: it removes the confirmed
  exploitation path on FPM. Progress bars that rely on it stop updating; uploads still work.
- **The EOL backports are minimal.** The PHP team calls them a mitigation for end-of-life
  versions. They lack the full hardening in the supported releases, and 7.4/8.0/8.1 still
  miss every other fix since they went EOL. Move to 8.2+ as soon as you can.
- **Distro EOL PHP may have no free fix.** Ubuntu 20.04's PHP 7.4 is only fixed through
  Ubuntu Pro (ESM); Debian 11's only through Freexian ELTS. The script tells you when no fixed
  package is available.
- **Panels:** don't use the panel's own PHP update or reinstall for these versions afterwards.
  It would rebuild them without the fix. Patched EOL source installs are marked with
  `<prefix>/.php2shell-patched`.
- **Not covered:** Docker containers (rebuild on fixed images), Windows, and mod_php built
  from source. The script warns when it sees these.

### Tested on

- Ubuntu 20.04 + aaPanel 8.0.5 (PHP 7.4 and 8.3 source builds): full `--apply` run on
  PHP 7.4 under live traffic, with the FPM swapped by reload. 4,022 probe requests
  during the run, 0 failed.

The package-manager paths (apt, dnf/yum) are implemented but not yet tested on a real
server. Run without `--apply` first and check the report. Reports from other setups are welcome.

## Verifying the patches yourself

The files in `patches/` are unmodified `git format-patch` output of these signed commits in
[php/php-src](https://github.com/php/php-src):

| File | Branch | Commit |
|---|---|---|
| `php-7.4.patch` | `PHP-7.4-CVE-2026-109618-109619` | `712e60f9edfd03f0960fc4fc3c2c375f42b90aa2` |
| `php-8.0.patch` | `PHP-8.0-CVE-2026-109618-109619` | `82f8f31b16a035c1b67cc253e79f7cc288f4cc20` |
| `php-8.1.patch` | `PHP-8.1-CVE-2026-109618-109619` | `1d7dec178a094e6e75b229ce22754045f8c6070a` |

```bash
# each pair of patch ids must be identical
for p in 7.4:712e60f9ed 8.0:82f8f31b16 8.1:1d7dec178a; do
  git patch-id < patches/php-${p%:*}.patch | cut -d' ' -f1
  curl -sL https://github.com/php/php-src/commit/${p#*:}.patch | git patch-id | cut -d' ' -f1
done
```

## References

- [GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w) (CVE-2026-109618)
- [GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp) (CVE-2026-109619)
- [CISA alert, 2026-10-21](https://www.cisa.gov/news-events/alerts/2026/10/21/critical-vulnerabilities-php-require-immediate-patching)

## License

The script is MIT licensed (see `LICENSE`). The files in `patches/` are derived from PHP and
remain under the PHP License v3.01 (`patches/LICENSE.PHP`).
Not affiliated with the PHP Group or any panel vendor.
