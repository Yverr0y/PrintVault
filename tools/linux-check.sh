#!/usr/bin/env bash
# Does the Rust shell still compile on Linux?
#
# This is what .github/workflows/check.yml did on ubuntu-22.04, moved somewhere
# we control because Actions stopped running on 2026-09-11. Runs anywhere with
# apt and a kernel: a WSL distro, a VM, a remote box.
#
# Under WSL, keep the checkout in the ext4 filesystem rather than on /mnt/c.
# Cargo touches thousands of small files and every one of them crosses the 9p
# boundary, which turns a three minute check into a thirty minute one. It answers one
# question and deliberately does nothing else: no installers, no signing, no
# uploads. The macOS half of that workflow has no replacement, because there is
# no Mac to run it on.
#
# Run it from inside a checkout, on the Linux side:
#
#   tools/linux-check.sh            check the working tree as it stands
#   tools/linux-check.sh main       fetch that branch from origin first
#
# Exits non-zero if it does not compile, so a hook or a cron can act on it.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$(pwd)

say(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# rustup installs into ~/.cargo, which a non-login shell (a git hook, cron)
# does not have on PATH. Sourcing it here rather than asking every caller to.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v cargo >/dev/null 2>&1 || die "cargo is not on PATH. Run tools/linux-setup.sh first."
command -v node  >/dev/null 2>&1 || die "node is not on PATH. Run tools/linux-setup.sh first."

if [ "${1:-}" != "" ]; then
  say "Fetching $1"
  git fetch --quiet origin "$1"
  git checkout --quiet -B "$1" "origin/$1"
fi
say "Checking $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
git --no-pager log -1 --format='  %s%n  %an, %ar'

# tauri-build reads tauri.conf.json while compiling and expects both the
# frontend and the icons to be on disk. Neither is committed: dist is a copy of
# index.html and the icons are drawn from raw pixels by make-icon.mjs. Without
# this step cargo check fails on a missing path and looks like a code problem.
#
# Neither script needs anything from npm, they are node built-ins throughout,
# so there is no npm ci here. The only dependency in desktop/package.json is
# the Tauri CLI, which builds installers and has no part in a check.
say "Staging the frontend and icons"
cd "$REPO/desktop"
node build.mjs
node make-icon.mjs

say "cargo check"
cd "$REPO/desktop/src-tauri"
# --all-targets so tests and benches are compiled too, matching what the
# workflow ran. Without it a broken test module passes here and fails later.
if cargo check --all-targets --message-format short; then
  say "Compiles on Linux"
else
  die "Does not compile on Linux"
fi
