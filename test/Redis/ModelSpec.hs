{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Suite 3 of three — the stateful model.

* __Rung 3__ (model, or lockstep), where the model is __one we wrote__
* __Question__ — does /any/ sequence of commands behave like a key-value
  store with expiry?
* __Oracle__ — 'step', a pure function in this file. __Not Redis__ — nothing
  here opens a socket.
* __Contract__ — always green. Red means the code and our own stated semantics disagree.
* __Industry pattern__ — model-based, or lockstep, testing

The ladder of specs these rungs refer to:

> architecture/research/spec-driven-development.md   section 1

__The two flavours of rung 3, side by side.__ Both suites run two
implementations step for step and compare. They differ only in where the right
answer comes from, and that one difference decides what each can ask:

> DifferentialSpec   model = real Redis   high trust, no upkeep, but you can
>                                          only ask what the wire allows
> ModelSpec          model = step         can be wrong and needs upkeep, but
>                                          you can ask it anything

__What "anything" buys here: time.__ Redis has no command for "advance your
clock", so testing expiry against it means really sleeping — slow, flaky, and
for sub-second TTLs simply wrong, because our commands run in-process while
Redis's each cost a round trip. 'Redis.Sut.sutReplyAt' takes @now@ as an
argument, so 'Advance' is just another generated operation: the expiry instant is
hit exactly, nothing sleeps, and a failure reproduces from its seed forever.

__Where the model's authority comes from.__ It is second-hand truth: every
semantic in 'step' was measured against Redis 8.10.1 and then frozen into code.
Suite 2 earns those facts; this suite spends them over sequences and clocks that
Suite 2 cannot reach.

__The risk, and the guard.__ A wrong model is confidently wrong — red on good
code, or green on bad. Two defences. The example rows assert a /third/ answer,
stated independently and checked against both sides, so the model cannot be
"whatever makes the property pass". And on 2026-10-09 the suite was audited by
hand by mutating the implementation: @isLive@'s @\<@ becoming @\<=@, @EX@
meaning milliseconds, @msToDiff@ losing its division by 1000, @SET@ dropping the
TTL, and @pSetOptions@ taking @head@ instead of @last@ were all killed. Nothing
re-runs that audit, so treat it as a dated observation, not a standing guarantee.

__Two blind spots, both known.__ Expiry /validation/ (@PX 0@ is rejected) is
Suite 1's, and 'genTtl' only produces valid values. __List order__ is nobody's:
no command reads a list back, so a mutation making @RPUSH@ prepend survived every
suite in this project when tried by hand on 2026-10-09. Green here is not evidence that
lists are ordered correctly. See @known-gaps.md@ #18; the model already tracks
order, so @LRANGE@ closes it for free.

__Hand-rolled rather than @quickcheck-state-machine@.__ The library is in
@lts-23.18@, but its ceremony buys symbolic references and linearizability
testing (__rung 4__), and we need neither yet: keys are generated directly rather
than returned by an earlier command, and the store is driven single-threaded. It
goes back on the table the day concurrent clients are tested.
-}
module Redis.ModelSpec (spec) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time (
    NominalDiffTime,
    UTCTime (UTCTime),
    addUTCTime,
    fromGregorian,
    secondsToDiffTime,
 )

import Test.Hspec (Expectation, Spec, describe, it, shouldBe)
import Test.QuickCheck (
    Gen,
    Property,
    choose,
    counterexample,
    elements,
    forAllShrink,
    frequency,
    ioProperty,
    listOf1,
    shrinkList,
    sized,
    vectorOf,
    (===),
 )

import Redis (newRedisStore)
import Redis.Reference (Reply (Reply))
import Redis.Sut (Frame, sutReplyAt)

-- * The operation language

{- | One step of a run.

'Advance' is the odd one out and the important one: it is the only operation
with no wire form, because moving the clock is not something a client can ask
for. It exists so that expiry — the only behaviour in the store that depends on
anything other than the command history — becomes an ordinary generated value.
-}
data Op
    = Set Key Value (Maybe Ttl)
    | Get Key
    | RPush Key [Value]
    | Advance Millis
    deriving (Eq, Show)

{- | An expiry, in the unit the client wrote it in.

__The unit is carried rather than normalised at generation, on purpose.__ The
factor of 1000 between @EX@ and @PX@ is only under test if the unit reaches the
wire. Normalising to milliseconds in the generator would leave it untested
everywhere: 'Redis.ConformanceSpec' answers @+OK@ either way because it has no
clock, and a @PX@-only model never performs the conversion at all.
-}
data Ttl
    = -- | @EX@: whole seconds
      Ex Int
    | -- | @PX@: milliseconds
      Px Millis
    deriving (Eq, Show)

