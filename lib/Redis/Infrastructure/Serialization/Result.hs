{-# LANGUAGE OverloadedStrings #-}

module Redis.Infrastructure.Serialization.Result where

import Redis.Domain.Result
import qualified Resp as Resp

toResp :: Result -> Resp.Resp
toResp Pong = Resp.simpleString "PONG"
toResp (Echo msg) = Resp.bulkString msg
toResp SetOK = Resp.simpleString "OK"
toResp GetNull = Resp.nullBulkString
toResp (GetValue v) = Resp.bulkString v
