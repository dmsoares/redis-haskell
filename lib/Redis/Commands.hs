{-# LANGUAGE OverloadedStrings #-}

module Redis.Commands (module Types, module Deserialization, dispatch) where

import Redis.Commands.Types as Types
import Redis.Commands.Deserialization as Deserialization
import Redis.Table (RedisTable, runGet, runSet, SetOptions (..))
import Redis.RESP (Resp)
import qualified Redis.RESP as RESP
import Control.Applicative (asum)
import Data.Time (NominalDiffTime)

dispatch :: RedisTable -> Command -> IO Resp
dispatch _ (Echo msg) = pure $ RESP.bulkString msg
dispatch _ (Ping) = pure $ RESP.simpleString "PONG"
dispatch table cmd@(Set key value opts) = runSet table key value SetOptions{expiryTime = getExpiryTime opts}
dispatch table (Get key) = runGet table key

getExpiryTime :: [SetOption] -> Maybe NominalDiffTime
getExpiryTime opts = msToDiff <$> (asum $ fmap f opts)
    where
        f (SetOptionEX s) = Just (s * 1000)
        f (SetOptionPX ms) = Just ms

msToDiff :: Integral a => a -> NominalDiffTime
msToDiff ms = fromIntegral ms / 1000
