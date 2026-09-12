module Redis.Workflows.Echo (run) where

import Redis.Data.Command (EchoDto (EchoDto))
import Redis.Workflows.Echo.Data (Input (Input), Message (Message), Reply (..))

run :: EchoDto -> Reply
run = execute . deserializeInput

execute :: Input -> Reply
execute (Input (Message msg)) = Reply msg

deserializeInput :: EchoDto -> Input
deserializeInput (EchoDto msg) = Input (Message msg)
