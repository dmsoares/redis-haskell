{-# LANGUAGE OverloadedStrings #-}

module Redis.Data.Error (RedisError (..)) where

import Data.ByteString (ByteString)
import Resp.Data (Resp (SimpleError), ToResp (..))

data RedisError
    = UnknownCommand
    | InvalidExpireTimeInSetCommand
    | MalformedExpiry ByteString
    | WrongType
    | WrongNumberOfArgumentsForRPushCommand
    | SyntaxError
    deriving (Show, Eq)

instance ToResp RedisError where
    toResp UnknownCommand = SimpleError "ERR unknown command"
    toResp InvalidExpireTimeInSetCommand = SimpleError "ERR invalid expire time in 'set' command"
    toResp (MalformedExpiry s) = SimpleError $ "ERR malformed expiry:" <> s
    toResp WrongType = SimpleError $ "WRONGTYPE Operation against a key holding the wrong kind of value"
    toResp WrongNumberOfArgumentsForRPushCommand = SimpleError $ "ERR wrong number of arguments for 'rpush' command"
    toResp SyntaxError = SimpleError $ "ERR syntax error"
