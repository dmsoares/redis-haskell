# Known gaps

A running log of defects and divergences we have found, understood, and chosen not to fix
yet. The point is that nothing has to be re-derived: each entry records the *observed*
behaviour with the exact input that produces it, so it can be turned into a test or a fix
without repeating the investigation.

**Conventions**

- Every `Observed` block has been run against the code at the stated commit. If a claim is
  inferred rather than executed it says so.
- `Status` is one of `open` (no decision yet), `deferred` (decided to fix later),
  `accepted` (decided this is fine).
- When an entry is fixed, add the test that pins it and replace the entry with a one-line
  resolution naming that test. Numbers stay stable so cross-references keep working; the
  test is the permanent record, this file is only the waiting room.
- Entries that turn into design decisions graduate to `decisions/`.

Last verified on 2026-10-13, against the working tree on top of `2408f3c`. Claims about *real* Redis behaviour were
checked against `redis-server` 8.10.1, available in the dev shell via `flake.nix` — start one
on a spare port with `redis-server --port 6390 --save "" --appendonly no` and talk to it with
`redis-cli -p 6390`.

Since 2026-10-09 most of this is also checked automatically. `Redis.ConformanceSpec` holds
the rows we match, `Redis.DifferentialSpec`'s `baseline` holds the divergence classes we do
not, and `Redis.ModelSpec` holds expiry semantics on a logical clock. An entry here that has
no corresponding test is an entry nothing is watching.

Sentences of the form "a mutation doing X fails N rows" record a **hand mutation audit run
once on 2026-10-09**. No tooling re-runs it, so those counts are dated observations, not
guarantees.

| # | Gap | Area | Status |
|---|-----|------|--------|
| 1 | `Resp` can hold values RESP cannot encode | protocol / data design | open |
| 2 | `fromBytes` silently discards trailing bytes | protocol | deferred |
| 3 | RESP2 null array unsupported | protocol | **fixed** |
| 4 | `$-2\r\n` parses as `NullBulkString` | protocol | **fixed** |
| 5 | `RedisInteger` overflows silently | protocol | open |
| 6 | Commands and options are case-sensitive | command parsing | **fixed** |
| 7 | Unknown SET options are silently discarded | command parsing | **fixed** |
| 8 | Malformed and negative expiry values are accepted | command parsing | open |
| 9 | Conflicting-expiry error message diverges | conformance | **fixed** |
| 10 | No end-to-end test tier | testing | partly closed |
| 11 | Wrong arity reported as unknown command | conformance | mostly **fixed** |
| 12 | Simple strings and errors accept LF in the body | protocol | open |
| 13 | `shrinkResp` has no depth move | testing | open |
| 14 | `RPUSH` ignores expiry and sees dead records | store semantics | **fixed** |
| 15 | Expiry integer grammar is looser than Redis's | command parsing | open |
| 16 | A value error pre-empts a grammar error | command parsing | open |
| 17 | An option's value is not consumed positionally | command parsing | open |
| 18 | List order is unobservable, so untested | testing | open |

---

## 1. `Resp` can hold values RESP cannot encode

**Status** open · **Area** protocol / data design

`SimpleString` and `SimpleError` accept any `ByteString`, but RESP2 defines both as bytes
that **must not contain CR or LF**, terminated by CRLF. So the type admits values with no
wire representation, and `toBytes` does not fail on them — it emits bytes that mean
something else.

**Observed**

```
toBytes   (SimpleString "a\r\nb")  = "+a\r\nb\r\n"
fromBytes "+a\r\nb\r\n"            = Just (SimpleString "a")
```

**Why** `pSimpleString` takes bytes up to the first CR, then `pCRLF` consumes the embedded
CRLF as if it were the terminator. `"b\r\n"` is left unconsumed and then dropped by gap #2.

Two independent defects produce that single result. Fixing #2 alone turns it into `Nothing`
— still a round-trip failure, but a loud one. Fixing this entry alone makes the input
unconstructible.

**Impact now** Blocks the round-trip property `fromBytes (toBytes r) == Just r`; a generator
drawing arbitrary bodies finds it immediately. Writing that property *requires* deciding
this first, which is why the decision is on the critical path rather than optional.

