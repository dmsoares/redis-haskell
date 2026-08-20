{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Redis.Parser where

import Redis.DataTypes (DataType(..))

import qualified Data.ByteString as BS
import Data.ByteString.Char8 (readInt)
import Data.Void
import Text.Megaparsec
import qualified Text.Megaparsec.Byte.Lexer as L
import Text.Megaparsec.Byte (char, alphaNumChar)
import Control.Monad (when)
import Data.Text.Encoding (decodeASCII)

type Parser = Parsec Void BS.ByteString

pCRLF :: Parser ()
pCRLF = do
    _ <- char 13
    _ <- char 10
    pure ()

pInteger :: Parser DataType
pInteger = do
    _ <- char 58
    n <- L.decimal
    pCRLF
    pure $ RedisInteger n

pBulkString :: Parser DataType
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

pArray :: Parser DataType
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

pRedisValue :: Parser DataType
pRedisValue = pInteger <|> pBulkString <|> pArray
