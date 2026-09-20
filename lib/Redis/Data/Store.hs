{-# LANGUAGE NamedFieldPuns #-}

module Redis.Data.Store where

import Data.ByteString (ByteString)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)

type Key = ByteString
type Value = ByteString

data RedisStore = RedisStore
    { redisSet :: Key -> Value -> SetOptions -> IO ()
    , redisGet :: Key -> IO (Maybe Value)
    }

data RedisRecord = RedisRecord
    { rValue :: Value
    , rInsertedAt :: UTCTime
    , rExpiryTime :: Maybe NominalDiffTime
    }
    deriving (Show)

data SetOptions = SetOptions
    { expiryTime :: Maybe NominalDiffTime
    }
    deriving (Show)

expiresAt :: RedisRecord -> Maybe UTCTime
expiresAt RedisRecord{rInsertedAt, rExpiryTime} = flip addUTCTime rInsertedAt <$> rExpiryTime

isLive :: UTCTime -> RedisRecord -> Bool
isLive now = maybe True (now <) . expiresAt

liveValue :: UTCTime -> RedisRecord -> Maybe Value
liveValue now rec
    | isLive now rec = Just $ rValue rec
    | otherwise = Nothing
