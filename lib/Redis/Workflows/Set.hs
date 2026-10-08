{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Workflows.Set where

import Control.Monad ((>=>))
import Control.Monad.Except (MonadError)
import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)
import Data.Time (UTCTime)

import Redis.Data.Command (SetPayload (SetPayload))
import Redis.Data.DataType (RedisType (RedisStringType), RedisValue (RedisStringValue))
import Redis.Data.Error (RedisError)
import Redis.Data.Record (RedisRecord)
import qualified Redis.Data.Record as RR
import qualified Redis.Data.Store as Store
import Redis.Workflows.Set.Data (Input (..), Key (..), Options (..), Reply (..), Value (..), deserializeOptions)

data Env = Env {receivedAt :: UTCTime, setKey :: Store.Key -> RedisRecord -> IO ()}

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => SetPayload -> m Reply
workflow = pure . deserializeInput >=> execute

deserializeInput :: SetPayload -> Input
deserializeInput (SetPayload k v opts) = Input (Key k) (Value v) (deserializeOptions opts)

execute :: (MonadReader Env m, MonadIO m) => Input -> m Reply
execute Input{key = Key key, value = Value value, options = Options{expiryTime}} = do
    now <- asks receivedAt
    set <- asks setKey

    let record =
            RR.RedisRecord
                { RR.value = RedisStringValue value
                , RR.typeTag = RedisStringType
                , RR.insertedAt = now
                , RR.expiryTime = expiryTime >>= RR.mkExpiryTime
                }

    liftIO $ set key record
    pure OK
