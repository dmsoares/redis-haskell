module Redis.Data.DataType where

import Data.ByteString (ByteString)

data RedisType
    = RedisStringType
    | RedisListType
    deriving (Show, Eq)

data RedisValue
    = RedisStringValue ByteString
    | RedisListValue [RedisValue]
    deriving (Show, Eq)
