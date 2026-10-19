{-# LANGUAGE FlexibleContexts #-}

module Redis.Workflows.LRange where

import Control.Monad.Except (MonadError (throwError))
import Control.Monad.Reader (MonadIO, MonadReader, asks, liftIO)
import Data.ByteString (ByteString)

import Redis.Data.Command (LRangePayload (LRangePayload))
import Redis.Data.DataType (RedisValue (RedisListValue), toByteStrings)
import Redis.Data.Error (RedisError)
import qualified Redis.Data.Error as RedisError
import Redis.Data.Record (RedisRecord (..))
import qualified Redis.Data.Store as Store
import Resp.Data (Resp (Array, BulkString), ToResp (toResp))

newtype Key = Key ByteString
    deriving (Show)
newtype Start = Start Int
    deriving (Show)
newtype Stop = Stop Int
    deriving (Show)

data Input = Input
    { key :: Key
    , start :: Start
    , stop :: Stop
    }
    deriving (Show)

newtype Reply = Values [ByteString]
    deriving (Show)

instance ToResp Reply where
    toResp (Values xs) = Array $ BulkString <$> xs

data Env = Env {getKey :: Store.Key -> IO (Maybe RedisRecord)}

workflow :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => LRangePayload -> m Reply
workflow = execute . deserializeInput

deserializeInput :: LRangePayload -> Input
deserializeInput (LRangePayload key start stop) = Input (Key key) (Start start) (Stop stop)

execute :: (MonadReader Env m, MonadError RedisError m, MonadIO m) => Input -> m Reply
execute Input{key = Key k, start = Start start, stop = Stop stop} = do
    get <- asks getKey
    mRecord <- liftIO $ get k
    case mRecord of
        Nothing -> pure $ Values []
        Just RedisRecord{value = RedisListValue values} -> do
            let values' = slice values start stop
            pure $ Values (concatMap toByteStrings values')
        Just _ -> throwError $ RedisError.WrongType
  where
    slice values start stop =
        let len = length values
            start' = computeBound start len
            stop' = 1 + computeBound stop len
         in if stop' >= start'
                then drop start' $ take stop' values
                else []
    computeBound n len
        | n < 0 = (len + 1) + n
        | otherwise = n

-- >>> computeBound' (13) 36
-- 13
--
-- >>> computeBound' (-24) 36
-- 13
