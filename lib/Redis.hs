{-# LANGUAGE OverloadedStrings #-}

module Redis (RedisTable, newRedisTable, reply) where

import Redis.Data.Command (Command (..), fromResp)
import Redis.Data.Table (RedisTable)
import Redis.Table (newRedisTable)
import qualified Redis.Workflows.Echo as Echo
import qualified Redis.Workflows.Get as Get
import qualified Redis.Workflows.Ping as Ping
import qualified Redis.Workflows.Set as Set
import Resp (Resp (..), nullBulkString, toResp)

reply :: RedisTable -> Resp -> IO Resp
reply table query = dispatch query table

-- Dispatches to specific workflow
dispatch :: Resp -> RedisTable -> IO Resp
dispatch query table = case fromResp query of
    Nothing -> pure nullBulkString
    Just cmd -> case cmd of
        Ping -> pure . toResp $ Ping.run
        Echo payload -> pure . toResp $ Echo.run payload
        Set payload -> toResp <$> Set.run payload table
        Get payload -> toResp <$> Get.run payload table