-- | The one place the @EX@-to-@PX@ factor is written down on this side.
ttlMillis :: Ttl -> Millis
ttlMillis = \case
    Ex s -> s * 1000
    Px ms -> ms

type Key = ByteString
type Value = ByteString

-- | Milliseconds. Named because a bare 'Int' here is read as seconds half the
-- time, and @PX@ takes milliseconds.
type Millis = Int

{- | The frame a client would send for this operation.

'Nothing' for 'Advance', which has no wire form. A 'Maybe' rather than a partial
function because the absence is a fact about the operation language worth stating
in the type, not an oversight to crash on.
-}
frameOf :: Op -> Maybe Frame
frameOf = \case
    Set k v Nothing -> Just ["SET", k, v]
    Set k v (Just (Ex secs)) -> Just ["SET", k, v, "EX", C8.pack (show secs)]
    Set k v (Just (Px ms)) -> Just ["SET", k, v, "PX", C8.pack (show ms)]
    Get k -> Just ["GET", k]
    RPush k vs -> Just (["RPUSH", k] <> vs)
    Advance _ -> Nothing

-- * The model

{- | A key-value store with expiry, as a value.

Expiry is stored as the __absolute instant__ the key dies, not as a duration,
because that is the only form in which it is comparable to the clock. Keeping
the duration instead means recomputing against an insertion time on every read,
which is exactly where @Redis.Data.Record@ keeps the complexity and exactly the
arithmetic a model exists to cross-check.
-}
data Model = Model
    { entries :: Map Key Entry
    , now :: UTCTime
    }
    deriving (Show)

data Entry = Entry
    { stored :: Stored
    , diesAt :: Maybe UTCTime
    }
    deriving (Show)

data Stored
    = AString ByteString
    | AList [ByteString]
    deriving (Eq, Show)

{- | What an operation answers, at the level the model reasons about.

Separate from reply bytes so the model states semantics and 'render' states
rendering, once. A model that spoke in bytes would make every case below carry a
@\"$\" <> length <> ...@ that has nothing to do with storage.
-}
data Answer
    = Ok
    | Nil
    | Returned ByteString
    | Length Int
    | WrongType
    | -- | 'Advance' sends nothing, so there is nothing to compare. Both sides
      -- emit this so that indices stay aligned and a counterexample can be read
      -- straight down against the operation list.
      Moved
    deriving (Eq, Show)

-- | The reply bytes an 'Answer' corresponds to.
render :: Answer -> Reply
render = \case
    Ok -> Reply "+OK\r\n"
    Nil -> Reply "$-1\r\n"
    Returned v -> Reply ("$" <> C8.pack (show (C8.length v)) <> "\r\n" <> v <> "\r\n")
    Length n -> Reply (":" <> C8.pack (show n) <> "\r\n")
    WrongType -> Reply "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
    Moved -> Reply "<clock moved>"

{- | An arbitrary fixed instant.

Any instant would do; a round one keeps counterexamples readable. It must be the
same on both sides, which is the only thing that matters.
-}
epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

initialModel :: Model
initialModel = Model Map.empty epoch

millis :: Millis -> NominalDiffTime
millis ms = fromIntegral ms / 1000

