{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Network.Simple.TCP (serve, HostPreference(HostAny), closeSock, recv, send, Socket)
import System.IO (hPutStrLn, hSetBuffering, stdout, stderr, BufferMode(NoBuffering))
import Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import Control.Monad (forever, forM)
import Text.Megaparsec (runParser)
import Data.IORef
import qualified Data.Map as Map

import qualified Redis.Redis as Redis
import Redis.RESP (DataType(..))
import qualified Redis.RESP as RESP
import qualified Redis.Commands as Commands

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

        tableRef <- newIORef Map.empty

        forever $ do
            mBytes <- recv socket 64
            case mBytes of
                Just bytes -> do
                    putStrLn $ show bytes
                    case Redis.deserializeCommand bytes of
                        Just command -> do
                            putStrLn $ show command
                            reply <- Redis.computeReply tableRef $ command
                            send socket . Redis.serializeReply $ reply
                        Nothing -> pure ()
                Nothing -> pure ()

        closeSock socket
