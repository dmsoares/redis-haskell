{-# LANGUAGE NamedFieldPuns #-}

module Redis.Data.Record where

import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Redis.Data.DataType (RedisDataType)

data RedisRecord = RedisRecord
    { value :: RedisDataType
    , insertedAt :: UTCTime
    , expiryTime :: Maybe NominalDiffTime
    }
    deriving (Show)

expiresAt :: RedisRecord -> Maybe UTCTime
expiresAt RedisRecord{insertedAt, expiryTime} = flip addUTCTime insertedAt <$> expiryTime

isLive :: UTCTime -> RedisRecord -> Bool
isLive now = maybe True (now <) . expiresAt

liveValue :: UTCTime -> RedisRecord -> Maybe RedisDataType
liveValue now rec
    | isLive now rec = Just $ value rec
    | otherwise = Nothing