{- | The model's transition function: one operation, one answer, one new state.

Pure, total, and the whole specification of the store's semantics.
-}
step :: Op -> Model -> (Answer, Model)
step op m@Model{entries, now} = case op of
    Advance ms -> (Moved, m{now = addUTCTime (millis ms) now})
    Get k -> case live k m of
        Nothing -> (Nil, m)
        Just Entry{stored = AString v} -> (Returned v, m)
        Just Entry{stored = AList _} -> (WrongType, m)
    -- A plain SET replaces the entry outright, including dropping any TTL the
    -- key already had. That is not obvious -- KEEPTTL exists precisely because
    -- clearing is the default -- and it is the kind of thing a model pins for
    -- free while a hand-written example has to think of it.
    Set k v ttl -> (Ok, m{entries = Map.insert k (Entry (AString v) (expiryFor ttl)) entries})
    RPush k vs -> case live k m of
        Nothing -> (Length (length vs), put k (Entry (AList vs) Nothing))
        -- Appending preserves the existing expiry: RPUSH is not a fresh write.
        Just e@Entry{stored = AList xs} ->
            let xs' = xs <> vs in (Length (length xs'), put k e{stored = AList xs'})
        Just Entry{stored = AString _} -> (WrongType, m)
  where
    put k e = m{entries = Map.insert k e entries}
    expiryFor = fmap (\ttl -> addUTCTime (millis (ttlMillis ttl)) now)

{- | The entry under a key, if there is one and it has not expired.

__The boundary.__ Live means @now < diesAt@, so a key is dead __at__ its expiry
instant, not one tick after. This mirrors @Redis.Data.Record.isLive@ and pinning
it is one of this suite's stated targets: @<@ versus @<=@ here is a one-character
edit that no example-based test is likely to sit exactly on, and that a
wall-clock test can never sit on at all.

Worth knowing, and deliberately /not/ asserted: real Redis's own boundary
condition at the exact millisecond is not something this project has verified,
and it is not differentially reachable either, since we cannot move the model
server's clock. So this pins __our__ chosen semantics. If the boundary is ever
checked against Redis and found to differ, the fix is one character here and one
in @isLive@ -- and this suite is what makes that safe to do.
-}
live :: Key -> Model -> Maybe Entry
live k Model{entries, now} = do
    e <- Map.lookup k entries
    case diesAt e of
        Just t | now >= t -> Nothing
        _ -> Just e

-- | The model's replies to a run, in order.
modelReplies :: [Op] -> [Reply]
modelReplies = go initialModel
  where
    go _ [] = []
    go m (o : os) = let (a, m') = step o m in render a : go m' os

-- * The implementation

{- | Our replies to the same run, with the clock advanced by 'Advance' alone.

The store is built fresh per run, and @now@ is threaded explicitly, so a run is
a closed experiment: nothing leaks in from the real clock or from a previous
case, and a counterexample reproduces from its seed indefinitely.
-}
runOps :: [Op] -> IO [Reply]
runOps ops = do
    store <- newRedisStore
    go store epoch ops
  where
    go _ _ [] = pure []
    go store t (o : os) = case frameOf o of
        Nothing -> (render Moved :) <$> go store (advanceFor o t) os
        Just f -> do
            r <- sutReplyAt t store f
            (r :) <$> go store t os

    advanceFor (Advance ms) t = addUTCTime (millis ms) t
    advanceFor _ t = t

-- * Generation

{- | A run of operations.

Small pools everywhere, because the interesting events are __collisions__: two
commands on the same key, a type conflict, an advance that lands exactly on an
expiry. Widening the pools makes each case more varied and far less likely to
contain anything that interacts.
-}
genOps :: Gen [Op]
genOps = sized $ \n -> choose (0, min 20 n) >>= \k -> vectorOf k genOp

genOp :: Gen Op
genOp =
    frequency
        [ (3, Set <$> genKey <*> genValue <*> genTtl)
        , (3, Get <$> genKey)
        , (2, RPush <$> genKey <*> listOf1 genValue)
        , (3, Advance <$> genAdvance)
        ]

-- | Two keys, so that a six-operation run almost always touches one twice.
genKey :: Gen Key
genKey = elements ["a", "b"]

genValue :: Gen Value
genValue = elements ["", "v", "w"]

{- | A TTL, or none, in either unit.

Only __valid__ values: this suite is about when a key dies, not about whether
the command parses. @PX 0@ and @PX -1@ are 'Redis.ConformanceSpec' rows.

Both units are generated so that the seconds-to-milliseconds conversion is
exercised; see 'Ttl'.
-}
genTtl :: Gen (Maybe Ttl)
genTtl =
    frequency
        [ (1, pure Nothing)
        , (2, Just . Px <$> elements pxPool)
        , (2, Just . Ex <$> elements exPool)
        ]

{- | Advances drawn from the __same pool__ as the TTLs, plus their pairwise sums
and zero.

This is the one piece of targeted generation in the suite, and it is what makes
the expiry boundary reachable. Drawing advances from a wide range would make
@now == diesAt@ a measure-zero coincidence; sharing a pool makes landing exactly
on the boundary routine, so the @<@ in 'live' is genuinely exercised rather than
merely approached.

The pool includes the @EX@ values in milliseconds, so a one-second expiry is
reachable both by a single @Advance 1000@ and by accumulating smaller steps.
-}
genAdvance :: Gen Millis
genAdvance = elements (0 : pool <> [a + b | a <- pool, b <- pool])
  where
    pool = pxPool <> fmap (* 1000) exPool

pxPool :: [Millis]
pxPool = [100, 200, 500, 1000]

exPool :: [Int]
exPool = [1, 2]

{- | Shrink by dropping operations, then by simplifying one.

Every element move strictly decreases something — a TTL becomes absent, a push
loses a value, an advance gets smaller — so no candidate can equal its input.
That is the well-foundedness QuickCheck requires: @x `elem` shrink x@ makes
shrinking loop forever.
-}
shrinkOps :: [Op] -> [[Op]]
shrinkOps = shrinkList shrinkOp
  where
    shrinkOp = \case
        Set k v (Just (Ex s)) -> Set k v Nothing : [Set k v (Just (Px (s * 1000)))]
        Set k v (Just (Px _)) -> [Set k v Nothing]
        Set _ _ Nothing -> []
        Get _ -> []
        RPush k vs -> [RPush k (init vs) | length vs > 1]
        Advance ms -> [Advance m | m <- [0, ms `div` 2], m < ms]

-- * The suite

spec :: Spec
spec = describe "Store" $ do
    it "answers every generated sequence the way the model does" matchesModel
    describe "expiry boundary" boundarySpec
    describe "expiry and other commands" interactionSpec
    describe "beyond the operation language" rawSpec

{- | The property: our implementation answers every sequence the way 'step' says.

__Both sides are ours.__ @sut@ is the real implementation; @expected@ is
'modelReplies', a pure fold over the
'Model' defined above -- not a reply from @redis-server@. Nothing in this suite
opens a socket; the only thing it borrows from 'Redis.Reference' is the
'Reply' type, so that all three suites compare the same kind of value.

That is the trade this suite makes. 'Redis.DifferentialSpec' gets its answers
from a live Redis, which cannot be wrong but cannot be asked about time. This
one gets its answers from a model, which can be wrong but can be asked
anything -- see the module header.
-}
matchesModel :: Property
matchesModel = forAllShrink genOps shrinkOps $ \ops -> ioProperty $ do
    sut <- runOps ops
    let expected = modelReplies ops
    pure $ counterexample (renderRun ops sut expected) (sut === expected)

{- | A run, one line per operation, so a counterexample can be read downward.

Zips three lists rather than using a record, because here they are produced by
two traversals and consumed immediately. 'Redis.Sut.Step' is the record version,
for the differential suites, where the triple is passed between functions and
misalignment would be a real hazard.
-}
renderRun :: [Op] -> [Reply] -> [Reply] -> String
renderRun ops sut expected = unlines (zipWith3 line ops sut expected)
  where
    line o a b =
        (if a == b then "  ok   " else "  DIFF ")
            <> show o
            <> "\n          sut   : "
            <> show a
            <> "\n          model : "
            <> show b

{- | The boundary, stated as three examples around one instant.

The property above reaches these, but only as a coincidence of the generator;
written out, they say what the boundary /is/ and will keep saying it if the
generator is ever retuned. The middle row is the whole point.
-}
boundarySpec :: Spec
boundarySpec = do
    it "keeps a key alive one millisecond before its expiry" $
        expectLast [Set "a" "v" (Just (Px 100)), Advance 99, Get "a"] (Returned "v")

    it "kills a key exactly at its expiry" $
        expectLast [Set "a" "v" (Just (Px 100)), Advance 100, Get "a"] Nil

    it "keeps a key dead after its expiry" $
        expectLast [Set "a" "v" (Just (Px 100)), Advance 500, Get "a"] Nil

    it "counts EX in seconds, not milliseconds" $
        expectLast [Set "a" "v" (Just (Ex 1)), Advance 500, Get "a"] (Returned "v")

    it "kills an EX key exactly one second in" $
        expectLast [Set "a" "v" (Just (Ex 1)), Advance 1000, Get "a"] Nil

    it "keeps an EX key alive one millisecond short of its second" $
        expectLast [Set "a" "v" (Just (Ex 1)), Advance 999, Get "a"] (Returned "v")

    it "reaches the same instant by accumulating smaller advances" $
        expectLast
            [Set "a" "v" (Just (Ex 1)), Advance 500, Advance 200, Advance 200, Advance 100, Get "a"]
            Nil

    it "does not expire a key set without a TTL" $
        expectLast [Set "a" "v" Nothing, Advance 100000, Get "a"] (Returned "v")

    it "clears an existing TTL on a plain SET" $
        expectLast [Set "a" "v" (Just (Px 100)), Set "a" "w" Nothing, Advance 500, Get "a"] (Returned "w")

    it "replaces an existing TTL rather than keeping the longer one" $
        expectLast [Set "a" "v" (Just (Px 500)), Set "a" "w" (Just (Px 100)), Advance 200, Get "a"] Nil

{- | How expiry interacts with the commands that are not @GET@.

These are the cases a model finds and a hand-written suite forgets, because they
need two features held in mind at once.

__A gap in the operation language, not in the suite.__ There is no way here to
give a /list/ a TTL, because the only command that sets one is @SET@ and @SET@
always stores a string. So 'step'\''s preservation of @diesAt@ when @RPUSH@
appends is currently unreachable. It is written as the correct semantics anyway,
and becomes reachable the day @EXPIRE@ exists.
-}
interactionSpec :: Spec
interactionSpec = do
    it "creates a list with no TTL when RPUSH finds no key" $
        expectLast [RPush "a" ["x"], Advance 100000, Get "a"] WrongType

    it "treats an expired string as absent for RPUSH" $
        expectLast [Set "a" "v" (Just (Px 100)), Advance 200, RPush "a" ["x"]] (Length 1)

    it "does not resurrect an expired key by appending to it" $
        expectLast
            [Set "a" "v" (Just (Px 100)), Advance 200, RPush "a" ["x"], Get "a"]
            WrongType

    it "keeps keys independent across expiry" $
        expectLast [Set "a" "v" (Just (Px 100)), Set "b" "w" Nothing, Advance 200, Get "b"] (Returned "w")

-- * Scenarios the operation language cannot express

{- | A raw frame, or a push of the logical clock.

'Op' is a deliberately small language -- one expiry option per @SET@, in one
unit -- because that is what keeps the model readable. Some rules live outside
it, and this is how they are reached: raw tokens, still on the logical clock, so
they stay deterministic.
-}
data Beat
    = Send Frame
    | Wait Millis
    deriving (Show)

-- | Replies to the frames in a scenario, in order. 'Wait's produce nothing.
beats :: [Beat] -> IO [Reply]
beats bs = do
    store <- newRedisStore
    go store epoch bs
  where
    go _ _ [] = pure []
    go store t (Wait ms : rest) = go store (addUTCTime (millis ms) t) rest
    go store t (Send f : rest) = do
        r <- sutReplyAt t store f
        (r :) <$> go store t rest

{- | Rules about repeated expiry options.

__Why these are not in the property.__ Redis accepts a repeated expiry and
validates only the last one, which @pSetOptions@ already implements. But the
rule is only /observable/ when two expiry options carry different valid values
-- and then both implementations answer @+OK@, so no reply distinguishes them.
Only the clock does.

That makes these rows the sole evidence for @last@ in @pSetOptions@. When tried
by hand on 2026-10-09, a mutation to @head@ passed every other test in this
project, including the whole conformance table, because the reply bytes are
identical either way.
-}
rawSpec :: Spec
rawSpec = do
    it "lets the last of two valid expiries win, when the last is the longer" $
        lastOf [Send ["SET", "a", "v", "EX", "1", "EX", "100"], Wait 2000, Send ["GET", "a"]]
            `shouldReply` Returned "v"

    it "lets the last of two valid expiries win, when the last is the shorter" $
        lastOf [Send ["SET", "a", "v", "EX", "100", "EX", "1"], Wait 2000, Send ["GET", "a"]]
            `shouldReply` Nil

    it "validates only the last expiry, so an earlier invalid one is ignored" $
        lastOf [Send ["SET", "a", "v", "EX", "-1", "EX", "1"], Wait 500, Send ["GET", "a"]]
            `shouldReply` Returned "v"

    -- Needs all three of: an invalid value, and two *different* valid ones
    -- after it. @pSetOptions@ reaches this through a separate branch from the
    -- all-valid case above, and only a row of this shape distinguishes `last`
    -- from `head` inside it. Confirmed against 8.10.1 by reading TTL back:
    -- `SET k v EX -1 EX 1 EX 100` leaves `TTL k` at 100.
    it "takes the last valid expiry even when an invalid one came first" $
        lastOf
            [ Send ["SET", "a", "v", "EX", "-1", "EX", "1", "EX", "100"]
            , Wait 2000
            , Send ["GET", "a"]
            ]
            `shouldReply` Returned "v"
  where
    lastOf = fmap last . beats
    shouldReply actual expected = actual >>= (`shouldBe` render expected)

{- | Assert the final reply of a run, against __both__ implementations.

Checking the model too is what stops these examples becoming decoration. The
property already compares model to implementation, so an example that only
checked one side would pass whenever they agreed — including when they agree on
something wrong. Stating the answer independently lets each row catch a wrong
model as well as wrong code.
-}
expectLast :: [Op] -> Answer -> Expectation
expectLast ops expected = do
    sut <- runOps ops
    last sut `shouldBe` render expected
    last (modelReplies ops) `shouldBe` render expected
