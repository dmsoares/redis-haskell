module Redis.Workflows.Echo where

import Control.Monad (MonadPlus (mzero), (>=>))
import Redis.Domain.Command (Command)
import qualified Redis.Domain.Command as Command
import Redis.Domain.Result (Result (Echo))
import Redis.Infrastructure.Serialization.Command (fromResp)
import Redis.Infrastructure.Serialization.Result (toResp)
import Resp (Resp, nullBulkString)

type Workflow a = Maybe a

run :: Resp -> Resp
run query = case workflow query of
    Just res -> res
    Nothing -> handleError

workflow :: Resp -> Workflow Resp
workflow = parseCommand >=> buildResult >=> serializeResult

parseCommand :: Resp -> Workflow Command
parseCommand = fromResp

buildResult :: Command -> Workflow Result
buildResult (Command.Echo msg) = pure $ Echo msg
buildResult _ = mzero

serializeResult :: Result -> Workflow Resp
serializeResult = pure . toResp

handleError :: Resp
handleError = nullBulkString
