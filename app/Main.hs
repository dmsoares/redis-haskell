{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forever)
import Data.ByteString (ByteString)
import Network.Simple.TCP (HostPreference (HostAny), Socket, closeSock, recv, send, serve)
import System.IO (BufferMode (NoBuffering), hPutStrLn, hSetBuffering, stderr, stdout)

import Redis (RedisTable)
import qualified Redis as Redis

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
        forever $ do
            mBytes <- recv socket 64
            processBytes socket redisTable mBytes
        closeSock socket

processBytes :: Socket -> RedisTable -> Maybe ByteString -> IO ()
processBytes _ _ Nothing = pure ()
processBytes socket table (Just bytes) = do
    putStrLn $ show bytes
    mReply <- Redis.reply table bytes
    putStrLn $ show mReply

    case mReply of
        Just reply -> send socket reply
        Nothing -> pure ()
