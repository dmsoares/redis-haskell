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
fromResp (Array [BulkString "PING"]) = Just Ping
fromResp (Array [BulkString "ECHO", BulkString message]) = Just $ Echo (EchoPayload{message})
fromResp (Array (BulkString "SET" : BulkString key : BulkString value : opts)) = Just $ Set (SetPayload key value (parseSetOptions opts))
fromResp (Array [BulkString "GET", BulkString key]) = Just $ Get (GetPayload key)
fromResp _ = Nothing

parseSetOptions :: [Resp] -> [SetOption]
parseSetOptions (BulkString "EX" : BulkString s : dts) = SetOptionEX (parseInt s) : parseSetOptions dts
parseSetOptions (BulkString "PX" : BulkString ms : dts) = SetOptionPX (parseInt ms) : parseSetOptions dts
parseSetOptions _ = []

parseInt :: ByteString -> Int
parseInt bs = maybe (-1) id $ fst <$> BC.readInt bs
