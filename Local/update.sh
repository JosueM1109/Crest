#!/bin/zsh
# Moves the josue branch onto the maintainer's latest stable release (or a ref
# you name), then rebuilds and installs with Local/build-and-install.sh.
#
#   Local/update.sh                 latest stable release (GitHub "Latest")
#   Local/update.sh v0.8.60         a specific tag
#   Local/update.sh upstream/main   the maintainer's newest code (less tested)
#   Local/update.sh --rebuild       rebuild the current checkout without fetching
#
# Your commits on josue are replayed on top. If one conflicts with the
# maintainer's changes, git stops and this script explains what to do next.

set -euo pipefail

# Captured at top level: inside a zsh function, $0 is the function name.
script_path="${0:A}"

# The whole script is one function, so zsh has parsed all of it before the
# rebase rewrites the working tree (this file included).
main() {
  local repo="${script_path:h:h}"
  cd "$repo"

  if [[ "${1:-}" == "--rebuild" ]]; then
    exec "$repo/Local/build-and-install.sh"
  fi

  if [[ "$(git branch --show-current)" != "josue" ]]; then
    print -u2 "Switch to the josue branch first (git switch josue)."
    exit 1
  fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    print -u2 "You have uncommitted changes. Commit them (or git stash) and rerun."
    exit 1
  fi

  print "Fetching the maintainer's changes..."
  git fetch upstream --tags --prune --quiet
  local target="${1:-$(gh release view --repo pauljoda/Crest --json tagName --jq .tagName)}"
  git rev-parse --verify --quiet "${target}^{commit}" >/dev/null \
    || { print -u2 "Unknown ref: $target"; exit 1; }

  local base="$(git describe --tags --abbrev=0 --match 'v*' HEAD 2>/dev/null || print '')"
  local old_head="$(git rev-parse HEAD)"

  if git merge-base --is-ancestor "$target" HEAD; then
    print "Already on $target. Use --rebuild to rebuild anyway."
    exit 0
  fi

  print "Moving josue from ${base:-its current base} onto $target..."
  if ! git rebase "$target"; then
    print -u2 ""
    print -u2 "One of your commits conflicts with the maintainer's changes."
    print -u2 "  1. Fix the files git lists (git status), then: git add <files>"
    print -u2 "  2. git rebase --continue   (repeat until it finishes)"
    print -u2 "  3. Local/update.sh --rebuild"
    print -u2 "To give up and go back: git rebase --abort"
    print -u2 "Your branch before the update: $old_head"
    exit 1
  fi

  # Local/build-and-install.sh follows these upstream recipes. If the
  # maintainer changed them, the local copy may need the same change.
  if [[ -n "$base" ]]; then
    local changed="$(git diff --name-only "$base" "$target" -- \
      Scripts/install-local-macos-release.sh \
      Scripts/control-plane/package-chromium-host.py \
      CrestMac/Configuration/Crest.entitlements \
      CrestMac/Configuration/Crest-Info.plist)"
    if [[ -n "$changed" ]]; then
      print ""
      print "Heads up: the maintainer changed files Local/ is based on:"
      print "$changed" | sed 's/^/  /'
      print "If the build or app misbehaves, compare them with Local/ (git diff $base $target -- <file>)."
      print ""
    fi
  fi

  exec "$repo/Local/build-and-install.sh"
}

main "$@"
