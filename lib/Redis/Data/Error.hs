{-# LANGUAGE OverloadedStrings #-}

module Redis.Data.Error (RedisError (..)) where

import Data.ByteString (ByteString)
import Resp.Data (Resp (SimpleError), ToResp (..))

data RedisError
    = UnknownCommand ByteString
    | InvalidExpireTimeInSetCommand
    | MalformedExpiry ByteString
    | WrongType
    | WrongNumberOfArguments ByteString
    | NotAnInteger
    | SyntaxError
    deriving (Show, Eq)

instance ToResp RedisError where
    toResp (UnknownCommand cmd) = SimpleError $ "ERR unknown command '" <> cmd <> "'"
    toResp InvalidExpireTimeInSetCommand = SimpleError "ERR invalid expire time in 'set' command"
    toResp (MalformedExpiry s) = SimpleError $ "ERR malformed expiry:" <> s
    toResp NotAnInteger = SimpleError $ "ERR value is not an integer or out of range"
    toResp WrongType = SimpleError $ "WRONGTYPE Operation against a key holding the wrong kind of value"
    toResp (WrongNumberOfArguments cmd) = SimpleError $ "ERR wrong number of arguments for '" <> cmd <> "' command"
    toResp SyntaxError = SimpleError $ "ERR syntax error"
