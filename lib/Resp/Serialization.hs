{-# LANGUAGE OverloadedStrings #-}

module Resp.Serialization (toBytes, fromBytes) where

import Resp.Data (Resp (..))

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import Data.Void
import Text.Megaparsec
import Text.Megaparsec.Byte (string')
import qualified Text.Megaparsec.Byte.Lexer as L

toBytes :: Resp -> BS.ByteString
toBytes (RedisInteger n) = ":" <> Char8.pack (show n) <> crlf
toBytes (SimpleString str) = "+" <> str <> crlf
toBytes (BulkString str) = "$" <> Char8.pack (show $ BS.length str) <> crlf <> str <> crlf
toBytes NullBulkString = "$" <> "-1" <> crlf
toBytes (Array elems) = "*" <> Char8.pack (show $ length elems) <> crlf <> BS.concat (fmap toBytes elems)
toBytes NullArray = "*-1" <> crlf
toBytes (SimpleError str) = "-" <> str <> crlf

crlf :: BS.ByteString
crlf = "\r\n"

type Parser = Parsec Void BS.ByteString

fromBytes :: BS.ByteString -> Maybe Resp
fromBytes bytes = either (const Nothing) Just (runParser pRedisValue "" bytes)

pRedisValue :: Parser Resp
pRedisValue =
    choice . fmap try $
        [ pInteger
        , pBulkString
        , pNullBulkString
        , pArray
        , pNullArray
        , pSimpleError
        , pSimpleString
        ]

pCRLF :: Parser ()
pCRLF = do
    _ <- string' crlf
    pure ()

pSignedDecimal :: Parser Int
pSignedDecimal = L.signed (pure ()) L.decimal

pLength :: Parser Int
pLength = do
    n <- L.decimal
    pCRLF
    pure n

pInteger :: Parser Resp
pInteger = do
    _ <- string' ":"
    n <- pSignedDecimal
    pCRLF
    pure $ RedisInteger n

pNullBulkString :: Parser Resp
pNullBulkString = do
    _ <- string' "$-1"
    pCRLF
    pure NullBulkString

pBulkString :: Parser Resp
pBulkString = do
    _ <- string' "$"
    len <- pLength
    body <- takeP (Just "bulk string body") len
    pCRLF
    pure $ BulkString body

pNullArray :: Parser Resp
pNullArray = do
    _ <- string' "*-1"
    pCRLF
    pure NullArray

pArray :: Parser Resp
pArray = do
    _ <- string' "*"
    len <- pLength
    elems <- count len pRedisValue
    pure $ Array elems

pSimpleString :: Parser Resp
pSimpleString = do
    _ <- string' "+"
    str <- takeWhileP Nothing (/= 13)
    pCRLF
    pure $ SimpleString str

pSimpleError :: Parser Resp
pSimpleError = do
    _ <- string' "-"
    str <- takeWhileP Nothing (/= 13)
    pCRLF
    pure $ SimpleError str
