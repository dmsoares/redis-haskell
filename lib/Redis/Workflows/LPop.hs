{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.LPop where

import Control.Monad.Except (MonadError (throwError))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, asks)

import Data.Maybe (fromJust, isJust)
import Redis.Data.Command (LPopPayload (LPopPayload))
import Redis.Data.DataType (RedisValue (RedisListValue, RedisStringValue))
import Redis.Data.Error (RedisError)
import qualified Redis.Data.Error as RedisError
import Redis.Data.Record (RedisRecord (RedisRecord, value))
import qualified Redis.Data.Store as Store
import Redis.Workflows.LPop.Data (Count (Count), Input (Input, count, key), Key (Key), Reply (NoValue, NoValues, Value, Values))

data Env = Env
    { getKey :: Store.Key -> IO (Maybe RedisRecord)
    , setKey :: Store.Key -> RedisRecord -> IO ()
    , deleteKey :: Store.Key -> IO ()
    }

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => LPopPayload -> m Reply
workflow = execute . deserializeInput

deserializeInput :: LPopPayload -> Input
deserializeInput (LPopPayload key count) =
    Input (Key key) $ do
        c <- count
        pure $ Count c

execute :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => Input -> m Reply
-- no count arg
execute Input{key = Key k, count = Nothing} = do
    get <- asks getKey
    set <- asks setKey
    delete <- asks deleteKey

    mRecord <- liftIO $ get k

    case mRecord of
        Nothing -> pure NoValue
        Just RedisRecord{value = RedisListValue []} -> pure NoValue
        Just RedisRecord{value = RedisListValue [RedisStringValue v]} -> do
            liftIO $ delete k
            pure $ Value v
        Just rec@RedisRecord{value = RedisListValue (RedisStringValue s : vs)} -> do
            let newRecord = rec{value = RedisListValue vs}
            liftIO $ set k newRecord
            pure $ Value s
        Just _ -> throwError $ RedisError.WrongType
-- with count arg
execute Input{key = Key k, count = Just (Count n)} = do
    get <- asks getKey
    set <- asks setKey
    delete <- asks deleteKey

    mRecord <- liftIO $ get k

    case mRecord of
        Nothing -> pure NoValues
        Just RedisRecord{value = RedisListValue []} -> pure NoValues
        Just RedisRecord{value = RedisListValue [RedisStringValue v]} -> do
            liftIO $ delete k
            pure $ Values [v]
        Just rec@RedisRecord{value = RedisListValue vs} -> do
            let newList = drop n vs
            let newRecord = rec{value = RedisListValue newList}
            liftIO $ set k newRecord
            pure . Values $ extract (take n vs)
        Just _ -> throwError $ RedisError.WrongType
  where
    extract = map fromJust . filter isJust . map extract'
    extract' (RedisStringValue s) = Just s
    extract' _ = Nothing
