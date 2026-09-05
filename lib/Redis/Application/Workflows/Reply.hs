{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module Redis.Application.Workflows.Reply (run) where

import Redis.Domain.Command (Command (..), SetOption)
import qualified Redis.Domain.Command as Command
import Redis.Domain.Resp (Resp)
import Redis.Domain.Result (Result)
import qualified Redis.Domain.Result as Result
import Redis.Domain.Table (Key, RedisTable, SetOptions (..), Value)
import qualified Redis.Domain.Table as Table
import qualified Redis.Infrastructure.Serialization.Command as Command
import qualified Redis.Infrastructure.Serialization.Resp as Resp
import Redis.Infrastructure.Serialization.Result ()
import qualified Redis.Infrastructure.Serialization.Result as Result
import qualified Redis.Infrastructure.Table as Table

import Control.Monad (MonadPlus (mzero), (>=>))
import Control.Monad.Reader (MonadIO (liftIO))
import Control.Monad.Trans.Maybe (MaybeT)
import Data.ByteString (ByteString)

run :: RedisTable -> Resp -> App ByteString
run table = resp2cmd >=> dispatchCmd table >=> result2resp >=> serialize

type App a = MaybeT IO a

resp2cmd :: Resp -> App Command
resp2cmd = maybe mzero pure . Command.fromResp

dispatchCmd :: RedisTable -> Command -> App Result
dispatchCmd table = liftIO . dispatch table
  where
    dispatch :: RedisTable -> Command -> IO Result.Result
    dispatch _ (Echo msg) = pure $ Result.Echo msg
    dispatch _ (Ping) = pure $ Result.Pong
    dispatch table (Set key value opts) = handleSet table key value opts
    dispatch table (Get key) = handleGet table key

    handleSet :: RedisTable -> Key -> Value -> [SetOption] -> IO Result.Result
    handleSet table key value opts = do
        result <- Table.runSet table key value SetOptions{expiryTime = Command.getExpiryTime opts}
        pure $ case result of
            Table.SetOK -> Result.SetOK

    handleGet :: RedisTable -> Key -> IO Result.Result
    handleGet table key = do
        result <- Table.runGet table key
        pure $ case result of
            Table.GetNull -> Result.GetNull
            Table.GetValue v -> Result.GetValue v

result2resp :: Result -> App Resp
result2resp = pure . Result.toResp

serialize :: Resp -> App ByteString
serialize = pure . Resp.toBytes
