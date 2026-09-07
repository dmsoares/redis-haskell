{-# LANGUAGE OverloadedStrings #-}

module Redis (RedisTable, newRedisTable, reply) where

import qualified Redis.Application.Workflows.Reply as Reply
import Redis.Domain.Table (RedisTable)
import Redis.Infrastructure.Table (newRedisTable)

import Resp (Resp)

import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Data.ByteString (ByteString)

reply :: RedisTable -> Resp -> IO (Maybe ByteString)
reply table query = runMaybeT $ Reply.run table query