**Impact later — response splitting.** `Redis.Data.Error` splices bytes into a frame:

```haskell
toResp (MalformedExpiry s) = SimpleError $ "ERR malformed expiry:" <> s
```

If `s` ever carries CRLF the server emits two frames where it meant one:

```
toBytes (SimpleError ("ERR malformed expiry:" <> "\r\n+PONG"))
  = "-ERR malformed expiry:\r\n+PONG\r\n"
```

A client reads an error *and* a `+PONG` it never requested — the same shape as HTTP header
injection.

**This is currently dormant.** `MalformedExpiry` is declared and has a `ToResp` instance but
is never constructed anywhere in `lib`, `app` or `test`; the other three errors use literal
strings, so no client-controlled bytes reach `SimpleError`. What wakes it up is fixing gap
#8 — raising `MalformedExpiry bs` with the offending bytes is the obvious improvement there,
and it makes this path live in the same commit. Fix #1 before or with #8.

**Where the rule lives today.** The generator route was taken. `Resp.SerializationSpec`
defines `noCRLF :: ByteString -> Bool` and applies it via `suchThat` to the `SimpleString`
and `SimpleError` generators, and `shrinkResp` re-applies it to shrink candidates so
shrinking cannot leave the domain. That makes the round-trip property true and meaningful —
it killed every mutation tried by hand when it was written — but the consequence is
exactly the one below:
**`noCRLF` is stated only in test code.** Nothing stops `lib/` constructing
`SimpleString "a\r\nb"`, and `toBytes` will emit two frames for it without complaint.

The property is therefore not evidence that the library maintains the invariant. It is
evidence that the library round-trips values that *happen to* satisfy it.

**Fix directions**

- Constrain the generator only — cheapest, and what is in place now. The invariant lives
  solely in test code and production can still build the bad value.
- Smart constructors returning `Maybe Resp`, or sanitising. These existed and were removed
  when the length fields went; reinstating them costs the raw constructors in the export list.
- Make it unrepresentable, as was done for the length fields — needs a `newtype` wrapper for
  CRLF-free bytes, so unlike the length-field fix this one is not free.

---

## 2. `fromBytes` silently discards trailing bytes

**Status** deferred · **Area** protocol

`fromBytes` uses `runParser` without requiring `eof`, so everything after the first complete
frame is thrown away without a word.

**Observed**

```
fromBytes "+OK\r\n+SECOND\r\n"                       = Just (SimpleString "OK")
fromBytes "*1\r\n$4\r\nPING\r\n*1\r\n$4\r\nPING\r\n" = Just (Array [BulkString "PING"])
fromBytes "+OK\r\nTOTAL GARBAGE"                     = Just (SimpleString "OK")
```

Confirmed end-to-end earlier in the project: three pipelined `PING`s over one socket produce
a single `+PONG`.

**Impact** Pipelined commands are dropped. A valid frame followed by arbitrary junk parses
*successfully*, which is worse than rejecting it.

**Second-order impact.** `Main.fullQuery` reads `Nothing` as "need more bytes" and recurses,
so it cannot distinguish a *truncated* frame from a *malformed* one and will block forever
waiting for bytes that can never make a malformed frame valid. The two groups in
`Resp.SerializationSpec` (`rejects incomplete input` / `rejects malformed input`) name that
distinction, but both currently assert `Nothing` because the result type cannot express it.

**Fix direction** `fromBytes :: ByteString -> Maybe (Resp, ByteString)` returning the
remainder, or a three-way result distinguishing complete / incomplete / malformed. Either
changes `fullQuery`, which should then loop over the buffer rather than restarting it per
command. `Text.Megaparsec.getInput` gives the remainder after a successful parse, and
`TrivialError _ (Just EndOfInput) _` discriminates truncated from malformed.

---

## 3. RESP2's null array is unsupported — FIXED

**Status** fixed · **Area** protocol

`NullArray` was added to `Resp`, with `toBytes NullArray = "*-1\r\n"` and a `pNullArray`
branch. Pinned by `serializes a NullArray`, `deserializes a NullArray` and
`rejects "*-2\r\n"` in `Resp.SerializationSpec`, and covered by the round-trip property.

