{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Redis where
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Control.Monad
import Control.Concurrent (MVar)
import qualified Control.Concurrent.MVar as MVar
import Data.Map (Map)
import qualified Data.Map as Map

import Redis.Commands (Command(..), SetOption(..))
import qualified Redis.Commands as Commands
import qualified Redis.RESP as RESP
import Data.Time (UTCTime, getCurrentTime, diffUTCTime, secondsToDiffTime, addUTCTime, secondsToNominalDiffTime, NominalDiffTime)
import Control.Applicative
import Data.Maybe (fromJust)
import GHC.Clock (getMonotonicTime)

type Key = ByteString
type Value = ByteString
type ExpiryTime = NominalDiffTime
type Milliseconds = Int

data RedisTable = RedisTable {
    redisSet :: Key -> Value -> Milliseconds -> IO (),
    redisGet :: Key -> IO (Maybe Value)
}

data RedisRecord = RedisRecord {
    rValue :: Value,
    rInsertedAt :: UTCTime,
    rExpiryTime :: ExpiryTime
}
    deriving Show

newRedisTable :: IO RedisTable
newRedisTable = do
    var <- MVar.newMVar Map.empty
    let set = \key value expiryTime -> do
            now <- getCurrentTime
            let record = RedisRecord{rValue = value, rInsertedAt = now, rExpiryTime = msToDiff expiryTime}
            putStrLn $ "record: " <> show record
            MVar.modifyMVar_ var $ pure . Map.insert key record
        get = \key -> do
            table <- MVar.readMVar var
            now <- getCurrentTime
            pure $ Map.lookup key table >>=
                \RedisRecord{rValue, rInsertedAt, rExpiryTime} ->
                    if rExpiryTime < 0 || addUTCTime rExpiryTime rInsertedAt > now
                    then Just rValue else Nothing
    pure $ RedisTable set get

computeReply :: RedisTable -> Command -> IO RESP.DataType
computeReply _ (Echo msg) = pure $ RESP.bulkString msg
computeReply _ (Ping) = pure $ RESP.simpleString "PONG"
computeReply table cmd@(Set key value opts) = runSet table key value opts
computeReply table (Get key) = runGet table key

runSet :: RedisTable -> Key -> Value -> [SetOption] -> IO RESP.DataType
runSet RedisTable{redisSet} key value opts = do
    redisSet key value (getExpiryTime opts)
    pure $ RESP.simpleString "OK"

runGet :: RedisTable -> Key -> IO RESP.DataType
runGet RedisTable{redisGet} key = do
    mValue <- redisGet key
    pure $ maybe RESP.nullBulkString RESP.bulkString mValue

getExpiryTime :: [SetOption] -> Int
getExpiryTime opts =
    maybe (-1) (id) (asum $ fmap f opts)
    where
        f (SetOptionEX s) = Just (s * 1000)
        f (SetOptionPX ms) = Just ms

msToDiff :: Integral a => a -> NominalDiffTime
msToDiff ms = fromIntegral ms / 1000

deserializeCommand :: ByteString -> Maybe Command
deserializeCommand = RESP.parse >=> resp2command

resp2command :: RESP.DataType -> Maybe Command
resp2command (RESP.Array _ [RESP.BulkString _ "ECHO", RESP.BulkString _ msg]) = Just $ Commands.Echo msg
resp2command (RESP.Array _ [RESP.BulkString _ "PING"]) = Just $ Commands.Ping
resp2command (RESP.Array _ (RESP.BulkString _ "SET" : RESP.BulkString _ key : RESP.BulkString _ value : opts)) = Just $ Commands.Set key value (parseSetOptions opts)
resp2command (RESP.Array _ [RESP.BulkString _ "GET", RESP.BulkString _ key]) = Just $ Commands.Get key
resp2command _ = Nothing

parseSetOptions :: [RESP.DataType] -> [SetOption]
parseSetOptions (dt:arg:dts) =
    case (dt, arg) of
        (RESP.BulkString _ "EX", RESP.BulkString _ s) -> SetOptionEX (parseInt s) : parseSetOptions dts
        (RESP.BulkString _ "PX", RESP.BulkString _ ms) -> SetOptionPX (parseInt ms) : parseSetOptions dts
parseSetOptions _ = []

parseInt :: ByteString -> Int
parseInt bs = maybe (-1) id $ fst <$> BC.readInt bs

serializeReply :: RESP.DataType -> ByteString
serializeReply = RESP.serialize
