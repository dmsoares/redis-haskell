{-# LANGUAGE OverloadedStrings #-}

module Redis (RedisTable, newRedisTable, reply) where

import Redis.Domain.Table (RedisTable)
import Redis.Infrastructure.Table (newRedisTable)
import qualified Redis.Workflows.Echo as Echo
import qualified Redis.Workflows.Get as Get
import qualified Redis.Workflows.Ping as Ping
import qualified Redis.Workflows.Set as Set
import Resp (Resp (..), nullBulkString)

reply :: RedisTable -> Resp -> IO Resp
reply table query = dispatch query table

-- Dispatches to specific workflow
dispatch :: Resp -> RedisTable -> IO Resp
dispatch query table = case query of
    (Array _ (BulkString _ "PING" : _)) -> pure $ Ping.run query
    (Array _ (BulkString _ "ECHO" : _)) -> pure $ Echo.run query
    (Array _ (BulkString _ "SET" : _)) -> Set.run query table
    (Array _ (BulkString _ "GET" : _)) -> Get.run query table
    _ -> pure $ nullBulkString
