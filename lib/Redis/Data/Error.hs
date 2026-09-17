{-# LANGUAGE OverloadedStrings #-}

module Redis.Data.Error (RedisError (..)) where

import Data.ByteString (ByteString)
import Resp.Data (ToResp (..), simpleError)

data RedisError
    = UnknownCommand
    | ConflictingExpiryOptions
    | MalformedExpiry ByteString
    deriving (Show, Eq)

instance ToResp RedisError where
    toResp UnknownCommand = simpleError "ERR unknown command"
    toResp ConflictingExpiryOptions = simpleError "ERR conflicting expiry options"
    toResp (MalformedExpiry s) = simpleError $ "ERR malformed expiry:" <> s
