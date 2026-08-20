{-# LANGUAGE OverloadedStrings #-}

module Redis.Printer where

import Redis.DataTypes (DataType(..))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8

crlf :: BS.ByteString
crlf = "\r\n"

pprint :: DataType -> BS.ByteString
pprint (BulkString len str) = "$" <> Char8.pack (show len) <> crlf <> str <> crlf
pprint (RedisInteger n) = ":" <> Char8.pack (show n) <> crlf
pprint (Array len elems) = "*" <> Char8.pack (show len) <> crlf <> BS.concat (fmap pprint elems)
pprint (SimpleString str) = "+" <> str <> crlf
