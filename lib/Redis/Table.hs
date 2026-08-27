{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Table where

import Redis.RESP (Resp)
import qualified Redis.RESP as RESP

import Data.ByteString (ByteString)
import Data.Time (UTCTime, getCurrentTime, diffUTCTime, secondsToDiffTime, addUTCTime, secondsToNominalDiffTime, NominalDiffTime)
import Control.Concurrent (MVar)
import qualified Control.Concurrent.MVar as MVar
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Applicative (asum)

type Key = ByteString
type Value = ByteString
type ExpiryTime = NominalDiffTime
type Milliseconds = Int

data RedisTable = RedisTable {
    redisSet :: Key -> Value -> SetOptions -> IO (),
    redisGet :: Key -> IO (Maybe Value)
}

data RedisRecord = RedisRecord {
    rValue :: Value,
    rInsertedAt :: UTCTime,
    rExpiryTime :: Maybe ExpiryTime
}
    deriving Show

data SetOptions = SetOptions {
   expiryTime :: Maybe ExpiryTime
}
    deriving Show

newRedisTable :: IO RedisTable
newRedisTable = do
    var <- MVar.newMVar Map.empty
    let set = \key value opts -> do
            now <- getCurrentTime
            let record = RedisRecord{rValue = value, rInsertedAt = now, rExpiryTime = (expiryTime opts)}
            putStrLn $ "record: " <> show record
            MVar.modifyMVar_ var $ pure . Map.insert key record
        get = \key -> do
            table <- MVar.readMVar var
            now <- getCurrentTime
            pure $ Map.lookup key table >>=
                \RedisRecord{rValue, rInsertedAt, rExpiryTime} ->
                    case rExpiryTime of
                        Nothing -> Nothing
                        Just exp -> if addUTCTime exp rInsertedAt > now then Just rValue else Nothing
    pure $ RedisTable set get

runSet :: RedisTable -> Key -> Value -> SetOptions -> IO Resp
runSet RedisTable{redisSet} key value opts = do
    redisSet key value opts
    pure $ RESP.simpleString "OK"

runGet :: RedisTable -> Key -> IO Resp
runGet RedisTable{redisGet} key = do
    mValue <- redisGet key
    pure $ maybe RESP.nullBulkString RESP.bulkString mValue
