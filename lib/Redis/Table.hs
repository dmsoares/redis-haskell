{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Table where

import Redis.Data.Table

import Control.Concurrent.STM (atomically)
import Data.Time (getCurrentTime)
import qualified StmContainers.Map as Map
import Prelude hiding (exp)

newRedisTable :: IO RedisTable
newRedisTable = do
    table <- atomically Map.new

    let set = \key value opts -> do
            now <- getCurrentTime
            let record = RedisRecord{rValue = value, rInsertedAt = now, rExpiryTime = (expiryTime opts)}
            atomically $ Map.insert record key table

    let get = \key -> do
            now <- getCurrentTime
            mValue <- atomically $ Map.lookup key table
            pure $ case mValue of
                Nothing -> Nothing
                Just record -> liveValue now record

    pure $ RedisTable set get
