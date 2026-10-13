{-# LANGUAGE OverloadedStrings #-}

{- | The __SUT__ — system under test: our own server, driven at the boundary
@Main@ uses.

Not a rung — this is the other half of the plumbing. 'Redis.Reference' owns the
side we trust; this module owns the side we are testing. Naming them that way
round is the standard pairing, and it is what makes a differential step
symmetric: both sides take a 'Frame' and answer with a 'Reply'.

All three suites reach the implementation through here, so there is one
definition of "what our server replies" rather than one per suite.

__The boundary is bytes in, bytes out__, exactly as in @Main@: parse with
@fromBytes@, dispatch with @reply@, render with @toBytes@. That puts the
deserializer, the dispatcher and the serializer all inside the tested region.
Handing @reply@ a @Resp@ value built in the test would leave @fromBytes@ outside
it, and @fromBytes@ is part of the server.

__The clock is an argument, not an effect.__ 'sutReply' reads the real clock the
way @Main@ does; 'sutReplyAt' takes it as a parameter. That one seam is what lets
'Redis.ModelSpec' test expiry on a logical clock without sleeping, and it is the
architectural precondition for __rung 5__ (deterministic simulation) later.

__Requests are encoded by 'Redis.Reference.encodeCommand'__, not by
@Resp.toBytes@. Both implementations must receive identical bytes, and bytes
produced by the code under test are not trustworthy for that job.
-}
module Redis.Sut (
    Frame,
    sutReplies,
    sutReply,
    sutReplyAt,
    runBoth,
    Step (..),
    diverged,
    renderStep,
    renderRun,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import Data.Time (UTCTime, getCurrentTime)

import Redis (RedisStore, newRedisStore, reply)
import Redis.Reference (Reference, Reply (..), encodeCommand, runSequence)
import Resp (fromBytes, toBytes)

{- | One command as a client sends it: the tokens, nothing else.

Tokens are the common currency of every surface syntax Redis accepts — a RESP
array of bulk strings and an inline @PING\\r\\n@ both reduce to the same token
list — which is why both sides of a differential step take this and not a
@Resp@. It also keeps the generator honest: there is exactly one rendering, in
'encodeCommand', so the two sides cannot drift.
-}
type Frame = [ByteString]

{- | One differential step: what we sent, and what each side said about it.

One record per step rather than three parallel lists of frames, SUT replies and
reference replies. Parallel lists need @zipWith3@ to read and a length check to
trust, because misalignment is a state they can represent; here it cannot
happen, so there is nothing to check.
-}
data Step = Step
    { stepFrame :: Frame
    , stepSut :: Reply
    , stepReference :: Reply
    }
    deriving (Eq, Show)

-- | Did the two implementations disagree about this step?
diverged :: Step -> Bool
diverged s = stepSut s /= stepReference s

{- | Run one sequence against both implementations and pair up the answers.

Order matters: the model goes first and 'runSequence' resets it with @FLUSHALL@,
while our store is simply built fresh. Both sides therefore start empty.
-}
runBoth :: Reference -> [Frame] -> IO [Step]
runBoth ref frames = do
    reference <- runSequence ref frames
    sut <- sutReplies frames
    pure (zipWith3 Step frames sut reference)

{- | Our replies to a sequence of frames, one per frame, in order.

A fresh store per sequence, so runs cannot leak state into each other.
-}
sutReplies :: [Frame] -> IO [Reply]
sutReplies frames = do
    store <- newRedisStore
    traverse (sutReply store) frames

{- | Our reply to a single frame, against a store that persists across the call.

The clock is sampled __here__, after the frame is in hand, because that is where
@Main@ samples it: @getCurrentTime@ runs after the blocking read, not before.
Sampling once per sequence instead would make every command in a run share a
timestamp — the exact shape of the bug that injecting the clock was meant to
expose, reintroduced in the harness.
-}
sutReply :: RedisStore -> Frame -> IO Reply
sutReply store ts = getCurrentTime >>= \now -> sutReplyAt now store ts

{- | As 'sutReply', but with the clock supplied rather than read.

This is the seam the whole stateful suite rests on. With @now@ as an argument,
expiry is a pure function of a value the test chooses, so
'Redis.ModelSpec' can step a logical clock forward by an exact number of
milliseconds, land on the expiry instant precisely, and never sleep.

@Redis.DifferentialSpec@ cannot use it: the model server reads the real clock
and we have no way to move it, which is why wall-clock TTLs are not
differentially testable and expiry semantics live in Suite 3 instead.
-}
sutReplyAt :: UTCTime -> RedisStore -> Frame -> IO Reply
sutReplyAt now store ts = case fromBytes (encodeCommand ts) of
    -- Unreachable while 'encodeCommand' is correct, since every token list has a
    -- well-formed RESP rendering. Kept total and mapped to 'NoReply' because
    -- that is what a client would actually observe: @Main.fullQuery@ reads
    -- 'Nothing' as "need more bytes" and blocks for bytes that never come
    -- (known-gaps #2), so nothing is sent back.
    Nothing -> pure NoReply
    Just query -> Reply . toBytes <$> reply now store query

-- | One step, as a two-line block. Shared by every suite's counterexamples.
renderStep :: Step -> String
renderStep (Step f sut reference) =
    "  "
        <> show (C8.unpack <$> f)
        <> "\n      sut       : "
        <> show sut
        <> "\n      reference : "
        <> show reference

-- | A whole run, for context around the step that failed.
renderRun :: [Step] -> String
renderRun = unlines . fmap renderStep
