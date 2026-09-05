{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Infrastructure.Table where

import Redis.Domain.Table

import qualified Control.Concurrent.MVar as MVar
import qualified Data.Map as Map
import Data.Time (addUTCTime, getCurrentTime)
import Prelude hiding (exp)

newRedisTable :: IO RedisTable
newRedisTable = do
    var <- MVar.newMVar Map.empty
    let set = \key value opts -> do
            now <- getCurrentTime
            let record = RedisRecord{rValue = value, rInsertedAt = now, rExpiryTime = (expiryTime opts)}
            MVar.modifyMVar_ var $ pure . Map.insert key record
        get = \key -> do
            table <- MVar.readMVar var
            now <- getCurrentTime
            pure $
                Map.lookup key table
                    >>= \RedisRecord{rValue, rInsertedAt, rExpiryTime} ->
                        case rExpiryTime of
                            Nothing -> Just rValue
                            Just exp -> if addUTCTime exp rInsertedAt > now then Just rValue else Nothing
    pure $ RedisTable set get

runSet :: RedisTable -> Key -> Value -> SetOptions -> IO SetResult
runSet RedisTable{redisSet} key value opts = do
    redisSet key value opts
    pure $ SetOK

runGet :: RedisTable -> Key -> IO GetResult
runGet RedisTable{redisGet} key = do
    mValue <- redisGet key
    pure $ maybe GetNull GetValue mValue
