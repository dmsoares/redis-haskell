{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Infrastructure.Table where

import Redis.Domain.Table

import Control.Concurrent.STM (atomically)
import Data.Time (addUTCTime, getCurrentTime)
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
                Just RedisRecord{rValue, rInsertedAt, rExpiryTime} ->
                    case rExpiryTime of
                        Nothing -> Just rValue
                        Just exp -> if addUTCTime exp rInsertedAt > now then Just rValue else Nothing

    pure $ RedisTable set get

runSet :: RedisTable -> Key -> Value -> SetOptions -> IO SetResult
runSet RedisTable{redisSet} key value opts = do
    _ <- redisSet key value opts
    pure $ SetOK

runGet :: RedisTable -> Key -> IO GetResult
runGet RedisTable{redisGet} key = do
    mValue <- redisGet key
    pure $ maybe GetNull GetValue mValue
