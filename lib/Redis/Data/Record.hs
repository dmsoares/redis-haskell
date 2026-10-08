{-# LANGUAGE NamedFieldPuns #-}

module Redis.Data.Record (RedisRecord (..), mkExpiryTime, expiresAt, isLive, liveValue) where

import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Redis.Data.DataType (RedisType, RedisValue)

data RedisRecord = RedisRecord
    { value :: RedisValue
    , typeTag :: RedisType
    , insertedAt :: UTCTime
    , expiryTime :: Maybe ExpiryTime
    }
    deriving (Show)

newtype ExpiryTime = ExpiryTime NominalDiffTime
    deriving (Show)

mkExpiryTime :: NominalDiffTime -> Maybe ExpiryTime
mkExpiryTime time = if time > 0 then Just (ExpiryTime time) else Nothing

expiresAt :: RedisRecord -> Maybe UTCTime
expiresAt RedisRecord{insertedAt, expiryTime} = do
    ExpiryTime time <- expiryTime
    pure $ addUTCTime time insertedAt

isLive :: UTCTime -> RedisRecord -> Bool
isLive now = maybe True (now <) . expiresAt

liveValue :: UTCTime -> RedisRecord -> Maybe RedisValue
liveValue now rec
    | isLive now rec = Just $ value rec
    | otherwise = Nothing
