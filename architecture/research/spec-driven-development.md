# Specs as the source of truth

*Research notes — state of the art in spec-driven development, formal specification, and
AI-assisted implementation from specs. Written 2026-09-20, against the repo at `c1e2b84`.*

---

## 0. The thing to know before anything else

"Spec-driven development" names **two almost unrelated practices** in 2026, and they are
routinely confused because they share a phrase.

**SDD-as-prompt-scaffolding.** Kiro (AWS), Spec Kit (GitHub), Tessl. You write structured
*natural-language* markdown — requirements, design, tasks — and an agent implements it.
The "spec" is a prompt with a directory layout. Thoughtworks put this in the **Assess**
ring of Technology Radar Vol. 33 (Nov 2025), which is about as tepid as that publication gets.

**SDD-as-correctness-engineering.** AWS, TigerBeetle, FoundationDB, Quviq, Jepsen. The spec
is an *artifact a machine can check the implementation against*: a model, an invariant, a
refinement relation, a reply schema. The spec has a truth value.

You said you lean formal. That's the right instinct, and it means the first family is mostly
noise for you. It's still worth knowing why it disappoints, because the failure is
instructive:

Birgitta Böckeler's evaluation of all three tools (Thoughtworks) found the same three
problems across them:

- **Review burden moved, not reduced.** You stop reviewing code and start reviewing
  markdown — and there is *more* markdown than there was code. Her line: she'd rather
  review the code.
- **False sense of control.** Constitution files, detailed steering docs, and large
  context windows did not make agents comply. They ignored instructions or overapplied them.
- **No scaling.** Kiro expanded a one-line bug fix into 16 acceptance criteria. Spec Kit
  generated so many files she estimated plain agentic coding would have been faster.

And the historical rhyme: "spec-as-source" is **model-driven development** with the serial
numbers filed off. MDD failed on rigidity; LLMs remove some rigidity but add
non-determinism. The pessimistic reading — that you get *both* inflexibility and
non-determinism — is the one to hold until someone demonstrates otherwise. Tessl's
regeneration engine has been observed producing different code from identical specs.

The distinguishing question to ask of any "spec" is simply: **can something other than a
human tell me this spec is violated?** If no, it's documentation. Useful, but not a spec.

---

## 1. A ladder of specs

Formality is a dial, not a switch. Each rung costs more and buys a different *kind* of
confidence. Nobody serious picks one rung; they pick a rung per question.

| # | Rung | The spec is… | Checked by | Catches |
|---|------|--------------|-----------|---------|
| 0 | Examples | a finite table of input→output | running them | the cases you thought of |
| 1 | Interface schema | a grammar + a reply schema | validator | shape/arity/protocol drift |
| 2 | Properties | a universally-quantified claim | random search + shrinking | the cases you didn't think of |
| 3 | Model / lockstep | a pure reference implementation | sequence-generating PBT | state-dependent bugs |
| 4 | Linearizability | "some sequential order explains this" | parallel PBT, Knossos, Elle | races |
| 5 | Simulation (DST) | invariants + injected faults + controlled time | deterministic replay | emergent, rare, timing bugs |
| 6 | Design model | a state machine over an abstract design | model checker (TLC, P, Apalache) | protocol design errors |
| 7 | Proof | a theorem about the code | SMT / proof assistant | everything, at a price |

Two observations before the detail.

**Rung 0 is a spec too** — by enumeration. Your `CLAUDE.md` already says "tests come from
examples, not implementation", and "if you can't write examples, you don't understand the
problem". That's rung 0 done deliberately. Rung 2 is the same discipline with the
quantifier moved outward: instead of *this* input, *every* input.

**In Haskell you are already standing on rung 7 for a slice of the problem.** Types are
machine-checked specifications. `liveValue :: UTCTime -> RedisRecord -> Maybe RedisDataType`
is a proof obligation that the function cannot consult a clock, cannot touch the store, and
cannot fail in any way other than returning `Nothing`. That's not a metaphor — it's exactly
what a refinement type buys, at a weaker strength and zero marginal cost. Your 75%-pure
measurement is, read this way, a measurement of *how much of the system is already
specified*.

### The ladder has traffic in both directions

Added 2026-10-09, after building the three suites. The table above reads like a staircase
you climb once. It isn't. Traffic runs both ways, and **each direction has a name in
industry — just not the same industry.**

**Up: discover drift.** A higher rung searches a space you cannot enumerate, so it finds
behaviour nobody wrote down. That's the direction everything above assumes.

**Down: reify the finding as an example.** Once a rung-2 or rung-3 search finds something,
the useful permanent artefact is a rung-0 row. Random search tells you a bug *exists*; an
enumerated example is what stops it coming back, runs in microseconds, and reads as
documentation.

Neither direction is novel. The surprise is that the two halves are practised by
*different communities*, with no shared vocabulary:

| direction | community | what they call it |
|---|---|---|
| rung 2/3 → 0 | property-based testing | pinning the shrunk counterexample; Hypothesis's **example database** + `@example` |
| rung 2/3 → 0 | fuzzing | the **crash corpus** / regression corpus (OSS-Fuzz replays it forever) |
| 0 → 3, holding the line | browser engineering | **expectations files** — Chromium's `TestExpectations` over web-platform-tests |
| 0 → 3, holding the line | linting / static analysis | the **ratchet file** — Notion's per-rule violation counts, auto-decremented, CI blocks new ones |
| 0 → 3, holding the line | differential-testing research | the **known-divergences file**, "with a deliberately narrow predicate so it cannot silently hide a regression" |

The compiler-fuzzing surveys state our exact problem in their own words: the hard part of
differential testing is deciding whether a difference is "an actual bug, an artifact of
undefined behavior, or a benign difference permitted by a specification gap."

