# Testing plan: three suites, three contracts

Written 2026-10-09. Supersedes the single `DifferentialSpec` that tried to be all
three at once — which is why its oracle got convoluted.

**Built 2026-10-09.** All four steps of the work order are done. What exists:

| module | role | contract | state |
|---|---|---|---|
| `test/Redis/Reference.hs` | owns a real `redis-server` | — | green |
| `test/Redis/Sut.hs` | drives our implementation at `Main`'s boundary | — | green |
| `test/Redis/FrameGen.hs` | token-level frame generator | — | green |
| `test/Redis/ConformanceSpec.hs` | Suite 1 | always green | 43 rows, green |
| `test/Redis/DifferentialSpec.hs` | Suite 2 | no *new* divergence class | green at 27k cases |
| `test/Redis/ModelSpec.hs` | Suite 3 | always green | green |

Suite 3 found a real defect on its first run: `RPUSH` appended to expired records
(`known-gaps.md` #14, confirmed against 8.10.1). It is fixed, with liveness now decided in
`Store.get`, and all three suites are green: `stack test` reports 122 examples and 0
failures.

**Day-to-day use is in `testing-workflow.md`:** what to edit, in what order, when adding a
command, fixing a divergence or refactoring, and what each suite's red light means.

**Names follow the literature, deliberately.** The two sides of a differential step are
the **SUT** (system under test) and the **reference implementation**, so the modules are
`Redis.Sut` and `Redis.Reference`. "Model" is reserved for the *abstract* model, which is
`Redis.ModelSpec.step` — calling the real server a "ModelServer", as an earlier version
did, inverts the standard vocabulary and did in fact mislead a reader into thinking Suite 3
compared against Redis. Naming the observed-divergence step `triage` rather than `classify`
avoids a collision with `Test.QuickCheck.classify`, which labels test-case distribution and
is unrelated. See §1 of `architecture/research/spec-driven-development.md` for the prior art
these names come from.

Two names deliberately do *not* follow the literature. `baseline` is kept because it is
already the standard term in lint and static analysis, the closest analog (Chromium's
synonym is "expectations"). `FrameGen.perturb` is kept rather than renamed to a fuzzing
*mutator*, because this project uses "mutation" for mutating the **implementation** — the
hand audit described under "What the build taught us", and the vacuity defence in §3 of the
research doc. Keeping the two unconfusable is worth more here than matching the term.

The suites found four more things while being built, all now in `known-gaps.md`:
#15 (our expiry integer grammar is looser than Redis's), #16 (a value error
pre-empts a grammar error), #17 (an option's value is not consumed
positionally), #18 (list order is unobservable, found by a hand mutation audit,
not by a suite). Gaps #6, #7 and #9 turned out to be already fixed and now have
tests naming them; #8, #10 and #11 are narrowed.

## The diagnosis

One suite was doing two incompatible jobs:

- **conformance** — does `SET k v EX abc` produce Redis's exact bytes? A finite
  question about a grammar, with a lookup-table answer.
- **exploration** — are there behaviours where we differ from Redis that we have
  not noticed? An open question, answerable only by generation.

They want opposite contracts. Conformance must be **green always** or it is not a
regression gate. Exploration must be **allowed to find things** or it is pointless.
Forcing both through one property is what produced `knownDivergence` +
`verdict` — a predicate trying to *predict* divergence, which needs a model of
Redis's error precedence that we do not have.

Add to that a third job that neither covers:

- **stateful semantics** — does a sequence of commands behave like a key-value
  store with expiry? Infinite, interaction-shaped, and the only one of the three
  where property-based testing is clearly the best tool.

## The key realisation about subsets

We only generate commands we have implemented, so it is tempting to think the
comparison is already scoped. It is not: every divergence found so far was
*inside* an implemented command.

| divergence | command implemented? |
|---|---|
| `PING msg` echoes the message | yes — the optional argument is not |
| `SET k v NX` | yes — the NX option is not |
| `SET k v EX abc` error text | yes, and EX too — the error vocabulary is not |
| `SET k v EX -1 0` validation order | yes — the precedence is not |
| `BOGUS a` lists arguments | yes — the argument listing is not |

