{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forever)
import Data.ByteString (ByteString)
import Network.Simple.TCP (HostPreference (HostAny), Socket, closeSock, recv, send, serve)
import System.IO (BufferMode (NoBuffering), hPutStrLn, hSetBuffering, stderr, stdout)

import Redis (RedisTable)
import qualified Redis as Redis
import Resp (Resp)
import qualified Resp as Resp

segmentSize :: Int
segmentSize = 3_000

main :: IO ()
main = do
    -- Disable output buffering
    hSetBuffering stdout NoBuffering
    hSetBuffering stderr NoBuffering

    -- You can use print statements as follows for debugging, they'll be visible when running tests.
    hPutStrLn stderr "Logs from your program will appear here"

    -- Uncomment the code below to pass the first stage stage 1
    let port = "6379"
    putStrLn $ "Redis server listening on port " ++ port

    redisTable <- Redis.newRedisTable

    serve HostAny port $ \(socket, address) -> do
        putStrLn $ "successfully connected client: " ++ show address
        _ <- forever $ do
            query <- fullQuery socket ""
            putStrLn $ "msg: " <> show query
            maybe (pure ()) (processQuery socket redisTable) query
        closeSock socket

fullQuery :: Socket -> ByteString -> IO (Maybe Resp)
fullQuery sock buffer = do
    -- https://stackoverflow.com/questions/2862071/how-large-should-my-recv-buffer-be-when-calling-recv-in-the-socket-library
    mBytes <- recv sock segmentSize
    case mBytes of
        Nothing -> pure Nothing
        Just bytes ->
            let buffer' = buffer <> bytes
             in case Resp.fromBytes buffer' of
                    Nothing -> fullQuery sock buffer'
                    query -> pure query

processQuery :: Socket -> RedisTable -> Resp -> IO ()
processQuery socket table query = do
    putStrLn $ show query
    reply <- Redis.reply table query
    putStrLn $ show reply
    send socket (Resp.toBytes reply)
