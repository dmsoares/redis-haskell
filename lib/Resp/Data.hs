module Resp.Data where

import qualified Data.ByteString as BS

class ToResp a where
    toResp :: a -> Resp

data Resp
    = RedisInteger Int
    | Array Int [Resp]
    | BulkString Int BS.ByteString
    | SimpleString BS.ByteString
    | NullBulkString
    deriving (Show)

integer :: Int -> Resp
integer = RedisInteger

array :: [Resp] -> Resp
array xs = Array (length xs) xs

bulkString :: BS.ByteString -> Resp
bulkString bs = BulkString (BS.length bs) bs

simpleString :: BS.ByteString -> Resp
simpleString = SimpleString

nullBulkString :: Resp
nullBulkString = NullBulkString
