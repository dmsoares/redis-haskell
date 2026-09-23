{-# LANGUAGE OverloadedStrings #-}

module Resp.SerializationSpec (spec) where

import qualified Data.ByteString as BS

import Resp (Resp (Array, NullBulkString, RedisInteger, SimpleError, SimpleString), fromBytes)
import Resp.Data (Resp (BulkString))
import Resp.Serialization (toBytes)
import Test.Hspec (Spec, describe, it, shouldBe)

crlf :: BS.ByteString
crlf = "\r\n"

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
        it "serializes a NullBulkString" $
            toBytes (NullBulkString) `shouldBe` "$-1" <> crlf
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
        it "deserializes a SimpleString" $
            fromBytes ("+Hello" <> crlf) `shouldBe` Just (SimpleString "Hello")
        it "deserializes a BulkString" $
            fromBytes ("$5" <> crlf <> "Hello" <> crlf) `shouldBe` Just (BulkString "Hello")
        it "deserializes a NullBulkString" $
            fromBytes ("$-1" <> crlf) `shouldBe` Just NullBulkString
        it "deserializes a Array" $
            fromBytes ("*2" <> crlf <> "+Hello" <> crlf <> "+World" <> crlf)
                `shouldBe` Just (Array [SimpleString "Hello", SimpleString "World"])
        it "deserializes a SimpleError" $
            fromBytes ("-OOPsy daisy" <> crlf) `shouldBe` Just (SimpleError "OOPsy daisy")