**Worth keeping in mind.** The fix restructured `pRedisValue` into an `asum` whose null
branches (`pNullBulkString` matching the literal `"$-1"`, `pNullArray` matching `"*-1"`) come
*before* the general ones, carrying a `-- order matters!` comment. That ordering is safe
without `try` for a non-obvious reason: Megaparsec's `string`/`string'` is atomic — it
consumes nothing when it fails — so a failed `"$-1"` leaves the input untouched for
`pBulkString`. Any branch added to that `asum` which can fail *after* consuming input needs
an explicit `try`, or it will kill the alternatives that follow it. This is the same
non-backtracking behaviour that previously made `pNullBulkString` unreachable.

---

## 4. `$-2\r\n` parses as `NullBulkString` — FIXED

**Status** fixed · **Area** protocol

Resolved by the same restructure: `pNullBulkString` now matches the literal `"$-1"` rather
than accepting any negative length, so `$-2\r\n` falls through to `pBulkString`, whose
unsigned `pLength` rejects it. Pinned by `rejects "$-2\r\n"`.

---

## 5. `RedisInteger` overflows silently

**Status** open · **Area** protocol

`pInteger` uses `L.decimal` at type `Int`, which wraps instead of failing.

**Observed**

```
fromBytes ":99999999999999999999\r\n" = Just (RedisInteger 7766279631452241919)
fromBytes ":9223372036854775808\r\n"  = Just (RedisInteger (-9223372036854775808))
```

The second is `2^63`, one past `maxBound :: Int`, and comes back negative.

**Impact** None today — nothing constructs a `RedisInteger` from client input, and the
server only emits small integers. It becomes real when a command parses a client-supplied
integer, and a value that silently changes sign is a bad primitive to build on.

**Fix direction** Parse into `Integer` and range-check against `Int64`, rejecting on
overflow. RESP integers are specified as signed 64-bit.

---

## 6. Commands and options are case-sensitive — FIXED

**Status** fixed · **Area** command parsing

`Redis.Data.Command.lower` (`BC.map Char.toLower`, which is byte-safe where the earlier
`decodeASCII` was partial) now normalises the command name in `pCommand` and the option name
in `pName`. Keys and values are untouched, as they must be.

Pinned by the `PING` / `ping` / `PiNg`, `ECHO` / `echo`, `RPUSH` / `rpush` and
`EX` / `ex`, `PX` / `px` rows in `Redis.ConformanceSpec`, and by the `bogus` row, which
checks the *argument* survives byte for byte in the error message. A mutation reducing
`lower` to `id` fails 38 of those rows.


## 7. Unknown SET options are silently discarded — FIXED

**Status** fixed · **Area** command parsing

The catch-all is gone: `pSet` requires `eof` after `pSetOptions`, so an unrecognised token
is a `SyntaxError` rather than a dropped option.

**Observed**

```
SET k v BOGUS           ->  -ERR syntax error        (redis 8.10.1: identical)
SET k v EX 100 BOGUS    ->  -ERR syntax error        (redis 8.10.1: identical)
```

Pinned by those two rows in `Redis.ConformanceSpec`. A mutation replacing `pSet`'s `eof`
with `pure ()` fails both.

Note what remains, as gap #16: Redis reaches the syntax error even when the option list also
carries an *invalid value*, and we report the value error first.


## 8. Malformed and negative expiry values are accepted — PARTLY FIXED

**Status** open (narrowed) · **Area** command parsing

**What is fixed.** Values are no longer *accepted*. `pInt` raises `NotAnInteger` instead of
defaulting to `-1`, and `pSetOptions` rejects non-positive expiry, zero included. Pinned by
the `EX 0`, `EX -1`, `PX 0` and `PX -500` rows in `Redis.ConformanceSpec`; a mutation
loosening the boundary to `>= 0` fails two of them.

**What remains, and is the live part of this entry.** The *error text* for an unparseable
value is still wrong, because `many`/`<|>` discards `NotAnInteger` from a branch that had
already consumed input and the generic `SyntaxError` from the failed alternative escapes
instead:

```
SET k v EX abc  ->  ours: -ERR syntax error
                    redis: -ERR value is not an integer or out of range
