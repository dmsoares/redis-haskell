{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.Set where

import Control.Monad ((>=>))
import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)

import Control.Monad.Except (MonadError, liftEither)
import Redis.Data.Command (SetPayload (SetPayload))
import Redis.Data.Error (RedisError)
import Redis.Data.Store (SetOptions (SetOptions))
import qualified Redis.Data.Store as Store
import Redis.Workflows.Set.Data (Input (..), Key (..), Options (..), Reply (..), Value (..), deserializeOptions)

data Env = Env {setKey :: Store.Key -> Store.Value -> Store.SetOptions -> IO ()}

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => SetPayload -> m Reply
workflow = deserializeInput >=> execute

deserializeInput :: (MonadError RedisError m) => SetPayload -> m Input
deserializeInput (SetPayload k v opts) = Input (Key k) (Value v) <$> liftEither (deserializeOptions opts)

execute :: (MonadReader Env m, MonadIO m) => Input -> m Reply
execute Input{key = Key key, value = Value value, options = Options{expiryTime}} = do
    set <- asks setKey
    liftIO $ set key value SetOptions{Store.expiryTime = expiryTime}
    pure $ OK
