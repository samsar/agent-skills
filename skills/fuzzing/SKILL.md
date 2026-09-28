---
name: fuzzing
description: >
  Find crashes, hangs, memory-safety bugs and wrong outputs with coverage-guided fuzzing:
  write a harness, seed it, run the fuzzer (libFuzzer, AFL++, cargo-fuzz, Go's native
  fuzzing, Atheris, Jazzer), then triage, minimize and fix what it finds. Use this skill when
  the user mentions fuzzing, fuzzers, fuzz tests or harnesses, OSS-Fuzz, or ASan/UBSan — and
  also, even if they don't say "fuzz", when code handles input it doesn't control and the
  question is "what happens with malformed or hostile input": file formats and media
  decoders, network protocols, deserializers, decompression, config, template and query
  languages, interpreters, HTML/URL sanitizers, an encode/decode pair that should
  round-trip, or two implementations that should agree. Not for concurrency between actors
  (use tla-plus), proving logic correct for all inputs (use lean4), CRUD or UI, systems the
  user isn't authorized to test, or "fuzzy" string matching.
allowed-tools: Bash Read Write Edit Grep Glob
---

# Fuzzing

A fuzzer calls a target function with a huge number of generated inputs, often thousands per
second, and reports the ones that make it misbehave. Coverage-guided fuzzers instrument the
code, keep every input that reaches a new branch, and mutate those inputs further. That lets
them work their way into deep parser states that random input never reaches. A fuzzer only
finds bugs in code the **harness** calls, and only the ones the **oracle** flags. Getting
those two right is most of the work.

## 1. Check whether fuzzing fits

Good fit: code that takes bytes or structured data from outside and branches a lot on it.
That covers parsers, decoders, deserializers, protocol handlers, decompressors, interpreters,
sanitizers and format converters. The payoff is highest in C, C++, unsafe Rust and cgo,
where a malformed input can corrupt memory. Memory-safe languages still hit panics, uncaught
exceptions, infinite loops, stack overflows on deep nesting, and huge allocations sized by a
length field. With a round-trip or differential oracle, fuzzing also finds wrong outputs.

Poor fit, so say so briefly and move on:
- Bugs that depend on interleaving between threads, processes or services: use the
  **tla-plus** skill.
- A small piece of pure logic that must be right for *all* inputs: use the **lean4** skill.
  A fuzzer can still generate the inputs for its differential test.
- CRUD, UI and glue code with little input handling: use ordinary tests.
- Targets that need a network call, a database or a new process for every input run too
  slowly to fuzz well. Stub the I/O and fuzz the logic behind it, or say fuzzing isn't worth
  it here.

Only fuzz code and services the user owns or is authorized to test. An in-process harness
on local code is always fine. Fuzzing a network service sends it a large volume of
malformed traffic, so use a local or staging instance and confirm with the user first.

## 2. Choose targets

Find where outside data enters. Grep for `parse`, `decode`, `unmarshal`, `deserialize`,
`load`, `read_`, `from_bytes`, request-body and upload handlers, and CLI options that take a
file. Rank the candidates by:
- how directly untrusted input reaches them (network, then uploaded files, then config
  written by operators),
- how much branching logic they contain,
- memory-unsafe code, hand-written length and offset arithmetic, and recursion,
- past bugs in the area (look for crash fixes in `git log`).

Start with one or two targets, and write one harness per entry point.

## 3. Define the oracle

A fuzzer that only watches for crashes finds memory corruption in C and C++ and not much
else. Use every check below that applies:

- **Sanitizers** (C, C++, Rust, cgo). AddressSanitizer catches out-of-bounds access and
  use-after-free, and UndefinedBehaviorSanitizer catches undefined behavior. Turn both on by
  default. MemorySanitizer (uninitialized reads) needs a separate build and only runs on
  Linux.
- **No unexpected errors.** Rejecting bad input with a documented error is correct. Any
  other exception, panic or abort is a bug.
