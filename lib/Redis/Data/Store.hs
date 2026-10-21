{-# LANGUAGE RecordWildCards #-}

module Redis.Data.Store (RedisStore, Key, mkRedisStore, get, set, delete) where

import Data.ByteString (ByteString)
import Data.Time (UTCTime)
import Redis.Data.Record (RedisRecord, isLive)

type Key = ByteString

data RedisStore = RedisStore
    { redisSet :: Key -> RedisRecord -> IO ()
    , redisGet :: Key -> IO (Maybe RedisRecord)
    , redisDelete :: Key -> IO ()
    }

mkRedisStore ::
    (Key -> RedisRecord -> IO ()) ->
    (Key -> IO (Maybe RedisRecord)) ->
    (Key -> IO ()) ->
    RedisStore
mkRedisStore = RedisStore

set :: RedisStore -> Key -> RedisRecord -> IO ()
set RedisStore{..} = redisSet

get :: UTCTime -> RedisStore -> Key -> IO (Maybe RedisRecord)
get now RedisStore{..} key = do
    record <- redisGet key
    case isLive now <$> record of
        Just True -> pure record
        _ -> pure Nothing

delete :: RedisStore -> Key -> IO ()
delete RedisStore{..} key = redisDelete key
