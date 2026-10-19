{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Workflows.LPush where

import Control.Monad ((>=>))
import Control.Monad.Except (MonadError (throwError))
import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)
import Data.Time (UTCTime)
import Redis.Data.Command (LPushPayload (LPushPayload))
import Redis.Data.DataType (RedisType (RedisListType), RedisValue (RedisListValue, RedisStringValue))
import Redis.Data.Error (RedisError (WrongType))
import Redis.Data.Record (RedisRecord (RedisRecord))
import qualified Redis.Data.Record as R
import qualified Redis.Data.Store as Store
import Redis.Workflows.LPush.Data (Input (..), Key (..), Reply (..), Value (..))

data Env = Env
    { receivedAt :: UTCTime
    , getKey :: Store.Key -> IO (Maybe RedisRecord)
    , setKey :: Store.Key -> RedisRecord -> IO ()
    }

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => LPushPayload -> m Reply
workflow = pure . deserializeInput >=> execute

deserializeInput :: LPushPayload -> Input
deserializeInput (LPushPayload k vs) = Input (Key k) (Value <$> vs)

execute :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => Input -> m Reply
execute Input{key = Key key', values} = do
    now <- asks receivedAt
    get <- asks getKey
    set <- asks setKey

    mCurrentVal <- liftIO $ get key'

    case mCurrentVal of
        Nothing -> do
            let newRecord = RedisRecord (RedisListValue (toRedisStringValue <$> reverse values)) RedisListType now Nothing
            setListRecord set key' newRecord
        Just record@RedisRecord{R.value = recordValue} -> case recordValue of
            RedisListValue elems -> do
                let updatedRecord = record{R.value = RedisListValue ((toRedisStringValue <$> reverse values) <> elems)}
                setListRecord set key' updatedRecord
            _ -> throwError WrongType
  where
    setListRecord setter key record@RedisRecord{R.value = (RedisListValue list)} = do
        _ <- liftIO $ setter key record
        pure $ OK (length list)
    setListRecord _ _ _ = throwError WrongType
    toRedisStringValue (Value v) = RedisStringValue v
