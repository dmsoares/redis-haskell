{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.Get where

import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)
import Data.Time (UTCTime)

import Control.Monad.Except (MonadError (throwError))
import Redis.Data.Command (GetPayload (GetPayload))
import Redis.Data.DataType (RedisDataType (RedisString))
import Redis.Data.Error (RedisError (WrongDataType))
import Redis.Data.Record (RedisRecord (RedisRecord, value), isLive)
import qualified Redis.Data.Store as Store
import Redis.Workflows.Get.Data (Error (..), Input (Input, key), Key (Key), Reply (..))

data Env = Env {receivedAt :: UTCTime, getKey :: Store.Key -> IO (Maybe RedisRecord)}

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => GetPayload -> m Reply
workflow = execute . deserializeInput

deserializeInput :: GetPayload -> Input
deserializeInput (GetPayload key) = Input (Key key)

execute :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => Input -> m Reply
execute Input{key = Key k} = do
    now <- asks receivedAt
    get <- asks getKey
    mRecord <- liftIO $ get k
    handleResult $ do
        record@RedisRecord{value} <- maybe (Left NotFound) Right mRecord
        case (isLive now record, value) of
            (True, RedisString str) -> Right str
            (True, _) -> Left (WrongType "String")
            (False, _) -> Left DeadValue
  where
    handleResult (Right str) = pure $ Value str
    handleResult (Left DeadValue) = pure Nil
    handleResult (Left NotFound) = pure Nil
    handleResult (Left (WrongType typ)) = throwError $ WrongDataType typ
