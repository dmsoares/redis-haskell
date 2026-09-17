module Redis.Workflows.Get.Data where

import Data.ByteString (ByteString)

import Resp (bulkString, nullBulkString)
import Resp.Data (ToResp (toResp))

newtype Key = Key ByteString
    deriving (Show)

data Input = Input {key :: Key}
    deriving (Show)

data Reply
    = Null
    | Value ByteString
    deriving (Show)

-- Serialization
instance ToResp Reply where
    toResp Null = nullBulkString
    toResp (Value v) = bulkString v
