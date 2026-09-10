{-# LANGUAGE OverloadedStrings #-}

module Redis (RedisTable, newRedisTable, reply) where

import Redis.Domain.Table (RedisTable)
import Redis.Infrastructure.Table (newRedisTable)

import Resp (Resp)

import qualified Redis.Infrastructure.Dispatcher as Dispatcher

reply :: RedisTable -> Resp -> IO Resp
reply table query = Dispatcher.dispatch query table
