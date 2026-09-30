{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Data.Command where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC

import Data.Maybe (fromJust, isNothing)
import Resp (Resp (..))

data Command
    = Ping
    | Echo EchoPayload
    | Set SetPayload
    | Get GetPayload
    | RPush RPushPayload
    deriving (Show)

newtype EchoPayload = EchoPayload {message :: ByteString}
    deriving (Show)

data SetPayload = SetPayload
    { key :: ByteString
    , value :: ByteString
    , options :: [SetOption]
    }
    deriving (Show)

data SetOption
    = SetOptionEX Int
    | SetOptionPX Int
    deriving (Show)

newtype GetPayload = GetPayload
    { key :: ByteString
    }
    deriving (Show)

data RPushPayload = RPushPayload
    { key :: ByteString
    , value :: [ByteString]
    }
    deriving (Show)

-- Serialization
fromResp :: Resp -> Maybe Command
fromResp (Array [BulkString "PING"]) = Just Ping
fromResp (Array [BulkString "ECHO", BulkString message]) = Just $ Echo (EchoPayload{message})
fromResp (Array (BulkString "SET" : BulkString key : BulkString value : opts)) = Just $ Set (SetPayload key value (parseSetOptions opts))
fromResp (Array [BulkString "GET", BulkString key]) = Just $ Get (GetPayload key)
fromResp (Array (BulkString "RPUSH" : BulkString key : values)) = RPush <$> (RPushPayload key <$> (parseRPushValues values))
fromResp _ = Nothing

parseRPushValues :: [Resp] -> Maybe [ByteString]
parseRPushValues = resolve . fmap parseValue
  where
    parseValue (BulkString str) = Just str
    parseValue (_) = Nothing
    resolve mValues = if any (isNothing) mValues then Nothing else Just (fromJust <$> mValues)

parseSetOptions :: [Resp] -> [SetOption]
parseSetOptions (BulkString "EX" : BulkString s : dts) = SetOptionEX (parseInt s) : parseSetOptions dts
parseSetOptions (BulkString "PX" : BulkString ms : dts) = SetOptionPX (parseInt ms) : parseSetOptions dts
parseSetOptions _ = []

parseInt :: ByteString -> Int
parseInt bs = maybe (-1) fst (BC.readInt bs)
