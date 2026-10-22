#!/usr/bin/env bash
# php2shell-fix.sh - find every PHP installation on this server and fix
# CVE-2026-109618 / CVE-2026-109619 ("php2shell").
#
# How each install is fixed depends on what owns it:
#   apt / dnf / yum packages   upgraded through the package manager (Debian, Ubuntu,
#                              ondrej/sury, RHEL family, remi, cPanel EA-PHP, Plesk, lsphp)
#   source builds              rebuilt from php.net with the install's own configure flags
#                              (aaPanel / BT Panel, DirectAdmin custombuild, /opt/php*, ...)
#     8.2 - 8.5                  fixed upstream release
#     7.4 - 8.1 (EOL)            final release + the PHP security team's official backport
#   7.0 - 7.3, 5.x             no official fix exists; reported only
#
# Default mode only reports. Nothing changes without --apply.
#
# Usage: php2shell-fix.sh [--apply] [--only <install|branch>,...] [--no-restart]

set -Eeuo pipefail   # -E so the rollback ERR trap also fires inside functions

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -d /www/server ]; then WORK=${WORK:-/www/server/php2shell-build}; else WORK=${WORK:-/var/tmp/php2shell-build}; fi
MARKER=.php2shell-patched
CVE_RE='CVE-2026-10961[89]'
BIN_RE='^(php|php-cgi|php-fpm|lsphp)[0-9.]*$'

APPLY=0
RESTART=1
ONLY=""
APPLIED=0

# branch -> "release tarball-sha256 [patch patch-sha256]"
# Tarball hashes are from https://www.php.net/releases/index.php?json&version=X
# Patches are the head commits of php-src branches PHP-X-CVE-2026-109618-109619.
declare -A TARGET=(
    [7.4]="7.4.33 5a2337996f07c8a097e03d46263b5c98d2c8e355227756351421003bea8f463e php-7.4.patch 5fe57ca6ee96d59b36c6e0ca842843c50884f177bef1e85234cf669b577f5e48"
    [8.0]="8.0.30 449d2048fcb20a314d8c218097c6d1047a9f1c5bb72aa54d5d3eba0a27a4c80c php-8.0.patch 534478c973cef6f493605b7af907f639a364912ee92c24598ddae44c3bc72d1c"
    [8.1]="8.1.34 3c5b060ec8e0d5dd1d8237823f3161cc8bc5342aab3c46893eba9857759c4bfa php-8.1.patch c85ad0fddcbff7f2318617eeaa54d271135463b5bf70a01228447e3ed78de96e"
    [8.2]="8.2.35 9db4204f0a2d1911277ae832185e07bb4c3b3559772753a70d2968ca346d6910"
    [8.3]="8.3.36 c93f3441f87f6ab156bef4432db215d7e61ca2c0183bb3a2aa28d9886ab59f53"
    [8.4]="8.4.27 5bafed9994c1a49796b25b5f61c22c9183bfe046b6acc7b363842d03c77f972f"
    [8.5]="8.5.12 81a0f450349e84b08eb43faa85f8a4c835684f3cc1c50471775d1317a046c525"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --apply)      APPLY=1 ;;
        --no-restart) RESTART=0 ;;
        --only)       ONLY=$2; shift ;;
        -h|--help)    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "run as root"

