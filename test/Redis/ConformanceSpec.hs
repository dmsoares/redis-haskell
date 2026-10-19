{-# LANGUAGE OverloadedStrings #-}

{- | Suite 1 of three — the conformance table.

* __Rung 0__ (examples), with a slice of __rung 1__ (interface schema)
* __Question__ — does the server still do what we decided it does?
* __Oracle__ — a table in this file; every row carries its own answer
* __Contract__ — always green. Red means agreed behaviour changed.
* __Industry pattern__ — a conformance suite; the rows are golden, or
  approval, tests

The ladder of specs these rungs refer to:

> architecture/research/spec-driven-development.md   section 1

__Where the rows come from.__ They were measured against @redis-server@ 8.10.1 by
running both implementations over the same frames, then reviewed one by one and
kept only where the two /already agree/. The review is the important step: it
turns a recording of current behaviour into a decision about correct behaviour.

__The rung-1 slice.__ 'arities' is the @arity@ field of @COMMAND INFO@, copied
verbatim, and 'arityRows' derives every rejection case from it. That is rung 1 in
miniature: a machine-readable fact about the interface generating tests, rather
than a hand-written case per command. A sixth command costs one line.

__Why no generator here.__ These cases are finite and each has one right answer,
so a row can simply carry it. Generating inputs would instead mean /predicting/
answers, which needs a model of Redis's error precedence — the problem
'Redis.DifferentialSpec' is built to sidestep rather than solve.

__Its blind spot, and who covers it.__ This file only knows what someone thought
to write down. 'Redis.DifferentialSpec' is what finds the rest — and this file is
where its findings come to rest. When a divergence is fixed, its @baseline@ entry
is deleted and a row appears here. That downward traffic, rung 3 to rung 0, is
what stops a fix from quietly regressing.
-}
module Redis.ConformanceSpec (spec) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import Data.Foldable (for_)

import Test.Hspec (Spec, describe, it, shouldBe)

import Redis (newRedisStore)
import Redis.Reference (Reply (Reply))
import Redis.Sut (Frame, sutReplies, sutReply)

spec :: Spec
spec = describe "Conformance" $ do
    describe "single commands" $ for_ singles (uncurry expectReply)
    describe "arity, from COMMAND INFO" $ for_ arityRows (uncurry expectReply)
    describe "sequences" $ for_ sequences (uncurry expectSequence)

{- | A frame, and the only reply we accept for it.

Asserted through 'sutReply', which goes bytes-in to bytes-out through the real
deserializer, dispatcher and serializer — the same boundary @app/Main.hs@ uses.
-}
expectReply :: Frame -> ByteString -> Spec
expectReply frame expected =
    it (label frame) $ do
        store <- newRedisStore
        actual <- sutReply store frame
        actual `shouldBe` Reply expected

{- | A frame sequence against one store, with an expected reply for each step.

Separate from 'expectReply' because the interesting rows here are the ones where
the answer depends on what came before — a type conflict, an overwrite — and
those cannot be expressed one frame at a time.
-}
expectSequence :: String -> [(Frame, ByteString)] -> Spec
expectSequence name rows =
    it name $ do
        actual <- sutReplies (fst <$> rows)
        actual `shouldBe` (Reply . snd <$> rows)

label :: Frame -> String
label = unwords . fmap C8.unpack

-- * Rows

{- | Captured from redis 8.10.1, reviewed, and limited to behaviour we match.

Notable absences, all of them 'Redis.DifferentialSpec' baseline entries rather
than oversights: @PING hello@ (we ignore the message), @BOGUS a b@ (we omit the
argument list from the error), and @SET k v EX abc@ (we report a syntax error
where Redis reports a non-integer).
-}
singles :: [(Frame, ByteString)]
singles =
    [ (["PING"], "+PONG\r\n")
    , (["ping"], "+PONG\r\n")
    , (["PiNg"], "+PONG\r\n")
    , (["ECHO", "hi"], "$2\r\nhi\r\n")
    , (["echo", "hi"], "$2\r\nhi\r\n")
    , -- An empty bulk string is a value, not an absence. It must not come back
      -- as $-1, which is how a Maybe-shaped reply type would be tempted to
      -- render it.
      (["ECHO", ""], "$0\r\n\r\n")
    , (["GET", "absent"], "$-1\r\n")
    , (["SET", "k", "v"], "+OK\r\n")
    , (["SET", "k", ""], "+OK\r\n")
    , -- Expiry grammar: accepted forms. Whether the key later dies is
      -- Redis.ModelSpec's question, not this file's.
      (["SET", "k", "v", "EX", "100"], "+OK\r\n")
    , (["SET", "k", "v", "PX", "100000"], "+OK\r\n")
    , (["SET", "k", "v", "ex", "100"], "+OK\r\n")
    , (["SET", "k", "v", "px", "100000"], "+OK\r\n")
    , -- Expiry validation: zero is invalid, not just negatives. The boundary is
      -- `> 0`, which is easy to write as `>= 0` and never notice.
      (["SET", "k", "v", "EX", "0"], invalidExpireTime)
    , (["SET", "k", "v", "EX", "-1"], invalidExpireTime)
    , (["SET", "k", "v", "PX", "0"], invalidExpireTime)
    , (["SET", "k", "v", "PX", "-500"], invalidExpireTime)
    , -- Two expiry options are a grammar violation, not a semantic conflict, so
      -- the answer is a syntax error and not a bespoke "conflicting options".
      (["SET", "k", "v", "EX", "1", "PX", "1000"], syntaxError)
    , (["SET", "k", "v", "PX", "1000", "EX", "1"], syntaxError)
    , -- Redis's genuinely subtle rule: repeated EX is accepted, and only the
      -- \*last* one is validated. These two rows differ in order alone and must
      -- stay that way; collapsing them to "any invalid value errors" is wrong.
      (["SET", "k", "v", "EX", "-1", "EX", "6"], "+OK\r\n")
    , (["SET", "k", "v", "EX", "6", "EX", "-1"], invalidExpireTime)
    , -- An unrecognised option is rejected, not discarded. Discarding it would
      -- answer +OK and store a key with semantics the client did not ask for.
      (["SET", "k", "v", "BOGUS"], syntaxError)
    , (["SET", "k", "v", "EX", "100", "BOGUS"], syntaxError)
    , (["RPUSH", "l", "a"], ":1\r\n")
    , (["RPUSH", "l", "a", "b"], ":2\r\n")
    , (["rpush", "l", "a"], ":1\r\n")
    , (["LPUSH", "l", "a"], ":1\r\n")
    , (["LPUSH", "l", "a", "b"], ":2\r\n")
    , (["lpush", "l", "a"], ":1\r\n")
    , -- If key does not exist, return empty array
      (["LRANGE", "l", "0", "1"], "*0\r\n")
    , (["LRANGE", "l", "x", "x"], notAnInteger)
    , -- An absent key is an empty list, not a nil.
      (["LLEN", "l"], ":0\r\n")
    , (["llen", "l"], ":0\r\n")
    , -- The command name is case-insensitive; the *argument* is not, and must
      -- survive byte for byte.
      (["BOGUS"], "-ERR unknown command 'BOGUS'\r\n")
    , (["bogus"], "-ERR unknown command 'bogus'\r\n")
    ]

{- | Stateful rows, where the expected reply depends on the preceding commands.

@WRONGTYPE@ is here in both directions deliberately. It is the one error whose
code is not @ERR@, so a serializer that hardcoded the prefix would pass
everything else in this file.
-}
sequences :: [(String, [(Frame, ByteString)])]
sequences =
    [
        ( "GET returns what SET stored"
        , [(["SET", "s", "v"], "+OK\r\n"), (["GET", "s"], "$1\r\nv\r\n")]
        )
    ,
        ( "SET overwrites, last write wins"
        ,
            [ (["SET", "s", "v1"], "+OK\r\n")
            , (["SET", "s", "v2"], "+OK\r\n")
            , (["GET", "s"], "$2\r\nv2\r\n")
            ]
        )
    ,
        ( "SET replaces a list outright, rather than refusing"
        ,
            [ (["RPUSH", "s", "a"], ":1\r\n")
            , (["SET", "s", "v"], "+OK\r\n")
            , (["GET", "s"], "$1\r\nv\r\n")
            ]
        )
    ,
        ( "GET on a list is WRONGTYPE"
        , [(["RPUSH", "s", "a"], ":1\r\n"), (["GET", "s"], wrongType)]
        )
    ,
        ( "RPUSH onto a string is WRONGTYPE"
        , [(["SET", "s", "v"], "+OK\r\n"), (["RPUSH", "s", "a"], wrongType)]
        )
    ,
        ( "RPUSH appends and reports the new length"
        ,
            [ (["RPUSH", "s", "a"], ":1\r\n")
            , (["RPUSH", "s", "b", "c"], ":3\r\n")
            , (["RPUSH", "s", "d"], ":4\r\n")
            ]
        )
    ,
        ( "LPUSH onto a string is WRONGTYPE"
        , [(["SET", "s", "v"], "+OK\r\n"), (["LPUSH", "s", "a"], wrongType)]
        )
    ,
        ( "LPUSH preppends and reports the new length"
        ,
            [ (["LPUSH", "s", "a"], ":1\r\n")
            , (["LPUSH", "s", "b", "c"], ":3\r\n")
            , (["LPUSH", "s", "d"], ":4\r\n")
            , (["LRANGE", "s", "0", "4"], "*4\r\n$1\r\nd\r\n$1\r\nc\r\n$1\r\nb\r\n$1\r\na\r\n")
            ]
        )
    ,
        ( "keys are independent"
        ,
            [ (["SET", "a", "1"], "+OK\r\n")
            , (["SET", "b", "2"], "+OK\r\n")
            , (["GET", "a"], "$1\r\n1\r\n")
            , (["GET", "b"], "$1\r\n2\r\n")
            ]
        )
    ,
        ( "LRANGE deals with negative indexes"
        ,
            [ (["RPUSH", "mango", "grape", "apple", "pear", "blueberry"], ":4\r\n")
            , (["LRANGE", "mango", "-3", "-1"], "*3\r\n$5\r\napple\r\n$4\r\npear\r\n$9\r\nblueberry\r\n")
            ]
        )
    ,
        ( "LLEN counts what both ends pushed"
        ,
            [ (["RPUSH", "s", "a", "b"], ":2\r\n")
            , (["LPUSH", "s", "c"], ":3\r\n")
            , (["LLEN", "s"], ":3\r\n")
            ]
        )
    ,
        ( "LLEN on a string is WRONGTYPE"
        , [(["SET", "s", "v"], "+OK\r\n"), (["LLEN", "s"], wrongType)]
        )
    ]

-- * Arity

{- | @arity@ as reported by @COMMAND INFO@ on redis 8.10.1.

A positive @n@ means exactly @n@ tokens including the command name; a negative
@n@ means at least @|n|@, variadic beyond that. Captured verbatim:

> ping -1   echo 2   get 2   set -3   rpush -3   lrange 4   llen 2

Keeping this as data rather than as a case per command is the point: 'arityRows'
is one rule, and a sixth command costs one line here instead of a new test.
-}
arities :: [(ByteString, Int)]
arities =
    [ ("PING", -1)
    , ("ECHO", 2)
    , ("GET", 2)
    , ("SET", -3)
    , ("RPUSH", -3)
    , ("LPUSH", -3)
    , ("LRANGE", 4)
    , ("LLEN", 2)
    ]

{- | Every token count the arity table says must be rejected.

__Too few__ for any command, and __too many__ only for the fixed-arity ones,
since a variadic command has no upper bound to violate.

@PING@ contributes no rows at all, and that is correct rather than a gap: arity
@-1@ makes "fewer than one token" the only violation, and a zero-token frame is
not a command — Redis answers nothing at all, so there are no bytes to assert.
@PING a b@ /is/ rejected by Redis, but by a command-specific check rather than
by arity, which is why it is not derivable here and lives in the differential
baseline instead.
-}
arityRows :: [(Frame, ByteString)]
arityRows =
    [ (frame name count, wrongNumberOfArguments name)
    | (name, arity) <- arities
    , count <- violatingCounts arity
    ]
  where
    violatingCounts arity
        | arity < 0 = [1 .. abs arity - 1]
        | otherwise = [1 .. arity - 1] <> [arity + 1]

    -- Filler that is not an option name for any command in the table, so a
    -- "too many" row fails on the count and not on the grammar.
    frame name count = name : replicate (count - 1) "x"

wrongNumberOfArguments :: ByteString -> ByteString
wrongNumberOfArguments name =
    "-ERR wrong number of arguments for '" <> C8.map toLowerAscii name <> "' command\r\n"
  where
    toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

syntaxError :: ByteString
syntaxError = "-ERR syntax error\r\n"

invalidExpireTime :: ByteString
invalidExpireTime = "-ERR invalid expire time in 'set' command\r\n"

wrongType :: ByteString
wrongType = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"

notAnInteger :: ByteString
notAnInteger = "-ERR value is not an integer or out of range\r\n"