The subset boundary is at the level of **behaviours within a command** — options,
arities, error codes, error precedence, value edge cases — not at the level of
commands. And that boundary is **discovered, not declared**: we learn where it is
by running the explorer.

Which makes the divergence list an *output*, not scaffolding. It is the discovered
specification of what our subset currently is.

---

## Suite 1 — Conformance table

`test/Redis/ConformanceSpec.hs` · **contract: always green** · no generation

A list of `(tokens, expectedReplyBytes)` rows, asserted exactly. Covers only
behaviour we *claim* to support. No oracle problem: each row carries its own
answer.

**Where the rows come from**

- Captured from `redis-server` once, then reviewed row by row. Recording is
  accurate and fast; the review is what makes it a specification rather than a
  snapshot of whatever we currently do.
- Arity rows driven by data: `COMMAND INFO <name>` gives `arity` (negative means
  "at least |n|, variadic"), so "fewer than |arity| tokens → wrong number of
  arguments" is one rule per command rather than a hand-written case each.
- Seeded from the explorer's baseline: every time a divergence gets *fixed*, its
  case moves from the baseline into this table. That migration is how a fix is
  recorded, and it is the only fix-detection mechanism we need.

**Why not a generator here.** The cases are enumerable and each has one right
answer. Generation adds a need to predict answers, which is the whole problem.

**Note.** Redis serves its own spec — `COMMAND DOCS set` returns the full
argument grammar including which version added each option. No need to fetch
`src/commands/*.json` from GitHub, and no version skew: it is the spec of the
exact server under comparison.

---

## Suite 2 — Differential explorer

`test/Redis/DifferentialSpec.hs` · **contract: no *new* divergence class** · generated

Keeps the token-level perturbation generator, which is what reached the five findings
the `Command`-level generator structurally could not. Everything about the oracle
changes.

**Triage, do not predict.** The current `knownDivergence` tries to say in
advance which inputs will differ, and cannot, because an input may carry several
violations and Redis reports whichever comes first. Replace it with a classifier
that runs *after* observing a divergence:

```haskell
triage :: TestInput -> Reply -> Reply -> DivergenceClass
```

No precedence model needed — we are naming something we already observed.

**One assertion:** the set of classes seen in this run is a subset of the
recorded baseline. A new class fails the suite and prints the minimal example.

**Deliberately one-directional.** Asserting "every baseline class must still
appear" would be flaky — a class may not be hit in 300 cases. Fix detection lives
in Suite 1 instead, via the migration above. A baseline entry is removed by hand
when its conformance row is added.

**Baseline lives in `architecture/known-gaps.md`** or a sibling data file, so it
stays a readable statement of where we stop matching Redis.

**Data-design fix owed here:** replace the three parallel lists (`frames`,
`ours`, `theirs`) with one record per step. That removes `zipWith3`, the
hand-rolled `zipWith4`, and makes the length check unnecessary — misalignment
becomes impossible by construction rather than caught by assertion.

---

## Decision: wall-clock TTLs are not differentially testable

Found 2026-10-09, while reviewing the fix that moved `getCurrentTime` into
`getReply` so `now` is sampled per command (correct — it matches `Main`, which
samples after the frame arrives).

**Two clocks, two timelines.** Both sides now read the real wall clock, but time
does not *elapse* at the same rate between commands:

- our commands run in-process, back to back, microseconds apart;
- each of Redis's commands costs a socket round trip, so twenty commands span a
  millisecond or more.

So a 1 ms TTL expires on Redis partway through a sequence and never expires on
our side. Measured directly through `Reference`:

| sequence | ours | redis |
|---|---|---|
| `PX 1`, `GET` immediately | `$1 v` | `$1 v` |
| `PX 1`, 20 `PING`s, `GET` | `$1 v` | `$-1` |
| `PX 1`, 60 `PING`s, `GET` | `$1 v` | `$-1` |
| `PX 50`, 60 `PING`s, `GET` | `$1 v` | `$1 v` |

Neither implementation is wrong. They are being asked about different instants.

