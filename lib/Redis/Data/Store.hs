{-# LANGUAGE NamedFieldPuns #-}

module Redis.Data.Store where

import Data.ByteString (ByteString)
import Redis.Data.Record (RedisRecord)

type Key = ByteString

data RedisStore = RedisStore
    { redisSet :: Key -> RedisRecord -> IO ()
    , redisGet :: Key -> IO (Maybe RedisRecord)
    }
