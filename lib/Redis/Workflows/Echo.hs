module Redis.Workflows.Echo (workflow) where

import Redis.Data.Command (EchoPayload (EchoPayload))
import Redis.Workflows.Echo.Data (Input (Input), Message (Message), Reply (..))

workflow :: EchoPayload -> Reply
workflow = execute . deserializeInput

execute :: Input -> Reply
execute (Input (Message msg)) = Reply msg

deserializeInput :: EchoPayload -> Input
deserializeInput (EchoPayload msg) = Input (Message msg)
