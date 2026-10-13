{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.Get where

import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)
import Data.Time (UTCTime)

import Control.Monad.Except (MonadError (throwError))
import Redis.Data.Command (GetPayload (GetPayload))
import Redis.Data.DataType (RedisValue (RedisStringValue))
import Redis.Data.Error (RedisError)
import qualified Redis.Data.Error as RedisError
import Redis.Data.Record (RedisRecord (RedisRecord, value))
import qualified Redis.Data.Store as Store
import Redis.Workflows.Get.Data (Input (Input, key), Key (Key), Reply (..))

data Env = Env {receivedAt :: UTCTime, getKey :: Store.Key -> IO (Maybe RedisRecord)}

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => GetPayload -> m Reply
workflow = execute . deserializeInput

deserializeInput :: GetPayload -> Input
deserializeInput (GetPayload key) = Input (Key key)

execute :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => Input -> m Reply
execute Input{key = Key k} = do
    get <- asks getKey
    mRecord <- liftIO $ get k
    case mRecord of
        Nothing -> pure Nil
        Just RedisRecord{value = RedisStringValue str} -> pure $ Value str
        Just _ -> throwError $ RedisError.WrongType
