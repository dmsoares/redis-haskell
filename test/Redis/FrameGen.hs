{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The input generator for 'Redis.DifferentialSpec'.

Not a rung — this is what turns rung 3 from a table into a search. It produces a
well-formed command, then applies a few token-level edits.

__Why tokens and not @Resp@ values.__ A differential step depends on getting one
reply per command, and that correspondence does not hold over arbitrary @Resp@:
a malformed frame makes Redis answer @ERR Protocol error@ and __close the
connection__, ending the run; @*0@ and @*-1@ draw no reply at all; and a bare
bulk string is read as an inline command and can draw two.

__Why perturbation and not a command model.__ Generating @Command@ values and
rendering them can only produce frames our own parser already accepts, so it
cannot reach a wrong-arity, wrong-case or unknown-option frame — and every
entry in 'Redis.DifferentialSpec'\'s baseline is exactly one of those. Editing a
well-formed token list reaches them while keeping the frame recognisable enough
that Redis still answers once.

__The garbage pool must contain no real Redis names.__ A name that turns out to
be a real command makes the reference implement it and the SUT reject it, which
is a divergence the generator caused rather than found. Every name in 'garbage'
is checked against @COMMAND INFO@ on 8.10.1, and 'Redis.DifferentialSpec' is the
backstop: a frame that reaches an unimplemented command or option produces a
divergence that is not in its baseline, so the suite fails.
-}
module Redis.FrameGen (
    genRun,
    shrinkRun,
    genFrame,
    genWellFormed,
    perturb,
    garbage,
    maxFramesPerRun,
) where

import Control.Monad (foldM)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import qualified Data.Char as Char
import Test.QuickCheck (
    Arbitrary (arbitrary),
    Gen,
    choose,
    elements,
    frequency,
    listOf1,
    oneof,
    shrinkList,
    sized,
    vectorOf,
 )

import Redis.Sut (Frame)

{- | A run is a short sequence of frames down one connection.

__Kept short on purpose.__ Our commands run in-process, microseconds apart,
while each of Redis's costs a socket round trip; the two timelines drift by
roughly a millisecond every twenty commands. A short run bounds that drift. The
other half of the defence is in 'genExpiry' — see
@architecture/testing-plan.md@, "wall-clock TTLs are not differentially
testable".

Never empty, and never containing an empty frame: @*0@ draws no reply from
Redis at all, so a run containing one is a step whose two sides are not
comparable rather than a step that disagrees.
-}
genRun :: Gen [Frame]
genRun = sized $ \n -> do
    k <- choose (1, max 1 (min maxFramesPerRun n))
    vectorOf k genFrame

-- | See 'genRun' for why this cap exists.
maxFramesPerRun :: Int
maxFramesPerRun = 8

{- | Shrink a run by dropping frames, then by dropping tokens within a frame.

Both moves stay inside the generator's domain — dropping a token is one of the
'perturb' moves — so a shrunk counterexample is always one the generator could
have produced. The @filter (not . null)@ is load-bearing for the same reason
'genRun' avoids empty frames.
-}
shrinkRun :: [Frame] -> [[Frame]]
shrinkRun = shrinkList shrinkFrame
  where
    shrinkFrame f = filter (not . null) [dropAt i f | i <- [0 .. length f - 1]]

{- | A well-formed command, then zero to two perturbations.

Zero is included so that plain correct traffic is still exercised: the explorer
has to keep agreeing on the happy path, not only find edges.
-}
genFrame :: Gen Frame
genFrame = do
    base <- genWellFormed
    n <- frequency [(2, pure 0), (3, pure 1), (2, pure 2)]
    foldM (\f () -> perturb f) base (replicate n ())

{- | A frame our implementation is meant to handle, in canonical form.

Only commands we claim to support. The subset boundary this suite discovers is
at the level of /behaviours within/ a command — options, arities, error
vocabulary, precedence — so there is nothing to learn from generating @DEL@.
-}
genWellFormed :: Gen Frame
genWellFormed =
    oneof
        [ pure ["PING"]
        , (\m -> ["ECHO", m]) <$> genValue
        , (\k -> ["GET", k]) <$> genKey
        , (\k v o -> ["SET", k, v] <> o) <$> genKey <*> genValue <*> genSetOptions
        , (\k vs -> ["RPUSH", k] <> vs) <$> genKey <*> listOf1 genValue
        , (\k vs -> ["LPUSH", k] <> vs) <$> genKey <*> listOf1 genValue
        , (\k start stop -> ["LRANGE", k, start, stop]) <$> genKey <*> genInt <*> genInt
        ]

{- | A tiny key space, so that collisions between commands in a run are the
norm rather than a rarity. Three keys over an eight-frame run makes
last-write-wins, type conflicts and expiry overlap all likely.
-}
genKey :: Gen ByteString
genKey = elements ["a", "b", "c"]

{- | Short, printable, sometimes empty. Binary values are @Resp@'s problem, and
the round-trip property in @Resp.SerializationSpec@ already owns them.
-}
genValue :: Gen ByteString
genValue = elements ["", "v", "v2", "xyz", "0", "-1"]

{- | Zero or one expiry option. Two is reachable only by 'perturb' duplicating
one, which is the interesting way to reach it.
-}
genSetOptions :: Gen [ByteString]
genSetOptions =
    frequency
        [ (3, pure [])
        , (1, (\n -> ["EX", n]) <$> genExpiry 1 100)
        , (1, (\n -> ["PX", n]) <$> genExpiry 1000 100000)
        ]

genInt :: Gen ByteString
genInt = C8.pack . show <$> (arbitrary :: Gen Int)

