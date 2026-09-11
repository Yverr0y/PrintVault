#!/bin/sh
# Render og.svg to og.png, which is what the social card meta actually points at.
#
# og.png went missing from this folder once and nobody noticed, because the copy
# already on the server kept serving fine. The deploy is what broke: scp stats
# every source before sending, so one absent file aborts the whole upload.
#
# Chrome does the rendering because it is the one thing already on every machine
# this site gets deployed from. Do not reach for `convert` here: on Windows that
# name belongs to the filesystem conversion tool, not ImageMagick.
#
# Only run this when og.svg has actually changed, or when og.png has gone
# missing again. Chrome renders with whatever fonts this machine has, so a
# needless re-render moves the type around slightly and produces a file two and
# a half times the size, for a card that scrapers have already cached.
#
#   tools/make-og.sh    rewrites site/og.png from site/og.svg

set -e

# og.svg and og.png live in site/, which is gitignored, so this script is kept
# in the repo instead and reaches across to them. Same arrangement as
# mirror-release.sh, and for the same reason: a helper stored inside the folder
# it maintains does not survive a fresh clone.
SITEDIR=$(cd "$(dirname "$0")/../site" 2>/dev/null && pwd) ||
  { echo "cannot find the site folder next to $(dirname "$0")" >&2; exit 1; }
[ -f "$SITEDIR/og.svg" ] ||
  { echo "$SITEDIR has no og.svg to render" >&2; exit 1; }
cd "$SITEDIR"

CHROME="/c/Program Files/Google/Chrome/Application/chrome.exe"
[ -x "$CHROME" ] || CHROME="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
[ -x "$CHROME" ] || { echo "No Chrome or Edge found, cannot render og.png" >&2; exit 1; }

# The size is not a guess: og.svg is authored at 1200x630 and index.html
# declares those numbers in og:image:width and og:image:height.
"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --window-size=1200,630 \
  --screenshot="$(pwd -W 2>/dev/null || pwd)/og.png" \
  "file:///$(pwd -W 2>/dev/null || pwd)/og.svg" 2>/dev/null

echo "og.png rewritten from og.svg"
