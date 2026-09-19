#!/usr/bin/env bash
# Sets up a push target on the Linux box that compiles what you send it.
#
# Only for a remote box reached over SSH. WSL does not need it: there is no
# sshd to push to, so tools/check-linux.sh drives the check directly instead.
#
# Run this ON the VPS, once, after linux-setup.sh. Afterwards:
#
#   git remote add vps <user>@<host>:printvault.git     (on your machine, once)
#   git push vps main
#
# and the check runs there, with its output coming back through the push.
#
# A note on what this can and cannot do. post-receive runs after the push has
# already been accepted, so a failing check reports loudly but does not reject
# anything. That is on purpose and it matches what check.yml did: this is a
# second opinion about Linux, not a gate. The canonical remote is still GitHub.
# Making it a gate means pre-receive, which refuses the push and leaves the two
# repos disagreeing about what exists, which is worse.

set -euo pipefail

BARE=${BARE:-$HOME/printvault.git}
WORK=${WORK:-$HOME/printvault}

say(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

command -v git >/dev/null 2>&1 || { echo "git is missing; run vps-setup.sh first" >&2; exit 1; }

say "Bare repo at $BARE"
[ -d "$BARE" ] || git init --quiet --bare "$BARE"

say "Work tree at $WORK"
mkdir -p "$WORK"
[ -d "$WORK/.git" ] || git -C "$WORK" init --quiet

say "Writing the post-receive hook"
cat > "$BARE/hooks/post-receive" <<'HOOK'
#!/usr/bin/env bash
set -uo pipefail

BARE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/printvault}

# Hooks run with GIT_DIR pointing at the bare repo, which quietly hijacks every
# git command run afterwards, including the ones inside the check. Clearing it
# first is not optional.
unset GIT_DIR GIT_WORK_TREE GIT_QUARANTINE_PATH

while read -r _old new ref; do
  branch=${ref#refs/heads/}
  [ "$branch" = "$ref" ] && continue          # a tag, not a branch

  printf '\n==> %s -> checking %s\n' "$branch" "${new:0:9}"
  git --git-dir="$BARE" --work-tree="$WORK" checkout -f "$new" -- 2>/dev/null \
    || git --git-dir="$BARE" --work-tree="$WORK" checkout -f "$new"

  if [ -x "$WORK/tools/linux-check.sh" ]; then
    # The check cds to its own repo root, so it does not care where it is run
    # from. Output streams back through the push as remote: lines.
    if "$WORK/tools/linux-check.sh"; then
      printf '\n==> OK, %s compiles on Linux\n\n' "${new:0:9}"
    else
      printf '\n'
      printf '!! ============================================\n'
      printf '!! %s DOES NOT COMPILE ON LINUX\n' "${new:0:9}"
      printf '!! The push was accepted; this is a report, not a gate.\n'
      printf '!! ============================================\n\n'
    fi
  else
    printf '!! tools/linux-check.sh is missing or not executable in %s\n' "$WORK"
  fi
done
HOOK
chmod +x "$BARE/hooks/post-receive"

say "Done"
echo "  On your machine, once:"
echo "    git remote add vps $(whoami)@$(hostname -f 2>/dev/null || hostname):${BARE#"$HOME"/}"
echo "  Then:"
echo "    git push vps main"
