{-# OPTIONS_GHC -Wno-unused-top-binds #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NumericUnderscores #-}

module Main (main) where

import Network.Simple.TCP (serve, HostPreference(HostAny), closeSock, recv, send, Socket)
import System.IO (hPutStrLn, hSetBuffering, stdout, stderr, BufferMode(NoBuffering))
import Data.ByteString as BS
import Control.Monad (forever, forM)

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
    serve HostAny port $ \(socket, address) -> do
        putStrLn $ "successfully connected client: " ++ show address

        forever $ do
            mBytes <- recv socket 14
            maybeReply socket mBytes

        closeSock socket

maybeReply :: Socket -> Maybe BS.ByteString -> IO ()
maybeReply socket Nothing = putStrLn "no data received"
maybeReply socket (Just "*1\r\n$4\r\nPING\r\n") = send socket $ "+PONG\r\n"
maybeReply socket (Just bytes) = putStrLn $ "received: " <> (show bytes)
