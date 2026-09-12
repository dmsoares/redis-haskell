{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.Set where

import Control.Monad.Reader (ReaderT (runReaderT), asks, liftIO)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))

import Redis.Data.Command (SetPayload (SetPayload))
import Redis.Data.Table (RedisTable (..), SetOptions (SetOptions))
import qualified Redis.Data.Table as Table
import Redis.Workflows.Set.Data (Input (..), Key (..), Options (..), Reply (..), Value (..), deserializeOptions)

data Env = Env {getTable :: RedisTable}

type Workflow a = ReaderT Env (MaybeT IO) a

run :: SetPayload -> RedisTable -> IO Reply
run payload table = do
    result <- runMaybeT $ runReaderT (workflow payload) (Env table)
    pure $ maybe UnknownError id result

workflow :: SetPayload -> Workflow Reply
workflow payload = deserializeInput payload >>= execute

deserializeInput :: SetPayload -> Workflow Input
deserializeInput (SetPayload k v opts) = pure $ Input (Key k) (Value v) (deserializeOptions opts)

execute :: Input -> Workflow Reply
execute Input{key = Key key, value = Value value, options = Options{expiryTime}} = do
    RedisTable{redisSet} <- asks getTable
    liftIO $ redisSet key value SetOptions{Table.expiryTime = expiryTime}
    pure $ OK
