{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Data.Command where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC

import Resp (Resp (..))

data Command
    = Ping
    | Echo EchoPayload
    | Set SetPayload
    | Get GetPayload
    deriving (Show)

data EchoPayload = EchoPayload {message :: ByteString}
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

data GetPayload = GetPayload
    { key :: ByteString
    }
    deriving (Show)

-- Serialization
fromResp :: Resp -> Maybe Command
fromResp (Array _ [BulkString _ "PING"]) = Just Ping
fromResp (Array _ [BulkString _ "ECHO", BulkString _ message]) = Just $ Echo (EchoPayload{message})
fromResp (Array _ (BulkString _ "SET" : BulkString _ key : BulkString _ value : opts)) = Just $ Set (SetPayload key value (parseSetOptions opts))
fromResp (Array _ [BulkString _ "GET", BulkString _ key]) = Just $ Get (GetPayload key)
fromResp _ = Nothing

parseSetOptions :: [Resp] -> [SetOption]
parseSetOptions (BulkString _ "EX" : BulkString _ s : dts) = SetOptionEX (parseInt s) : parseSetOptions dts
parseSetOptions (BulkString _ "PX" : BulkString _ ms : dts) = SetOptionPX (parseInt ms) : parseSetOptions dts
parseSetOptions _ = []

parseInt :: ByteString -> Int
parseInt bs = maybe (-1) id $ fst <$> BC.readInt bs
