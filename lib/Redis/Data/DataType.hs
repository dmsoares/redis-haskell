module Redis.Data.DataType where

import Data.ByteString (ByteString)

data RedisDataType
    = RedisString ByteString
    | RedisList [RedisDataType]
    deriving (Show, Eq)
