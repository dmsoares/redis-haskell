{-# LANGUAGE OverloadedStrings #-}

module Redis.Commands.Deserialization (deserialize) where

import Redis.Commands.Types (Command(..), SetOption(..))
import Redis.RESP (Resp(..))
import qualified Redis.RESP as RESP

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Control.Monad ((>=>))

deserialize :: ByteString -> Maybe Command
deserialize = RESP.parse >=> fromResp

fromResp :: Resp -> Maybe Command
fromResp (Array _ [BulkString _ "PING"]) = Just Ping
fromResp (Array _ [BulkString _ "ECHO", BulkString _ msg]) = Just $ Echo msg
fromResp (Array _ (BulkString _ "SET" : BulkString _ key : BulkString _ value : opts)) = Just $ Set key value (parseSetOptions opts)
fromResp (Array _ [BulkString _ "GET", BulkString _ key]) = Just $ Get key
fromResp _ = Nothing

parseSetOptions :: [Resp] -> [SetOption]
parseSetOptions (BulkString _ "EX":BulkString _ s:dts) = SetOptionEX (parseInt s) : parseSetOptions dts
parseSetOptions (BulkString _ "PX":BulkString _ ms:dts) = SetOptionPX (parseInt ms) : parseSetOptions dts
parseSetOptions _ = []

parseInt :: ByteString -> Int
parseInt bs = maybe (-1) id $ fst <$> BC.readInt bs
