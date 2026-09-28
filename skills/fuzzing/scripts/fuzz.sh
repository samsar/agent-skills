#!/usr/bin/env bash
# Fuzzing helper.
#
# Usage:
#   fuzz.sh doctor   list the fuzzing toolchains available on this machine
#   fuzz.sh cc       print a C compiler that can build libFuzzer targets (exit 1 if none)
#   fuzz.sh cxx      same, for C++
set -euo pipefail

# A clang that ships the libFuzzer runtime. Apple's Xcode clang does not, so prefer an
# explicit $FUZZ_CC, then Homebrew LLVM, then whatever clang is on PATH.
find_clang() {
  local probe cc brew_llvm=""
  command -v brew >/dev/null 2>&1 && brew_llvm="$(brew --prefix llvm 2>/dev/null)/bin/clang"
  probe="$(mktemp -d)"
  printf '#include <stddef.h>\n#include <stdint.h>\nint LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) { return 0; }\n' > "$probe/p.c"
  for cc in "${FUZZ_CC:-}" "$brew_llvm" /usr/local/opt/llvm/bin/clang clang; do
    [[ -n "$cc" ]] && command -v "$cc" >/dev/null 2>&1 || continue
    if "$cc" -fsanitize=fuzzer,address,undefined "$probe/p.c" -o "$probe/p" >/dev/null 2>&1; then
      rm -rf "$probe"; echo "$cc"; return 0
    fi
  done
  rm -rf "$probe"; return 1
}

no_clang_hint() {
  echo "No clang with the libFuzzer runtime found. Apple's Xcode clang doesn't ship it." >&2
  echo "  macOS: brew install llvm   (or set FUZZ_CC to a clang that has it)" >&2
  echo "  Linux: install clang (Debian/Ubuntu: apt install clang)" >&2
  echo "  Or build and run inside a Linux container." >&2
}

row() { printf '  %-22s %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

cmd="${1:-}"
case "$cmd" in
  cc|cxx)
    cc="$(find_clang)" || { no_clang_hint; exit 1; }
    if [[ "$cmd" == cxx ]]; then
      echo "$(dirname "$cc")/$(basename "$cc" | sed 's/clang/clang++/')" | sed 's|^\./||'
    else
      echo "$cc"
    fi
    ;;
  doctor)
    echo "Fuzzing toolchains on this machine:"
    if cc="$(find_clang)"; then row "C/C++ libFuzzer" "yes ($cc)"; else row "C/C++ libFuzzer" "no: Apple clang lacks it; brew install llvm, or use a Linux container"; fi
    if have afl-fuzz; then row "AFL++" "yes ($(command -v afl-fuzz))"; else row "AFL++" "no"; fi
    if have go; then
      v="$(go env GOVERSION 2>/dev/null || true)"
      minor="$(echo "$v" | sed -nE 's/^go1\.([0-9]+).*/\1/p')"
      if [[ -n "$minor" && "$minor" -ge 18 ]]; then row "Go native fuzzing" "yes ($v)"; else row "Go native fuzzing" "no: needs Go 1.18+ (have ${v:-unknown})"; fi
    else row "Go native fuzzing" "no: go not installed"; fi
    if have cargo; then
      if cargo fuzz --version >/dev/null 2>&1; then f="cargo-fuzz yes"; else f="cargo-fuzz no (cargo install cargo-fuzz)"; fi
      if have rustup && rustup toolchain list 2>/dev/null | grep -q '^nightly'; then n="nightly yes"; else n="nightly no (rustup toolchain install nightly)"; fi
      row "Rust" "$f; $n"
    else row "Rust" "no: cargo not installed"; fi
    if have python3; then
      py="$(python3 --version 2>&1)"
      if python3 -c 'import atheris' >/dev/null 2>&1; then a="atheris yes"; else a="atheris no (pip install atheris)"; fi
      if python3 -c 'import hypothesis' >/dev/null 2>&1; then h="hypothesis yes"; else h="hypothesis no"; fi
      row "Python" "$py; $a; $h"
    else row "Python" "no: python3 not installed"; fi
    if have java; then row "JVM" "$(java -version 2>&1 | head -1); Jazzer comes in as a build dependency"; else row "JVM" "no: java not installed"; fi
    if have node; then row "JavaScript" "node $(node --version); Jazzer.js / fast-check come in as npm dependencies"; else row "JavaScript" "no: node not installed"; fi
    if have docker && docker info >/dev/null 2>&1; then row "Docker" "yes: Linux containers available for tools that need Linux"; else row "Docker" "no"; fi
    ;;
  *)
    sed -n '2,7p' "$0"; exit 2
    ;;
esac