branch_of() { echo "${1%.*}"; }
ver_ge()    { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2

check_sha256() {  # file expected
    local got
    got=$(sha256sum "$1" | cut -d' ' -f1)
    [ "$got" = "$2" ] || die "checksum mismatch for $1 (got $got, expected $2)"
}

# ---------------------------------------------------------------- discovery

# Every PHP binary on PATH, in the usual panel/vendor locations, or currently running.
candidates() {
    local d p path
    {
        IFS=: read -ra path <<<"$PATH"
        for d in "${path[@]}" /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin; do
            ls -d "$d"/php* "$d"/lsphp* 2>/dev/null || true
        done
        find /opt /usr/local /www/server /usr/lib/cgi-bin -maxdepth 6 \( -type f -o -type l \) \
            -regextype posix-extended -regex '.*/(php|php-cgi|php-fpm|lsphp)[0-9.]*' 2>/dev/null || true
        for d in /proc/[0-9]*; do readlink "$d/exe" 2>/dev/null || true; done
    } | while read -r p; do
        p=$(readlink -f "$p" 2>/dev/null) || continue
        # Installed binaries live in bin/ or sbin/; this skips build trees (sapi/cli/php),
        # and our own backups and work dir are not installs either.
        [[ $(basename "$p") =~ $BIN_RE && $(basename "$(dirname "$p")") =~ ^(s?bin|cgi-bin)$ ]] || continue
        [[ $p == "$WORK"/* || $p == *.bak-*/* || $p == *.failed/* ]] && continue
        [ -f "$p" ] && [ -x "$p" ] && echo "$p"
    done | sort -u
}

# We run each binary with -v as root, so refuse ones a non-root user could have planted.
trusted() {
    local f
    for f in "$1" "$(dirname "$1")"; do
        [ "$(stat -c %u "$f")" = 0 ] && [ $((0$(stat -c %a "$f") & 022)) = 0 ] || return 1
    done
}

php_version() {
    { timeout 10 "$1" -n -v || timeout 10 "$1" -v; } 2>/dev/null |
        head -1 | grep -oE '^PHP [0-9]+\.[0-9]+\.[0-9]+' | cut -d' ' -f2 || true
}

owner_of() {
    local p
    if command -v dpkg-query > /dev/null && p=$(dpkg-query -S "$1" 2>/dev/null); then echo "deb:${p%%[:,]*}"; return; fi
    if command -v rpm > /dev/null && p=$(rpm -qf --qf '%{NAME}\n' "$1" 2>/dev/null); then echo "rpm:$p"; return; fi
    echo src
}

php_config_of() { ls "$1"/bin/php-config* 2>/dev/null | head -1; }

declare -A KIND VER STATUS
IDS=()

# Installs are keyed by prefix for source builds and by package type + branch otherwise.
scan() {
    local bin ver owner id
    IDS=(); KIND=(); VER=(); STATUS=()
    while read -r bin; do
        trusted "$bin" || { warn "skipping $bin: not root-owned, or writable by non-root users"; continue; }
        ver=$(php_version "$bin")
        [ -n "$ver" ] || continue
        owner=$(owner_of "$bin")
        if [ "$owner" = src ]; then id=$(dirname "$(dirname "$bin")"); else id="${owner%%:*}:php$(branch_of "$ver")"; fi
        if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$id,"* && ",$ONLY," != *",$(branch_of "$ver"),"* ]]; then continue; fi
        [ -z "${KIND[$id]:-}" ] || continue
        IDS+=("$id"); KIND[$id]=$owner; VER[$id]=$ver
    done < <(candidates)
}

# Distro backports keep the old version number, so also look for the CVE in the changelog.
pkg_fixed() {  # owner version
    local kind=${1%%:*} pkg=${1#*:} t
    t=${TARGET[$(branch_of "$2")]:-}
    if [ -n "$t" ] && [ -z "$(cut -d' ' -f3 <<<"$t")" ] && ver_ge "$2" "${t%% *}"; then return 0; fi
    case $kind in
        deb) if [ -f "/usr/share/doc/$pkg/changelog.Debian.gz" ]; then
                 zgrep -qsE "$CVE_RE" "/usr/share/doc/$pkg/changelog.Debian.gz"
             else   # minimized images drop /usr/share/doc
                 apt-get changelog "$pkg" 2>/dev/null | grep -qE "$CVE_RE"
             fi ;;
        rpm) rpm -q --changelog "$pkg" 2>/dev/null | grep -qE "$CVE_RE" ;;
        *)   return 1 ;;
    esac
}

# A prefix we can safely back up and install over as a whole.
src_rebuildable() {
    [[ $1 != / && $1 != /usr && $1 != /usr/local && $1 == *php* ]] && [ -n "$(php_config_of "$1")" ]
}

status_of() {
    local id=$1 ver=${VER[$1]} t rel patch
    ver_ge "$ver" 8.6 && { echo ok; return; }
    t=${TARGET[$(branch_of "$ver")]:-}
    [ -n "$t" ] || { echo nofix; return; }
    read -r rel _ patch _ <<<"$t"
    if [ "${KIND[$id]}" != src ]; then
        if pkg_fixed "${KIND[$id]}" "$ver"; then echo ok; else echo pkg; fi
        return
    fi
    if [ -n "${patch:-}" ]; then
        [ -f "$id/$MARKER" ] && [ "$ver" = "$rel" ] && { echo ok; return; }
        # No upstream release exists past the final one, so a higher version is a
        # vendor-patched build (aaPanel ships 7.4.34 and 8.1.35, for example).
        [ "$ver" != "$rel" ] && ver_ge "$ver" "$rel" && { echo vendor; return; }
    elif ver_ge "$ver" "$rel"; then
        echo ok; return
    fi
    if src_rebuildable "$id"; then echo rebuild; else echo manual; fi
}

describe() {  # id status
    local t
    t=${TARGET[$(branch_of "${VER[$1]}")]:-}
    case $2 in
        ok)      echo "fixed" ;;
        vendor)  echo "fixed by a vendor build (newer than the final php.net ${t%% *}); confirm with your vendor" ;;
        pkg)     if [ "$APPLIED" = 1 ]; then
                     echo "VULNERABLE: no fixed package in your repositories (Ubuntu: Ubuntu Pro/ESM, Debian 11: Freexian ELTS)"
                 else
                     echo "needs package upgrade"
                 fi ;;
        rebuild) echo "needs rebuild -> ${t%% *}$([ -n "$(cut -d' ' -f3 <<<"$t")" ] && echo ' + official backport')" ;;
        manual)  echo "VULNERABLE: source build in a shared prefix or without php-config; rebuild it by hand" ;;
        nofix)   echo "VULNERABLE: no official fix for PHP ${VER[$1]%.*}; move these sites to PHP 8.2+" ;;
    esac
}

report() {
    local id
    printf '\n  %-36s %-8s %-7s %s\n' INSTALL VERSION TYPE STATUS
    for id in "${IDS[@]}"; do
        STATUS[$id]=$(status_of "$id")
        printf '  %-36s %-8s %-7s %s\n' "$id" "${VER[$id]}" "${KIND[$id]%%:*}" "$(describe "$id" "${STATUS[$id]}")"
    done
    echo
}

# ----------------------------------------------------------------- restarts

# systemd units (or bare PIDs) of processes still running PHP code replaced on disk.
stale() {
    local d exe unit
    for d in /proc/[0-9]*; do
        exe=$(readlink "$d/exe" 2>/dev/null) || continue
        if { [[ $exe == *" (deleted)" ]] && [[ $(basename "${exe% (deleted)}") =~ $BIN_RE ]]; } ||
           grep -qsE '/libphp[^/]*\.so \(deleted\)$' "$d/maps"; then
            unit=$(grep -oE '[^/]+\.service' "$d/cgroup" 2>/dev/null | tail -1 || true)
            echo "${unit:-pid ${d#/proc/} (${exe% (deleted)})}"
        fi
    done | sort -u
}

unit_stale() { stale | grep -qx "$1"; }

# php-fpm gets a reload first: the master re-executes the new binary but keeps its
# listening socket, so new requests queue instead of failing. Everything else, and any
# FPM that is still on the old binary after 30 s, gets a full restart.
restart_unit() {
    local u=$1
    if [[ $u == *fpm* ]] && systemctl reload "$u" 2>/dev/null; then
        for _ in $(seq 30); do
            sleep 1
            systemctl is-active --quiet "$u" && ! unit_stale "$u" && { log "reloaded $u"; return 0; }
        done
        warn "reload of $u did not pick up the new binary, restarting"
    fi
    log "restarting $u"
    systemctl restart "$u"
}

restart_stale() {
    local u units=() left=()
    mapfile -t units < <(stale)
    [ ${#units[@]} -gt 0 ] || return 0
    if [ "$RESTART" = 0 ]; then warn "restart these to load the fix: ${units[*]}"; return 0; fi
    for u in "${units[@]}"; do
        case $u in
            *.service) restart_unit "$u" || warn "restart of $u failed" ;;
            *)         warn "not managed by systemd, restart it by hand: $u" ;;
        esac
    done
    sleep 2
    mapfile -t left < <(stale | grep '\.service$' || true)
    [ ${#left[@]} -eq 0 ] || warn "still running the old code: ${left[*]}"
}

units_under() {  # prefix
    local d exe
    for d in /proc/[0-9]*; do
        exe=$(readlink "$d/exe" 2>/dev/null) || continue
        [[ ${exe% (deleted)} == "$1"/* ]] || continue
        grep -oE '[^/]+\.service' "$d/cgroup" 2>/dev/null | tail -1 || true
    done | sort -u
}

fpm_conf() {  # fpm binary -> config file its running master was started with
    local d
    for d in /proc/[0-9]*; do
        [ "$(readlink "$d/exe" 2>/dev/null)" = "$1" ] || continue
        tr '\0' ' ' < "$d/cmdline" | grep -oE 'master process \(/[^)]+\)' | grep -oE '/[^)]+' && return 0
    done
    return 0
}

# ---------------------------------------------------------------- fixing

pkg_upgrade() {  # deb|rpm
    local pm pkgs=()
    case $1 in
        deb)
            mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" && $2 ~ /php/ {print $2}')
            log "apt: upgrading ${#pkgs[@]} installed PHP packages"
            apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade \
                -o Dpkg::Options::=--force-confold "${pkgs[@]}" || warn "apt upgrade failed"
            ;;
        rpm)
            pm=$(command -v dnf || command -v yum) || { warn "no dnf/yum found"; return 0; }
            mapfile -t pkgs < <(rpm -qa --qf '%{NAME}\n' | grep php | sort -u)
            log "$(basename "$pm"): upgrading ${#pkgs[@]} installed PHP packages"
            "$pm" -y upgrade "${pkgs[@]}" || warn "$(basename "$pm") upgrade failed"
            ;;
    esac
}

ROLLBACK_UNITS=()

rollback() {
    local dir=$1 backup=$2 u
    # With -E, subshells inherit the trap; let only the main shell restore.
    [ "$BASHPID" = "$$" ] || exit 1
    trap - ERR
    warn "[$dir] failed, restoring $backup"
    rm -rf "$dir.failed" && mv "$dir" "$dir.failed" && cp -a "$backup" "$dir"
    for u in "${ROLLBACK_UNITS[@]}"; do systemctl restart "$u" || true; done
    die "[$dir] rolled back; the failed install is in $dir.failed"
}

rebuild() {
    local dir=$1 ver=${VER[$1]} release tsha patch psha pc src tarball backup extdir fpm conf so name u opts=()
    read -r release tsha patch psha <<<"${TARGET[$(branch_of "$ver")]}"
    pc=$(php_config_of "$dir")

    log "[$dir] $ver -> $release${patch:+ + official backport}"
    mkdir -p "$WORK/dl"
    tarball="$WORK/dl/php-$release.tar.gz"
    [ -f "$tarball" ] || curl -fSL --retry 3 -o "$tarball" "https://www.php.net/distributions/php-$release.tar.gz"
    check_sha256 "$tarball" "$tsha"

    local build
    build="$WORK/$(tr / _ <<<"${dir#/}")"
    src="$build/php-$release"
    rm -rf "$build" && mkdir -p "$build"
    tar -xzf "$tarball" -C "$build"
    if [ -n "${patch:-}" ]; then
        check_sha256 "$SCRIPT_DIR/patches/$patch" "$psha"
        (cd "$src" && patch -p1 -s < "$SCRIPT_DIR/patches/$patch")
    fi

    # Reuse exactly the flags this install was built with.
    read -ra opts <<<"$("$pc" --configure-options)"
    log "[$dir] configure + make (logs in $build)"
    (cd "$src" && ./configure "${opts[@]}" > "$build/configure.log" 2>&1) || die "[$dir] configure failed, see $build/configure.log"
    (cd "$src" && nice -n 10 make -j"$(nproc)" > "$build/make.log" 2>&1) || die "[$dir] make failed, see $build/make.log"

    fpm=$(ls "$dir"/sbin/php-fpm* 2>/dev/null | head -1 || true)
    conf=""
    [ -z "$fpm" ] || conf=$(fpm_conf "$fpm")
    mapfile -t ROLLBACK_UNITS < <(units_under "$dir")

    backup="$dir.bak-$ver-$(date +%Y%m%d%H%M%S)"
    log "[$dir] backing up to $backup"
    cp -a "$dir" "$backup"

    # From here on, any failure restores the backup.
    # shellcheck disable=SC2064  # the paths must be captured now
    trap "rollback '$dir' '$backup'" ERR
    (cd "$src" && make install > "$build/install.log" 2>&1)

    # Shared extensions that ship with PHP must be rebuilt too; several are part of the fix.
    extdir=$("$pc" --extension-dir)
    for so in "$extdir"/*.so; do
        [ -e "$so" ] || continue
        name=$(basename "$so" .so)
        [ "$name" = opcache ] && continue   # installed by make install
        if [ -d "$src/ext/$name" ]; then
            log "[$dir] rebuilding shared extension $name"
            (cd "$src/ext/$name" && "${pc/php-config/phpize}" && ./configure --with-php-config="$pc" &&
                make -j"$(nproc)" && make install) > "$build/ext-$name.log" 2>&1
        else
            warn "[$dir] third-party extension $name left as is (same ABI)"
        fi
    done

    [ -n "$conf" ] || conf="$dir/etc/php-fpm.conf"
    [ -z "$fpm" ] || [ ! -f "$conf" ] || "$fpm" -t -y "$conf"
    if [ -n "${patch:-}" ]; then echo "$release + $patch $psha" > "$dir/$MARKER"; fi

    if [ "$RESTART" = 1 ]; then
        for u in "${ROLLBACK_UNITS[@]}"; do restart_unit "$u"; done
        sleep 2
        for u in "${ROLLBACK_UNITS[@]}"; do systemctl is-active --quiet "$u"; done
    fi
    trap - ERR

    log "[$dir] done: $("$dir/bin/php" -n -v | head -1), backup kept at $backup"
}

# -------------------------------------------------------------------- main

log "looking for PHP installations"
scan
[ ${#IDS[@]} -gt 0 ] || { log "no PHP found"; exit 0; }
report

for lib in /usr/lib/apache2/modules/libphp*.so /etc/httpd/modules/libphp*.so /usr/lib64/httpd/modules/libphp*.so /usr/local/apache*/modules/libphp*.so; do
    [ -e "$lib" ] && [ "$(owner_of "$(readlink -f "$lib")")" = src ] && warn "source-built mod_php $lib is not handled; rebuild it by hand"
done
if command -v docker > /dev/null && [ -n "$(docker ps -q 2>/dev/null)" ]; then
    warn "running Docker containers were not scanned; rebuild them on fixed php images"
fi

todo=0 unfixed=0
for id in "${IDS[@]}"; do
    case ${STATUS[$id]} in
        pkg|rebuild) todo=1 ;;
        ok|vendor)   ;;
        *)           unfixed=1 ;;
    esac
done
if [ "$todo" = 0 ]; then
    [ "$unfixed" = 0 ] && { log "all PHP installations are fixed"; exit 0; }
    log "nothing this script can fix automatically; see the VULNERABLE lines above"
    exit 1
fi
if [ "$APPLY" = 0 ]; then
    log "report only; rerun with --apply to fix (each affected PHP service restarts once, a few seconds)"
    exit 0
fi

# Packages first: one upgrade per package manager.
for kind in deb rpm; do
    for id in "${IDS[@]}"; do
        if [ "${STATUS[$id]}" = pkg ] && [ "${KIND[$id]%%:*}" = $kind ]; then pkg_upgrade $kind; break; fi
    done
done
APPLIED=1
restart_stale

# Then source builds, one at a time.
rebuilds=()
for id in "${IDS[@]}"; do [ "${STATUS[$id]}" = rebuild ] && rebuilds+=("$id"); done
if [ ${#rebuilds[@]} -gt 0 ]; then
    for t in gcc make patch curl; do command -v $t > /dev/null || die "missing build tool: $t"; done
    mkdir -p "$WORK"
    avail=$(df -Pm "$WORK" | awk 'NR == 2 {print $4}')
    [ "$avail" -gt 3000 ] || die "need ~3 GB free for $WORK, have ${avail} MB (set WORK=/some/dir)"
    for id in "${rebuilds[@]}"; do rebuild "$id"; done
fi
restart_stale

log "result"
scan
report
for id in "${IDS[@]}"; do [[ ${STATUS[$id]} == ok || ${STATUS[$id]} == vendor ]] || exit 1; done
log "all PHP installations are fixed"
[ ! -d /www/server/panel ] || log "aaPanel: later PHP updates from the panel are fine as long as they install its patched builds (7.4.34+, 8.1.35+); rerun this report to check"
