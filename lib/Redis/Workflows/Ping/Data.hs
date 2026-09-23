{-# LANGUAGE OverloadedStrings #-}

module Redis.Workflows.Ping.Data where

import Resp.Data (Resp (SimpleString), ToResp (..))

data Reply = Pong deriving (Show)

instance ToResp Reply where
    toResp _ = SimpleString "PONG"
