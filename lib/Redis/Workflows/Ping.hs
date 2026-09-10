module Redis.Workflows.Ping where

import Redis.Domain.Result (Result (Pong))
import Redis.Infrastructure.Serialization.Result (toResp)
import Resp (Resp)

run :: Resp -> Resp
run _ = toResp Pong
