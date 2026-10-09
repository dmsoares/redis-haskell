{-# LANGUAGE OverloadedStrings #-}

module Redis.DifferentialSpec where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import Data.Time (getCurrentTime)

import Test.Hspec (Spec, aroundAll, describe, it, pendingWith, runIO)
import Test.QuickCheck (Arbitrary (arbitrary), Gen, counterexample, forAll, ioProperty, listOf, oneof, (===))
import Test.QuickCheck.Gen (elements)
import Test.QuickCheck.Instances.ByteString ()

import Redis (newRedisStore, reply)
import Redis.Data.Command (
    Command (..),
    EchoPayload (..),
    GetPayload (..),
    RPushPayload (..),
    SetOption (SetOptionEX, SetOptionPX),
    SetPayload (..),
 )
import Redis.ModelServer (Reply (Reply), modelAvailable, runSequence, withModelServer)
import Resp.Data (Resp (Array, BulkString), ToResp (toResp))
import Resp.Serialization (toBytes)

newtype TestCmd = TestCmd Command
    deriving (Show)

spec :: Spec
spec = do
    available <- runIO modelAvailable
    if not available
        then
            describe "Differential" $
                it "is skipped" $
                    pendingWith "redis-server is not on PATH -- run inside `nix develop`"
        else
            -- aroundAll (not aroundAll_) so the handle reaches the property; the
            -- server is spawned once for the whole group rather than per case.
            aroundAll withModelServer $
                describe "Differential" $
                    -- `it`, not `prop`: Test.Hspec.QuickCheck.prop always returns
                    -- a plain Spec, because Testable would read the extra argument
                    -- as one to generate rather than as a resource to receive.
                    it "testing model testing" $ \ms ->
                        forAll (listOf genCmd) $ \cmds -> ioProperty $ do
                            theirs <- runSequence ms (tokensOf <$> cmds)
                            ours <- ourReplies cmds
                            pure $
                                counterexample
                                    (unlines (zipWith3 fmt cmds ours theirs))
                                    (theirs === ours)
  where
    fmt cmd o t =
        "  "
            <> show cmd
            <> "\n      ours  : "
            <> show o
            <> "\n      redis : "
            <> show t

{- | Wrapped in 'Reply' so both sides share one type. Comparing a @ByteString@
against a @Reply@ would mean unwrapping the model's side, and the point of the
sum type is that "no reply" cannot silently compare equal to reply bytes.
-}
ourReplies :: [TestCmd] -> IO [Reply]
ourReplies cmds = do
    redisStore <- newRedisStore
    traverse (getReply redisStore) cmds
  where
    getReply redisStore cmd = do
        now <- getCurrentTime
        Reply . toBytes <$> reply now redisStore (toResp cmd)

{- | The tokens a client would actually send.

Now the single source of truth for rendering: the model side takes these
directly, and 'toResp' is derived from them. Previously the token list lived
inside the 'ToResp' instance, so the two sides could in principle have drifted.
-}
tokensOf :: TestCmd -> [ByteString]
tokensOf (TestCmd cmd) = case cmd of
    Ping -> ["PING"]
    (Echo (EchoPayload msg)) -> ["ECHO", msg]
    (Set (SetPayload k v opts)) -> ["SET", k, v] ++ concatMap unpackSetOpt opts
    (Get (GetPayload k)) -> ["GET", k]
    (RPush (RPushPayload k vs)) -> ["RPUSH", k] ++ vs
  where
    unpackSetOpt (SetOptionEX n) = ["EX", C8.pack (show n)]
    unpackSetOpt (SetOptionPX n) = ["PX", C8.pack (show n)]

instance ToResp TestCmd where
    toResp = Array . fmap BulkString . tokensOf

genCmd :: Gen TestCmd
genCmd = oneof cmds
  where
    cmds =
        fmap TestCmd
            <$> [ pure $ Ping
                , Echo . EchoPayload <$> arbitrary
                , Set <$> (SetPayload <$> genKey <*> arbitrary <*> listOf genSetOption)
                , Get . GetPayload <$> genKey
                , RPush <$> (RPushPayload <$> genKey <*> listOf arbitrary)
                ]

genKey :: Gen ByteString
genKey = elements ["a", "b", "c"]

genSetOption :: Gen SetOption
genSetOption = oneof [SetOptionEX <$> arbitrary, SetOptionPX <$> arbitrary]
