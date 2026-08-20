module Redis.DataTypes (DataType(..)) where
import qualified Data.ByteString as BS

data DataType =
    RedisInteger Int
    | Array Int [DataType]
    | BulkString Int BS.ByteString
    | SimpleString BS.ByteString
    deriving Show
