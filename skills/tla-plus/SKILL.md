---
name: tla-plus
description: >
  Model a system's design in TLA+ (or PlusCal) and exhaustively check it with the TLC model
  checker to find concurrency and partial-failure bugs that tests almost never hit. Use this
  skill when the user mentions TLA+, PlusCal, TLC, model checking, or formally verifying a
  design — and also, even if they don't name TLA+, when they are designing or debugging logic
  where multiple actors share state or messages: job queues and workers, retries and
  timeouts, locks and leases, leader election, idempotency / exactly-once / "can this ever
  double-charge", cache invalidation, sagas and multi-step workflows across services,
  replication, or a rare race condition nobody can reproduce. Works both spec-first (design
  before code) and on existing source code (extract a model from it). Not for single-threaded
  pure logic, CRUD endpoints, or UI.
allowed-tools: Bash Read Write Edit Grep Glob
---

# TLA+ design checking

TLA+ describes a system as a state machine: its initial states and the steps each actor can
take. TLC explores every reachable state of a small instance (say 2 workers, 2 jobs, 1
retry) and either confirms the properties hold or returns the exact sequence of steps that
breaks one. It checks the *design*, not the code. The value is in finding interleavings and
failure orderings that no one thought to test.

## 1. Check whether TLA+ fits

Good fit: several actors (threads, processes, services, clients) share state or exchange
messages, and correctness depends on ordering, crashes, retries, duplicates, or timeouts.

Poor fit, so say so briefly and move on:
- Single-threaded logic, algorithms, or calculations: use tests or property-based tests.
  If it must never be wrong, mention Lean.
- CRUD endpoints, UI, and glue code: use ordinary tests.

## 2. Pick the mode

- **Spec-first**: the design isn't built yet, or it's about to change. Model the design,
  check it, then implement from the checked spec.
- **Model existing code**: the code exists. Read it and extract a model of the concurrency
  part. Tag every action in the spec with the `file:line` it comes from, so each step of a
  counterexample points back to real code.

## 3. Scope the model

Model the smallest piece where interleaving or failure matters. Leave out everything else
and say what you left out. Write down:

- **Actors** and **shared state**, such as DB rows, queues, caches, and in-flight messages.
- **Atomic steps.** This is the most important modeling decision. One TLA+ action should
  equal one step that nothing else can interleave with in the real system. A DB read
  followed by a write, without a transaction or conditional update, is *two* actions. Models
  that are too coarse hide exactly the bugs you're looking for. When modeling code, check
  the real atomicity (transactions, `SELECT ... FOR UPDATE`, compare-and-set, locks) and
  don't assume it.
- **Failures the real system can have**: crash/restart, message loss, duplication and
  reordering, timeouts firing late, retries. Leaving a failure out means it won't be checked.

## 4. Write the properties first, in plain English, and have the user confirm them

TLC proves the spec satisfies the properties. It cannot tell whether the properties are the
ones the user cares about. That review is the user's job, and it's the most valuable thing
they'll do. Show them a short plain-English list before or alongside the first run:

- **Safety**, meaning something bad never happens: "a job is never processed by two workers
  at once", "the balance never goes negative".
- **Liveness**, meaning something good eventually happens: "every submitted job eventually
  completes". Liveness needs fairness assumptions (`WF_vars`, or `fair process` in PlusCal),
  so state them, because they are claims about the real system.

Also guard against **vacuity**, which is the classic trap. A model that deadlocks early or
never reaches the interesting states passes every safety check. Add a reachability check: a
temporary invariant that *should* fail, e.g. `~(\E j \in Jobs : state[j] = "done")`. Confirm
that TLC finds a trace to that state, then remove the check.

## 5. Write the spec

- Use **PlusCal** when the actors are naturally sequential processes (workers, clients,
  handlers). It reads like code, so the user can review it against their implementation.
  Each label is one atomic step. Use **raw TLA+** for message-passing protocols and
  anything that doesn't fit "process runs a sequence of steps".
- Keep constants tiny: 2–3 actors, 2 items, bounded retries. Most bugs show up at small
  sizes, and state spaces grow exponentially. Use model values (`Workers = {w1, w2}`).
- Put `Spec.tla` and `Spec.cfg` next to the code under `specs/`, or in a temp directory if
  the user doesn't want files in the repo. The `.cfg` lists `CONSTANTS`, `SPECIFICATION Spec`,
  `INVARIANT ...`, and `PROPERTY ...`.

## 6. Run TLC

```bash
scripts/tlc.sh path/to/specs/Spec.tla   # add -deadlock if the model is meant to terminate
```

`scripts/tlc.sh` is relative to this skill's directory. The script downloads `tla2tools.jar`
on first use (it needs Java), translates PlusCal if present, and runs TLC.

Read the result:
- **Invariant or property violated.** Don't paste the raw trace. Tell it as a story with
  real names ("1. Worker A reads the job as pending. 2. Worker B reads it as pending. 3. A
  claims it..."), with `file:line` in code mode. Before calling it a bug, check whether the
  real system can actually take those steps. If it can't, the model is too permissive, so
  fix the model instead.
- **Deadlock.** Either the system really can get stuck, or the model reaches a legitimate
  end state. For the second case, use `-deadlock` or add an explicit terminal step.
- **No errors.** Report the constants and the distinct-state count. This means no bug
  exists *within these bounds*. It isn't a proof for all sizes. Say so.
- **Too slow or out of memory.** Shrink the constants, add symmetry, or narrow the scope.

After a fix, update the spec and run TLC again, so the fix itself is checked.

## 7. Report

1. **What was modeled**: actors, atomic steps, the failures included, and what was left out.
2. **Properties**: the plain-English list, marked pass or fail.
3. **Result**: bounds, state count, and the narrated counterexample if any.
4. **Fix**: a concrete change to the design or code, re-checked.
5. **Model gaps**: assumptions where the model may differ from reality.

## Keeping spec and code aligned

- **Spec-first:** implement each spec action as an identifiable unit (a function, a
  transaction, a handler) and name it after the action, so reviewers can compare the code
  to the spec. When the design changes, change the spec first.
- **Trace validation** (offer it, don't do it by default): when the gap between model and
  code matters, have the code log each state transition as structured events, then check
  those logs against the spec with TLC. This turns "the model matches the code" from an
  assumption into something checked on real runs.