```

Recorded as `NonIntegerExpiryIsSyntaxError` in `Redis.DifferentialSpec`'s baseline. Gaps
#15, #16 and #17 are the rest of the same parser shape, and `MalformedExpiry` is still
unconstructed, so gap #1's response-splitting path is still dormant.

**Original entry follows.**


`Command.parseInt` swallows parse failures: `maybe (-1) id $ fst <$> BC.readInt bs`.

**Observed**

```
fromResp ["SET","k","v","EX","abc"]  = Just (Set (SetPayload "k" "v" [SetOptionEX (-1)]))
fromResp ["SET","k","v","PX","-500"] = Just (Set (SetPayload "k" "v" [SetOptionPX (-500)]))
```

**Impact** `EX abc` becomes `EX -1`, indistinguishable from a client that actually sent
`-1`. Both produce a record whose `expiresAt` is *before* its `insertedAt`, so the key is
born dead and `GET` returns nil immediately.

Real Redis rejects all three, and note the third — **zero is invalid too**, not just
negatives, which our code would happily accept:

```
redis 8.10.1:  SET k v EX abc   ->  ERR value is not an integer or out of range
               SET k v PX -500  ->  ERR invalid expire time in 'set' command
               SET k v EX 0     ->  ERR invalid expire time in 'set' command
```

**Fix direction** Raise `MalformedExpiry bs` for unparseable input and a new error for
non-positive expiry — the boundary is `> 0`, not `>= 0`. **Read gap #1 first** — raising `MalformedExpiry` with client bytes is
what activates the response-splitting path, so the two must be fixed together.

---

## 9. Conflicting-expiry error message diverges — FIXED

**Status** fixed · **Area** conformance

`ConflictingExpiryOptions` was deleted rather than renamed, which was the right call: two
expiry tokens are a grammar violation, not a semantic conflict. `pSetOptions` now returns
`empty` — a `SyntaxError` — when both `EX` and `PX` are present.

**Observed**

```
SET k v EX 1 PX 1000    ->  -ERR syntax error        (redis 8.10.1: identical)
SET k v PX 1000 EX 1    ->  -ERR syntax error        (redis 8.10.1: identical)
```

Pinned by both rows in `Redis.ConformanceSpec` — both orders, because the rule is
order-independent and a one-sided test would not say so. A mutation turning that branch into
`pure []` fails them.


## 10. No end-to-end test tier — PARTLY CLOSED

**Status** open (narrowed to the socket) · **Area** testing

**What is closed.** `Redis.Sut` drives the implementation at the same boundary
`app/Main.hs` uses — bytes in through `fromBytes`, `reply` with an injected clock, bytes out
through `toBytes` — so the deserializer, dispatcher and serializer are all inside the tested
region. `Redis.Reference` starts a real `redis-server` on an ephemeral port, so the
differential suite is self-contained and runs on a fresh clone.

The clock scenario named below is now a test, in `Redis.ModelSpec`, and better than the one
proposed: on a *logical* clock, so it needs no sleep and reproduces from its seed. Both
directions are covered — keys outliving a TTL and keys born dead.

**What remains.** Nothing drives a real socket against our own server. `Main.fullQuery`'s
buffering loop, its treatment of `Nothing` as "need more bytes" (gap #2) and its
`segmentSize` chunking are still untested, and that loop is exactly where the clock bug
lived. The thin shell is thinner than it was, and still uncovered.

**Original entry follows.**


Everything under test today is reached through the library. The clock-injection bug lived in
`app/Main.hs` — the clock was sampled *before* the blocking `fullQuery`, so every command was
timestamped with the client's think-time subtracted — and no property over `Set.execute` or
`Get.execute` could have caught it, because the defect was outside the boundary the `Env`
injection draws.

Inverting an effect makes the core deterministically testable and simultaneously
concentrates the remaining risk in the thin shell that nothing tests.

**Still true after property-based testing arrived.** The round-trip property covers
`Resp.Serialization` thoroughly, but its domain is `Resp` values — it never sees a socket, a
clock, or `Main.fullQuery`. The clock bug would still pass today.

**Fix direction** A second suite that starts the server on an ephemeral port, drives a real
socket, and asserts on reply bytes. The scenario that found the clock bug is the first case:
`SET foo bar PX 100`, wait 150 ms, `GET foo`, expect `$-1`. Its mirror is just as important —
idle 2 s, then `SET k v PX 100` and `GET` immediately, expecting the value — because the
original bug made keys *born dead* as well as immortal, and a suite checking only expiry
would have gone green on it.

---

## 11. Wrong arity is reported as an unknown command — MOSTLY FIXED

**Status** open (narrowed to `PING`) · **Area** conformance

**What is fixed.** Name resolution and argument matching are now separate: `pCommand`
resolves the name, then each `p*` validates its own shape through
`withError (WrongNumberOfArguments name)`. `ECHO`, `GET`, `SET`, `RPUSH`, `LRANGE` and `LLEN`
all report the right error with the right command name.

`Redis.ConformanceSpec` drives these from the `arity` field of `COMMAND INFO` rather than
case by case, which is what the original fix direction asked for — `echo 2`, `get 2`,
`set -3`, `rpush -3`, captured verbatim. A mutation dropping the command name from the error
fails eight rows.

**What remains.** `PING`, and only `PING`. `pPing = pure Ping` never looks at its arguments,
so `PING hello` answers `+PONG` where Redis echoes the message, and `PING a b` answers
`+PONG` where Redis reports wrong arity. Note this is *not* derivable from arity: `PING` is
`-1`, so "at least one token", and a zero-token frame is not a command. Redis rejects three
tokens by a command-specific check. Recorded as `PingIgnoresArguments` in
`Redis.DifferentialSpec`'s baseline.

**Original entry follows.**


`fromResp` matches each command by an exact-shape pattern, so a command with the right name
but the wrong number of arguments falls through to the catch-all and becomes
`UnknownCommand`.

**Observed**

```
fromResp ["GET"]          = Nothing   -- -ERR unknown command
fromResp ["SET","k"]      = Nothing   -- -ERR unknown command
fromResp ["PING","extra"] = Nothing   -- -ERR unknown command
```

Real Redis distinguishes the two conditions:

```
redis 8.10.1:  GET    ->  ERR wrong number of arguments for 'get' command
               SET k  ->  ERR wrong number of arguments for 'set' command
