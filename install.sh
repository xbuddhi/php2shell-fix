#!/usr/bin/env bash
# One-step installer for php2shell-fix.
#
#   curl -fsSL https://raw.githubusercontent.com/xbuddhi/php2shell-fix/v1.0.3/install.sh | sudo bash
#
# Downloads the pinned release, verifies it, installs it as `php2shell-fix`, shows the
# report, and asks before fixing anything. Options are passed on to php2shell-fix:
#
#   ... | sudo bash -s -- --yes                 fix without asking (unattended)
#   ... | sudo bash -s -- --yes --only 7.4      only some installs
#   ... | sudo bash -s -- --check               report only, never fix

set -euo pipefail

VERSION=1.0.3
SCRIPT_SHA256=3a1ff0b6352bfae9fefbe2cb757c0e66d38fb9aa786079607b1f82804e544a89   # sha256 of php2shell-fix.sh in this release
REPO=xbuddhi/php2shell-fix
PREFIX=/opt/php2shell-fix
LINK=/usr/local/sbin/php2shell-fix

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

YES=0
CHECK=0
PASS=()
while [ $# -gt 0 ]; do
    case $1 in
        --yes|-y) YES=1 ;;
        --check)  CHECK=1 ;;
        --only)   PASS+=("$1" "${2:?--only needs a value}"); shift ;;
        *)        PASS+=("$1") ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "run as root: curl ... | sudo bash"
for t in curl tar sha256sum; do command -v $t > /dev/null || die "missing $t"; done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "downloading php2shell-fix v$VERSION"
curl -fsSL "https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz" | tar -xz -C "$tmp"
src="$tmp/php2shell-fix-$VERSION"

# The main script checks the php.net tarballs and the bundled patches itself.
got=$(sha256sum "$src/php2shell-fix.sh" | cut -d' ' -f1)
[ "$got" = "$SCRIPT_SHA256" ] || die "php2shell-fix.sh checksum mismatch (got $got); not running it"

rm -rf "$PREFIX.new"
cp -a "$src" "$PREFIX.new"
rm -rf "$PREFIX"
mv "$PREFIX.new" "$PREFIX"
chmod 755 "$PREFIX/php2shell-fix.sh"
ln -sf "$PREFIX/php2shell-fix.sh" "$LINK"
log "installed to $PREFIX (run it again any time with: sudo php2shell-fix)"

report=$("$LINK" ${PASS[@]+"${PASS[@]}"} 2>&1) && rc=0 || rc=$?
printf '%s\n' "$report"
if ! grep -qE 'needs (rebuild|package upgrade)' <<<"$report"; then
    exit "$rc"
fi
if [ "$CHECK" = 1 ]; then
    log "check only; to fix: sudo php2shell-fix --apply"
    exit 0
fi

if [ "$YES" = 0 ]; then
    # /dev/tty always exists; only opening it shows whether there's a terminal.
    if (: < /dev/tty) 2> /dev/null; then
        printf 'Fix the installs marked "needs ..." now? Each affected PHP service is reloaded or restarted once. [y/N] ' > /dev/tty
        read -r answer < /dev/tty || answer=""
        [[ $answer == [yY]* ]] || { log "nothing changed; to fix later: sudo php2shell-fix --apply"; exit 0; }
    else
        log "no terminal to ask on; nothing changed. To fix: sudo php2shell-fix --apply (or rerun this with: sudo bash -s -- --yes)"
        exit 0
    fi
fi

"$LINK" --apply ${PASS[@]+"${PASS[@]}"}   # not exec, so the EXIT trap still cleans up