{- | An expiry value that is either comfortably long-lived or plainly invalid,
and never briefly valid.

__This is the TTL floor decision in code.__ A short positive TTL — @PX 1@ — is
not differentially testable: it expires on Redis's slower timeline partway
through the run and never on ours, so the two sides are asked about different
instants and disagree for reasons that have nothing to do with the
implementation. It fails /reproducibly/, which is worse than flakily, because it
looks exactly like a real finding.

Invalid values are safe to generate and worth generating: a rejected expiry
never creates a live key, so no clock is involved, and the validation path is
precisely where divergences have been found. Hence the range is
@{ floor .. ceiling } ∪ { 0, negatives }@ rather than a blanket floor.

Expiry /semantics/ — when a key actually dies — belong to
'Redis.ModelSpec', where the clock is a logical value we advance ourselves.
-}
genExpiry :: Int -> Int -> Gen ByteString
genExpiry lo hi =
    C8.pack . show
        <$> frequency
            [ (4, choose (lo, hi))
            , (1, pure 0)
            , (1, negate <$> choose (lo, hi))
            ]

{- | One token-level edit.

Each move is guarded so that it either changes the frame or is not offered. In
particular, a move that could empty the frame is never offered on a singleton:
@*0@ draws no reply from Redis, so such a step has nothing to compare rather
than something to disagree about.
-}
perturb :: Frame -> Gen Frame
perturb f = oneof (always <> whenMultiple <> whenNumeric)
  where
    n = length f
    anyIndex = choose (0, n - 1)

    always =
        [ (\i -> duplicateAt i f) <$> anyIndex
        , (\i g -> replaceAt i g f) <$> anyIndex <*> garbageToken
        , (\i -> modifyAt i recase f) <$> anyIndex
        , (\g -> f <> [g]) <$> garbageToken
        ]

    whenMultiple
        | n <= 1 = []
        | otherwise =
            [ (\i -> dropAt i f) <$> anyIndex
            , (\i -> swapAt i f) <$> choose (0, n - 2)
            ]

    -- Only offered when there is a number to mangle, so the move is never a
    -- no-op dressed up as a perturbation.
    whenNumeric = case numericIndices f of
        [] -> []
        is -> [(\i g -> replaceAt i g f) <$> elements is <*> notAnInteger]

{- | Tokens that are not Redis command names and not SET option names.

Verified against @COMMAND INFO@ and @COMMAND DOCS SET@ on redis 8.10.1. See the
module header for why this list is checked rather than invented.
-}
garbage :: [ByteString]
garbage = ["ZZQ", "WOBBLE", "NOTACOMMAND", "frobnicate", "EXX", "PXP", "KEEPTTLX", ""]

garbageToken :: Gen ByteString
garbageToken = elements garbage

{- | Values a client might send where an integer is expected.

Chosen to straddle @readInt@'s boundary rather than to be uniformly nonsense,
because that boundary is where the divergences live:

* @readInt@ __rejects__ @abc@, @\"\"@, @\" 1\"@, @+1@ and anything that
  overflows @Int@. Those take the 'Redis.DifferentialSpec' syntax-error path.
* @readInt@ __accepts a prefix__ of @\"1 \"@, @1.5@ and @0x10@ and silently
  drops the rest, so these are accepted with the wrong value.
* @readInt@ __accepts in full__ what Redis's own grammar rejects: @-0@ and
  leading zeros.

A pool of only the first kind would have left two thirds of that behaviour
unreached, and the suite would have looked thorough while testing one branch.
-}
notAnInteger :: Gen ByteString
notAnInteger =
    elements
        [ "abc"
        , ""
        , " 1"
        , "1 "
        , "1.5"
        , "+1"
        , "0x10"
        , "-0"
        , "007"
        , "18446744073709551616"
        , "99999999999999999999"
        ]

-- Token-list surgery. Each is total: an out-of-range index leaves the frame
-- alone rather than throwing, so a guard bug degrades into a wasted test case
-- instead of an exception that looks like a failure of the code under test.

numericIndices :: Frame -> [Int]
numericIndices f = [i | (i, t) <- zip [0 ..] f, isNumeric t]
  where
    isNumeric t = not (C8.null t) && C8.all Char.isDigit (dropSign t)
    dropSign t = if C8.head t == '-' then C8.tail t else t

dropAt :: Int -> [a] -> [a]
dropAt i xs = take i xs <> drop (i + 1) xs

duplicateAt :: Int -> [a] -> [a]
duplicateAt i xs = case drop i xs of
    (x : _) -> take i xs <> [x, x] <> drop (i + 1) xs
    [] -> xs

replaceAt :: Int -> a -> [a] -> [a]
replaceAt i x = modifyAt i (const x)

modifyAt :: Int -> (a -> a) -> [a] -> [a]
modifyAt i g xs = case drop i xs of
    (x : rest) -> take i xs <> [g x] <> rest
    [] -> xs

swapAt :: Int -> [a] -> [a]
swapAt i xs = case drop i xs of
    (x : y : rest) -> take i xs <> [y, x] <> rest
    _ -> xs

{- | Flip the case of every ASCII letter.

Bytes above 127 are left alone. @Data.Char.toUpper@ over 'C8.map' would truncate
them — @toUpper '\\xFF'@ is codepoint 376, which @Char8@ narrows back to @'x'@ —
silently corrupting a binary token into a different one.
-}
recase :: ByteString -> ByteString
recase = C8.map $ \case
    c
        | Char.isAsciiLower c -> Char.toUpper c
        | Char.isAsciiUpper c -> Char.toLower c
        | otherwise -> c