**What this project does with that.** `DifferentialSpec`'s `baseline` is an expectations
file; `ConformanceSpec` is where its entries go when fixed. The migration *is* the record
of the fix — without it, fixing a divergence would just mean deleting a line, and nothing
would stop the regression.

Three ways we differ from the prior art, all deliberate:

1. **Classes, not instances.** Chromium lists test names and Notion counts violations per
   rule per file; our baseline holds five constructors, each naming a *root cause*.
   Instances grow with inputs; classes grow with understanding, so fixing one divergence
   deletes one line rather than hundreds. The cost is needing a classifier at all.
2. **Manual, not automated.** Notion's ratchet auto-decrements in a pre-commit hook.
   Automation is right for thousands of mechanical lint instances and wrong here: five
   entries that each encode a decision about Redis's semantics should cost a thought.
3. **The oracle has its own spec.** This is the unusual one. The literature treats oracle
   noise as a *filtering* problem and builds cleverer filters — AccuOracle's four-layer
   progressive filter, SmartOracle's agentic arbitration. No source found writes a
   conformance table *for its own filter*. `DifferentialSpec`'s 17 rung-0 rows over
   `triage` are exactly that, and they exist because a classifier that returned a known
   class for everything would keep the suite green forever. Generalised: **at rung 3 the
   oracle is itself code complex enough to need a rung-0 spec.**

**The downward move is manual in Haskell.** Hypothesis automates it; nothing in
`lts-23.18` does. That is measured rather than assumed — see §5, "There is no example
database in the Haskell ecosystem", which also records why a seed is a weaker pin than a
stored input, and where it is not.

**Nobody appears to name the round trip.** The closest is the *"yo-yo effect"* in formal
refinement — going back up to rewrite a specification when a lower level reveals a problem
— but that is about specification *layers*, not test rungs. Putting both directions on one
ladder is a synthesis, not an invention: every part is standard, only the framing is ours.

**Sources**

