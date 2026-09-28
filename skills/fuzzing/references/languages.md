# Per-language fuzzing recipes

Read only the section you need. Each one covers harness, build, run, reproduce, minimize and
regression. Commands assume the skill directory is `$SKILL` (e.g. `$SKILL/scripts/fuzz.sh`).

- [C and C++ (libFuzzer)](#c-and-c-libfuzzer)
- [C and C++ inside an existing build](#c-and-c-inside-an-existing-build)
- [AFL++](#afl)
- [Rust (cargo-fuzz)](#rust-cargo-fuzz)
- [Go (native fuzzing)](#go-native-fuzzing)
- [Python (Atheris, or Hypothesis)](#python-atheris-or-hypothesis)
- [Java and Kotlin (Jazzer)](#java-and-kotlin-jazzer)
- [JavaScript and TypeScript](#javascript-and-typescript)
- [HTTP APIs (Schemathesis)](#http-apis-schemathesis)
- [libFuzzer output and flags](#libfuzzer-output-and-flags)

## C and C++ (libFuzzer)

```c
// fuzz/fuzz_png.c
#include <stddef.h>
#include <stdint.h>
#include "png.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  struct image *img = png_decode(data, size);   // NULL on invalid input: not a bug
  if (img) {
    // An oracle beyond "doesn't crash": the pixel buffer matches the header.
    if (img->len != (size_t)img->width * img->height * 4) __builtin_trap();
    png_free(img);
  }
  return 0;
}
```

For C++, declare it `extern "C"`. To split the bytes into typed values, include
`<fuzzer/FuzzedDataProvider.h>` and use `FuzzedDataProvider fdp(data, size);` with
`fdp.ConsumeIntegral<uint16_t>()`, `fdp.ConsumeRandomLengthString()`, and
`fdp.ConsumeRemainingBytes<uint8_t>()`.

Build with a clang that has the libFuzzer runtime:

```bash
CC=$("$SKILL/scripts/fuzz.sh" cc)     # or: CXX=$("$SKILL/scripts/fuzz.sh" cxx)
$CC -g -O1 -fno-omit-frame-pointer \
    -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined \
    fuzz/fuzz_png.c src/png.c -Iinclude -o fuzz_png
```

`-fno-sanitize-recover=undefined` makes UBSan abort, so libFuzzer records the input. Without
it, UBSan prints a warning and the fuzzer carries on. If `fuzz.sh cc` finds nothing on macOS,
either `brew install llvm` (ask the user first, it's a large install) or work in a container:

```bash
docker run --rm -it -v "$PWD:/src" -w /src ubuntu:24.04 \
  bash -c 'apt-get update -qq && apt-get install -y -qq clang llvm && exec bash'
```

Run:

```bash
mkdir -p corpus crashes
./fuzz_png -max_total_time=300 -timeout=5 -artifact_prefix=crashes/ corpus seeds
```

The first directory (`corpus`) receives new interesting inputs. Later directories (`seeds`)
are only read. To use every core and keep going after crashes, add
`-fork=$(getconf _NPROCESSORS_ONLN) -ignore_crashes=1`. At the end of a fork run libFuzzer
may print a small leak report whose frames are all inside `fuzzer::FuzzWithFork`. That leak
belongs to libFuzzer, not your code.

Reproduce, minimize and prune the corpus:

```bash
./fuzz_png crashes/crash-<sha1>
./fuzz_png -minimize_crash=1 -runs=10000 -exact_artifact_path=crash.min crashes/crash-<sha1>
mkdir corpus.min && ./fuzz_png -merge=1 corpus.min corpus   # keep only inputs that add coverage
```

As a regression test, commit `crash.min` into a `fuzz/regressions/` directory and run
`./fuzz_png fuzz/regressions/*` in CI. Given files instead of directories, the binary runs
each one once and exits non-zero if any crashes.

Coverage report over the corpus (to find where the fuzzer is stuck):

```bash
$CC -g -fprofile-instr-generate -fcoverage-mapping -fsanitize=fuzzer \
    fuzz/fuzz_png.c src/png.c -Iinclude -o cov_png
LLVM_PROFILE_FILE=cov.profraw ./cov_png -runs=0 corpus
llvm-profdata merge -sparse cov.profraw -o cov.profdata
llvm-cov show ./cov_png -instr-profile=cov.profdata src/png.c   # 0-count lines never ran
```

Use the `llvm-profdata` and `llvm-cov` that match the clang (for Homebrew LLVM, they're in
the same `bin/` directory).

## C and C++ inside an existing build

Compile the project's own code with instrumentation but without libFuzzer's `main`, then add
`-fsanitize=fuzzer` only when linking the harness:

```bash
export CC=$("$SKILL/scripts/fuzz.sh" cc) CXX=$("$SKILL/scripts/fuzz.sh" cxx)
export CFLAGS="-g -O1 -fno-omit-frame-pointer -fsanitize=fuzzer-no-link,address,undefined -fno-sanitize-recover=undefined -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
export CXXFLAGS="$CFLAGS"
# configure and build the library with the project's build system (cmake, make, meson, ...)
$CC $CFLAGS -fsanitize=fuzzer fuzz/fuzz_png.c build/libpng.a -o fuzz_png
```

## AFL++

Use AFL++ when the target is a program that reads a file or stdin and is hard to wrap in a
harness function. It's easiest on Linux, and on macOS it needs a container
(`docker run -it -v "$PWD:/src" aflplusplus/aflplusplus`).

```bash
CC=afl-clang-fast AFL_USE_ASAN=1 make           # or afl-cc; builds an instrumented program
afl-fuzz -i seeds -o findings -V 300 -- ./prog @@   # @@ is replaced by the input file path
```

Crashes land in `findings/default/crashes/`. Minimize one with
`afl-tmin -i findings/default/crashes/<id> -o crash.min -- ./prog @@`. AFL++ can also run a
libFuzzer-style `LLVMFuzzerTestOneInput` harness. See its docs for the setup.

## Rust (cargo-fuzz)

```bash
cargo install cargo-fuzz
rustup toolchain install nightly
cargo fuzz init -t parse          # creates fuzz/ with fuzz/fuzz_targets/parse.rs
cargo fuzz add decode             # more targets later
```

```rust
// fuzz/fuzz_targets/parse.rs
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = mycrate::parse(data); // Err is fine; a panic is the bug
});
```

For structured input, derive `arbitrary::Arbitrary` on an input type (add `arbitrary` with
the `derive` feature to `fuzz/Cargo.toml`) and write `fuzz_target!(|input: MyInput| ...)`.

```bash
cargo +nightly fuzz run parse -a -- -max_total_time=300 -timeout=5
```

`-a` turns on debug assertions and integer-overflow checks, which the default release build
leaves off. ASan is on by default. Arguments after `--` go to libFuzzer. Crashes are saved to
`fuzz/artifacts/parse/crash-<sha1>`, and cargo-fuzz prints the commands to reproduce and
minimize:

```bash
cargo +nightly fuzz run parse -a fuzz/artifacts/parse/crash-<sha1>
cargo +nightly fuzz tmin parse fuzz/artifacts/parse/crash-<sha1>   # writes minimized-from-<sha1>
cargo +nightly fuzz cmin parse                                      # prune the corpus
cargo +nightly fuzz coverage parse                                  # coverage over the corpus
```

For a regression test, add a normal `#[test]` that calls the function on the minimized bytes
(`include_bytes!` or an inline byte string).

## Go (native fuzzing)

```go
// kv/kv_fuzz_test.go
func FuzzParse(f *testing.F) {
	f.Add([]byte("name=alice\nrole=admin\n")) // seeds
	f.Fuzz(func(t *testing.T, data []byte) {
		m, err := Parse(data)
		if err != nil {
			return // rejecting bad input is fine; a panic is the bug
		}
		again, err := Parse(Marshal(m)) // round-trip oracle
		if err != nil || !reflect.DeepEqual(m, again) {
			t.Fatalf("round trip changed the value: %q -> %q (err %v)", m, again, err)
		}
	})
}
```

Fuzz arguments can be `[]byte`, `string`, `bool`, `byte`, `rune`, any int or uint type,
`float32` and `float64`. Take several of them instead of splitting one byte slice.

```bash
go test -run='^$' -fuzz='^FuzzParse$' -fuzztime=5m ./kv
```

`-fuzz` must match exactly one fuzz target per package. Go minimizes a failure
automatically, writes it to `testdata/fuzz/FuzzParse/<hash>`, and prints the command to
rerun it (`go test -run=FuzzParse/<hash> ./kv`). Plain `go test` replays everything in
`testdata/fuzz/`, so a committed failing input is already a regression test.

The generated corpus lives outside the repo, in `$(go env GOCACHE)/fuzz/<import path>/FuzzParse/`.
For a coverage report, copy those files into `testdata/fuzz/FuzzParse/`, then run
`go test -run=FuzzParse -coverprofile=c.out ./kv && go tool cover -html=c.out`. Remove the
copies afterwards unless the user wants them committed as seeds.

Go has no sanitizers for pure Go code. For cgo, `go test -asan` builds with AddressSanitizer
(it needs a clang or gcc that supports it).

## Python (Atheris, or Hypothesis)

```python
#!/usr/bin/env python3
# fuzz/fuzz_parse.py
import sys

import atheris

with atheris.instrument_imports():
    from mylib import ParseError, parse


def TestOneInput(data: bytes) -> None:
    try:
        parse(data)
    except ParseError:
        pass  # documented rejection of bad input, not a bug


atheris.Setup(sys.argv, TestOneInput)
atheris.Fuzz()
```

Atheris publishes wheels only for x86-64 Linux, so on macOS and ARM Linux run it in an amd64
container (emulated on Apple Silicon: slower, but it works). Install the project's own
dependencies inside it too:

```bash
docker run --rm -it --platform linux/amd64 -v "$PWD:/src" -w /src python:3.12 \
  bash -c 'pip install -q atheris && exec bash'
```

Make the harness executable (`chmod +x`, with the shebang above) and run it directly. Crash
minimization re-runs the program as `argv[0]`, which fails for a plain `python fuzz_parse.py`.

```bash
./fuzz/fuzz_parse.py -max_total_time=300 -timeout=5 -artifact_prefix=crashes/ corpus seeds
./fuzz/fuzz_parse.py crashes/crash-<sha1>                                  # reproduce
./fuzz/fuzz_parse.py -minimize_crash=1 -runs=2000 -exact_artifact_path=crash.min crashes/crash-<sha1>
```

Atheris takes libFuzzer flags. Use `atheris.FuzzedDataProvider(data)` for structured input.
If the code under test calls C extensions, see the Atheris README for building those with
sanitizers.

**Fallback: Hypothesis.** It isn't coverage-guided, but it installs everywhere, runs inside
pytest, and shrinks failures automatically:

```python
from hypothesis import given, settings, strategies as st

@settings(max_examples=50_000, deadline=None)
@given(st.binary())
def test_parse_only_raises_parse_error(data):
    try:
        parse(data)
    except ParseError:
        pass
```

Prefer strategies shaped like the input (`st.text()`, `st.from_regex(...)`, `st.recursive(...)`)
over raw bytes, because random bytes rarely get past the first check of a text format.

## Java and Kotlin (Jazzer)

Add the `com.code-intelligence:jazzer-junit` test dependency (check Jazzer's README for the
current version and setup), then:

```java
import com.code_intelligence.jazzer.api.FuzzedDataProvider;
import com.code_intelligence.jazzer.junit.FuzzTest;

class ParserFuzzTest {
  @FuzzTest(maxDuration = "5m")
  void parse(FuzzedDataProvider data) {
    try {
      Parser.parse(data.consumeRemainingAsString());
    } catch (ParseException expected) {
      // documented rejection of bad input
    }
  }
}
```

With `JAZZER_FUZZ=1` set, the test fuzzes (e.g. `JAZZER_FUZZ=1 mvn test -Dtest=ParserFuzzTest`).
Without it, the test runs in regression mode and replays saved inputs from a
`ParserFuzzTestInputs` directory under the test resources. That directory is where findings
go, so committing it gives you regression tests. Jazzer also reports SQL, LDAP and OS command
injection, unsafe deserialization, SSRF and path traversal on its own, with no oracle code.

## JavaScript and TypeScript

**Jazzer.js** is coverage-guided:

```js
// fuzz/parse.fuzz.js
const { parse, ParseError } = require("../src/parse");

module.exports.fuzz = function (data /* Buffer */) {
  try {
    parse(data.toString());
  } catch (e) {
    if (!(e instanceof ParseError)) throw e; // anything else is a bug
  }
};
```

```bash
npm install --save-dev @jazzer.js/core
mkdir -p corpus crashes
npx jazzer fuzz/parse.fuzz.js corpus --sync -- -max_total_time=300 -artifact_prefix=crashes/
npx jazzer fuzz/parse.fuzz.js --sync -- crashes/crash-<sha1>          # reproduce
npx jazzer fuzz/parse.fuzz.js --sync -- -minimize_crash=1 -runs=2000 \
  -exact_artifact_path=crash.min crashes/crash-<sha1>
```

`--sync` is faster when the target never returns a promise. Drop it for async targets.

**fast-check** is property-based and runs inside the existing Jest or Vitest suite:

```js
fc.assert(
  fc.property(fc.string(), (s) => {
    try { parse(s); } catch (e) { if (!(e instanceof ParseError)) throw e; }
  }),
  { numRuns: 100_000 },
);
```

## HTTP APIs (Schemathesis)

Only run this against a local or staging instance the user controls. Schemathesis generates
requests from the OpenAPI schema and flags 5xx responses and responses that don't match the
schema.

```bash
schemathesis run http://localhost:8000/openapi.json   # see `schemathesis run --help` for limits and auth
```

Each 5xx comes with a reproducing `curl` command. Triage it like any other crash: find the
handler, reproduce the failure in a unit test, and fix the root cause.

## libFuzzer output and flags

These apply to libFuzzer, cargo-fuzz, Atheris and Jazzer.

Progress lines look like
`#44480 NEW cov: 9 ft: 37 corp: 15/530b lim: 397 exec/s: 1134149 rss: 45Mb`.
`cov` is the number of code edges covered and `ft` counts finer-grained features. If both
stop rising early, the fuzzer has plateaued. `exec/s` is throughput.

Artifact names show the kind of failure: `crash-` (sanitizer error, abort, uncaught
exception), `timeout-` (over `-timeout`), `oom-` (over `-rss_limit_mb`, default 2048),
`leak-` (LeakSanitizer), `slow-unit-` (slow but under the timeout).

| Flag | Use |
|---|---|
| `-max_total_time=N` | Stop after N seconds. Always set it. |
| `-timeout=N` | Per-input time limit. The default is 1200 s, far too long to catch hangs, so use 5–10. |
| `-rss_limit_mb=N` | Memory limit, default 2048. |
| `-max_len=N` | Largest input to generate. Raise it if bugs need big inputs. |
| `-dict=FILE` | Dictionary of tokens (`kw="SELECT"`, `"\x89PNG"`). |
| `-fork=N -ignore_crashes=1` | N worker processes. Keep going after crashes. |
| `-artifact_prefix=DIR/` | Where crash files go. The trailing slash matters. |
| `-runs=N` | Stop after N inputs. `-runs=0` just replays the corpus. |
| `-merge=1 NEW OLD...` | Copy into NEW only the inputs that add coverage. |
| `-minimize_crash=1 -runs=N` | Shrink a crashing input. |
| `-print_final_stats=1` | Totals at exit, for the report. |
