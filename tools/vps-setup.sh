#!/usr/bin/env bash
# One-time provisioning for the Linux box that runs cargo check.
#
# Run this ON the VPS, not from here. It installs what the Rust shell needs to
# compile on Linux and nothing else: no installer bundling, no signing keys, no
# deploy credentials. If this box is later compromised the worst it holds is a
# checkout of a public repo.
#
#   curl -o vps-setup.sh https://... && bash vps-setup.sh
#   or just scp it over and run it
#
# Safe to re-run. Everything here checks before it installs.

set -euo pipefail

say(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

command -v apt-get >/dev/null 2>&1 || die "This expects a Debian or Ubuntu box; adapt the package names for anything else."

# The five that the Check workflow installs. webkit2gtk is the one that matters
# and the one whose package name keeps moving between releases: 4.1 is what
# Tauri v2 wants, 4.0 is Tauri v1 and will not do.
say "Installing build dependencies"
sudo apt-get update
sudo apt-get install -y \
  build-essential curl git pkg-config \
  libwebkit2gtk-4.1-dev \
  libgtk-3-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev \
  libssl-dev

say "Checking there is enough memory to compile with"
mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
swap=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
echo "  ${mem} MB RAM, ${swap} MB swap"
if [ "$((mem + swap))" -lt 2048 ]; then
  echo "  Under 2 GB all in. The dependency tree here is large and rustc will"
  echo "  most likely be killed part way through. Add swap before relying on this."
fi

if command -v rustc >/dev/null 2>&1; then
  say "Rust already present: $(rustc --version)"
else
  say "Installing Rust"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck disable=SC1090
  . "$HOME/.cargo/env"
fi

if command -v node >/dev/null 2>&1; then
  say "Node already present: $(node --version)"
else
  # Only build.mjs and make-icon.mjs need this, and both use node built-ins
  # only, so the distro package is fine and the version barely matters.
  say "Installing Node"
  sudo apt-get install -y nodejs
fi

say "Done"
echo "  rustc:  $(command -v rustc >/dev/null 2>&1 && rustc --version || echo 'not on PATH, open a new shell')"
echo "  cargo:  $(command -v cargo >/dev/null 2>&1 && cargo --version || echo 'not on PATH, open a new shell')"
echo "  node:   $(node --version 2>/dev/null || echo missing)"
echo
echo "Next: put a checkout somewhere and run tools/vps-check.sh from inside it."
