{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Redis.Data.Error (RedisError (..)) where

import Codec.Binary.UTF8.String (encode)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Resp.Data (ToResp (..), simpleError)

data RedisError
    = UnknownCommand
    | ConflictingExpiryOptions
    | MalformedExpiry ByteString
    | WrongDataType String
    deriving (Show, Eq)

instance ToResp RedisError where
    toResp UnknownCommand = simpleError "ERR unknown command"
    toResp ConflictingExpiryOptions = simpleError "ERR conflicting expiry options"
    toResp (MalformedExpiry s) = simpleError $ "ERR malformed expiry:" <> s
    toResp (WrongDataType expected) = simpleError $ "ERR wrong data type. Expected " <> BS.pack (encode expected)
