{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forever)
import Data.ByteString (ByteString)
import Network.Simple.TCP (HostPreference (HostAny), Socket, closeSock, recv, send, serve)
import System.IO (BufferMode (NoBuffering), hPutStrLn, hSetBuffering, stderr, stdout)

import Data.Time (UTCTime, getCurrentTime)
import Redis (RedisStore)
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

    redisStore <- Redis.newRedisStore

    serve HostAny port $ \(socket, address) -> do
        putStrLn $ "successfully connected client: " ++ show address
        _ <- forever $ do
            query <- fullQuery socket ""
            -- currentTime needs to be read *after* the blocking fullQuery action
            now <- getCurrentTime
            putStrLn $ "msg: " <> show query
            maybe (pure ()) (processQuery socket now redisStore) query
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

processQuery :: Socket -> UTCTime -> RedisStore -> Resp -> IO ()
processQuery socket now store query = do
    putStrLn $ show query
    reply <- Redis.reply now store query
    putStrLn $ show reply
    send socket (Resp.toBytes reply)
