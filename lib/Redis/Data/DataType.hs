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

toByteStrings :: RedisValue -> [ByteString]
toByteStrings (RedisStringValue bs) = [bs]
toByteStrings (RedisListValue bss) = concatMap toByteStrings bss