- **Round-trip**: `decode(encode(x)) == x`, or `parse(print(parse(s))) == parse(s)`.
- **Differential**: two implementations must agree. Examples: old vs new, optimized vs
  reference, yours vs a well-known library, or production vs a Lean model from the lean4
  skill.
- **Output invariants**: lengths add up, results stay sorted, values stay within declared
  bounds, `normalize(normalize(x)) == normalize(x)`.
- **Resource limits**: a per-input timeout catches infinite loops and catastrophic regex
  backtracking. A memory limit catches decompression bombs and allocations sized by an
  attacker-controlled length field.

The most common mistake is putting the line between "rejected" and "bug" in the wrong place.
If the harness catches every error (`except Exception`, `catch (Throwable)`, `recover()`), it
hides real bugs. If it catches none, the fuzzer "finds" hundreds of documented parse errors.
Catch exactly the error types the API documents for bad input. Before or alongside the first
run, show the user a short plain-English list of what counts as a bug, so they can correct it.

## 4. Pick the tool

Use the tool that fits the project's language and test setup. Run `scripts/fuzz.sh doctor`
(the path is relative to this skill's directory) to see what's installed.

| Language | Tool | Notes |
|---|---|---|
| C, C++ | libFuzzer with ASan + UBSan | Needs a clang that ships the libFuzzer runtime. Apple's Xcode clang doesn't: use Homebrew LLVM or a Linux container. For programs that read a file or stdin and are hard to harness, use AFL++. |
| Rust | cargo-fuzz | libFuzzer + ASan. Needs a nightly toolchain. |
| Go | `go test -fuzz` | Built in since Go 1.18. There are no sanitizers, so panics and your own `t.Fatal` checks are the oracle. |
| Python | Atheris | Wheels are published only for x86-64 Linux. On macOS or ARM, run it in an amd64 Linux container, or fall back to Hypothesis. |
| Java, Kotlin | Jazzer | JUnit 5 `@FuzzTest`. Built-in detectors for injection, unsafe deserialization and path traversal. |
| JavaScript, TypeScript | Jazzer.js, or fast-check | fast-check is property-based (not coverage-guided) but runs in Jest and Vitest. |
| HTTP API with an OpenAPI spec | Schemathesis | Local or staging instance only. |

`references/languages.md` has the harness, build, run, reproduce, minimize and regression
steps for each tool. Read the section for the tool you're using. Flags change between
versions, so trust the tool's `-help` output and error messages over remembered flags.

## 5. Write the harness

A harness takes the fuzzer's input and drives one entry point:

- **Fast and in-process.** No network, disk, subprocesses or sleeps. Stub them, or fuzz the
  layer below them. Aim for thousands of executions per second (hundreds for Python and
  Java). Throughput turns directly into coverage.
- **Deterministic.** Derive any randomness from the input, freeze the clock, and reset global
  state and caches between runs. Otherwise crashes won't reproduce.
- **Clean between iterations.** Free what you allocate. libFuzzer reports leaks, and a slow
  leak eventually shows up as an out-of-memory crash.
- **Catches only the documented errors** from section 3, and lets everything else escape.
- **Calls the API the way real callers can.** If callers always guarantee a precondition (a
  valid handle, a length that fits the buffer, a header that was already validated), the
  harness must guarantee it too. A crash caused by breaking a documented precondition is a
  harness bug.
- **Splits structured input.** When the target takes several typed arguments or an object,
  build them from the bytes with `FuzzedDataProvider` (C++, Atheris, Jazzer), the
  `arbitrary` crate (Rust), or typed fuzz arguments (Go).
- **Gets past checks the fuzzer can't satisfy.** Checksums, MACs, signatures and compression
  wrappers stop the fuzzer at the first check. Recompute the checksum in the harness, or skip
  the check in fuzzing builds only (the C/C++ convention is
  `#ifndef FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION`).

Put harnesses in the repo where the language's tooling expects them: `fuzz/` for C, C++ and
Rust, `*_test.go` for Go, the test tree for Java.

## 6. Seeds and dictionary

The fuzzer builds on its seeds, so good seeds save hours.

- **Seeds**: small, valid, varied inputs. Take them from test fixtures, docs examples and
  sample files in the repo. Many small seeds beat a few large ones. Then read the parser and
  write seeds for the features the fixtures miss, such as each message type, optional
  section or encoding.
- **Dictionary**: for text formats and anything with magic numbers, collect the keywords,
  delimiters and magic byte sequences the parser compares against. libFuzzer and AFL++ take
  `-dict=file`, one token per line: `kw1="SELECT"`, `"\x89PNG"`.

## 7. Run

A fuzzer runs until it's stopped, so always set a time limit, and run it in the background
if your environment allows.

1. **Smoke run, about a minute.** Check executions per second, and check that coverage keeps
   growing. A crash in the first seconds on a near-empty input is almost always a harness
   bug, usually a documented error that wasn't caught. Fix the harness and run again.
2. **Real run.** In an interactive session, default to 5–10 minutes per target on all
   cores, and tell the user the budget. Offer hours for code exposed to untrusted input,
   because new bugs keep turning up well after the first few minutes.
3. **Check for a plateau.** If coverage stops growing early, the fuzzer is stuck behind a
   check. Generate a coverage report over the corpus, find the first important branch it
   never takes, and unblock it: add a seed or dictionary entry, bypass the checksum, or
   switch to structured input. Then run again. A clean run with low coverage says little.

## 8. Triage every crash

A long run often saves hundreds of crash files for a handful of bugs. For each one:

1. **Reproduce** it by running the harness on that single file. If it doesn't reproduce,
   the harness isn't deterministic (see section 5). Fix that first.
2. **Minimize** it with the tool's minimizer, so the input shows the trigger and nothing else.
3. **Deduplicate** by error type plus the top stack frames in the project's own code.
4. **Find the root cause.** The crash site is often not the bug. A read overflow in
   `copy_pixels` usually traces back to an unchecked width in `read_header`. Report the
   root cause as `file:line`.
5. **Classify** it:
   - *Real bug*: real input can reach this code with these bytes.
   - *Harness bug*: the harness called the API in a way real callers can't. Fix the harness,
     not the code.
   - *Expected*: the code rejected bad input as documented, and the harness should have
     caught the error.
6. **Rate severity.** Out-of-bounds writes, use-after-free and double frees can be
   code-execution bugs. Out-of-bounds reads can leak memory. Null dereferences, panics,
   uncaught exceptions, hangs and OOMs are denial of service when the input is untrusted.
   Round-trip, differential and invariant failures are correctness bugs.

A memory-corruption bug in code that handles untrusted input may be a security
vulnerability. Say so, and let the user decide how to disclose it before any reproducer
goes somewhere public, including a commit to a public repo.

## 9. Fix and lock it in

- Fix the root cause. Catching the panic or exception in the caller hides the bug; it
  doesn't fix it.
- Keep the minimized input as a regression test. Go does this automatically in
  `testdata/fuzz/`. For other tools, add it to a committed regression corpus, or write a unit
  test with the bytes inline.
- Run the fuzzer again after the fix. This confirms the fix, and often finds the next bug
  deeper in the code that the first one was hiding.
- Offer this, but don't do it by default: commit the harnesses and a minimized seed corpus,
  replay the corpus as ordinary tests on every build, and add a short fuzzing job to CI
  (ClusterFuzzLite, or `go test -fuzz` with `-fuzztime`). Open-source projects can apply to
  OSS-Fuzz for continuous fuzzing.

## 10. Report

1. **Targets**: each entry point fuzzed, where its harness lives, and its oracle.
2. **Setup**: tool, sanitizers, seed count and dictionary.
3. **Run**: duration, cores, executions per second, total executions, final coverage, and
   whether coverage plateaued.
4. **Findings**: each unique bug with its minimized input (as hex or an escaped string), the
   root cause as `file:line`, its classification and severity, and the command that
   reproduces it.
5. **Fixes and regression tests** added.
6. **Gaps**: code the harness doesn't reach and checks the oracle doesn't make. A clean run
   isn't a proof: "no crashes in 12M executions over 10 minutes" is evidence, and only for
   the code that was covered.
