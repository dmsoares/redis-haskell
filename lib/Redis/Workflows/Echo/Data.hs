module Redis.Workflows.Echo.Data where

import Data.ByteString (ByteString)
import Resp (bulkString)
import Resp.Data (ToResp (..))

newtype Message = Message ByteString
    deriving (Show)

data Input = Input {message :: Message}
    deriving (Show)

newtype Reply = Reply ByteString
    deriving (Show)

instance ToResp Reply where
    toResp (Reply msg) = bulkString msg
