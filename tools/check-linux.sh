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

# /c/Users/... here is /mnt/c/Users/... over there.
WINREPO=$(pwd | sed 's|^/\([a-z]\)/|/mnt/\1/|')

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

if [ ! -d "$CLONE/.git" ]; then
  # Deliberately a clone into the ext4 filesystem rather than building in
  # place on /mnt/c. Cargo touches thousands of small files and every one of
  # them would cross the 9p boundary; it is the difference between minutes
  # and most of an hour.
  echo "==> First run: cloning into $CLONE"
  git clone --quiet "$WINREPO" "$CLONE"
fi

cd "$CLONE"
git remote set-url origin "$WINREPO"
git fetch --quiet origin "$REF"
git checkout --quiet -B "$REF" FETCH_HEAD
exec tools/linux-check.sh
REMOTE
