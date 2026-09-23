{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Resp.Serialization (toBytes, fromBytes) where

import Resp.Data (Resp (..))

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import Data.Void
import Text.Megaparsec
import Text.Megaparsec.Byte (char)
import qualified Text.Megaparsec.Byte.Lexer as L

toBytes :: Resp -> BS.ByteString
toBytes (RedisInteger n) = ":" <> Char8.pack (show n) <> crlf
toBytes (SimpleString str) = "+" <> str <> crlf
toBytes (BulkString str) = "$" <> Char8.pack (show $ BS.length str) <> crlf <> str <> crlf
toBytes NullBulkString = "$" <> "-1" <> crlf
toBytes (Array elems) = "*" <> Char8.pack (show $ length elems) <> crlf <> BS.concat (fmap toBytes elems)
toBytes (SimpleError str) = "-" <> str <> crlf

crlf :: BS.ByteString
crlf = "\r\n"

type Parser = Parsec Void BS.ByteString

fromBytes :: BS.ByteString -> Maybe Resp
fromBytes bytes = either (const Nothing) Just (runParser pRedisValue "" bytes)

pRedisValue :: Parser Resp
pRedisValue =
    pInteger
        <|> pBulkStringOrNull
        <|> pArray
        <|> pSimpleString
        <|> pSimpleError

pCRLF :: Parser ()
pCRLF = do
    _ <- char 13
    _ <- char 10
    pure ()

pSignedDecimal :: Parser Int
pSignedDecimal = L.signed (pure ()) L.decimal

pInteger :: Parser Resp
pInteger = do
    _ <- char 58
    n <- pSignedDecimal
    pCRLF
    pure $ RedisInteger n

pBulkStringOrNull :: Parser Resp
pBulkStringOrNull = do
    len <- pBulkStringLength
    if len < 0 then pure NullBulkString else pBulkString len
  where
    pBulkStringLength = do
        _ <- char 36
        n <- pSignedDecimal
        pCRLF
        pure n
    pBulkString len = do
        body <- takeP (Just "bulk string body") len
        pCRLF
        pure $ BulkString body

pArray :: Parser Resp
pArray = do
    len <- pLength
    elems <- count len pRedisValue
    pure $ Array elems
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
