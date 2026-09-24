{-# LANGUAGE OverloadedStrings #-}

module Resp.SerializationSpec (spec) where

import qualified Data.ByteString as BS

import Resp (Resp (Array, NullBulkString, RedisInteger, SimpleError, SimpleString), fromBytes)
import Resp.Data (Resp (BulkString))
import Resp.Serialization (toBytes)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe)

spec :: Spec
spec = do
    describe "toBytes" $ do
        it "serializes a positive RedisInteger" $
            toBytes (RedisInteger 5) `shouldBe` ":5" <> crlf
        it "serializes a negative RedisInteger" $
            toBytes (RedisInteger (-5)) `shouldBe` ":-5" <> crlf
        it "serializes a SimpleString" $
            toBytes (SimpleString "Hello") `shouldBe` "+Hello" <> crlf
        it "serializes a BulkString" $
            toBytes (BulkString "Hello") `shouldBe` "$5" <> crlf <> "Hello" <> crlf
        it "serializes a BulkString containing CRLF, counting raw bytes" $
            toBytes (BulkString "a\r\nb") `shouldBe` "$4" <> crlf <> "a\r\nb" <> crlf
        it "serializes a NullBulkString" $
            toBytes NullBulkString `shouldBe` "$-1" <> crlf
        it "serializes a Array" $
            toBytes (Array [SimpleString "Hello", SimpleString "World"])
                `shouldBe` "*2" <> crlf <> "+Hello" <> crlf <> "+World" <> crlf
        it "serializes a SimpleError" $
            toBytes (SimpleError "OOPsy daisy") `shouldBe` "-OOPsy daisy" <> crlf

    describe "fromBytes" $ do
        it "deserializes a positive RedisInteger" $
            fromBytes (":5" <> crlf) `shouldBe` Just (RedisInteger 5)
        it "deserializes a negative RedisInteger" $
            fromBytes (":-5" <> crlf) `shouldBe` Just (RedisInteger (-5))
        it "deserializes a 0 RedisInteger" $
            fromBytes (":0" <> crlf) `shouldBe` Just (RedisInteger 0)
        it "deserializes a SimpleString" $
            fromBytes ("+Hello" <> crlf) `shouldBe` Just (SimpleString "Hello")
        it "deserializes a BulkString" $
            fromBytes ("$5" <> crlf <> "Hello" <> crlf) `shouldBe` Just (BulkString "Hello")
        it "deserializes an empty BulkString" $
            fromBytes "$0\r\n\r\n" `shouldBe` Just (BulkString "")
        -- The length prefix is what makes bulk strings binary-safe: the body is
        -- taken by byte count, never scanned for a terminator. This is the whole
        -- reason they exist alongside simple strings, which cannot carry CRLF.
        it "deserializes a BulkString whose body contains CRLF" $
            fromBytes ("$4" <> crlf <> "a\r\nb" <> crlf) `shouldBe` Just (BulkString "a\r\nb")
        it "deserializes a BulkString whose body contains a NUL byte" $
            fromBytes ("$3" <> crlf <> "a\NULb" <> crlf) `shouldBe` Just (BulkString "a\NULb")
        it "deserializes a NullBulkString" $
            fromBytes ("$-1" <> crlf) `shouldBe` Just NullBulkString
        it "deserializes an Array" $
            fromBytes "*2\r\n$4\r\nPING\r\n$4\r\nPONG\r\n" `shouldBe` Just (Array [BulkString "PING", BulkString "PONG"])
        it "deserializes an empty Array" $
            fromBytes "*0\r\n" `shouldBe` Just (Array [])
        it "deserializes a nested Array" $
            fromBytes "*2\r\n*1\r\n:1\r\n+ok\r\n" `shouldBe` Just (Array [Array [RedisInteger 1], SimpleString "ok"])
        it "deserializes a SimpleError" $
            fromBytes ("-OOPsy daisy" <> crlf) `shouldBe` Just (SimpleError "OOPsy daisy")

        -- Both groups below come back as Nothing, because `fromBytes` cannot
        -- distinguish "not enough bytes yet" from "this can never be valid".
        -- Main.fullQuery reads Nothing as "read more", so every case in the
        -- second group makes it wait for bytes that cannot help it. The grouping
        -- is documentation until the result type can express the difference.
        describe "rejects incomplete input" $ do
            it "an empty buffer" $
                rejects ""
            it "an integer with no terminator" $
                rejects ":5"
            it "a simple string with no terminator" $
                rejects "+OK"
            it "a simple string terminated by CR alone" $
                rejects "+OK\r"
            it "a bulk string whose body is cut short" $
                rejects ("$5" <> crlf <> "hel")
            it "a bulk string missing its trailing CRLF" $
                rejects ("$5" <> crlf <> "hello")
            it "a bulk string shorter than its declared length" $
                rejects ("$9" <> crlf <> "hello" <> crlf)
            it "an array with no elements present" $
                rejects ("*2" <> crlf)
            it "an array with fewer elements than declared" $
                rejects ("*3" <> crlf <> "+a" <> crlf)

        describe "rejects malformed input" $ do
            it "a bare terminator" $
                rejects crlf
            it "a value with no type byte" $
                rejects ("5" <> crlf)
            it "an unknown type byte" $
                rejects ("%bogus" <> crlf)
            it "a non-numeric integer" $
                rejects (":abc" <> crlf)
            it "a non-numeric bulk string length" $
                rejects ("$abc" <> crlf)
            it "a non-numeric array length" $
                rejects ("*x" <> crlf)
            it "a negative array length" $
                rejects ("*-1" <> crlf)
            it "a bulk string longer than its declared length" $
                rejects ("$2" <> crlf <> "hello" <> crlf)
  where
    rejects :: BS.ByteString -> Expectation
    rejects bytes = fromBytes bytes `shouldBe` Nothing

    crlf :: BS.ByteString
    crlf = "\r\n"
