#!/bin/sh
# Mirror a published GitHub release onto this site, then point the download
# page at it.
#
# This exists because the GitHub account is under manual review: the release
# still builds and publishes exactly as it always did, but its URLs answer 404
# to everyone except the account owner, so the files have to be carried across
# by hand. Everything below is the manual sequence used for 0.2.28, written
# down so it cannot be done half way.
#
#   ./mirror-release.sh 0.2.29              mirror it and repoint the site
#   ./mirror-release.sh 0.2.29 --full       re-download every file over HTTPS
#                                           afterwards and checksum the lot
#   ./mirror-release.sh 0.2.29 --no-deploy  do the mirror, leave the site alone
#   ./mirror-release.sh 0.2.29 --keep-old   leave the version it replaces on disk
#
# The mirror it replaces is deleted at the very end, once the new files have
# been checked on the server, checked over HTTPS, and confirmed live on the
# download page. Anything failing before that leaves the previous installers
# exactly where they were, which is the copy you would be sending people back
# to. Use --keep-old when a release is unproven and you want the last known
# good one to stay reachable.
#
# It refuses to touch the site unless the bytes on the server match the
# checksums CI generated, because a mirror nobody can verify is worse than no
# mirror: this site would be both serving the binary and vouching for it.
#
# When the account is restored, none of this is needed. Point the download
# links back at releases/latest, drop the notices from index.html and
# guide.html, and delete public_html/dl.

set -eu

REPO=magikh0e/PrintVault
HOST=u959320219@217.196.54.195
PORT=65002
KEY=~/.ssh/id_ed25519
ROOT=/home/u959320219/domains/printvault.magikh0e.pl/public_html
SITE=https://printvault.magikh0e.pl

VER=${1:-}
FULL=no
DEPLOY=yes
KEEP_OLD=no
for a in "$@"; do
  case "$a" in
    --full) FULL=yes ;;
    --no-deploy) DEPLOY=no ;;
    --keep-old) KEEP_OLD=yes ;;
  esac
done

if [ -z "$VER" ] || [ "${VER#-}" != "$VER" ]; then
  echo "usage: $0 <version> [--full] [--no-deploy] [--keep-old]   e.g. $0 0.2.29" >&2
  exit 2
fi

TAG=desktop-v$VER

say(){ printf '\n== %s\n' "$1"; }
die(){ printf '\n!! %s\n' "$1" >&2; exit 1; }

# This script is tracked in the repo, but everything it edits and uploads lives
# in site/, which is not. Keeping the one copy here rather than beside the files
# it touches is deliberate: site/ is gitignored wholesale, so a copy living
# there is one fresh clone away from being gone, and two copies would drift.
SITEDIR=$(cd "$(dirname "$0")/../site" 2>/dev/null && pwd) ||
  die "cannot find a site folder next to $(dirname "$0")"
[ -f "$SITEDIR/index.html" ] ||
  die "$SITEDIR has no index.html, so that is not the marketing site"
cd "$SITEDIR"

for tool in gh ssh scp curl sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

# ---------------------------------------------------------------- fetch
say "Fetching $TAG from GitHub"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
gh release download "$TAG" -R "$REPO" -D "$TMP" >/dev/null 2>&1 ||
  die "could not download $TAG. Is it published, and is gh logged in?"

[ -f "$TMP/SHA256SUMS.txt" ] ||
  die "no SHA256SUMS.txt in $TAG, so nothing here can be verified"

# SHA256SUMS.txt is the manifest as well as the proof. Mirroring exactly what
# it lists means a new artifact added to the release in future comes across on
# its own, and the .sig files and latest.json stay behind, which is right:
# they only mean anything to the updater, and the updater cannot reach this
# site anyway.
FILES=$(awk '{print $2}' "$TMP/SHA256SUMS.txt")
[ -n "$FILES" ] || die "SHA256SUMS.txt lists no files"

