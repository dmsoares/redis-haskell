{-# LANGUAGE NamedFieldPuns #-}

module Redis (RedisStore, newRedisStore, reply) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (ReaderT (runReaderT))
import Data.Time (UTCTime)

import Redis.Data.Command (Command (..), fromResp)
import Redis.Data.Store (RedisStore)
import qualified Redis.Data.Store as Store
import Redis.Store (newRedisStore)
import qualified Redis.Workflows.Echo as Echo
import qualified Redis.Workflows.Get as Get
import qualified Redis.Workflows.LRange as LRange
import qualified Redis.Workflows.Ping as Ping
import qualified Redis.Workflows.RPush as RPush
import qualified Redis.Workflows.Set as Set
import Resp (Resp (..), ToResp, toResp)

reply :: UTCTime -> RedisStore -> Resp -> IO Resp
reply = dispatch

-- Dispatches to specific workflow
dispatch :: UTCTime -> RedisStore -> Resp -> IO Resp
dispatch receivedAt store query =
    case fromResp query of
        Left e -> runPure $ e
        Right cmd -> case cmd of
            Ping -> runPure Ping.workflow
            Echo payload -> runPure $ Echo.workflow payload
            Set payload -> runEffectful (Set.Env receivedAt (Store.set store)) (Set.workflow payload)
            Get payload -> runEffectful (Get.Env receivedAt (Store.get receivedAt store)) (Get.workflow payload)
            RPush payload -> runEffectful (RPush.Env receivedAt (Store.get receivedAt store) (Store.set store)) (RPush.workflow payload)
            LRange payload -> runEffectful (LRange.Env (Store.get receivedAt store)) (LRange.workflow payload)
  where
    runPure :: (ToResp a) => a -> IO Resp
    runPure = pure . toResp
    runEffectful env = fmap (either toResp toResp) . runExceptT . flip runReaderT env
