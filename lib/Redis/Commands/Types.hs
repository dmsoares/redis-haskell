{-# LANGUAGE OverloadedStrings #-}

module Redis.Commands.Types where

import Data.ByteString (ByteString)

data Command
    = Ping
    | Echo ByteString
    | Set ByteString ByteString [SetOption]
    | Get ByteString
    deriving Show

data SetOption
    = SetOptionEX Int
    | SetOptionPX Int
    deriving Show
