{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Store where

import Redis.Data.Store

import Control.Concurrent.STM (atomically)
import Data.Time (getCurrentTime)
import qualified StmContainers.Map as Map
import Prelude hiding (exp)

newRedisStore :: IO RedisStore
newRedisStore = do
    store <- atomically Map.new

    let set = \key value opts -> do
            now <- getCurrentTime
            let record = RedisRecord{rValue = value, rInsertedAt = now, rExpiryTime = (expiryTime opts)}
            atomically $ Map.insert record key store

    let get = \key -> do
            now <- getCurrentTime
            mValue <- atomically $ Map.lookup key store
            pure $ case mValue of
                Nothing -> Nothing
                Just record -> liveValue now record

    pure $ RedisStore set get
