# 2. Actively evict expired keys

Date: 2026-08-30

## Status

Proposed

## Context

`Redis.Table.newRedisTable` only checks a key's expiry lazily, at `GET` time
(`Table.hs:50-54`). A key that is set with `EX`/`PX` and never read again
stays in the underlying `Map` forever — its memory is never reclaimed. Under
sustained write load with short-lived keys, this is an unbounded memory leak.

## Decision

Add a background **Expiry Reaper** component that periodically scans the
In-Memory Key-Value Store and removes records whose expiry has passed,
independent of whether a client ever reads them again. Lazy expiry-on-read
stays in place as a correctness backstop (a key must never be served after
it has expired, even if the reaper hasn't run yet); the reaper's job is
reclaiming memory, not correctness.

Modeled as a `Proposed`-tagged component with an `Expiry Reaper -> In-Memory
Key-Value Store` relationship in the C4 workspace's `ComponentsTarget` view.

## Consequences

- Bounds memory growth from expiring keys under sustained write load.
- Introduces a second writer to the store running on its own schedule; the
  store's concurrency model (see ADR 0004) needs to support that safely.
- Needs a sweep interval decision (trade-off between reclaim latency and scan
  overhead) — not yet decided, deferred to implementation time.
