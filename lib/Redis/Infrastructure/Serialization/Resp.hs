{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Redis.Infrastructure.Serialization.Resp where

import Redis.Domain.Resp (Resp (..))

import Control.Monad (guard, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import Data.Void
import Text.Megaparsec
import Text.Megaparsec.Byte (alphaNumChar, char)
import qualified Text.Megaparsec.Byte.Lexer as L

toBytes :: Resp -> BS.ByteString
toBytes (BulkString len str) = "$" <> Char8.pack (show len) <> crlf <> str <> crlf
toBytes (RedisInteger n) = ":" <> Char8.pack (show n) <> crlf
toBytes (Array len elems) = "*" <> Char8.pack (show len) <> crlf <> BS.concat (fmap toBytes elems)
toBytes (SimpleString str) = "+" <> str <> crlf
toBytes NullBulkString = "$" <> "-1" <> crlf

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
    str <- some alphaNumChar
    when (len /= length str) (fail "stated length of bulk string does not match actual length!")
    pCRLF
    pure $ BulkString len (BS.pack str)

pBulkStringLength :: Parser Int
pBulkStringLength = do
    _ <- char 36
    n <- L.decimal
    pCRLF
    pure n

pArray :: Parser Resp
pArray = do
    len <- pArrayLength
    elems <- some pRedisValue
    when (len /= length elems) (fail "stated length of array does not match actual length!")
    pure $ Array len elems

pArrayLength :: Parser Int
pArrayLength = do
    _ <- char 42
    n <- L.decimal
    pCRLF
    pure n

pPureString :: Parser Resp
pPureString = do
    _ <- char 43
    str <- some alphaNumChar
    pCRLF
    pure $ SimpleString (BS.pack str)

pNullBulkString :: Parser Resp
pNullBulkString = do
    len <- pBulkStringLength
    guard $ len == -1
    pCRLF
    pure NullBulkString

pRedisValue :: Parser Resp
pRedisValue =
    pInteger
        <|> pBulkString
        <|> pArray
        <|> pNullBulkString
        <|> pPureString