```

**Impact** A client that sends a known command with a bad argument count is told the command
does not exist, which sends debugging in the wrong direction. `PING extra` is a separate
sub-case: real Redis accepts `PING <message>` and echoes it back, so ours is rejecting a
valid command, not merely mislabelling an invalid one.

**Fix direction** Split name resolution from argument matching: resolve the command name
first, then validate arity against it, so "unknown name" and "known name, wrong shape" are
different errors. `arity` in `redis/redis:src/commands/*.json` gives the expected count for
every command as data — `-3` meaning "at least 3, variadic" — so this is one rule driven by
a table rather than a case per command.

---

## 12. Simple strings and errors accept LF in the body

**Status** open · **Area** protocol

RESP2 says a simple string is `+`, then bytes that **must not contain CR or LF**, then CRLF.
`pSimpleString` stops at CR (`takeWhileP Nothing (/= 13)`) but says nothing about LF, so a
frame the grammar forbids is accepted. `pSimpleError` is identical.

**Observed**

```
fromBytes "+a\nb\r\n" = Just (SimpleString "a\nb")
fromBytes "-a\nb\r\n" = Just (SimpleError "a\nb")
```

**Impact** We accept input real Redis would reject — leniency, not data loss, and no client
sends this. It is logged because it is a *known* divergence from a spec we have read, and
because it interacts with gap #1: the two together mean neither the type, nor the
serializer, nor the parser enforces the CRLF-free rule anywhere in `lib/`. Only the test
generator does.

Note the round-trip property does **not** catch this, and cannot: the generator never
produces a `SimpleString` containing LF, precisely because such a value has no wire form.
It was found by reading the spec.

**Fix direction** Reject rather than scan-to-CR — take bytes while neither CR nor LF, then
require CRLF. That makes the parser agree with the grammar, and makes `"+a\nb\r\n"` a
rejection case for `Resp.SerializationSpec`.

---

## 13. `shrinkResp` has no depth move

**Status** open · **Area** testing

```haskell
shrinkResp (Array elems) = Array <$> shrinkList shrinkResp elems
```

`shrinkList` shortens the list and shrinks elements in place, but it can never replace an
array by one of its children. So an array wrapper survives shrinking even when it is
irrelevant to the failure, and with a generator reaching depth 7 that means up to seven
layers of noise around the culprit.

**Observed** — the same mutation (array elements serialized in reverse), two shrinkers:

```
without the depth move:  Array [Array [RedisInteger 0,NullArray]]
with it:                 Array [NullArray,SimpleString ""]
```

**Impact** Counterexample legibility only; the property's bug-finding power is unaffected.
Logged because it is a silent quality loss — the suite still reports a genuine failure, just
a harder one to read, and nothing flags that the value could have been smaller.

**Fix direction** Concatenate both families, which is the shape the QuickCheck haddock shows
for recursive types (`[l, r] ++ [Branch l' r' | ...]`):

```haskell
shrinkResp (Array elems) = elems ++ (Array <$> shrinkList shrinkResp elems)
```

**Related constraint for later.** A shrinker belongs to its *generator*, not to the type. If
a second generator over `Resp` appears — the arrays-of-bulk-strings shape a client actually
sends — it needs its own shrinker: `elems` would immediately produce a non-array and leave
that domain, reporting counterexamples the generator could never have produced. This is why
the property uses `forAllShrink` with an explicit pair rather than an `Arbitrary Resp`
instance, which would allow only one pair per type.

---

## 14. `RPUSH` ignores expiry and appends to dead records — FIXED

**Status** fixed · **Area** store semantics · found 2026-10-09 by `Redis.ModelSpec`

Liveness is now decided in one place. `Redis.Data.Store.get` takes the current time and
returns `Nothing` for a record that has expired, and `RedisStore` is opaque, so every
workflow reads through it. `Get` and `RPush` no longer check `isLive` themselves. An
expired string is therefore absent to `RPUSH`, which creates a fresh list, as Redis does.

Pinned by `Redis.ModelSpec`: the rows "treats an expired string as absent for RPUSH" and
"does not resurrect an expired key by appending to it", and the property "answers every
generated sequence the way the model does". Making `Store.get` skip the filter fails 9 of
`ModelSpec`'s 19 examples, since `Get` no longer has a check of its own either.

---

## 15. Our expiry integer grammar is looser than Redis's

**Status** open · **Area** command parsing · found 2026-10-09 by `Redis.DifferentialSpec`

`pInt` is `BC.readInt`, which is a *prefix* parser and has its own idea of which integers
exist. Two mechanisms, both reachable, both producing silent wrong answers rather than
errors.

**Observed** — ours, then redis 8.10.1

```
SET k v EX "1 "   ->  +OK                              redis: ERR value is not an integer
SET k v EX 1.5    ->  +OK                              redis: ERR value is not an integer
SET k v EX 0x10   ->  ERR invalid expire time          redis: ERR value is not an integer
SET k v EX -0     ->  ERR invalid expire time          redis: ERR value is not an integer
SET k v EX 007    ->  +OK                              redis: ERR value is not an integer
```

The first two are prefix acceptance: `readInt "1 "` is `Just (1, " ")` and `pInt` throws the
remainder away, so the command succeeds with a TTL the client never asked for. `0x10` is the
same mechanism landing on `0`, which then fails the `> 0` check and reports the wrong error.

The last two are different: `readInt` consumes the *whole* token and still disagrees with
Redis, whose `string2ll` rejects `-0`, a leading `+`, and leading zeros.

**Impact** `SET k v EX "1 "` is the bad one — a trailing space from a hand-built client
command silently becomes a one-second TTL instead of an error. The key is gone a second
later and nothing said so.

**Fix direction** `pInt` should require the whole token and match Redis's grammar: optional
`-`, then digits with no leading zero unless the number *is* zero, no `+`, no whitespace,
range-checked against `Int64`. That is also gap #5's fix, so the two are one change.

---

## 16. A value error pre-empts a grammar error

**Status** open · **Area** command parsing · found 2026-10-09 by `Redis.DifferentialSpec`

Redis parses a `SET` option list for grammatical validity **in full**, and only then
validates the values it collected. So a syntax problem anywhere in the list wins, regardless
of position.

**Observed** — redis 8.10.1

```
SET k v PX 0               ->  ERR invalid expire time in 'set' command
SET k v KEEPTTLX           ->  ERR syntax error
SET k v PX 0 KEEPTTLX      ->  ERR syntax error
SET k v KEEPTTLX PX 0      ->  ERR syntax error
```

Ours answers `ERR invalid expire time in 'set' command` for both of the last two.
`pSetOptions` validates *during* the scan: `many` stops at the unrecognised token, the
collected expiry is checked immediately, and the error escapes before `eof` can object to
what is left over.

**Impact** Cosmetic in isolation, and it matters because it is the clearest statement of a
structural difference: Redis's parse and validate are two phases, ours are interleaved. The
same interleaving is behind gaps #15 and #17.

**Fix direction** Collect options first, consume to `eof`, validate last. It is a change in
*where* the check happens, not in the check.

---

## 17. An option's value is not consumed positionally

**Status** open · **Area** command parsing · found 2026-10-09 by `Redis.DifferentialSpec`

Redis's option loop takes the token after `EX`/`PX` as that option's value whatever it looks
like, advances two, and validates nothing until the loop ends.

**Observed** — redis 8.10.1

```
SET a v PX PX            ->  ERR value is not an integer   (the value is the token "PX")
SET a v PX PX PX 41605   ->  OK                            (second PX wins; only 41605 checked)
SET a v EX EX 5          ->  ERR syntax error              (EX ate "EX"; "5" is then unknown)
SET a v PX 1000 PX       ->  ERR syntax error              (trailing PX has no value to eat)
```

Ours answers `ERR syntax error` to all four. `pSetOptions` is
`many (choice [pName "EX" >> pInt, pName "PX" >> pInt])`, so when `pInt` fails the whole
alternative fails, `many` backtracks as though no option were there, and `eof` rejects the
leftovers.

Note the second line: Redis accepts it. This is the *same* "last expiry wins, and only the
last is validated" rule that `pSetOptions` already implements for `EX -1 EX 6` — it simply
also applies when the discarded value happens to be an option name.

**Impact** We reject a command Redis accepts. Low practical risk, high diagnostic value: it
pins down that the difference is commitment, not validation. Redis commits to an option as
soon as its *name* matches; we only commit once its value parses.

**Fix direction** Commit on the name. `pName "PX" >> withError NotAnInteger pInt` is not
enough on its own — the error has to survive `many`, which today it does not (gap #8).

---

## 18. List order is unobservable, and therefore untested

**Status** open · **Area** testing · found 2026-10-09 by a hand mutation audit

No command in the project reads a list back. `RPUSH` replies with a length, `GET` on a list
is `WRONGTYPE`, and there is no `LRANGE`, `LPOP` or `LLEN`. So nothing anywhere observes the
*order* of list elements.

**Observed** — a mutation swapping `RPUSH`'s append for a prepend:

```haskell
-- lib/Redis/Workflows/RPush.hs
RedisListValue ((toRedisStringValue <$> values) <> elems)   -- was: elems <> (… values)
```

survives the conformance table, the stateful model, the differential explorer against the
real server, and the serialization suite. Every reply is byte-identical.

**Impact** None today, by definition — unobservable behaviour cannot be wrong from outside.
It becomes real the moment a read command lands, and at that point the bug would be *older*
than the test that finds it, which is the worst time to discover it.

**Why it is logged rather than fixed.** The fix is not a test; it is `LRANGE`. The model in
`Redis.ModelSpec` already stores elements in order, so adding the command closes this gap
without new test machinery. Logged so that "the model suite is green" is not mistaken for
"lists are correct".
