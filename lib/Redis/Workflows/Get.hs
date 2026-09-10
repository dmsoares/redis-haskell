module Redis.Workflows.Get where

import Control.Monad (MonadPlus (mzero), (>=>))
import Control.Monad.Reader (ReaderT (runReaderT), asks, liftIO)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Redis.Domain.Command (Command)
import qualified Redis.Domain.Command as Command
import Redis.Domain.Result (Result)
import qualified Redis.Domain.Result as Result
import Redis.Domain.Table
import qualified Redis.Domain.Table as Table
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
execute (Command.Get key) = do
    table <- asks getTable
    liftIO $ handleGet table key
execute _ = mzero

handleGet :: RedisTable -> Key -> IO Result.Result
handleGet table key = do
    result <- Table.runGet table key
    putStrLn $ "res: " <> show result
    pure $ case result of
        Table.GetNull -> Result.GetNull
        Table.GetValue v -> Result.GetValue v

serializeResult :: Result -> Workflow Resp
serializeResult = pure . toResp

handleError :: Resp
handleError = nullBulkString
