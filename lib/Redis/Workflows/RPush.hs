{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module Redis.Workflows.RPush where

import Control.Monad ((>=>))
import Control.Monad.Except (MonadError (throwError))
import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)
import Data.Time (UTCTime)
import Redis.Data.Command (RPushPayload (RPushPayload))
import Redis.Data.DataType (RedisType (RedisListType), RedisValue (RedisListValue, RedisStringValue))
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
deserializeInput (RPushPayload k vs) = Input (Key k) (Value <$> vs)

execute :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => Input -> m Reply
execute Input{key = Key key', values} = do
    now <- asks receivedAt
    get <- asks getKey
    set <- asks setKey

    mCurrentVal <- liftIO $ get key'

    case mCurrentVal of
        Nothing -> do
            let newRecord = RedisRecord (RedisListValue (toRedisStringValue <$> values)) RedisListType now Nothing
            setListRecord set key' newRecord
        Just record@RedisRecord{R.value = recordValue, R.typeTag = recordType} -> case recordValue of
            RedisListValue elems -> do
                let updatedRecord = record{R.value = RedisListValue (elems <> (toRedisStringValue <$> values))}
                setListRecord set key' updatedRecord
            _ -> throwError $ WrongDataType (show recordType)
  where
    setListRecord setter key record@RedisRecord{R.value = (RedisListValue list)} = do
        _ <- liftIO $ setter key record
        pure $ OK (length list)
    toRedisStringValue (Value v) = RedisStringValue v
