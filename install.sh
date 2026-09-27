#!/usr/bin/env bash
# Symlink every skill in ./skills into each agent's personal skills directory.
# Safe to re-run: existing links are refreshed; real directories are never overwritten.
#
# Usage: ./install.sh
#   SKILL_DIRS overrides the target directories (space-separated), e.g. to add Codex:
#   SKILL_DIRS="$HOME/.claude/skills $HOME/.agents/skills" ./install.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
read -r -a targets <<< "${SKILL_DIRS:-$HOME/.claude/skills}"

for dir in "${targets[@]}"; do
  mkdir -p "$dir"
  for skill in "$repo"/skills/*/; do
    name="$(basename "$skill")"
    link="$dir/$name"
    if [[ -e "$link" && ! -L "$link" ]]; then
      echo "skip  $link (a real directory exists; move it aside first)" >&2
      continue
    fi
    ln -sfn "${skill%/}" "$link"
    echo "link  $link -> ${skill%/}"
  done
done
