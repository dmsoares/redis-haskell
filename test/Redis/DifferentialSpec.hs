{-# LANGUAGE OverloadedStrings #-}

{- | Suite 2 of three — the differential explorer.

* __Rung 3__ (model, or lockstep), where the model is __the real @redis-server@__
* __Question__ — where do we differ from Redis without knowing it?
* __Oracle__ — a live Redis: nothing to maintain, and it cannot be wrong
  about Redis
* __Contract__ — no /new/ divergence class. Red means Redis does something
  we had not recorded.
* __Industry pattern__ — differential testing (also called back-to-back testing)

The ladder of specs these rungs refer to:

> architecture/research/spec-driven-development.md   section 1

Rung 3 comes in two flavours and this project has both. Here the model is a
reference implementation we did not write; in 'Redis.ModelSpec' it is a model we
did. The trade is set out there.

__The contract is not "we agree with Redis".__ We do not, and a partial
implementation never will. Asserting agreement would leave the suite red forever
and tell us nothing new each time.

__Triage, do not predict.__ 'triage' runs /after/ a disagreement is observed, so
it only ever has to name what is already in hand. A predicate asking "will this
frame disagree?" would instead need a model of Redis's error precedence — the one
thing we lack, and the reason this suite exists. @SET k v EX 6 PX -5 KEEPTTL@
shows the difficulty: it carries three violations, and both sides stop at the
syntax error, so it agrees despite looking like a certain divergence.

__The oracle needs its own spec.__ 'triage' is real code and can be silently
wrong: one that returned a known class for everything would keep this suite
green forever. So it has its own table of exact-byte examples, including rows
that must come back 'Untriaged'. Worth noting as a pattern the ladder itself
does not mention — __at rung 3 the oracle is complex enough to need a rung-0
spec of its own.__

__One-directional on purpose.__ We check that what we found is in 'baseline',
never that all of 'baseline' is still found. The latter is flaky — a class may
not be reached in a few hundred runs — and it would confuse "fixed" with "not
reached". Fixes are recorded in 'Redis.ConformanceSpec' instead.

__What it cannot do.__ Move Redis's clock. So expiry is out of reach here and
belongs to 'Redis.ModelSpec'. The reasoning is recorded in:

> architecture/testing-plan.md   "wall-clock TTLs are not differentially testable"
-}
module Redis.DifferentialSpec (spec) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import Data.List (nub)

import Test.Hspec (Spec, SpecWith, aroundAll, describe, it, pendingWith, runIO, shouldBe)
import Test.QuickCheck (Property, counterexample, forAllShrink, ioProperty, property)

import Redis.FrameGen (genRun, shrinkRun)
import Redis.Reference (Reference, Reply (..), referenceAvailable, withReference)
import Redis.Sut (Step (..), diverged, renderRun, renderStep, runBoth)

{- | A disagreement we have seen, understood, and chosen not to fix yet.

One constructor per __root cause__, not per input. @PING hello@ and @PING a b@
disagree in different ways — one echoes, the other is a wrong-arity error — but
both are the single fact that @pPing = pure Ping@ never looks at its arguments,
so both are 'PingIgnoresArguments'. Splitting them would make the baseline grow
with inputs instead of with understanding.
-}
data Divergence
    = -- | @pPing@ ignores its arguments entirely. known-gaps #11.
      PingIgnoresArguments
    | -- | Redis appends @, with args beginning with: 'a' 'b' @; we stop at the name.
      UnknownCommandOmitsArguments
    | -- | @readInt@ rejected the expiry token outright, so @pInt@ raised
      -- 'NotAnInteger' -- and @many@ and @\<|\>@ then __discarded__ it, leaving the
      -- generic @syntax error@ from the failed alternative. Redis says
      -- @value is not an integer or out of range@. known-gaps #8.
      --
      -- Reached by @EX abc@, @EX +1@, @EX \" 1\"@ and by any value that
      -- overflows @Int@, which @readInt@ reports as failure.
      NonIntegerExpiryIsSyntaxError
    | -- | @readInt@ /accepted/ the expiry token, but Redis would not have.
      --
      -- Two mechanisms, one fix, so one class. @readInt@ stops at the first
      -- non-digit and @pInt@ drops the remainder, so @EX \"1 \"@ and @EX 1.5@
      -- become @EX 1@ and answer @+OK@, while @EX 0x10@ becomes @EX 0@ and
      -- answers @invalid expire time@. Separately, Redis's integer grammar is
      -- stricter than @readInt@'s even on a fully-consumed token: it rejects
      -- @-0@ and leading zeros, which @readInt@ happily accepts.
      --
      -- Both are "our expiry integer grammar is looser than Redis's", and both
      -- disappear together the moment @pInt@ demands the whole token and
      -- matches Redis's own @string2ll@ rules.
      ExpiryIntegerGrammarTooLoose
    | -- | We report a __value__ error on a frame Redis rejects on __grammar__.
      --
      -- Measured on 8.10.1, and order-independent: Redis parses the whole
      -- option list for grammatical validity first and only then validates the
      -- values it collected, so a syntax problem anywhere in the list wins.
      --
      -- > SET k v PX 0              -> invalid expire time
      -- > SET k v KEEPTTLX          -> syntax error
      -- > SET k v PX 0 KEEPTTLX     -> syntax error
      -- > SET k v KEEPTTLX PX 0     -> syntax error
      --
      -- @pSetOptions@ instead validates /during/ the scan: @many@ stops at the
      -- unrecognised token, the collected expiry is checked immediately, and
      -- the error escapes before @eof@ ever gets to object to the leftover. So
      -- the fix is to defer value validation until the token list is fully
      -- consumed -- a change in /where/ the check happens, not in the check.
      ValueErrorPreemptsSyntaxError
    | -- | Redis consumes an option's value __positionally__ and validates only
      -- the expiry that survives; we treat an unparseable value as "that was
      -- not an option after all" and backtrack out of it.
      --
      -- Measured on 8.10.1, and the table is the whole rule:
      --
      -- > SET a v PX PX            -> not an integer   value is the token "PX"
      -- > SET a v PX PX PX 41605   -> OK               2nd PX wins; only 41605 checked
      -- > SET a v EX EX 5          -> syntax error     EX ate "EX"; "5" now unknown
      -- > SET a v PX 1000 PX       -> syntax error     trailing PX has no value
      --
      -- Redis's option loop advances two tokens per expiry option and never
      -- looks at the value until the loop ends, so "last expiry wins and only
      -- it is validated" -- the rule @pSetOptions@ already implements for
      -- @EX -1 EX 6@ -- holds even when the value looks like an option name.
      --
      -- @pSetOptions@ cannot reach that: @pInt@ fails inside @choice@, so
      -- @many@ backtracks as though no option were present and @eof@ then
      -- rejects the leftovers. Fixing it means committing to an option once its
      -- /name/ matches, which is a different parser shape, not a different check.
      ExpiryOptionValueIsPositional
    | -- | Never in 'baseline', so reaching it fails the suite. This is the
      -- constructor that makes the contract bite.
      Untriaged
    deriving (Eq, Show)

{- | The divergences on record. Measured against redis 8.10.1 on 2026-10-09.

Shrinking this list is the project's conformance work. Adding to it is a
deliberate act: it says "understood, deferred", and it should be accompanied by
an entry in @architecture/known-gaps.md@ carrying the reasoning.
-}
baseline :: [Divergence]
baseline =
    [ PingIgnoresArguments
    , UnknownCommandOmitsArguments
    , NonIntegerExpiryIsSyntaxError
    , ExpiryIntegerGrammarTooLoose
    , ValueErrorPreemptsSyntaxError
    , ExpiryOptionValueIsPositional
    ]

{- | Name an already-observed disagreement.

Only ever called on a step where @stepSut /= stepReference@, so there is no
judgement about /whether/ something diverged — only about what to call it. The
guards read the observed replies rather than re-deriving them from the frame,
with one exception: 'PingIgnoresArguments' keys off the frame's head, because
"we replied @+PONG@ to a frame that was not a bare @PING@" is the cause, and the
two shapes Redis answers with are both consequences.
-}
triage :: Step -> Divergence
triage (Step f sut reference)
    | isPing f, length f > 1 = PingIgnoresArguments
    | referenceSide == Just notAnInteger = integerGrammar
    | sutSide == Just invalidExpireTime, referenceSide == Just syntaxError =
        ValueErrorPreemptsSyntaxError
    -- Needs the frame, not only the replies: "we said syntax error, Redis said
    -- OK" is also exactly what @SET k v NX@ looks like, and an option we have
    -- not implemented is out of scope rather than a defect. The expiry-name
    -- test separates them, and it is a statement about the frame we sent rather
    -- than a prediction about the reply.
    | sutSide == Just syntaxError, reference == okReply, any isExpiryName f =
        ExpiryOptionValueIsPositional
    | Just o <- sutSide, Just t <- referenceSide, unknownCommand o, unknownCommand t =
        UnknownCommandOmitsArguments
    | otherwise = Untriaged
  where
    sutSide = errorText sut
    referenceSide = errorText reference

    -- Redis rejected an integer we were asked to read. Which of our two defects
    -- produced the disagreement is visible in what *we* said about it.
    --
    -- The @Nothing@ case is a success on our side -- @+OK@ -- which is the
    -- loosest failure of the three and the reason this class exists at all.
    -- Safe to read as an expiry problem because an expiry is the only place
    -- this generator puts an integer; 'Redis.FrameGen' is where that stays true.
    integerGrammar
        | sutSide == Just syntaxError = NonIntegerExpiryIsSyntaxError
        | sutSide == Just invalidExpireTime = ExpiryIntegerGrammarTooLoose
        | sutSide == Nothing = ExpiryIntegerGrammarTooLoose
        | otherwise = Untriaged

    isPing (name : _) = lower name == "ping"
    isPing [] = False

    isExpiryName t = lower t `elem` ["ex", "px"]
    okReply = Reply "+OK\r\n"

    unknownCommand = C8.isPrefixOf "ERR unknown command"
    syntaxError = "ERR syntax error"
    notAnInteger = "ERR value is not an integer or out of range"
    invalidExpireTime = "ERR invalid expire time in \'set\' command"

{- | The message of a simple error reply, or 'Nothing' for anything else.

Deliberately a five-line matcher rather than a call to @Resp.fromBytes@: an
oracle that interprets replies with the parser under test can be misled by a bug
in it, which is the same reason 'Redis.Reference' frames replies itself.
-}
errorText :: Reply -> Maybe ByteString
errorText (Reply bytes) = case C8.uncons bytes of
    Just ('-', rest) -> Just (fst (C8.breakSubstring "\r\n" rest))
    _ -> Nothing
errorText NoReply = Nothing
errorText Closed = Nothing

lower :: ByteString -> ByteString
lower = C8.map toLowerAscii
  where
    toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

spec :: Spec
spec = do
    describe "Differential.triage" triageSpec

    available <- runIO referenceAvailable
    if not available
        then
            describe "Differential" $
                it "is skipped" $
                    pendingWith "redis-server is not on PATH -- run inside `nix develop`"
        else
            -- aroundAll (not aroundAll_) so the handle reaches the property; the
            -- server is spawned once for the whole group rather than per case.
            aroundAll withReference $
                describe "Differential" explorerSpec

explorerSpec :: SpecWith Reference
explorerSpec =
    -- `it`, not `prop`: Test.Hspec.QuickCheck.prop always returns a plain Spec,
    -- because Testable would read the extra argument as one to generate rather
    -- than as a resource to receive.
    it "finds no divergence outside the recorded baseline" noNewDivergence

{- | The property: __the first__ divergence in a run is one we have on record.

The first, and not every one, because the two implementations share a state and
a divergence splits it. Once Redis has refused a @SET@ that we accepted, its
store and ours hold different things, and every later step is comparing two
different worlds — a disagreement there is evidence about the earlier step, not
about the command that reported it.

A cascade looks like this:

> SET c 0 PX "1 "   sut: +OK          reference: ERR value is not an integer
> RPUSH c xyz       sut: WRONGTYPE    reference: :1

The second line reads like an @RPUSH@ defect. It is a consequence of the first:
the SUT created a key the reference never created, with a 1 ms TTL, and then
pushed onto its expired remains. Triaging that step would mean naming the
shadows of divergences already on record.

So the run is cut at the first disagreement. If that one is in 'baseline', the
rest of the run carries no information and is discarded.
-}
noNewDivergence :: Reference -> Property
noNewDivergence ref = forAllShrink genRun shrinkRun $ \run -> ioProperty $ do
    steps <- runBoth ref run
    pure (verdict steps)
  where
    verdict steps = case break diverged steps of
        -- Agreed all the way through.
        (_, []) -> property True
        (agreed, s : _)
            | explained s -> property True
            | otherwise -> counterexample (report s (agreed <> [s])) (property False)

    explained = (`elem` baseline) . triage

    report s upToHere =
        unlines
            [ "unexplained divergence, triaged as " <> show (triage s) <> ":"
            , renderStep s
            , "reached by:"
            , renderRun upToHere
            ]

{- | The classifier's own conformance table.

Needed because the explorer can only ever report "no new class", which a
classifier that returned a baseline entry for /everything/ would also report.
That is the vacuity trap: a green suite proving nothing. These rows are exact
bytes captured from redis 8.10.1 and from our own implementation, so they pin
each branch, and the last two pin the 'Untriaged' fall-through — without
them, a classifier with a catch-all of 'PingIgnoresArguments' would pass.
-}
triageSpec :: Spec
triageSpec = do
    it "names a PING that ignored its message" $
        triage (step ["PING", "hello"] "+PONG\r\n" "$5\r\nhello\r\n")
            `shouldBe` PingIgnoresArguments

    it "names a PING that ignored a bad argument count" $
        triage (step ["PING", "a", "b"] "+PONG\r\n" wrongArgsPing)
            `shouldBe` PingIgnoresArguments

    it "names an unknown command missing its argument list" $
        triage (step ["BOGUS", "a", "b"] unknownBogus unknownBogusWithArgs)
            `shouldBe` UnknownCommandOmitsArguments

    it "names a non-integer expiry mislabelled as a syntax error" $
        triage (step ["SET", "k", "v", "EX", "abc"] syntaxErr notAnIntegerErr)
            `shouldBe` NonIntegerExpiryIsSyntaxError

    it "names an overflowing expiry as the same root cause" $
        triage (step ["SET", "k", "v", "EX", "99999999999999999999"] syntaxErr notAnIntegerErr)
            `shouldBe` NonIntegerExpiryIsSyntaxError

    it "names a trailing-space expiry that we accepted as 1" $
        triage (step ["SET", "k", "v", "EX", "1 "] "+OK\r\n" notAnIntegerErr)
            `shouldBe` ExpiryIntegerGrammarTooLoose

    it "names a hex-looking expiry that we truncated to 0" $
        triage (step ["SET", "k", "v", "EX", "0x10"] invalidExpiryErr notAnIntegerErr)
            `shouldBe` ExpiryIntegerGrammarTooLoose

    it "names negative zero, which readInt accepts and Redis does not" $
        triage (step ["SET", "k", "v", "EX", "-0"] invalidExpiryErr notAnIntegerErr)
            `shouldBe` ExpiryIntegerGrammarTooLoose

    it "names a value error raised ahead of a grammar error" $
        triage (step ["SET", "k", "v", "PX", "0", "WOBBLE"] invalidExpiryErr syntaxErr)
            `shouldBe` ValueErrorPreemptsSyntaxError

    it "names it in the other token order too" $
        triage (step ["SET", "k", "v", "WOBBLE", "PX", "0"] invalidExpiryErr syntaxErr)
            `shouldBe` ValueErrorPreemptsSyntaxError

    it "names an expiry value swallowed by a repeated option name" $
        triage (step ["SET", "a", "v", "PX", "PX", "PX", "41605"] syntaxErr "+OK\r\n")
            `shouldBe` ExpiryOptionValueIsPositional

    it "refuses to name a non-integer disagreement it has no story for" $
        -- Redis rejected an integer, but our reply is neither of the two errors
        -- the known mechanisms produce. The fall-through has to stay
        -- 'Untriaged', or every future integer-shaped surprise would be
        -- silently filed under a defect we have already understood.
        triage (step ["SET", "k", "v", "EX", "9"] wrongTypeErr notAnIntegerErr)
            `shouldBe` Untriaged

    it "refuses to name a SET option we have not implemented" $
        triage (step ["SET", "k", "v", "NX"] syntaxErr "+OK\r\n")
            `shouldBe` Untriaged

    it "refuses to name a command we have not implemented" $
        triage (step ["DEL", "k"] "-ERR unknown command 'DEL'\r\n" ":0\r\n")
            `shouldBe` Untriaged

    it "refuses to name a disagreement over stored values" $
        triage (step ["GET", "a"] "$1\r\nv\r\n" "$-1\r\n")
            `shouldBe` Untriaged

    it "lists every baseline entry exactly once" $
        nub baseline `shouldBe` baseline

    it "never records Untriaged as explained" $
        (Untriaged `elem` baseline) `shouldBe` False
  where
    -- Rows are written as raw reply bytes, which is how they were captured.
    step f o t = Step f (Reply o) (Reply t)
    wrongArgsPing = "-ERR wrong number of arguments for 'ping' command\r\n"
    unknownBogus = "-ERR unknown command 'BOGUS'\r\n"
    unknownBogusWithArgs = "-ERR unknown command 'BOGUS', with args beginning with: 'a' 'b' \r\n"
    syntaxErr = "-ERR syntax error\r\n"
    notAnIntegerErr = "-ERR value is not an integer or out of range\r\n"
    invalidExpiryErr = "-ERR invalid expire time in 'set' command\r\n"
    wrongTypeErr = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
