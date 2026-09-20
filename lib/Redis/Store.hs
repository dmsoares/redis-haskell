{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Store where

import Redis.Data.Store (RedisStore (..))

import Control.Concurrent.STM (atomically)
import qualified StmContainers.Map as Map

newRedisStore :: IO RedisStore
newRedisStore = do
    store <- atomically Map.new

    let set = \key record -> atomically $ Map.insert record key store

    let get = \key -> atomically $ Map.lookup key store

    pure $ RedisStore set get
