{-# LANGUAGE NamedFieldPuns #-}

module Redis.Data.Record where

import Data.ByteString (ByteString)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)

data RedisRecord = RedisRecord
    { value :: ByteString
    , insertedAt :: UTCTime
    , expiryTime :: Maybe NominalDiffTime
    }
    deriving (Show)

expiresAt :: RedisRecord -> Maybe UTCTime
expiresAt RedisRecord{insertedAt, expiryTime} = flip addUTCTime insertedAt <$> expiryTime

isLive :: UTCTime -> RedisRecord -> Bool
isLive now = maybe True (now <) . expiresAt

liveValue :: UTCTime -> RedisRecord -> Maybe ByteString
liveValue now rec
    | isLive now rec = Just $ value rec
    | otherwise = Nothing
