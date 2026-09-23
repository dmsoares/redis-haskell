{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis (RedisStore, newRedisStore, reply) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (ReaderT (runReaderT))
import Data.Time (UTCTime)

import Redis.Data.Command (Command (..), fromResp)
import Redis.Data.Error (RedisError (UnknownCommand))
import Redis.Data.Store (RedisStore (..))
import Redis.Store (newRedisStore)
import qualified Redis.Workflows.Echo as Echo
import qualified Redis.Workflows.Get as Get
import qualified Redis.Workflows.Ping as Ping
import qualified Redis.Workflows.Set as Set
import Resp (Resp (..), ToResp, toResp)

reply :: UTCTime -> RedisStore -> Resp -> IO Resp
reply = dispatch

-- Dispatches to specific workflow
dispatch :: UTCTime -> RedisStore -> Resp -> IO Resp
dispatch receivedAt RedisStore{redisSet, redisGet} query =
    case fromResp query of
        Nothing -> runPure $ UnknownCommand
        Just cmd -> case cmd of
            Ping -> runPure Ping.workflow
            Echo payload -> runPure $ Echo.workflow payload
            Set payload -> runEffectful (Set.Env receivedAt redisSet) (Set.workflow payload)
            Get payload -> runEffectful (Get.Env receivedAt redisGet) (Get.workflow payload)
  where
    runPure :: (ToResp a) => a -> IO Resp
    runPure = pure . toResp
    runEffectful env = fmap (either toResp toResp) . runExceptT . flip runReaderT env
