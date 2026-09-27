module Redis.Workflows.RPush.Data where

import Data.ByteString (ByteString)
import Resp.Data (Resp (RedisInteger), ToResp (toResp))

newtype Key = Key ByteString
    deriving (Show)
newtype Value = Value ByteString
    deriving (Show)

data Input = Input
    { key :: Key
    , value :: Value
    }
    deriving (Show)

newtype Reply = OK Int
    deriving (Show)

instance ToResp Reply where
    toResp (OK n) = RedisInteger n
