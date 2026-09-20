{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}

module Redis.Workflows.Get where

import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)

import Redis.Data.Command (GetPayload (GetPayload))
import qualified Redis.Data.Store as Store
import Redis.Workflows.Get.Data (Input (Input, key), Key (Key), Reply (..))

data Env = Env {getKey :: Store.Key -> IO (Maybe Store.Value)}

workflow :: (MonadReader Env m, MonadIO m) => GetPayload -> m Reply
workflow = execute . deserializeInput

deserializeInput :: GetPayload -> Input
deserializeInput (GetPayload key) = Input (Key key)

execute :: (MonadReader Env m, MonadIO m) => Input -> m Reply
execute Input{key = Key k} = do
    get <- asks getKey
    liftIO $ do
        mValue <- get k
        pure $ maybe Null Value mValue
