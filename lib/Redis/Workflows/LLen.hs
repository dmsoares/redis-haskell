{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.LLen where

import Control.Monad.Except (MonadError (throwError))
import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)

import Redis.Data.Command (LLenPayload (LLenPayload))
import Redis.Data.DataType (RedisValue (RedisListValue))
import Redis.Data.Error (RedisError)
import qualified Redis.Data.Error as RedisError
import Redis.Data.Record (RedisRecord (RedisRecord, value))
import qualified Redis.Data.Store as Store
import Redis.Workflows.LLen.Data (Input (Input, key), Key (Key), Reply (..))

data Env = Env {getKey :: Store.Key -> IO (Maybe RedisRecord)}

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => LLenPayload -> m Reply
workflow = execute . deserializeInput

deserializeInput :: LLenPayload -> Input
deserializeInput (LLenPayload key) = Input (Key key)

execute :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => Input -> m Reply
execute Input{key = Key k} = do
    get <- asks getKey
    mRecord <- liftIO $ get k
    case mRecord of
        Nothing -> pure $ Length 0
        Just RedisRecord{value = RedisListValue values} -> pure $ Length (length values)
        Just _ -> throwError $ RedisError.WrongType
