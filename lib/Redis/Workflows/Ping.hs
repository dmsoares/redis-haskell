module Redis.Workflows.Ping (workflow) where

import Redis.Workflows.Ping.Data (Reply (Pong))

workflow :: Reply
workflow = Pong
