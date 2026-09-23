{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Redis.Data.Error (RedisError (..)) where

import Codec.Binary.UTF8.String (encode)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Resp.Data (Resp (SimpleError), ToResp (..))

data RedisError
    = UnknownCommand
    | ConflictingExpiryOptions
    | MalformedExpiry ByteString
    | WrongDataType String
    deriving (Show, Eq)

instance ToResp RedisError where
    toResp UnknownCommand = SimpleError "ERR unknown command"
    toResp ConflictingExpiryOptions = SimpleError "ERR conflicting expiry options"
    toResp (MalformedExpiry s) = SimpleError $ "ERR malformed expiry:" <> s
    toResp (WrongDataType expected) = SimpleError $ "ERR wrong data type. Expected " <> BS.pack (encode expected)
