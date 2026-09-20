module Redis.Workflows.Get.Data where

import Data.ByteString (ByteString)

import Resp (bulkString, nullBulkString)
import Resp.Data (ToResp (toResp))

newtype Key = Key ByteString
    deriving (Show)

data Input = Input {key :: Key}
    deriving (Show)

data Reply
    = Nil
    | Value ByteString
    deriving (Show)

data Error
    = DeadValue
    | WrongType String
    | NotFound

-- Serialization
instance ToResp Reply where
    toResp Nil = nullBulkString
    toResp (Value v) = bulkString v
