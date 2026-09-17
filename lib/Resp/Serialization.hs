{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Resp.Serialization where

import Resp.Data (Resp (..))

import Control.Monad (guard)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import Data.Void
import Text.Megaparsec
import Text.Megaparsec.Byte (char)
import qualified Text.Megaparsec.Byte.Lexer as L

toBytes :: Resp -> BS.ByteString
toBytes (BulkString len str) = "$" <> Char8.pack (show len) <> crlf <> str <> crlf
toBytes (RedisInteger n) = ":" <> Char8.pack (show n) <> crlf
toBytes (Array len elems) = "*" <> Char8.pack (show len) <> crlf <> BS.concat (fmap toBytes elems)
toBytes (SimpleString str) = "+" <> str <> crlf
toBytes NullBulkString = "$" <> "-1" <> crlf
toBytes (SimpleError str) = "-" <> str <> crlf

crlf :: BS.ByteString
crlf = "\r\n"

type Parser = Parsec Void BS.ByteString

fromBytes :: BS.ByteString -> Maybe Resp
fromBytes bytes = either (const Nothing) Just (runParser pRedisValue "" bytes)

pCRLF :: Parser ()
pCRLF = do
    _ <- char 13
    _ <- char 10
    pure ()

pInteger :: Parser Resp
pInteger = do
    _ <- char 58
    n <- L.decimal
    pCRLF
    pure $ RedisInteger n

pBulkString :: Parser Resp
pBulkString = do
    len <- pBulkStringLength
    body <- takeP (Just "bulk string body") len
    pCRLF
    pure $ BulkString len body

pNullBulkString :: Parser Resp
pNullBulkString = do
    len <- pBulkStringLength
    guard $ len == -1
    pCRLF
    pure NullBulkString

pBulkStringLength :: Parser Int
pBulkStringLength = do
    _ <- char 36
    n <- L.decimal
    pCRLF
    pure n

pArray :: Parser Resp
pArray = do
    len <- pLength
    elems <- count len pRedisValue
    pure $ Array len elems
  where
    pLength = do
        _ <- char 42
        n <- L.decimal
        pCRLF
        pure n

pSimpleString :: Parser Resp
pSimpleString = do
    _ <- char 43
    str <- takeWhileP Nothing (/= 13)
    pCRLF
    pure $ SimpleString str

pSimpleError :: Parser Resp
pSimpleError = do
    _ <- char 45
    str <- takeWhileP Nothing (/= 13)
    pCRLF
    pure $ SimpleError str

pRedisValue :: Parser Resp
pRedisValue =
    pInteger
        <|> pBulkString
        <|> pArray
        <|> pNullBulkString
        <|> pSimpleString
        <|> pSimpleError