**Why this is worse than flaky.** Seed 7 at 300 cases failed reproducibly, 3/3
runs, always at test 275 — because the skew is consistently one-directional
(Redis is always the slower timeline). A reliable failure that is purely an
artefact of the harness looks exactly like a genuine finding; it cost several
rounds of investigation before the cause was isolated.

The `now` fix neither caused nor cured it. Before, a frozen per-sequence `now`
meant our side could *never* expire mid-sequence while Redis always could — same
divergence, same direction.

**Chosen response — raise the floor, and move expiry to Suite 3.**

1. **Keep short TTLs out of the generator's reach.** `genSetOption` draws
   `arbitrary :: Int`, which at size 100 yields roughly `[-100, 100]`, so `PX 1`
   is reachable. Floor the generated values (around `PX >= 1000`, `EX >= 1`) so
   every generated TTL outlives any plausible sequence. This loses nothing the
   suite was actually testing: it exercises the expiry *grammar* and
   *validation*, never expiry *timing*.
2. **Expiry semantics belong to Suite 3**, where the injected clock and an
   explicit `AdvanceTime` command make them exhaustively testable with no
   sleeping and no second process.

Rejected: recording it as a known divergence class. It is a property of the
harness, not of the implementation, and `known-gaps.md` is for the latter.

Worth stating plainly: **the differential suite has never tested expiry
behaviour**, before or after the fix. A generated sequence completes in well
under a millisecond, so no key with a sane TTL ever expires during a run. The
floor makes that honest rather than accidental.

---

## Suite 3 — Stateful model

`test/Redis/ModelSpec.hs` · **contract: always green** · generated · no Redis

The suite that will find bugs we cannot enumerate, and the only one where
model-based PBT is clearly the right tool.

- **Model:** `Map ByteString RedisValue` plus a logical clock.
- **Commands:** `SET` (with TTL), `GET`, `RPUSH`, and `AdvanceTime`.
- **Enabler already in place:** the clock is injected via `Env`, so
  `AdvanceTime` is just another generated command and expiry becomes
  exhaustively testable without sleeping.
- **Targets:** the expiry boundary (`isLive` uses `now <`, so a key is dead *at*
  `expiresAt` — pin it), last-write-wins, operations on distinct keys commuting,
  `WRONGTYPE` on a list read as a string.
- **Sole owner of expiry timing**, per the wall-clock decision above. Suite 2
  checks that the expiry *grammar* parses and validates like Redis; everything
  about *when* a key dies is tested here, on the logical clock.
- **Library:** hand-rolled, **not** `quickcheck-state-machine`. This is the one
  deviation from the plan as written, and the reasoning is recorded in the
  module header. The library is in `lts-23.18` (0.10.1), but it earns its
  ceremony — a GADT over a reference type, `Rank2` instances, `ToExpr`
  instances for the model — by providing symbolic references and
  parallel/linearizability testing, and we need neither yet: keys are generated
  directly rather than returned by an earlier command, and the store is driven
  single-threaded. Hand-rolled is ~100 lines with `shrinkList` giving shrinking
  for free. The library goes back on the table the day concurrent clients are
  tested, which is a real and separate step rather than a deferral.

---

## Shared infrastructure

`test/Redis/Reference.hs` — not a `*Spec`, so hspec-discover ignores it.

Both differential suites need the same handful of genuinely intrinsic things, and
isolating them is what keeps the properties readable:

- **spawn and tear down `redis-server`** with `--save "" --appendonly no`, poll
  until it accepts a connection, terminate in a `bracket`. Fixes two standing
  problems: the suite currently needs an externally-running server (so it cannot
  run on a fresh clone or in CI), and whatever started the current one wrote
  `dump.rdb` into the repo.
- **`FLUSHALL` per run** — our store is rebuilt per run while the server is
  long-lived; without the reset, run 12 compares an empty store against a model
  that remembers runs 1–11.
- **read exactly one reply**, with a timeout. The timeout is load-bearing: some
  frames draw no reply at all (an empty array), and a blocking `recv` turns that
  into a hung suite instead of a failing test. The current `recv 4096` also
  truncates any reply over 4 KB — not reachable by today's generator, but a
  9000-byte `ECHO` round-trips fine in both implementations and would produce a
  false divergence.

