module Redis.RESP.DataTypes where

import qualified Data.ByteString as BS

data DataType =
    RedisInteger Int
    | Array Int [DataType]
    | BulkString Int BS.ByteString
    | SimpleString BS.ByteString
    deriving Show

integer :: Int -> DataType
integer = RedisInteger

array :: [DataType] -> DataType
array dts = Array (length dts) dts

bulkString :: BS.ByteString -> DataType
bulkString bs = BulkString (BS.length bs) bs

simpleString :: BS.ByteString -> DataType
simpleString = SimpleString
