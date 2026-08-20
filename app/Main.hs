{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Network.Simple.TCP (serve, HostPreference(HostAny), closeSock, recv, send, Socket)
import System.IO (hPutStrLn, hSetBuffering, stdout, stderr, BufferMode(NoBuffering))
import Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import Control.Monad (forever, forM)
import Redis.Parser
import Text.Megaparsec (runParser)
import Redis.DataTypes (DataType(..))
import Redis.Printer

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
            mBytes <- recv socket 64
            maybeReply socket mBytes

        closeSock socket

maybeReply :: Socket -> Maybe BS.ByteString -> IO ()
maybeReply socket Nothing = putStrLn "no data received"
maybeReply socket (Just bytes) = do
    let result = runParser pRedisValue "" bytes
    putStrLn $ show result
    case result of
        Left _ -> pure ()
        Right (Array _ [BulkString _ "ECHO", BulkString l msg]) -> send socket . pprint $ BulkString l msg
        Right (Array _ [BulkString _ "PING"]) -> send socket . pprint $ SimpleString "PONG"