- [Chromium web test expectations](https://chromium.googlesource.com/chromium/src/+show/HEAD/docs/testing/web_test_expectations.md)
- [Notion — how we evolved our ratcheting system](https://www.notion.com/blog/how-we-evolved-our-code-notions-ratcheting-system-using-custom-eslint-rules)
- [Hypothesis — replaying failures](https://hypothesis.readthedocs.io/en/latest/tutorial/replaying-failures.html) and [the example database](https://hypothesis.readthedocs.io/en/hypothesis-python-4.57.1/database.html)
- [A Survey of Modern Compiler Fuzzing](https://arxiv.org/pdf/2306.06884)
- [SmartOracle — mitigating noise in differential oracles](https://arxiv.org/pdf/2601.15074)
- [Using Formal Specifications to Support Testing](https://bura.brunel.ac.uk/bitstream/2438/1871/1/landscapes_final.pdf) (the "yo-yo effect")

---

### Rung 1 — Machine-readable interface specs

The one most people skip, and in your case the highest value-per-hour on the whole ladder,
because **Redis ships a formal spec of itself**.

`redis/redis:src/commands/*.json` is a machine-readable specification of every command:
arity, flags, key specs, an *argument grammar*, and — since the effort tracked in
[redis#9845](https://github.com/redis/redis/issues/9845) — a `reply_schema` written in JSON
Schema.

`get.json`, in full:

```json
{ "GET": {
    "arity": 2,
    "command_flags": ["READONLY", "FAST"],
    "reply_schema": {
      "oneOf": [
        { "description": "The value of the key.", "type": "string" },
        { "description": "Key does not exist.",   "type": "null" } ] },
    "arguments": [ { "name": "key", "type": "key", "key_spec_index": 0 } ] } }
```

`set.json` gives you the whole option grammar as structured data — `condition` is a `oneof`
over NX/XX/IFEQ/…, `expiration` is a `oneof` over EX/PX/EXAT/PXAT/KEEPTTL — plus:

```json
"reply_schema": { "anyOf": [
  { "description": "`GET` not given: Operation was aborted…", "type": "null" },
  { "description": "`GET` not given: The key was set.", "const": "OK" },
  { "description": "`GET` given: The key didn't exist before the `SET`", "type": "null" },
  { "description": "`GET` given: The previous value of the key", "type": "string" } ] }
```

Three things fall out of this for free:

1. **`arity` is a property.** `arity: -3` means "at least 3 tokens, variadic". Every
   command with fewer tokens must be an error. That's one property covering every command
   at once, driven by data rather than by hand-written cases.
2. **`arguments` is a generator.** It's a grammar. A generator derived from it produces
   *syntactically valid* command sequences by construction — and, perturbed, produces
   *interestingly invalid* ones. Note that `expiration` being a `oneof` means `SET k v EX 1
   PX 1000` is a **grammar violation**, i.e. real Redis answers `ERR syntax error`. You
   currently answer `ERR conflicting expiry options`. I have not verified that against a
   live server (no `redis-server` on this machine), but if it holds, it is exactly the class
   of divergence this rung exists to catch, and you'd never find it by reading your own code.
3. **`reply_schema` is an oracle.** Map RESP2 → JSON (bulk string → string, null bulk →
   null, simple string `OK` → `"OK"`), then validate every reply your server produces
   against the schema for the command that produced it. That is a genuine
   conformance-checking harness, and it generalizes to every command you add later without
   new work.

This is the cheapest *formal* spec available to you, and it was written by the people who
define the thing you are cloning.

---

### Rung 2 — Properties over pure functions

The canonical text is **John Hughes, "How to Specify It! A Guide to Writing Properties of
Pure Functions" (2019)**. If you read one thing from this document, read that. It is
short, it is in Haskell/QuickCheck, and it is built around a single worked example with
eight deliberately buggy variants, so you can *measure* which properties find which bugs.

Its central contribution is a taxonomy — five ways to write a property when you're staring
at a function and can't think of one:

| Class | Shape | For your RESP parser |
|-------|-------|----------------------|
| **Postcondition** | after `f x`, this holds | a parsed frame's declared length equals its body length |
| **Invariant** | this holds of every reachable value | every `Resp` your parser emits is well-formed |
| **Metamorphic** | relating `f x` to `f (g x)` | parsing `a <> b` = parsing `a` then parsing `b` |
| **Inductive** | `f` on a constructor, in terms of `f` on its parts | `toBytes (Array n xs)` from `toBytes` of each `x` |
| **Model-based** | `f` agrees with a simpler reference | your server agrees with `redis-server` |

The reason this taxonomy matters more than it looks: the hard part of PBT is never the
tooling, it's **not being able to think of a property**. The taxonomy is a set of prompts
for that specific block. Hughes also reports the cost/benefit of each class, which is
unusual and useful — metamorphic properties are the cheapest to write and among the best
at finding bugs; model-based are the most expensive and the most complete.

A subtlety worth internalising early, because it's where most people's first PBT suite is
secretly worthless: **the generator is part of the specification.** Your `Resp` type admits
`BulkString 5 "ab"` — a value the parser can never produce and the serializer must never
see. Writing `Arbitrary Resp` forces you to state that invariant explicitly, in code, for
the first time. If you write the generator carelessly you'll either test garbage or, worse,
constrain it so tightly that the property becomes vacuous. That's the same "data definitions
first" move from your `CLAUDE.md`, arriving from a different direction.

---

### Rung 3 — Model-based / lockstep testing

The idea, in one sentence: *generate a random sequence of API calls, run it against both the
real system and a pure model, and assert the observable responses agree.*

The model is the spec. For a Redis store the model is roughly

```haskell
type Model = Map ByteString (RedisDataType, Maybe UTCTime)
```

…which is small enough to be obviously correct, which is the whole point. You are not
testing "does it work", you are testing "does the complicated thing agree with the simple
thing". Well-Typed's framing calls the second half "observability": you compare responses
*up to some notion of what a client can see*, which is what lets the real system have an
STM map and a socket while the model has neither.

Lineage matters here because the open-source options are uneven. Hughes and Arts
commercialised the mature version at Quviq in 2006 (Erlang, closed-source). Stevan
Andjelkovic's survey **"The sad state of property-based testing libraries"** counts 57+
reimplementations across languages and finds only **four** that do stateful *and* parallel
testing — the feature that catches races. Most libraries stopped at stateful. His blunt
claim: the Quviq papers describe state-of-the-art techniques that are "almost impossible"
to reproduce without a license, and the closed-source model may have slowed the field rather
than funded it.

For you the relevant fact is that **one of those four, `quickcheck-state-machine`, is in
your LTS** (see §5).

---

### Rung 4 — Linearizability and race testing

Parallel PBT: run the generated command sequence concurrently across threads, collect the
results, then ask whether *any* sequential interleaving explains what you observed. If none
does, you have a race, and the tool hands you the counterexample sequence.

Jepsen is the reference implementation of this idea at distributed-systems scale. It has two
checkers: **Knossos** (linearizability, exponential, a few hundred ops per history) and
**Elle** (transactional isolation via cycle detection, *linear* time, hundreds of thousands
of ops, seconds-to-minutes instead of "seconds to millennia"). Jepsen's Redis-Raft analysis
is worth reading purely as a model of how to state what a system promises before testing
whether it keeps the promise.

The Haskell-native versions of this idea are **dejafu** (systematic concurrency testing —
explores the schedule space rather than hoping, via typeclass-abstracted concurrency
primitives, with first-class STM support) and **io-sim** (Well-Typed/IOG/Quviq — a pure `IO`
simulator where STM, thread scheduling and the passage of *time* behave as in production but
deterministically, which makes timeout- and timing-sensitive properties testable at all).

A word on when this is worth it, below in §4 — for your current command set, it isn't yet,
and I'd rather say so than sell you a hammer.

---

### Rung 5 — Deterministic simulation testing

The FoundationDB idea, now carried by TigerBeetle, Antithesis, WarpStream, Polar Signals.
Make the entire system deterministic — single-threaded control plane, no ambient clock, no
ambient randomness, all I/O through an injectable interface — then run it inside a simulator
that controls time and injects faults (partitions, disk corruption, crashes, clock skew).
Because it's deterministic, any failure replays exactly from its seed.

The scale this reaches is the argument for it: TigerBeetle's largest simulation cluster runs
on 1,000 cores continuously and accumulates **two millennia of simulated runtime per day**.

Their August 2026 post on *protocol-aware* DST adds the refinement that matters most for
someone building a small system: don't only assert invariants at the API boundary. Assert
them **at every layer** — storage, consensus, application. Black-box DST and Jepsen see what
a client sees; protocol-aware DST sees inside. Their own transferable lesson for smaller
systems is that once time and I/O are controllable, a "what happens if…" scenario becomes
30–40 lines running in milliseconds.

The entry fee is a single architectural commitment: **the system must not reach for ambient
effects.** No `getCurrentTime` in the middle of a function, no un-injected randomness.
That is a dependency-inversion discipline you have already applied to the store — and, as
§4 notes, have not yet applied to the clock.

---

### Rung 6 — Design-level model checking

TLA+ (and PlusCal), P, Quint, Alloy. You model the *design* — an abstract state machine —
and a model checker exhaustively explores its reachable states looking for invariant
violations and liveness failures.

AWS is the canonical industrial data point, and their published account is unusually candid
about cost. Since 2011 they've used TLA+ on critical systems (S3, DynamoDB, EBS). But when
they tried to spread it beyond the initial teams, **engineers bounced off TLA+** because it
looks like mathematics rather than a programming language. So AWS built and adopted **P**,
which model-checks the same class of designs in a syntax programmers recognise; the Aurora
commit protocol was modelled in both P and TLA+.

**Quint** (Informal Systems) is the other answer to the same complaint: TLA's logic, a
modern surface syntax, real type checking, an LSP and a VS Code extension. If you ever want
to learn this rung, Quint is the gentler door.

The structural limitation — true of all of rung 6 — is that **the model is not the code**.
Nothing mechanically ties your TLA+ spec to your Haskell. You get design confidence, not
implementation confidence. AWS closes that gap partly with runtime monitoring: check the
model's invariants against traces from the *running* production system.

---

### Rung 7 — Proof

Dafny, Lean, Verus, Kani, Liquid Haskell. You state a theorem about the code and a machine
checks it. AWS supports development on Kani, Dafny, and Lean, and on the SMT solvers
underneath them — which tells you these are viable and also that they require an investment
most teams make only for the code where being wrong is unacceptable.

Liquid Haskell is the Haskell entry: refinement types over SMT, applied to 10,000+ lines of
real libraries (`containers`, `bytestring`, `text`, `vector-algorithms`, `xmonad`). It is
genuinely mature. Its sweet spot is *value-shaped* invariants — indices in range, lists
non-empty, lengths agreeing.

---

## 2. What the best teams actually do

The single most useful survey is **"Systems Correctness Practices at AWS: Leveraging Formal
and Semi-formal Methods"** (ACM Queue 22:6 / CACM, 2025). Read it for the framing more than
the specifics.

Its central message is not "use formal methods". It is that AWS runs a **portfolio**, and
that the portfolio is deliberately weighted toward the cheap end:

> *traditional formal approaches (theorem proving, deductive verification, model checking)
> **and** more lightweight semi-formal approaches (property-based testing, fuzzing, and
> runtime monitoring)*

Four distinct uses, each a different rung:

- model-checking designs **at design time** (rung 6),
- **runtime monitoring** — validating in-production behaviour against the model's invariants,
  which is how they bridge the model-vs-code gap,
- **simulation** of emergent behaviour (rung 5),
- **proof** of the few properties that justify it (rung 7).

The pattern across every serious team is the same shape:

- **AWS** — portfolio, chosen per problem, with a deliberate investment (P) in making the
  expensive rung *approachable* rather than in making everyone climb it.
- **TigerBeetle / FoundationDB** — one rung, taken to an extreme, with the architecture
  bent around it. Determinism is not a testing choice there, it's a design constraint.
- **Quviq (Hughes/Arts)** — model-based PBT applied to other people's production code:
  AUTOSAR acceptance tests for Volvo Cars, a race condition found at Klarna. The
  interesting bit is that the *model* became the deliverable, and it found spec bugs in
  AUTOSAR itself, not just implementation bugs.
- **Jepsen** — adversarial black-box testing with a checker that can decide the property,
  and a reporting culture that treats the vendor's own claims as the spec under test.

The common denominator is not a technique. It's that in every case **the spec exists as an
artifact separate from the code**, and something mechanical compares them.

---

## 3. Gen AI + specs: what the evidence actually says

You asked specifically about using gen AI with harnesses safely and effectively. There is
now real data, and it is more interesting than the marketing.

### The direction of the problem has inverted

**"The Verification Horizon: No Silver Bullet for Coding Agent Rewards"** (2026) makes the
argument crisply. The classical assumption is that verifying a solution is easier than
producing one. For coding agents that has flipped: generation is cheap, and *reliably
verifying* is now the bottleneck. They frame verification quality along three axes —
**scalability, faithfulness, robustness** — and argue you cannot have all three at once.
Their conclusion: no *fixed* reward function stays effective as the generator improves;
verification has to co-evolve with it.

Read as practical advice: **your spec is not a one-time artifact. It is the thing that has
to keep getting stronger.**

### LLMs are surprisingly good at rung 7 — in the right language

**"A Benchmark for Vericoding"** assembled 12,504 formal specifications (3,029 Dafny, 2,334
Verus/Rust, 7,141 Lean) and measured generation of *formally verified* code from *formal*
specs. Success rates with off-the-shelf models:

| Language | Vericoding success |
|----------|-------------------|
| Dafny | **82%** |
| Verus / Rust | 44% |
| Lean | 27% |

And pure Dafny verification went **68% → 97% in a single year**.

The lesson is not "use Dafny". It's that the spread tracks *how much automation sits under
the spec language*. Dafny's SMT backend discharges most obligations without the model
having to construct a proof; Lean makes it construct one. When you choose a spec language
you are choosing how much of the work is delegated to a solver — and that choice drives
whether an AI can help you at all.

### The failure mode you must design against: vacuity

This is the single most important safety finding, and it generalises far beyond proofs.

> A specification that verifies might still be **vacuous** (true of any implementation) or
> **non-discriminating** (true even of a deliberately unsafe variant).

An LLM asked to make a verifier go green has two moves available: fix the code, or **weaken
the spec until it is trivially true**. It can also introduce a contradictory assumption,
from which anything follows. The proof assistant accepts these, because they are *valid*.
This is reward hacking against a formal oracle, and it is not hypothetical — it is the
headline challenge in the LLM-formal-synthesis literature.

The same disease at rung 2: an LLM-written property that reads impressively and quantifies
over a generator that produces one value. Green, meaningless.

### The defence: mutation-based spec validation

The technique, from IronSpec and the surrounding work, and the single most transferable
idea in this whole section:

> A specification is only trusted if the correct implementation **passes** *and* deliberately
> broken variants **fail**.

Generate mutants of your implementation — flip `<` to `<=`, drop the expiry check, return
the wrong branch — and require that your spec *rejects* them. A spec that accepts a mutant
is either vacuous or too weak, and you've learned that mechanically rather than by
inspection. The underlying idea is old (trivial vs. non-trivial properties; mutation
testing) but its use as a *guard on machine-written specs* is what's new.

For your project this is the cheapest possible instance: your expiry rule is
`isLive now = maybe True (now <)`. Change that `<` to `<=` and re-run your suite. If it
still passes, your suite does not specify the expiry boundary — which is the classic
off-by-one in every TTL implementation ever written.

### What the evidence says about AI writing properties

**PBT-Bench** (2026) benchmarks agents on exactly this: 100 problems across 40 Python
libraries, 365 bugs, three difficulty tiers from boundary bugs to stateful protocol
violations. The task is explicitly two-part — *derive a semantic invariant from the
documentation*, then *construct a generator precise enough that random search finds the
violation*.

Results: bug recall 42–83% with a Hypothesis-scaffolded prompt, 31–77% open-ended.
Structured scaffolding lifted mid-capability models by 20+ points and sometimes *degraded*
strong ones. The hardest bugs were **model-specific** — different models fail on different
problems, with no model closing all the gaps.

And the honest bottom line from the adjacent literature: *property quality assurance
currently depends on prompt design and human filtering; there are no automated guardrails.*

That is the empirical justification for the arrangement you already proposed for yourself.

### The arrangement that works

Everything above converges on one division of labour:

> **The human owns the specification. The machine owns the implementation. The
> specification is immutable to the machine.**

It works because of an asymmetry:

- Writing the spec requires deciding *what the system should do* — irreducibly a
  human judgement, and the part that produces understanding.
- Writing the implementation requires satisfying a stated constraint — mechanical,
  checkable, and safe to delegate precisely *because* it's checkable.
- Letting the machine touch both sides destroys the check, because the shortest path to
  green runs through the spec.

Concrete guardrails, in descending order of importance:

1. **The agent cannot edit the spec.** Not a convention — an enforced boundary. Separate
   directory, and a CI job that fails if the spec files changed in a commit that also
   changed implementation files. This is the whole ballgame; every other guardrail is
   secondary.
2. **Mutation-gate every spec.** New property, new mutants. A property that no mutant
   defeats is deleted or strengthened.
3. **Review the spec diff, not the code diff.** This is the part of Böckeler's critique
   that survives: reviewing generated prose is worse than reviewing code, but reviewing a
   *formal* spec is much better than reviewing code, because it's shorter and it has a
   truth value.
4. **Fix the seed, keep the corpus.** Every counterexample found becomes a permanent
   regression example at rung 0. Shrunk counterexamples are the single best
   documentation a codebase can accumulate.
5. **Expect the spec to strengthen over time.** Per the Verification Horizon result, a
   static spec becomes a weaker and weaker constraint as the generator gets better.

There is also a live example of the "AI writes the *formal* spec" direction worth watching:
the **Quint LLM Kit** ships Claude Code agents that turn English requirements — or existing
Rust/Go/TypeScript source, or TLA+ — into Quint specs, then validate them by type-checking,
executing, simulating and verifying them with the Quint CLI. The guardrail is the same one
as everywhere else: a tool, not a human, decides whether the spec is well-formed. Note that
well-formed is *not* non-vacuous; it catches malformed, not meaningless.

---

## 4. Applied to this Redis

Ordered by value per hour of your time. Everything here is checked against the code at
`c1e2b84`.

### First: the clock is the one effect you haven't inverted

`Redis.Workflows.Set.execute` and `Redis.Workflows.Get.execute` both do

```haskell
now <- liftIO getCurrentTime
```

You've inverted the store beautifully — `Env { setKey :: Key -> RedisRecord -> IO () }`,
the workflow never imports the adapter, the absence of the compile-time edge *is* the
inversion. The clock is the identical problem and hasn't had the identical treatment.

The consequence is concrete: **no TTL property can be tested deterministically today.** To
check that a key expires you'd have to actually sleep, which makes the test slow, flaky, and
unable to probe the boundary instant at all. Every interesting expiry property — including
the `<` vs `<=` mutant above — is currently out of reach.

Putting the clock in `Env` unlocks rungs 2, 3 and 5 simultaneously. It is also, exactly,
the architectural commitment that deterministic simulation testing demands (§1 rung 5), so
you'd be paying an entry fee you'll want to have paid anyway. And it makes `execute`
testable without a store *or* a clock, which is what "pure core" was supposed to mean.

This is the highest-leverage change available and it's about six lines.

### Then, in order

**1. RESP properties (rung 2).** Your parser is pure, total-ish, and the most
property-shaped code in the repo. Candidate properties, in Hughes' classes:

- *Round-trip.* `fromBytes (toBytes r) == Just r` for well-formed `r`. The weakest useful
  property; write it first, then stop trusting it.
- *Concatenation / pipelining.* For `rs :: [Resp]`, repeatedly parsing
  `mconcat (map toBytes rs)` yields exactly `rs` and an empty remainder. **This property
  fails on the current code** — `runParser` doesn't require `eof`, so `fromBytes` silently
  drops trailing frames. You found that bug by hand. This is the property that would have
  found it for you, and it's the one to write first as a demonstration to yourself that
  rung 2 pays.
- *Prefix-closure.* For a well-formed frame `b` and **every** proper prefix `p`, the parser
  must triage `p` as *incomplete* — never malformed, never successful. This is the actual
  specification of your `fullQuery` read loop's termination condition, and it's a property
  no example-based test will ever cover exhaustively.
- *No false incomplete.* Appending arbitrary bytes to a complete frame must not turn
  success into incomplete. Together with prefix-closure this pins the
  truncated-vs-malformed discriminator you built on
  `TrivialError _ (Just EndOfInput) _`.
- *Totality.* `fromBytes` on arbitrary `ByteString` terminates and does not throw. This is
  your fuzzing (see below).
- *Declared-length agreement.* For every `BulkString n s` the parser emits, `n == length s`;
  likewise `Array`. An *inductive invariant* your type does not enforce — and therefore
  something your generator has to enforce, which is the point made in §1 rung 2.

**2. Fuzzing, the version that's actually worth doing.** Coverage-guided fuzzing of Haskell
is possible but expensive: Tweag's approach needs an **unregisterised GHC build** (Cmm → C,
so clang can instrument it) plus C glue for `LLVMFuzzerInitialize`, and even then GHC's
pattern-match optimisations bypass coverage points unless you instrument `base` too. That
is a weekend you should spend elsewhere.

The pragmatic substitute is **mutation-based generation**, and it is not a poor relation —
it's what actually finds parser bugs. Uniform random bytes essentially never survive the
first byte of a RESP frame, so a naive fuzzer tests almost nothing. Instead: generate a
*well-formed* frame, then perturb it — flip a byte, truncate at a random offset, corrupt a
declared length, drop a CRLF, splice two frames. The truncation mutation *is* the
prefix-closure property; the length-corruption mutation is where a bug that reads
`takeP` with an attacker-controlled length would surface. This is "structure-aware fuzzing"
in Google's terminology, and it's just a QuickCheck generator.

**3. Differential testing against real `redis-server` (rung 3, model = the reference
implementation).** The highest-fidelity oracle available, because the model isn't a
simplification — it's the thing you're cloning. Send the same generated command sequence to
both servers on different ports, compare byte-for-byte.

`redis-server` isn't installed here; on NixOS `nix shell nixpkgs#redis` gets you one without
touching your system profile. The suspected `ERR syntax error` vs
`ERR conflicting expiry options` divergence from §1 is the kind of thing this finds in its
first minute.

**4. Lockstep model testing (rung 3).** Model:

```haskell
type Model = Map ByteString (RedisDataType, Maybe UTCTime)
```

plus a logical clock the generated commands can advance. Once the clock is injected, "advance
time by 5 seconds" is just another generated command — and suddenly TTL is exhaustively
testable, instantly, with shrinking. Note `RedisRecord` has no `Eq` instance yet; you'll want
one (or an explicit observability relation, per Well-Typed's framing, since `insertedAt` is
an implementation detail a client can't see — comparing it would be *over*-specifying).

Properties worth stating here, again by Hughes' classes:

- *Postcondition.* After `SET k v`, `GET k` returns `v` — provided no time has passed beyond
  the TTL.
- *Invariant.* No key ever returns a value at or after its expiry instant. Pin the boundary
  explicitly: your `isLive now = maybe True (now <)` means that **at exactly** `expiresAt`
  the key is dead. State that; don't let it be an accident.
- *Metamorphic — locality.* Operations on distinct keys commute. `SET k1 v1; SET k2 v2` is
  observationally equal to `SET k2 v2; SET k1 v1` for `k1 /= k2`. This is the strongest
  cheap property a key-value store has, and it's the one that will catch a store
  implementation bug.
- *Metamorphic — last write wins.* `SET k v1; SET k v2` ≡ `SET k v2`.

**5. Rung 1 conformance from `src/commands/*.json`.** Covered in §1. Do this once you have
more than four commands — it's the thing that keeps paying as the command set grows, and
CodeCrafters will grow it fast.

### What to park, and why

Saying "not yet" is part of the answer.

**Parallel / linearizability testing (rung 4) — park until you have a read-modify-write
command.** Your store's operations are single STM transactions over single keys:
`Map.insert` and `Map.lookup`. Those are trivially linearizable; a race checker will find
nothing because there is nothing. It becomes genuinely valuable the moment you add `INCR`,
`SETNX`, `SET … GET`, `MULTI/EXEC`, or any multi-key command — that's when
read-then-write windows appear and STM's composability starts doing real work worth
verifying. `quickcheck-state-machine` does parallel testing and is in your LTS, so the
capability is sitting there for free when you need it. `dejafu` (systematic schedule
exploration, in LTS) or `io-sim` (extra-dep) are the follow-ons.

**TLA+ / Quint / P (rung 6) — park until the replication stage.** A single-node key-value
store with lazy TTL has essentially no protocol content to model-check; the reachable state
space is "the map, and time moves forward". You'd spend the effort and learn the tool, but
find nothing. Replication — which the CodeCrafters challenge reaches — is *exactly* what
rung 6 is for: propagation ordering, replica consistency during handoff, what a replica may
serve mid-sync. When you get there, write the spec **before** the Haskell. That's the one
context where this rung earns its cost, and you'll have a real reason to care.

Same for your **active expiry reaper** (already a `Proposed` component in `workspace.dsl`)
— a background reaper racing lazy expiry against client reads is a small but genuine
concurrent design, and the first thing in this project worth a state machine.

**Liquid Haskell (rung 7) — park indefinitely.** Not in LTS 23.18, a heavy dependency, and
the mismatch is conceptual rather than practical: your invariants are about *behaviour over
time* (what a client observes after a sequence of commands), not *value shapes* (index in
range, list non-empty). Refinement types are excellent at the latter. Your types plus rung
3 already cover more of your actual risk. The exception, if you want one small taste:
`BulkString`'s declared length is precisely a refinement-type-shaped invariant.

**Jepsen — never, for this project.** It tests distributed systems under fault injection
across a cluster. Read the Redis-Raft analysis for how to *state* a safety property; don't
run the tool.

---

## 5. What's actually available in your toolchain

You're on `lts-23.18` (GHC 9.8.4). Checked against Stackage:

**In the LTS — no `extra-deps` needed:**

| Package | Version | Why |
|---------|---------|-----|
| `QuickCheck` | 2.14.3 | the lingua franca; Hughes' paper is written in it |
| `hedgehog` | 1.5 | integrated shrinking, generators-as-values, very polished |
| `falsify` | 0.2.0 | internal *and* integrated shrinking; works across monadic bind |
| `quickcheck-state-machine` | 0.10.1 | **stateful + parallel**; one of only four libraries anywhere that does both |
| `dejafu` | 2.4.0.7 | systematic concurrency testing, first-class STM |
| `tasty-quickcheck` / `hspec` | 0.11 / 2.11.12 | runners |
| `hspec-golden` / `tasty-golden` | 0.2.2.0 / 2.3.5 | golden (approval) files — rung 0 held in a file rather than in source |
| `hspec-golden-aeson` | 0.9.0.0 | golden files generated *from* `Arbitrary`; see below |

**Not in the LTS — `extra-deps` required:**

`quickcheck-dynamic` (4.0.1), `quickcheck-lockstep` (0.8.3), `io-sim` (1.11.0.0),
`io-classes` (1.11.0.0), `liquidhaskell`.

**Which to start with.** QuickCheck, and I'd hold that recommendation even though falsify
and hedgehog shrink better in principle. Three reasons: Hughes' paper is in QuickCheck so
you can follow it line by line; `quickcheck-state-machine` builds on it so rung 3 is a
continuous path rather than a rewrite; and an **experience report from 2026** evaluating
shrinking across QuickCheck, Hedgehog and Falsify on ETNA workloads found QuickCheck's
manual structural shrinking *usually faster and competitive on counterexample quality* —
integrated shrinking does not automatically win. The received wisdom on this is out of date.

The tradeoff you're accepting is writing `shrink` by hand. For a recursive type like `Resp`
that's real work, but it's also the kind of work that teaches you what shrinking is doing —
which, for a learning project, is the point.

### There is no example database in the Haskell ecosystem

Checked 2026-10-09, prompted by the downward direction in §1. Python's Hypothesis
**persists failing inputs**: a failure is written to a local example database and
*replayed before new generation* on every later run, and the `@example` decorator promotes
one into source permanently. That is the down-the-ladder move, automated inside the tool.

**Nothing in `lts-23.18` does this.** All 23 packages in the snapshot whose name mentions
QuickCheck were checked, and none of them stores a counterexample — they are generators,
law bundles, runner integrations, and in one case (`quickcheck-state-machine`) stateful
testing. Neither `hedgehog` nor `falsify` has it either. `hedgehog-corpus` sounds like a
failure corpus and is not: its synopsis is "collection of strings for testing things",
i.e. sample data *for* generators.

What is available, closest first:

**1. `hspec --rerun --failure-report=FILE`.** Already in the toolchain. The file it writes
is a `Show`n record:

```
FailureReport { failureReportSeed = 341725608, failureReportMaxSuccess = 100
              , failureReportMaxSize = 100, failureReportMaxDiscardRatio = 10
              , failureReportPaths = [(["Redis.Store",…],"treats an expired string as absent for RPUSH"), …] }
```

So it persists **the seed, the QuickCheck arguments, and which specs failed**. Not the
counterexample. It replays a random *schedule*, not an input.

**2. `hspec-golden-aeson`.** The downward move, automated, for one narrow job. Its golden
file holds a seed plus the serialized value; later runs "use a seed from the golden file to
create an arbitrary value of a type and check if the serialization matches the file." That
is genuinely "freeze a generated example as a permanent artefact" — scoped to JSON
serialization drift, but the right shape.

**3. Seed replay.** `QuickCheck`'s `replay` argument, `tasty-quickcheck`'s
`--quickcheck-replay`, `hspec`'s `--seed`, hedgehog's `recheck Size Seed`. Reproduces a
run, not an input.

**What is actually missing** is that Hypothesis stores the *choice sequence* — the decisions
the generator made — so it replays an input rather than a schedule, and survives a changed
generator rather than silently pointing somewhere else.

#### A measurement, which refuted the obvious claim

The expected argument is "seed replay is fragile: change the generator and the seed points
at different inputs". Tested on `Redis.ModelSpec`:

```
seed 42, before                                 [Set "a" "w" (Just (Px 1000)),Advance 1100,RPush "a" [""]]
added one unused element to genValue's pool, rebuilt
seed 42, after                                  [Set "a" "w" (Just (Px 1000)),Advance 1100,RPush "a" [""]]
```

Identical. **Shrinking converged**, so for an easily-reached bug a seed is a sturdier pin
than the argument suggests.

It breaks on the *rare* ones, which is the case that matters. The `SET a v PX PX PX 41605`
divergence surfaced at **test 1435 of 3000 on seed 10**; that needle depends on the exact
generation schedule, so any edit to `Redis.FrameGen` moves it. Which is exactly why that
finding was written into `DifferentialSpec`'s `baseline`, `known-gaps.md` #17 and a
`triageSpec` row — rather than a comment saying "see seed 10".

#### The consequence

**In Haskell the rung-3 → rung-0 migration is manual, so it has to be deliberate.** In
Python a weaker version of it is free. That is not a reason to envy Python: a database
replays whatever it caught, whereas writing the row by hand forces you to *name the root
cause*, which is what keeps `baseline` six entries long instead of six hundred (§1).

**If a small one is ever wanted**, the pieces are present: `Op` derives `Show` and `Read`
is a line away, `boundarySpec`'s rows are already hand-written pinned cases, and
`forAll (elements pinned)` beside `genOps` is the whole mechanism — roughly 30 lines, after
which appending a shrunk counterexample becomes mechanical. Not worth it at six baseline
entries; the natural shape if the gap list grows.

**Sources**

- [Hypothesis — replaying failures](https://hypothesis.readthedocs.io/en/latest/tutorial/replaying-failures.html) and [the example database](https://hypothesis.readthedocs.io/en/hypothesis-python-4.57.1/database.html)
- [`hspec-golden-aeson`](https://hackage.haskell.org/package/hspec-golden-aeson) (the quoted sentence is from its description)
- [`hedgehog-corpus`](https://hackage.haskell.org/package/hedgehog-corpus) · [`falsify`](https://hackage.haskell.org/package/falsify)
- [LTS 23.18 package set](https://www.stackage.org/lts-23.18/cabal.config) — the list the package check was run against
- The `FailureReport` dump and the seed-42 measurement were produced in this repo, not quoted.

---

## 6. Reading list

Ordered for actually reading, not for completeness.

**Start here**
1. John Hughes, *How to Specify It! A Guide to Writing Properties of Pure Functions* (2019).
   [PDF](https://research.chalmers.se/publication/517894/file/517894_Fulltext.pdf) ·
   [talk](https://www.youtube.com/watch?v=zvRAyq5wj38). The five property classes. Short.
2. John Hughes, *Experiences with QuickCheck: Testing the Hard Stuff and Staying Sane* (2016).
   [PDF](https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quviq-testing.pdf). What
   model-based PBT looks like against real production code (Volvo/AUTOSAR, Klarna).

**The industry picture**
3. *Systems Correctness Practices at Amazon Web Services*, ACM Queue 22:6 / CACM (2025).
   [Queue](https://queue.acm.org/detail.cfm?id=3712057) ·
   [CACM](https://cacm.acm.org/practice/systems-correctness-practices-at-amazon-web-services).
   The portfolio argument. The most useful single item here.
4. TigerBeetle, *Protocol-Aware Deterministic Simulation Testing* (Aug 2026).
   [post](https://tigerbeetle.com/blog/2026-08-20-protocol-aware-dst/). Assert invariants at
   every layer, not just the API boundary.
5. Phil Eaton, *What's the big deal about Deterministic Simulation Testing?*
   [post](https://notes.eatonphil.com/2024-08-20-deterministic-simulation-testing.html).
   The gentlest introduction to rung 5.

**Haskell specifics**
6. Well-Typed, *Lockstep-style testing with quickcheck-dynamic* (2022).
   [post](https://well-typed.com/blog/2022/09/lockstep-with-quickcheck-dynamic/) — and
   Haskell Unfolder #44 for the video version.
7. Stevan Andjelkovic, *The sad state of property-based testing libraries*.
   [post](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html).
   Why stateful+parallel PBT is rarer than it should be.
8. Well-Typed, *falsify: Hypothesis-inspired shrinking for Haskell* (2023).
   [post](https://well-typed.com/blog/2023/04/falsify/) — then
   *Evaluating Shrinking* (2026) [arXiv:2608.09935](https://arxiv.org/abs/2608.09935) for the
   counterpoint.
9. Tweag, *Coverage-guided fuzzing of Haskell programs for cheap* (2023).
   [post](https://www.tweag.io/blog/2023-06-15-ghc-libfuzzer/). Read to understand why
   you're not going to do this.

**AI and specs**
10. *The Verification Horizon: No Silver Bullet for Coding Agent Rewards* (2026).
    [arXiv:2606.26300](https://arxiv.org/abs/2606.26300). Verification, not generation, is
    the bottleneck now.
11. *A Benchmark for Vericoding: Formally Verified Program Synthesis*.
    [arXiv:2509.22908](https://arxiv.org/abs/2509.22908). The Dafny/Verus/Lean numbers, and
    vacuity as the central threat.
12. *PBT-Bench: Benchmarking AI Agents on Property-Based Testing*.
    [arXiv:2605.15229](https://arxiv.org/abs/2605.15229). How well models actually write
    properties.
13. Birgitta Böckeler (Thoughtworks), *Understanding Spec-Driven Development: Kiro, spec-kit,
    and Tessl*. The critique of the other SDD.
14. Informal Systems, [Quint](https://quint.sh/) and the
    [Quint LLM Kit](https://github.com/informalsystems/quint-llm-kit). The friendliest door
    into rung 6, and a working example of AI-written *formal* specs with tool validation.

**Reference material you'll actually use**
15. [`redis/redis:src/commands/*.json`](https://github.com/redis/redis/tree/unstable/src/commands)
    — the machine-readable spec. And
    [redis#9845](https://github.com/redis/redis/issues/9845) for the reply-schema rationale.
16. [RESP2](https://github.com/redis/redis-specifications/blob/master/protocol/RESP2.md) /
    [RESP3](https://github.com/redis/redis-specifications/blob/master/protocol/RESP3.md)
    specifications.
17. [Jepsen: Redis-Raft](https://jepsen.io/analyses/redis-raft-1b3fbf6) — as a model of how
    to state what a system promises.

---

## 7. If I had to compress this to five sentences

1. The "spec-driven development" you see in tooling announcements is structured prompting;
   the spec-driven development that works is an artifact a machine can check the code
   against — ignore the first, pursue the second.
2. Formality is a ladder, and the best teams stand on several rungs at once, deliberately
   weighted toward the cheap end.
3. Redis already publishes a formal spec of itself (`src/commands/*.json` with
   JSON-Schema reply schemas) and it is the cheapest real spec you will ever be handed.
4. The specific, non-negotiable guardrail for AI-assisted implementation is that the
   machine must not be able to touch the spec, and every spec must be mutation-gated —
   because the shortest path to green runs through weakening the spec.
5. Your next concrete move is six lines long: put the clock in `Env`, which unlocks every
   TTL property at once and pays the entry fee for deterministic simulation later.
