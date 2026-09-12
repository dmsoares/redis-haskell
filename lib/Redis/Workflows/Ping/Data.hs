{-# LANGUAGE OverloadedStrings #-}

module Redis.Workflows.Ping.Data where

import Resp (simpleString)
import Resp.Data (ToResp (..))

data Reply = Pong deriving (Show)

instance ToResp Reply where
    toResp _ = simpleString "PONG"
