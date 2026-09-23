{-# LANGUAGE OverloadedStrings #-}

module Redis.Workflows.Set.Data where

import Data.ByteString (ByteString)
import Data.Maybe (isJust)
import Data.Time (NominalDiffTime)
import Redis.Data.Command (SetOption (SetOptionEX, SetOptionPX))
import Redis.Data.Error (RedisError (..))
import Resp.Data (Resp (SimpleString), ToResp (toResp))

newtype Key = Key ByteString
    deriving (Show)
newtype Value = Value ByteString
    deriving (Show)
data Options = Options {expiryTime :: Maybe NominalDiffTime}
    deriving (Show)

data Input = Input
    { key :: Key
    , value :: Value
    , options :: Options
    }
    deriving (Show)

data Reply = OK
    deriving (Show)

-- Serialization
deserializeOptions :: [SetOption] -> Either RedisError Options
deserializeOptions opts = Options <$> getExpiryTime opts

getExpiryTime :: [SetOption] -> Either RedisError (Maybe NominalDiffTime)
getExpiryTime os = go (filter isJust $ fmap f os)
  where
    go [] = Right Nothing
    go [o] = Right $ fmap msToDiff o
    go _ = Left ConflictingExpiryOptions

    f (SetOptionEX s) = Just (s * 1000)
    f (SetOptionPX ms) = Just ms

msToDiff :: (Integral a) => a -> NominalDiffTime
msToDiff ms = fromIntegral ms / 1000

instance ToResp Reply where
    toResp OK = SimpleString "OK"
