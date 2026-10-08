{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module Redis.DifferentialSpec where

import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import Data.Time (getCurrentTime)
import Network.Simple.TCP (Socket)
import qualified Network.Simple.TCP as TCP

import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (prop)
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
import Resp.Data (Resp (Array, BulkString), ToResp (toResp))
import Resp.Serialization (toBytes)

newtype TestCmd = TestCmd Command
    deriving (Show)

port :: Int
port = 16379

spec :: Spec
spec = do
    describe "Differential" $
        prop "testing model testing" $
            forAll (listOf genCmd) $ \cmds -> ioProperty $ do
                theirs <- liftIO $ theirReplies cmds
                ours <- ourReplies cmds
                pure $
                    counterexample
                        (unlines (zipWith3 fmt cmds ours theirs))
                        (theirs === ours)
  where
    fmt ts o t =
        "  "
            <> show ts
            <> "\n      ours  : "
            <> show o
            <> "\n      redis : "
            <> show t

ourReplies :: [TestCmd] -> IO [ByteString]
ourReplies cmds = do
    now <- getCurrentTime
    redisStore <- newRedisStore
    traverse (getReply now redisStore) cmds
  where
    getReply now redisStore cmd = toBytes <$> reply now redisStore (toResp cmd)

theirReplies :: [TestCmd] -> IO [ByteString]
theirReplies cmds = callRedis port $ \sock -> do
    -- start by flushing all keys from the model DB
    _ <- talk sock "FLUSHALL\r\n"

    let serializedCmds = toBytes . toResp <$> cmds
    mBytes <- traverse (talk sock) serializedCmds
    pure $ maybe [] id $ traverse id mBytes
  where
    talk sock bytes = TCP.send sock bytes >> TCP.recv sock 4096

callRedis :: Int -> (Socket -> IO a) -> IO a
callRedis port cont = TCP.connect "127.0.0.1" (show port) $
    \(socket, _) -> cont socket

instance ToResp TestCmd where
    toResp (TestCmd cmd) = case cmd of
        Ping -> toCmdShape ["PING"]
        (Echo (EchoPayload msg)) -> toCmdShape ["ECHO", msg]
        (Set (SetPayload k v opts)) -> toCmdShape $ ["SET", k, v] ++ unpackSetOpts opts
        (Get (GetPayload k)) -> toCmdShape ["GET", k]
        (RPush (RPushPayload k vs)) -> toCmdShape $ ["RPUSH", k] ++ vs
      where
        toCmdShape bs = Array $ fmap BulkString bs
        unpackSetOpts = concatMap unpackSetOpt
        unpackSetOpt (SetOptionEX n) = ["EX", C8.pack (show n)]
        unpackSetOpt (SetOptionPX n) = ["PX", C8.pack (show n)]

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
