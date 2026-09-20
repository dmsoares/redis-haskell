# 1. Buffer connection reads for full RESP frames

Date: 2026-08-30

## Status

Proposed

## Context

`Main.hs` reads a fixed 64 bytes per `recv` call and passes that chunk straight
to `Commands.deserialize`, which assumes it received one complete RESP value.
Any command whose encoded size exceeds 64 bytes (a `SET` with a longer value,
or multiple pipelined commands split across TCP segments) arrives truncated
and fails to parse, with no mechanism to wait for and accumulate the rest of
the frame.

TCP is a byte stream, not a message stream: a single `recv()` may return less
than a full RESP value, more than one RESP value, or a value split arbitrarily
across several reads. Framing (deciding where one command ends and the next
begins) is the listener's responsibility, not the parser's.

## Decision

Introduce a **connection buffer** inside the TCP Listener's read loop, in
front of the call to `Commands.deserialize`. It accumulates bytes across
repeated `recv` calls and only hands a chunk onward once a complete RESP
frame is available, leaving any leftover bytes (e.g. the start of a pipelined
next command) buffered for the following read.

This is **not** modeled as a separate component in the C4 workspace. The
Connection Buffer is internal structure of the TCP Listener component — a
buffer plus a framing predicate inside its read loop — and C4 components are
"a grouping of related functionality encapsulated behind a well-defined
interface", not individual functions. It shows up at the code level instead:
`architecture/callgraphs/tcp-listener.svg` currently has just `main` and one
local binding, because the entire accept/read/dispatch loop is written inline.
This buffer would be that component's first real internal decomposition, and
the regenerated call graph is how you'd see it land.

## Consequences

- Values and pipelined commands of any size can be parsed correctly.
- The TCP Listener's read loop becomes slightly more stateful (per-connection
  buffer state), but that complexity is isolated to one component instead of
  leaking into the parser or command layer.
- The RESP Parser still needs to be able to signal "incomplete input, need
  more bytes" distinctly from "malformed input" for the buffer to know
  whether to wait for more data or reject the frame outright — worth
  revisiting `Redis.RESP.Parser`'s error handling alongside this change.
