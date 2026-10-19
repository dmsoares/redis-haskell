module Redis.Workflows.LLen.Data where

import Data.ByteString (ByteString)

import Resp.Data (Resp (RedisInteger), ToResp (toResp))

newtype Key = Key ByteString
    deriving (Show)

data Input = Input {key :: Key}
    deriving (Show)

newtype Reply = Length Int
    deriving (Show)

-- Serialization
instance ToResp Reply where
    toResp (Length n) = RedisInteger n
