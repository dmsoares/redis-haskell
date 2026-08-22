{-# LANGUAGE OverloadedStrings #-}

module Redis.Commands.Types where

import Data.ByteString (ByteString)

data Command
    = Ping
    | Echo ByteString
    | Set ByteString ByteString
    | Get ByteString
    deriving Show