---

## What the build taught us

Three things worth keeping, because none of them were in the plan.

**A divergence splits the state, so only the *first* one in a run is evidence.**
The explorer's first version asserted that *every* divergence in a run was on
record. It reported this:

```
SET c 0 PX "1 "    ours: +OK          redis: ERR value is not an integer
RPUSH c xyz        ours: WRONGTYPE    redis: :1
```

The second line looks like a fresh `RPUSH` defect. It is a shadow of the first:
we created a key Redis never created, with a 1 ms TTL, then pushed onto its
expired remains. After the first disagreement the two implementations hold
different state and every later step compares two different worlds. The property
now cuts the run at the first divergence and discards the rest.

**The classifier needs its own conformance table, or the suite is vacuous.**
Suite 2 can only ever report "no new class" — which a classifier returning a
baseline entry for *everything* would also report. So `DifferentialSpec` carries
a group of exact-byte rows pinning each branch, including rows that must come
back `Untriaged`. In the hand audit, a mutation making the fall-through return a
baseline class failed them.

**A hand mutation audit found a gap in our own suites that no suite found.** On
2026-10-09 a throwaway script mutated one line of `lib/` at a time, re-ran the relevant
test group, compared failure counts and restored the file. About twenty mutants were
tried. The script was not committed and nothing re-runs it, so the results below are
dated observations that age with every change to `lib/` — mutation testing is a practice
this project has performed once, not tooling it has. Making
`EX` mean milliseconds instead of seconds survived every test in the project:
Suite 1 sees `+OK` either way because it has no clock, and Suite 3's model
generated `PX` only. Suite 3 now carries the unit to the wire (`Ttl = Ex | Px`).
A second survivor — `RPUSH` prepending instead of appending — turned out to be
unkillable and became gap #18. The notable outcomes are recorded in prose, in the
module comments and in `known-gaps.md`; the full run is not.

## Order of work

All four steps are done; kept here as the record of the order they were done in.

1. ~~**`Reference.hs`**~~ — spawn/teardown, flush, framed read with timeout.
   `dump.rdb` is in `.gitignore`.
2. ~~**Refocus Suite 2**~~ onto the classifier + baseline contract.
   `knownDivergence` and `verdict` are gone; the three parallel lists are one
   `Step` record; TTLs are floored in `FrameGen.genExpiry`.
3. ~~**Suite 1**~~ seeded from the measured agreements, with arity rows derived
   from the `COMMAND INFO` table rather than written case by case.
4. ~~**Suite 3**~~ — hand-rolled against a pure `Map` plus a logical clock.

**Next**, in rough order of value:

1. Fix gap #15 — a strict full-token integer parser matching Redis's `string2ll`,
   which also closes gap #5. Then move `ExpiryIntegerGrammarTooLoose` out of the
   baseline and into `ConformanceSpec`, which is what a fix looks like here.
2. Fix gaps #16 and #17 together: collect options, consume to `eof`, validate
   last, and commit to an option on its *name*. Same parser shape change as
   gap #8's remaining half, so all three move at once.
3. `PING msg` — the last of gap #11, and the only `PingIgnoresArguments` input.
4. `LRANGE` in `ModelSpec`, which closes gap #18 for free since the model already
   stores order. `LLEN` is in the model as of 2026-10-19, but a count cannot see
   order, so it leaves #18 open.

Pick off the known-gaps entries using Suite 1 as the record of each fix:
`PING msg`, the `SET` validation order, and `pSetOptions`' swallowed
`NotAnInteger` are all one root cause away from each other —
`many`/`<|>` discarding errors from a branch that had already consumed input.

## Still open, unrelated to the above

- `known-gaps.md` #12 (simple strings accept LF) and #13 (`shrinkResp` has no
  depth move) are both still open and both one-liners.
- Nothing drives a real socket against our own server, so `Main.fullQuery`'s
  buffering loop is still untested — the narrowed remainder of gap #10.
