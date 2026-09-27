#!/usr/bin/env bash
# Run the TLC model checker on a TLA+ spec. Downloads tla2tools.jar on first use.
# If the spec contains a PlusCal algorithm, it is translated to TLA+ first.
#
# Usage: tlc.sh path/to/Spec.tla [extra TLC flags]
#   Spec.cfg must sit next to Spec.tla (TLC picks it up automatically).
#   Useful flags: -deadlock (do NOT report deadlock, for terminating models)
#                 -depth N  (with -simulate, for random-walk exploration of big models)
set -euo pipefail

JAR="${TLA2TOOLS_JAR:-$HOME/.tla/tla2tools.jar}"
if [[ ! -f "$JAR" ]]; then
  mkdir -p "$(dirname "$JAR")"
  echo "Downloading tla2tools.jar to $JAR ..." >&2
  curl -fsSL -o "$JAR" https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi

spec="$1"; shift
cd "$(dirname "$spec")"
base="$(basename "$spec" .tla)"

if grep -qE -- '--(fair )?algorithm' "$base.tla"; then
  # -nocfg keeps the translator from overwriting a hand-written Spec.cfg
  java -cp "$JAR" pcal.trans -nocfg "$base.tla" >/dev/null
  rm -f "$base.old"
fi

exec java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -cleanup "$@" "$base.tla"
