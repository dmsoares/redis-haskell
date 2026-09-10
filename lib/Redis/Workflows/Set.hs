module Redis.Workflows.Set where

import Control.Monad (MonadPlus (mzero), (>=>))
import Control.Monad.Reader (ReaderT (runReaderT), asks, liftIO)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Redis.Domain.Command (Command)
import qualified Redis.Domain.Command as Command
import Redis.Domain.Result (Result)
import qualified Redis.Domain.Result as Result
import Redis.Domain.Table
import Redis.Infrastructure.Serialization.Command (fromResp)
import Redis.Infrastructure.Serialization.Result (toResp)
import qualified Redis.Infrastructure.Table as Table
import Resp (Resp, nullBulkString)

data Env = Env {getTable :: RedisTable}

type Workflow a = ReaderT Env (MaybeT IO) a

run :: Resp -> RedisTable -> IO Resp
run query table = do
    result <- runMaybeT $ runReaderT (workflow query) (Env table)
    pure $ case result of
        Just res -> res
        Nothing -> handleError

workflow :: Resp -> Workflow Resp
workflow = parseCommand >=> execute >=> serializeResult

parseCommand :: Resp -> Workflow Command
parseCommand query = case fromResp query of
    Just cmd -> pure cmd
    Nothing -> mzero

execute :: Command -> Workflow Result
execute (Command.Set key value opts) = do
    table <- asks getTable
    liftIO $ handleSet table key value opts
execute _ = mzero

handleSet :: RedisTable -> Key -> Value -> [Command.SetOption] -> IO Result.Result
handleSet table key value opts = do
    _ <- Table.runSet table key value SetOptions{expiryTime = Command.getExpiryTime opts}
    pure Result.SetOK

serializeResult :: Result -> Workflow Resp
serializeResult = pure . toResp

handleError :: Resp
handleError = nullBulkString
