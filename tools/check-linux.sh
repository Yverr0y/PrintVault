#!/usr/bin/env bash
# Compile the Rust shell on Linux, from Windows, without leaving Windows.
#
# The desktop app is developed here and macOS and Linux were only ever compiled
# by CI. Actions stopped running on 2026-09-11, so this is the Linux half of
# .github/workflows/check.yml brought back under a WSL distro. There is still
# no replacement for the macOS half.
#
#   tools/check-linux.sh              check the branch you are on
#   tools/check-linux.sh main         check that branch
#   DISTRO=Ubuntu-22.04 tools/check-linux.sh
#
# It checks committed work, the same as CI did. Anything still sitting in the
# working tree here is not what gets compiled over there.

set -euo pipefail

DISTRO=${DISTRO:-Ubuntu}
CLONE=${CLONE:-\$HOME/printvault}          # expanded on the Linux side, not here

cd "$(dirname "$0")/.."
REF=${1:-$(git rev-parse --abbrev-ref HEAD)}

# Git Bash rewrites anything that looks like a unix path into a Windows one
# before handing it to a non-MSYS program, which turns /mnt/c into
# C:/Program Files/Git/mnt/c and is not obvious from the error.
export MSYS_NO_PATHCONV=1

# /c/Users/... here is /mnt/c/Users/... over there. Both spellings have to be
# handled: from a shell pwd gives /c/Users/..., but when git runs this from a
# hook it gives C:/Users/..., and a path carrying a colon reaches git on the far
# side as an scp-style remote. The symptom is "ssh: Could not resolve hostname
# c", which names nothing you would go looking at.
here=$(cygpath -u "$(pwd)" 2>/dev/null || pwd)
case "$here" in
  /mnt/*)      WINREPO=$here ;;
  /[A-Za-z]/*) WINREPO="/mnt/$(printf '%s' "$here" | cut -c2 | tr 'A-Z' 'a-z')${here#/?}" ;;
  *)           WINREPO=$here ;;
esac

command -v wsl.exe >/dev/null 2>&1 || { echo "wsl.exe not found" >&2; exit 1; }

printf '\n\033[1;36m==> %s, %s in %s\033[0m\n' "$REF" "$(git rev-parse --short "$REF" 2>/dev/null || echo '?')" "$DISTRO"

# The script goes over stdin rather than as an argument. Quoting survives one
# trip through Git Bash and a second through wsl.exe roughly never, and the
# failures look like shell bugs rather than quoting.
wsl.exe -d "$DISTRO" -- bash -s -- "$WINREPO" "$CLONE" "$REF" <<'REMOTE'
set -euo pipefail
WINREPO=$1; CLONE=$(eval echo "$2"); REF=$3

# rustup lives in ~/.cargo, which a non-login shell does not have on PATH.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# A setup problem and a compile failure are different answers, and one exit
# code cannot tell them apart. 2 means the check could not run.
fail_setup(){ printf '\n!! %s\n' "$*" >&2; exit 2; }

[ -d "$WINREPO" ] || fail_setup "$WINREPO is not visible from inside WSL"

if [ ! -d "$CLONE/.git" ]; then
  # Deliberately a clone into the ext4 filesystem rather than building in
  # place on /mnt/c. Cargo touches thousands of small files and every one of
  # them would cross the 9p boundary; it is the difference between minutes
  # and most of an hour.
  echo "==> First run: cloning into $CLONE"
  git clone --quiet "$WINREPO" "$CLONE" || fail_setup "clone from $WINREPO failed"
fi

cd "$CLONE" || fail_setup "$CLONE is not there"
git remote set-url origin "$WINREPO"
git fetch --quiet origin "$REF" || fail_setup "could not fetch $REF from $WINREPO"
git checkout --quiet -B "$REF" FETCH_HEAD || fail_setup "could not check out $REF"
exec tools/linux-check.sh
REMOTE
