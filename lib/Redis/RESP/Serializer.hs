{-# LANGUAGE OverloadedStrings #-}

module Redis.RESP.Serializer where

import Redis.RESP.DataTypes (DataType(..))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8

crlf :: BS.ByteString
crlf = "\r\n"

serialize :: DataType -> BS.ByteString
serialize (BulkString len str) = "$" <> Char8.pack (show len) <> crlf <> str <> crlf
serialize (RedisInteger n) = ":" <> Char8.pack (show n) <> crlf
serialize (Array len elems) = "*" <> Char8.pack (show len) <> crlf <> BS.concat (fmap serialize elems)
serialize (SimpleString str) = "+" <> str <> crlf
