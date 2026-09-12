{-# LANGUAGE OverloadedStrings #-}

module Redis.Workflows.Set.Data where

import Control.Applicative (asum)
import Data.ByteString (ByteString)
import Data.Time (NominalDiffTime)
import Redis.Data.Command (SetOption (SetOptionEX, SetOptionPX))
import Resp.Data (ToResp (toResp), nullBulkString, simpleString)

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

data Reply = OK | UnknownError
    deriving (Show)

-- Serialization
deserializeOptions :: [SetOption] -> Options
deserializeOptions opts = Options{expiryTime = getExpiryTime opts}

getExpiryTime :: [SetOption] -> Maybe NominalDiffTime
getExpiryTime opts = msToDiff <$> (asum $ fmap f opts)
  where
    f (SetOptionEX s) = Just (s * 1000)
    f (SetOptionPX ms) = Just ms

msToDiff :: (Integral a) => a -> NominalDiffTime
msToDiff ms = fromIntegral ms / 1000

instance ToResp Reply where
    toResp OK = simpleString "OK"
    toResp UnknownError = nullBulkString
