{-# LANGUAGE OverloadedStrings #-}

module Redis.Redis where
import Data.ByteString (ByteString)
import Control.Monad
import Data.IORef (IORef)
import qualified Data.IORef as IORef
import Data.Map (Map)
import qualified Data.Map as Map

import Redis.Commands (Command)
import qualified Redis.Commands as Commands
import qualified Redis.RESP as RESP

computeReply :: IORef (Map ByteString ByteString) -> Command -> IO RESP.DataType
computeReply _ (Commands.Echo msg) = pure $ RESP.bulkString msg
computeReply _ (Commands.Ping) = pure $ RESP.simpleString "PONG"
computeReply tableRef (Commands.Set key value) = do
    IORef.modifyIORef tableRef $ Map.insert key value
    pure $ RESP.simpleString "OK"
computeReply tableRef (Commands.Get key) = do
    table <- IORef.readIORef tableRef
    case Map.lookup key table of
        Nothing -> pure $ RESP.bulkString "null"
        Just value -> pure $ RESP.bulkString value

deserializeCommand :: ByteString -> Maybe Command
deserializeCommand = RESP.parse >=> resp2command

resp2command :: RESP.DataType -> Maybe Command
resp2command (RESP.Array _ [RESP.BulkString _ "ECHO", RESP.BulkString _ msg]) = Just $ Commands.Echo msg
resp2command (RESP.Array _ [RESP.BulkString _ "PING"]) = Just $ Commands.Ping
resp2command (RESP.Array _ [RESP.BulkString _ "SET", RESP.BulkString _ key, RESP.BulkString _ value]) = Just $ Commands.Set key value
resp2command (RESP.Array _ [RESP.BulkString _ "GET", RESP.BulkString _ key]) = Just $ Commands.Get key
resp2command _ = Nothing

serializeReply :: RESP.DataType -> ByteString
serializeReply = RESP.serialize
