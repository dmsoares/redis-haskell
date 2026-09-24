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
- When an entry is fixed, add the test that pins it and delete the entry. The test is the
  permanent record; this file is a waiting room.
- Entries that turn into design decisions graduate to `decisions/`.

Last verified against `3603a55` on 2026-09-24. Claims about *real* Redis behaviour were
checked against `redis-server` 8.10.1, available in the dev shell via `flake.nix` — start one
on a spare port with `redis-server --port 6390 --save "" --appendonly no` and talk to it with
`redis-cli -p 6390`.

| # | Gap | Area | Status |
|---|-----|------|--------|
| 1 | `Resp` can hold values RESP cannot encode | protocol / data design | open |
| 2 | `fromBytes` silently discards trailing bytes | protocol | deferred |
| 3 | `*-1\r\n` parses as an empty array | protocol | open |
| 4 | `$-2\r\n` parses as `NullBulkString` | protocol | open |
| 5 | `RedisInteger` overflows silently | protocol | open |
| 6 | Commands and options are case-sensitive | command parsing | deferred |
| 7 | Unknown SET options are silently discarded | command parsing | open |
| 8 | Malformed and negative expiry values are accepted | command parsing | open |
| 9 | Conflicting-expiry error message diverges | conformance | open |
| 10 | No end-to-end test tier | testing | open |
| 11 | Wrong arity reported as unknown command | conformance | open |

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

**Fix directions**

- Constrain the generator only — cheapest, but the invariant then lives solely in test code
  and production can still build the bad value.
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

## 3. `*-1\r\n` parses as an empty array

**Status** open · **Area** protocol

RESP2's null array is `*-1\r\n` and is semantically distinct from the empty array `*0\r\n`.
There is no `NullArray` constructor, and the parser now silently conflates the two.

**Observed**

```
fromBytes "*-1\r\n" = Just (Array [])
fromBytes "*0\r\n"  = Just (Array [])
```

**Why** `pArray`'s `pLength` uses `pSignedDecimal`, so `-1` parses, and `count (-1)` returns
`pure []` rather than failing.

**Regression, and how it got in.** Before the sign handling was unified, `pLength` used
`L.decimal`, which failed on the `-` and made this input `Nothing`. The unification was
suggested on consistency grounds without checking what `count` does with a negative
argument — a worse outcome than the inconsistency it removed, since a rejection became a
silent wrong answer. It also slipped past the new rejection tests, which cover `*x\r\n` but
not `*-1\r\n`.

**Fix direction** Either reject a negative array length explicitly, or add `NullArray` and
branch on the sign the way `pBulkStringOrNull` does. Redis sends `*-1\r\n` for an aborted
`EXEC` and for older blocking-command timeouts, so the constructor will eventually be needed.
Whichever is chosen, add `*-1\r\n` to the spec.

---

## 4. `$-2\r\n` parses as `NullBulkString`

**Status** open · **Area** protocol

**Observed**

```
fromBytes "$-2\r\n" = Just NullBulkString
```

**Why** `pBulkStringOrNull` branches on `len < 0`. RESP only defines `$-1`.

**Impact** Leniency, no known exploit. Recorded because it is an undecided question rather
than a considered choice: tightening to `len == -1` is a one-word change, and leaving it lax
is defensible. Not pinned by a test in either direction so that whichever is chosen is a
decision rather than an accident.

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

## 6. Commands and options are case-sensitive

**Status** deferred — explicitly out of scope for now · **Area** command parsing

Redis command and option names are case-insensitive. `fromResp` matches uppercase literals
(`"PING"`, `"ECHO"`, `"SET"`, `"GET"`), and `parseSetOptions` matches `"EX"` / `"PX"`.

**Observed**

