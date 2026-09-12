{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.Get where

import Control.Monad ((>=>))
import Control.Monad.Reader (ReaderT (runReaderT), asks, liftIO)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Redis.Data.Command (GetPayload (GetPayload))
import Redis.Data.Table (RedisTable (RedisTable), redisGet)
import Redis.Workflows.Get.Data (Input (Input, key), Key (Key), Reply (..))

data Env = Env {getTable :: RedisTable}

type Workflow a = ReaderT Env (MaybeT IO) a

run :: GetPayload -> RedisTable -> IO Reply
run payload table = do
    result <- runMaybeT $ runReaderT (workflow payload) (Env table)
    pure $ maybe UnknownError id result

workflow :: GetPayload -> Workflow Reply
workflow = deserializeInput >=> execute

deserializeInput :: GetPayload -> Workflow Input
deserializeInput (GetPayload key) = pure $ Input (Key key)

execute :: Input -> Workflow Reply
execute Input{key} = do
    table <- asks getTable
    liftIO $ handleGet table key

handleGet :: RedisTable -> Key -> IO Reply
handleGet RedisTable{redisGet} (Key key) = do
    mValue <- redisGet key
    pure $ maybe Null Value mValue
