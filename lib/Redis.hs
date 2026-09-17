{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis (RedisTable, newRedisTable, reply) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (ReaderT (runReaderT))

import Redis.Data.Command (Command (..), fromResp)
import Redis.Data.Error (RedisError (UnknownCommand))
import Redis.Data.Table (RedisTable (..))
import Redis.Table (newRedisTable)
import qualified Redis.Workflows.Echo as Echo
import qualified Redis.Workflows.Get as Get
import qualified Redis.Workflows.Ping as Ping
import qualified Redis.Workflows.Set as Set
import Resp (Resp (..), ToResp, toResp)

reply :: RedisTable -> Resp -> IO Resp
reply table query = dispatch query table

-- Dispatches to specific workflow
dispatch :: Resp -> RedisTable -> IO Resp
dispatch query RedisTable{redisSet, redisGet} = case fromResp query of
    Nothing -> runPure $ UnknownCommand
    Just cmd -> case cmd of
        Ping -> runPure Ping.workflow
        Echo payload -> runPure $ Echo.workflow payload
        Set payload -> runSet (Set.Env redisSet) (Set.workflow payload)
        Get payload -> runGet (Get.Env redisGet) (Get.workflow payload)
  where
    runPure :: (ToResp a) => a -> IO Resp
    runPure = pure . toResp
    runSet env = fmap (either toResp toResp) . runExceptT . flip runReaderT env
    runGet env = fmap toResp . flip runReaderT env
