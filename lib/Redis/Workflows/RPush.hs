{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.RPush where

import Control.Monad ((>=>))
import Control.Monad.Except (MonadError (throwError))
import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)
import Data.Time (UTCTime)
import Redis.Data.Command (RPushPayload (RPushPayload))
import Redis.Data.DataType (RedisDataType (RedisList, RedisString))
import Redis.Data.Error (RedisError (WrongDataType))
import Redis.Data.Record (RedisRecord (RedisRecord))
import qualified Redis.Data.Record as R
import qualified Redis.Data.Store as Store
import Redis.Workflows.RPush.Data (Input (..), Key (..), Reply (..), Value (..))

data Env = Env
    { receivedAt :: UTCTime
    , getKey :: Store.Key -> IO (Maybe RedisRecord)
    , setKey :: Store.Key -> RedisRecord -> IO ()
    }

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => RPushPayload -> m Reply
workflow = pure . deserializeInput >=> execute

deserializeInput :: RPushPayload -> Input
deserializeInput (RPushPayload k v) = Input (Key k) (Value v)

execute :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => Input -> m Reply
execute Input{key = Key key', value = Value value'} = do
    now <- asks receivedAt
    get <- asks getKey
    set <- asks setKey

    mCurrentVal <- liftIO $ get key'
    case mCurrentVal of
        Nothing -> do
            liftIO $ set key' (RedisRecord (RedisList [RedisString value']) now Nothing)
            pure (OK 1)
        Just record@RedisRecord{R.value} -> case value of
            RedisList elems -> do
                liftIO $ set key' record{R.value = RedisList (elems <> [RedisString value'])}
                pure (OK (length elems + 1))
            _ -> throwError $ WrongDataType ""
