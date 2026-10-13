# Testing workflow

How to keep the three suites in step with the server as it grows. `testing-plan.md` says
*why* the suites are shaped the way they are; this file says what to do, in what order, for
each kind of change.

## The rule

**Redis decides, rung 0 records, rung 3 searches, `baseline` remembers what you have chosen
not to fix yet.**

- Every expected answer comes from a real `redis-server`, never from reading our own code.
- A behaviour we support is pinned as an exact-bytes row in `ConformanceSpec` (rung 0).
- `DifferentialSpec` (rung 3, oracle = Redis) searches for behaviour nobody wrote down.
- `ModelSpec` (rung 3, oracle = our model) searches for state- and time-dependent bugs.
- A divergence we understand but have not fixed is a named class in `baseline`, with an
  entry in `known-gaps.md`.

Every suite stays green. A suite that is red for a known reason trains you to ignore red,
and then it stops being a gate.

## Setup

Everything runs inside the flake's dev shell, which provides GHC, `stack` and
`redis-server` 8.10.1:

```
nix develop
stack test
```

To ask the reference something by hand, start a throwaway server:

```
redis-server --port 6390 --save "" --appendonly no
redis-cli -p 6390 command info lrange     # arity
redis-cli -p 6390 command docs lrange     # argument grammar
redis-cli -p 6390 lrange l 0 -1           # any command, to see its reply
```

The suites start their own server on an ephemeral port, so this one never interferes.

## Adding a command

The common case: one per CodeCrafters stage. Write the tests first, from Redis's answers.

1. **Ask the reference.** Query `COMMAND INFO` and `COMMAND DOCS`, then try the happy path,
   the edge cases, and wrong-arity and wrong-type inputs with `redis-cli`.
2. **Rung 1.** Add the command's arity to `ConformanceSpec.arities`. The arity rows are
   derived from it.
3. **Rung 0.** Add rows to `ConformanceSpec.singles`, and to `sequences` where earlier
   commands affect the answer. Only behaviour you intend to support now; copy the reply
   bytes from Redis. The rows start red.
4. **Implement** in `lib/` until Suite 1 is green.
5. **Rung 3, reference.** Add the command to `FrameGen.genWellFormed`; the token
   perturbations apply to it automatically. Any new token added to `FrameGen.garbage` must
   be checked against `COMMAND INFO` first. Run the explorer at volume (see Cadence).
6. **Triage** whatever the explorer finds — see "When a suite goes red".
7. **Rung 3, model**, if the command reads or writes store state. In `ModelSpec`:
   - add an `Op` constructor, a `frameOf` case, a `step` case (semantics measured in
     step 1), a `genOp` weight and a `shrinkOps` case;
   - add an `Answer` constructor and a `render` case if the reply shape is new (an array,
     for `LRANGE`);
   - write `expectLast` rows for the boundaries.
8. **Spot-check by hand.** Break one line of the new code — an off-by-one, swapped
   branches — confirm some suite turns red, then revert.
9. **Record.** Update `known-gaps.md`, and "Next" in `testing-plan.md`.

## Fixing a known divergence

1. Pick a class from `DifferentialSpec.baseline`. Write its conformance rows first, with
   bytes from Redis. They start red.
2. Fix `lib/` until they are green.
3. In `DifferentialSpec`, delete the class completely: the constructor, its `baseline`
   entry, its `triage` guard and its `triageSpec` rows. If the bug returns, the
   conformance rows catch it, and the explorer reports it as `Untriaged`.
4. In `known-gaps.md`, replace the entry with a one-line resolution naming the test.
5. Run the explorer at volume. A fix can change which error Redis-visible precedence
   reaches first and expose a different class.

## Refactoring

No test changes. If a suite turns red, the refactor changed behaviour, and the failure says
where. For extra confidence, run the explorer with the same few `--seed` values before and
after.

## When a suite goes red

| suite | it means | what to do |
|---|---|---|
| `ConformanceSpec` | agreed behaviour changed | fix the code, or re-measure against Redis and change the row on purpose |
| `DifferentialSpec` | Redis does something not on record | reproduce the shrunk frame in `redis-cli`, then either fix it and add a conformance row, or name its root cause (below) |
| `ModelSpec` | the code and the model disagree | check the model against Redis first; fix whichever side is wrong, and if it was the model, add an `expectLast` row pinning the corrected fact |

**Naming a new divergence class** takes five edits, all in one commit:

1. a `Divergence` constructor named after the root cause, not the input;
2. a `triage` guard that recognises it from the observed replies;
3. `triageSpec` rows: at least one that it names, and one nearby that must stay
   `Untriaged`;
4. a `baseline` entry;
5. a `known-gaps.md` entry with the frame, both replies and the cause.

Two traps:

- **Do not loosen `triage` until the failure fits.** A triage that names everything keeps
  the suite green and proves nothing. The `Untriaged` rows in `triageSpec` exist to stop
  this.
- **Rule out the harness first.** A real command name in `garbage`, or a short TTL getting
  past `genExpiry`'s floor, produces a divergence the generator caused rather than found.

## Cadence

| when | run |
|---|---|
| every change | `stack test` |
| end of a stage, before committing | the explorer with a few seeds: `stack test --test-arguments '--match "finds no divergence" --qc-max-success 3000 --seed 1'`, then seeds 2, 3 |
| every stage | `codecrafters test` — the only thing that drives a real socket against `Main`, so the only coverage of `fullQuery` (known-gaps #10) |
| after a nixpkgs bump that changes `redis-server` | everything; reference behaviour can move, so re-verify a broken conformance row against Redis before changing code |

Commit the test change together with the code change, and a `baseline` deletion together
with the fix it records, so each commit reads as one decision.

## Where things live

| to change | edit |
|---|---|
| exact replies we support | `ConformanceSpec.singles`, `ConformanceSpec.sequences` |
| a command's arity | `ConformanceSpec.arities` |
| which commands the explorer generates | `FrameGen.genWellFormed` |
| tokens, keys, values, expiries the explorer uses | `FrameGen.garbage`, `genKey`, `genValue`, `notAnInteger`, `genExpiry` |
| divergences on record | `DifferentialSpec.Divergence`, `baseline`, `triage`, `triageSpec` |
| store semantics | `ModelSpec.Op`, `frameOf`, `step`, `live`, `Answer`, `render` |
| model generation and shrinking | `ModelSpec.genOp`, `genTtl`, `genAdvance`, `shrinkOps` |
| facts the operation language cannot express | `ModelSpec.rawSpec`, using `Beat` |
| how our server is driven | `Redis.Sut` (`sutReply`, `sutReplyAt`) |
| how the reference is driven | `Redis.Reference` |

## Current state

As of 2026-10-13: `stack test` reports 122 examples and 0 failures, so every suite can act
as a gate. The explorer and the model property are also clean at 3,000 cases over several
seeds.

Mutation testing has been done once, by hand, on 2026-10-09; nothing re-runs it. Step 8 of
"Adding a command" is the manual substitute.
