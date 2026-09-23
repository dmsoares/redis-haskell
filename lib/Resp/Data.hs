module Resp.Data (
    ToResp (..),
    Resp (..),
) where

import qualified Data.ByteString as BS

class ToResp a where
    toResp :: a -> Resp

data Resp
    = RedisInteger Int
    | Array [Resp]
    | BulkString BS.ByteString
    | SimpleString BS.ByteString
    | NullBulkString
    | SimpleError BS.ByteString
    deriving (Show, Eq)
