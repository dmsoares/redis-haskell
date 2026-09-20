# 4. Move the in-memory store from MVar to STM

Date: 2026-08-30

## Status

Proposed

## Context

`Redis.Table.newRedisTable` guards the entire key-value `Map` with a single
`MVar` (`Table.hs:41`). Every `GET` and `SET`, across every client
connection, serializes on that one lock — unrelated keys can't be read or
written concurrently. `stm` is already listed as a dependency in
`codecrafters-redis.cabal` but is not currently used anywhere in the code.

Once an Expiry Reaper (ADR 0002) is introduced as a second, independent
writer to the store running on its own schedule, coarse global locking also
becomes a source of contention between the reaper's sweeps and normal
request handling.

This is a change to a component's internal implementation, not to the
structure of the system — the "In-Memory Key-Value Store" box in the C4
model stays exactly where it is, with the same relationships in and out.
Component diagrams show structure, not concurrency strategy, so this
decision is **not** reflected in the C4 `Proposed`/`Superseded` tagging used
for ADRs 0001-0003 — it lives here instead.

## Decision

Replace the `MVar (Map Key RedisRecord)` with an `STM`-based structure
(`TVar (Map Key RedisRecord)` as a minimal first step; a sharded map of
multiple `TVar`s keyed by a hash of the key, if contention remains a problem
after measuring). `runSet`/`runGet` (and the future reaper sweep) become STM
transactions instead of `MVar.modifyMVar_`/`MVar.readMVar` calls.

## Consequences

- Independent keys can be read and written concurrently instead of
  serializing through one global lock.
- STM transactions must stay small and side-effect-free (no `putStrLn`
  inside a transaction, unlike the current `set` implementation at
  `Table.hs:45`) — the debug logging currently inside `redisSet` needs to
  move outside the transaction.
- Sharding (if pursued) trades simplicity for concurrency: key-to-shard
  hashing adds a small amount of complexity in exchange for reduced
  contention. Start with a single `TVar` and measure before sharding.