say "Verifying the download against the checksums CI generated"
( cd "$TMP" && sha256sum -c SHA256SUMS.txt ) || die "the download does not match its own checksums"

# ---------------------------------------------------------------- upload
DEST=$ROOT/dl/$VER
say "Uploading to $DEST"
ssh -i "$KEY" -p "$PORT" "$HOST" "mkdir -p '$DEST'" ||
  die "could not reach the server"
( cd "$TMP" && scp -i "$KEY" -P "$PORT" $FILES SHA256SUMS.txt "$HOST:$DEST/" ) ||
  die "upload failed"

say "Verifying the bytes that landed on the server"
ssh -i "$KEY" -p "$PORT" "$HOST" "cd '$DEST' && sha256sum -c SHA256SUMS.txt" ||
  die "what is on the server does not match the checksums. The site has not been touched."

# ---------------------------------------------------------------- delivery
# Correct bytes on disk are not the same as a working download. Apache calls a
# .dmg or an .AppImage text/plain unless .htaccess says otherwise, and because
# the site sends X-Content-Type-Options: nosniff the browser believes it and
# paints the binary into the window instead of saving it. That failure is
# invisible in a checksum and invisible in a HEAD status line, so the type is
# checked explicitly.
say "Checking how the files are actually served"
BAD=0
for f in $FILES SHA256SUMS.txt; do
  hdr=$(curl -sIL "$SITE/dl/$VER/$f?cb=$$" || true)
  code=$(printf '%s' "$hdr" | awk 'BEGIN{IGNORECASE=1}/^HTTP/{c=$2}END{print c}')
  type=$(printf '%s' "$hdr" | awk 'BEGIN{IGNORECASE=1}/^content-type/{t=$2}END{print t}')
  printf '   %-42s %s  %s\n' "$f" "${code:-???}" "${type:-no type}"
  [ "$code" = "200" ] || BAD=1
  case "$f" in
    *.txt) ;;
    *) case "$type" in
         application/*) ;;
         *) printf '      ^ served as %s, so a browser will display it rather than save it\n' "$type"
            printf '        add the type to .htaccess under AddType and re-run\n'
            BAD=1 ;;
       esac ;;
  esac
done
[ "$BAD" = "0" ] || die "the mirror is not being served correctly. The site has not been touched."

if [ "$FULL" = "yes" ]; then
  say "Re-downloading everything over HTTPS and checksumming it"
  V=$TMP/https; mkdir -p "$V"
  ( cd "$V" && curl -sL -O "$SITE/dl/$VER/SHA256SUMS.txt?cb=$$"
    for f in $FILES; do curl -sL -o "$f" "$SITE/dl/$VER/$f?cb=$$"; done
    diff SHA256SUMS.txt "$TMP/SHA256SUMS.txt" >/dev/null ||
      { echo "the sums file served differs from the real one"; exit 1; }
    sha256sum -c SHA256SUMS.txt ) || die "files served over HTTPS do not verify"
fi

if [ "$DEPLOY" = "no" ]; then
  say "Mirror is up at $SITE/dl/$VER/. Site left alone, as asked."
  exit 0
fi

# ---------------------------------------------------------------- the site
# The old version number appears in the download paths, in the filenames, in
# the JSON-LD, in body copy, in an FAQ answer and in the footer. It has always
# been moved with one global replace, so that is what happens here.
OLD=$(grep -o 'href="/dl/[0-9][0-9.]*/' index.html | head -1 | sed 's|.*/dl/||;s|/$||') || true
[ -n "${OLD:-}" ] || die "could not find the current version in index.html, so nothing was changed"

if [ "$OLD" = "$VER" ]; then
  say "index.html already points at $VER, leaving the copy alone"
else
  say "Repointing the site from $OLD to $VER"
  for f in index.html guide.html; do
    [ -f "$f" ] && sed -i "s/$(echo "$OLD" | sed 's/\./\\./g')/$VER/g" "$f"
  done
fi

