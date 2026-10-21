module Redis.Workflows.LPop.Data where

import Data.ByteString (ByteString)

import Resp.Data (Resp (Array, BulkString, NullArray, NullBulkString), ToResp (toResp))

newtype Key = Key ByteString
    deriving (Show)

newtype Count = Count Int
    deriving (Show)

data Input = Input {key :: Key, count :: Maybe Count}
    deriving (Show)

data Reply
    = NoValue
    | NoValues
    | Value ByteString
    | Values [ByteString]
    deriving (Show)

-- Serialization
instance ToResp Reply where
    toResp NoValue = NullBulkString
    toResp NoValues = NullArray
    toResp (Value v) = BulkString v
    toResp (Values vs) = Array $ BulkString <$> vs
