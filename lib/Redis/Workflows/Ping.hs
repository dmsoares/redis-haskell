module Redis.Workflows.Ping where

import Redis.Workflows.Ping.Data (Reply (Pong))

run :: Reply
run = Pong