# The AppImage size is written out on the button, and it is the one number a
# global version replace cannot fix.
#
# Decimal MB, not MiB. This is the number a visitor compares against what their
# browser shows them while it downloads, and Chrome, Firefox and the Finder all
# count in millions. Dividing by 1048576 here would quietly relabel an 82 MB
# file as 78 MB and look like the wrong file had been served.
AP=$(printf '%s\n' $FILES | grep -i '\.AppImage$' | head -1 || true)
if [ -n "${AP:-}" ] && [ -f "$TMP/$AP" ]; then
  MB=$(( ( $(wc -c < "$TMP/$AP") + 500000 ) / 1000000 ))
  sed -i "s/\.AppImage, [0-9]\{1,4\} MB/.AppImage, $MB MB/" index.html
  echo "   AppImage button now reads $MB MB"
fi

say "Deploying the two pages"
scp -i "$KEY" -P "$PORT" index.html guide.html "$HOST:$ROOT/" || die "site upload failed"

say "Confirming the live page points at the new files"
LIVE=$(curl -s "$SITE/?cb=$$" | grep -c "href=\"/dl/$VER/" || true)
[ "${LIVE:-0}" -gt 0 ] || die "the live page is not serving the new links yet"
echo "   $LIVE links on the live page point at /dl/$VER/"

# ---------------------------------------------------------------- sweep up
# Only now, with the new files verified on disk, verified over the wire and
# confirmed live on the page. $OLD is whatever the site pointed at when this
# started, so it is by definition the version just replaced.
REMOVED=
if [ "$OLD" != "$VER" ] && [ "$KEEP_OLD" = "no" ]; then
  # This string is interpolated straight into an rm -rf on a live server, so it
  # is checked rather than trusted. It comes out of a grep against index.html,
  # and a mangled file could otherwise turn this line into something far worse
  # than a tidy up. Digits and dots only, no empty value, no dot segments.
  case "$OLD" in
    ''|.|..|*..*|.*|*[!0-9.]*)
      printf '\n!! not deleting dl/%s, that does not look like a version number\n' "$OLD" >&2 ;;
    *)
      say "Removing the mirror it replaces, dl/$OLD"
      ssh -i "$KEY" -p "$PORT" "$HOST" "rm -rf -- '$ROOT/dl/$OLD'" ||
        die "could not remove the old mirror. Everything else is done and live."
      left=$(ssh -i "$KEY" -p "$PORT" "$HOST" "ls '$ROOT/dl' 2>/dev/null" || true)
      printf '%s\n' "$left" | grep -qx "$OLD" &&
        die "dl/$OLD is still there after the delete"
      printf '%s\n' "$left" | grep -qx "$VER" ||
        die "dl/$VER has gone missing. Re-run this script."
      gone=$(curl -s -o /dev/null -w '%{http_code}' "$SITE/dl/$OLD/SHA256SUMS.txt?cb=$$" || true)
      echo "   gone, and $SITE/dl/$OLD/ now answers $gone"
      REMOVED=$OLD ;;
  esac
fi

printf '\nDone. %s is mirrored at %s/dl/%s/ and the download page points at it.\n' "$VER" "$SITE" "$VER"
[ -z "$REMOVED" ] || printf 'The mirror it replaced, dl/%s, has been deleted.\n' "$REMOVED"
[ "$KEEP_OLD" = "no" ] || [ "$OLD" = "$VER" ] ||
  printf 'dl/%s has been kept, as asked. Nothing links to it now.\n' "$OLD"
printf '\nStill to do by hand:\n'
cat <<EOF
  * IndexNow is deliberately not pinged while the outage notice is up, to keep
    "GitHub is down for this project" out of search snippets. Run
    site/indexnow.sh / once the notice comes off.
  * in-app updates still fail for everyone. The updater reads latest.json from
    GitHub, which 404s publicly, and pointing it here would mean baking this
    host into every installed client for good.
EOF
