{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.Set where

import Control.Monad ((>=>))
import Control.Monad.Except (MonadError, liftEither)
import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)
import Data.Time (getCurrentTime)

import Redis.Data.Command (SetPayload (SetPayload))
import Redis.Data.DataType (RedisDataType (RedisString))
import Redis.Data.Error (RedisError)
import Redis.Data.Record (RedisRecord (RedisRecord))
import qualified Redis.Data.Store as Store
import Redis.Workflows.Set.Data (Input (..), Key (..), Options (..), Reply (..), Value (..), deserializeOptions)

data Env = Env {setKey :: Store.Key -> RedisRecord -> IO ()}

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => SetPayload -> m Reply
workflow = deserializeInput >=> execute

deserializeInput :: (MonadError RedisError m) => SetPayload -> m Input
deserializeInput (SetPayload k v opts) = Input (Key k) (Value v) <$> liftEither (deserializeOptions opts)

execute :: (MonadReader Env m, MonadIO m) => Input -> m Reply
execute Input{key = Key key, value = Value value, options = Options{expiryTime}} = do
    now <- liftIO getCurrentTime
    set <- asks setKey
    liftIO $ set key (RedisRecord (RedisString value) now expiryTime)
    pure $ OK
