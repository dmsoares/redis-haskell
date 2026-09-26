{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Store where

import Redis.Data.Store (RedisStore (..))

import Control.Concurrent.STM (atomically)
import qualified StmContainers.Map as StmMap

newRedisStore :: IO RedisStore
newRedisStore = do
    store <- atomically StmMap.new

    let set = \key record -> atomically $ StmMap.insert record key store

    let get = \key -> atomically $ StmMap.lookup key store

    pure $ RedisStore set get
