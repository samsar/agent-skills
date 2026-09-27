#!/usr/bin/env bash
# Lean 4 helper. Installs elan (Lean's toolchain manager) on first use.
#
# Usage:
#   lean.sh new <parent-dir> <Name>   create a Lake project <parent-dir>/<Name> (library + executable)
#   lean.sh check <project-dir>       build, then fail on unfinished proofs or trust escapes
#   lean.sh run <project-dir> [args]  build and run the project's executable (stdin passes through)
set -euo pipefail

export ELAN_HOME="${ELAN_HOME:-$HOME/.elan}"
export PATH="$ELAN_HOME/bin:$PATH"
if ! command -v lake >/dev/null 2>&1; then
  echo "Installing elan + stable Lean toolchain into $ELAN_HOME ..." >&2
  curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --no-modify-path --default-toolchain stable >&2
fi

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    cd "$1" && lake new "$2" >&2
    echo "Created $1/$2" >&2
    ;;
  check)
    cd "$1"
    set +e; log="$(lake build 2>&1)"; status=$?; set -e
    echo "$log" | tail -n 30
    [[ $status -eq 0 ]] || { echo "FAIL: build errors" >&2; exit 1; }
    if echo "$log" | grep -qE "declaration uses ['\`]sorry"; then
      echo "FAIL: unfinished proofs (sorry)" >&2; exit 1
    fi
    # Anything that makes Lean trust a claim instead of checking it.
    if grep -rnE '^\s*(axiom|unsafe)\b|native_decide|\badmit\b' --include='*.lean' --exclude-dir=.lake .; then
      echo "FAIL: trust escapes above (axiom / unsafe / native_decide / admit)" >&2; exit 1
    fi
    echo "OK: builds, no sorry, no trust escapes" >&2
    ;;
  run)
    dir="$1"; shift
    cd "$dir" && lake build >&2 && exec lake exe "$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]')" "$@"
    ;;
  *)
    sed -n '2,8p' "$0"; exit 2
    ;;
esac
