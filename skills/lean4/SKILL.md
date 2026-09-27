---
name: lean4
description: >
  Prove small, critical pieces of logic correct with the Lean 4 theorem prover, then tie the
  proof back to the real code with differential testing. Use this skill when the user mentions
  Lean, Lean 4, Mathlib, a theorem prover or proof assistant, or wants to formally prove or
  verify code — and also, even if they don't name Lean, when a piece of pure logic "must never
  be wrong" and tests feel insufficient: authorization / permission / policy evaluation,
  pricing, billing, tax or money math, rounding and allocation (splitting amounts, proration),
  parsers and serializers (round-trip), state-transition rules, scheduling or ranking
  algorithms, and data-structure invariants. Works on existing code in any language (port the
  core to Lean) or for new logic. Not for concurrency between actors (use tla-plus), I/O-heavy
  glue, CRUD, or UI — and not "lean" in the lean-startup / lean-manufacturing sense.
allowed-tools: Bash Read Write Edit Grep Glob
---

# Lean 4 proofs for critical logic

Lean 4 is a purely functional programming language and a proof assistant in one. You write a
function and theorems about it, and Lean's kernel checks every proof. If it builds with no
`sorry`, the theorem holds for **all** inputs, not just the tested ones. Lean compiles to C and
then to a native binary. Proofs are erased at compile time, so they cost nothing at runtime.
Lean cannot translate to Python, Go or TypeScript, and it cannot prove things about code
written in those languages. It only proves things about Lean code.

## 1. Check whether Lean fits

Good fit: a **small, pure** piece of logic (inputs in, outputs out, no I/O) where a wrong
answer is expensive or silent. Examples: money and rounding, access decisions, parsers,
state-transition rules.

Poor fit, so say so briefly and redirect:
- Several actors with interleaving, retries or crashes: use the **tla-plus** skill. That's a
  design problem, not a pure-function problem.
- Large surface area, I/O, CRUD, UI: use tests. Property-based tests get much of the value
  for a fraction of the effort.
- Proofs cost far more than tests. If the logic is simple and a bug would be cheap and
  obvious, say that proofs aren't worth it here.

## 2. Pick the mode

- **Reference model + differential testing** (the default, and the right choice whenever the
  production code isn't in Lean). Port the core logic to Lean, prove its properties, then
  run random inputs through both the Lean executable and the production code and require
  identical outputs. AWS runs its Cedar authorization language this way: the proven model is
  in Lean and the production engine is in Rust.
- **Tool written in Lean**: a CLI, checker, or compiler where Lean itself is the product.
- **Lean library called over C FFI** from a service: possible but awkward to build and ship.
  Only choose it if the user asks for it.

## 3. Port the logic faithfully

Mirror the production code's structure so the user can review the two side by side. For
existing code, add a `-- src: path/file.py:42` comment to each Lean definition. Then check
for semantic mismatches. These are where Lean models most often go wrong, and a mismatch can
make a proof true about Lean while false about production:

- **`Nat` subtraction stops at 0** (`3 - 5 = 0`). If production can go negative, use
  `Int`. Otherwise a model can "prove" `price ≥ 0` when production returns -250.
- **Integer division and modulo on negatives** differ between languages. Python floors;
  Go, Java, Rust and C truncate. Pick the Lean operation that matches, such as `Int.fdiv` or
  `Int.tdiv`.
- **Fixed-width overflow**: if production uses int32/int64 and could overflow, model it with
  `Int64`/`UInt64`/`BitVec`, or prove the inputs stay in range.
- **Floats**: proofs about `Float` are close to impossible. If the production code uses
  floats for money, that's a finding in itself. Model the value as integer cents or `Rat`,
  and flag the float usage.
- **Strings, Unicode, and ordering/tie-breaking** in sorts and maps.

Lean's standard library API changes between releases (for example, `String.trim` is
deprecated in favor of `String.trimAscii`). Trust compiler errors and warnings over memory
of API names.

## 4. Write theorem statements in plain English first, and have the user confirm them

The kernel checks the proof, not whether the theorem says anything useful. Show the user a
short list of what will be proved ("the discount never exceeds the price", "parse ∘ print =
id", "a denied rule always wins over an allowed one") and let them correct it before the
proof work starts.

Guard against statements that are true but hollow:
- **Contradictory or overly strong hypotheses** make any conclusion provable. Check that
  the hypotheses can actually be satisfied with a concrete example.
- **Weak conclusions**: `discounted p d ≤ p` holds for *any* input because of `Nat`
  truncation, so it proves nothing. Ask whether a buggy version of the function would fail
  the theorem. If it wouldn't, strengthen the theorem.
- Add a few `#eval` examples next to each theorem as a sanity check.

## 5. Prove

- Before a hard proof, look for a counterexample with `#eval` over a small range of inputs.
  If the theorem is false, you've found a bug: report the concrete input. That's often the
  most valuable result of the whole exercise.
- Useful tactics: `simp [defs]`, `omega` (linear arithmetic on `Nat`/`Int`), `decide`
  (finite checks), `induction ... with`, `cases`, `unfold`, and `grind` for more automation.
- Leave out Mathlib unless you need real mathematics. It's a multi-GB dependency, and core
  Lean is enough for most software logic.
- **Done means `lean.sh check` passes.** An unfinished proof marked `sorry` still compiles,
  so a clean build alone proves nothing.

## 6. Tooling

```bash
L=<this skill's directory>/scripts/lean.sh
$L new <parent-dir> <Name>     # Lake project: <Name>/Basic.lean (logic + theorems), Main.lean (exe)
$L check <project-dir>         # build; FAIL on sorry, axiom, unsafe, native_decide, admit
$L run <project-dir> < cases   # build and run the executable
```

On first use the script installs elan (Lean's toolchain manager) into `~/.elan`, a download
of a few hundred MB. Tell the user when that's about to happen. Put the project under
`verification/lean/` in the repo, or in a temp directory if the user doesn't want it
committed.

## 7. Differential testing

Make `Main.lean` read one test case per stdin line and print one result per line:

```lean
import Pricing

def main : IO Unit := do
  let stdin ← IO.getStdin
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    match (line.trimAscii.toString.splitOn " ").map String.toNat? with
    | [some price, some pct] => IO.println (discounted price pct)
    | _ => IO.println s!"ERR {line.trimAscii}"
```

On the production side, write a test in the project's own framework (pytest with
Hypothesis, `go test`, fast-check, proptest) that generates many inputs, pipes them through
the Lean executable in one batch, and compares outputs line by line. Weight input generation
toward edges: 0, negatives, boundaries, maximum values, empty collections, ties. Every
mismatch is either a production bug or a porting error. Work out which before reporting it.

## 8. Report

1. **What was modeled**: the functions ported (with source locations) and what was left out.
2. **Theorems**, in plain English, each marked proved or disproved. For a disproved theorem,
   give the concrete counterexample.
3. **Check**: the `lean.sh check` result.
4. **Semantic mismatches** found or ruled out (Nat/Int, division, overflow, floats).
5. **Differential testing**: number of cases run and any mismatches, each classified as a
   production bug or a porting error.