```
fromResp ["SET","k","v","px","100"] = Just (Set (SetPayload "k" "v" []))     -- TTL lost
fromResp ["SET","k","v","PX","100"] = Just (Set (SetPayload "k" "v" [PX 100]))
fromResp ["set","k","v","PX","100"] = Nothing                                -- UnknownCommand
fromResp ["ping"]                   = Nothing
```

**Impact** The lowercase *command* case is loud — it becomes `ERR unknown command`. The
lowercase *option* case is silent and worse: `SET foo bar px 100` answers `+OK` and stores a
key with no TTL. Verified against a live server: `px` never expires, `PX` expires correctly.

Real Redis accepts either case throughout — `set k v px 100` and `ping` both work on 8.10.1.

**Fix direction** Normalise the command and token names once, at the `fromResp` boundary,
rather than adding cases. Keep keys and values untouched — those are binary and
case-sensitive.

---

## 7. Unknown SET options are silently discarded

**Status** open · **Area** command parsing

`parseSetOptions`' catch-all `_ = []` drops anything it does not recognise, including the
rest of the option list.

**Observed**

```
fromResp ["SET","k","v","BOGUS"] = Just (Set (SetPayload "k" "v" []))
```

Real Redis answers `ERR syntax error`:

```
redis 8.10.1:  SET k v BOGUS  ->  ERR syntax error
```

**Impact** A client typo becomes a successful write with the wrong semantics. Note the
catch-all also truncates: an unrecognised token stops parsing, so any valid options *after*
it are lost too.

**Fix direction** Return `Either RedisError [SetOption]` and fail on the first unrecognised
token. `redis/redis:src/commands/set.json` is a machine-readable grammar for this and is
worth generating from rather than hand-writing — see `architecture/research/spec-driven-development.md`.

---

## 8. Malformed and negative expiry values are accepted

**Status** open · **Area** command parsing

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

## 9. Conflicting-expiry error message diverges

**Status** open · **Area** conformance

**Observed**

```
fromResp ["SET","k","v","EX","1","PX","1000"]
  = Just (Set (SetPayload "k" "v" [SetOptionEX 1, SetOptionPX 1000]))
```

…which `deserializeOptions` turns into `ConflictingExpiryOptions` →
`-ERR conflicting expiry options`.

In `set.json` the `expiration` argument is a `oneof`, so two expiry tokens are a **grammar
violation** rather than a semantic conflict, and real Redis answers `ERR syntax error`:

```
redis 8.10.1:  SET k v EX 1 PX 1000  ->  ERR syntax error
```

Our error name is also wrong about the nature of the problem: nothing *conflicts*, the
command simply does not parse.

**Impact** Cosmetic unless a client matches on error text, which real clients do. Recorded
mainly as the clearest example of a divergence that reading our own code can never reveal —
it needs either the published grammar or a differential test against a real server.

**Fix direction** Comes free with #7 if the option list is validated against the published
grammar. `ConflictingExpiryOptions` can then be deleted rather than renamed.

---

## 10. No end-to-end test tier

**Status** open · **Area** testing

Everything under test today is reached through the library. The clock-injection bug lived in
`app/Main.hs` — the clock was sampled *before* the blocking `fullQuery`, so every command was
timestamped with the client's think-time subtracted — and no property over `Set.execute` or
`Get.execute` could have caught it, because the defect was outside the boundary the `Env`
injection draws.

Inverting an effect makes the core deterministically testable and simultaneously
concentrates the remaining risk in the thin shell that nothing tests.

**Fix direction** A second suite that starts the server on an ephemeral port, drives a real
socket, and asserts on reply bytes. The scenario that found the clock bug is the first case:
`SET foo bar PX 100`, wait 150 ms, `GET foo`, expect `$-1`. Its mirror is just as important —
idle 2 s, then `SET k v PX 100` and `GET` immediately, expecting the value — because the
original bug made keys *born dead* as well as immortal, and a suite checking only expiry
would have gone green on it.

---

## 11. Wrong arity is reported as an unknown command

**Status** open · **Area** conformance

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
