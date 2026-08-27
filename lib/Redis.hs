{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis (module Table, reply) where

import Redis.Table as Table (RedisTable, newRedisTable)
import Redis.Commands (Command (..))
import qualified Redis.Commands as Commands
import Redis.RESP (Resp)
import Data.ByteString (ByteString)
import qualified Redis.RESP as RESP

reply :: RedisTable -> Command -> IO ByteString
reply table cmd = RESP.serialize <$> Commands.dispatch table cmd
