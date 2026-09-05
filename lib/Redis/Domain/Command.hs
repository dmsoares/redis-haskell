{-# LANGUAGE OverloadedStrings #-}

module Redis.Domain.Command where

import Control.Applicative (asum)
import Data.ByteString (ByteString)
import Data.Time (NominalDiffTime)

data Command
    = Ping
    | Echo ByteString
    | Set ByteString ByteString [SetOption]
    | Get ByteString
    deriving (Show)

data SetOption
    = SetOptionEX Int
    | SetOptionPX Int
    deriving (Show)

getExpiryTime :: [SetOption] -> Maybe NominalDiffTime
getExpiryTime opts = msToDiff <$> (asum $ fmap f opts)
  where
    f (SetOptionEX s) = Just (s * 1000)
    f (SetOptionPX ms) = Just ms

msToDiff :: (Integral a) => a -> NominalDiffTime
msToDiff ms = fromIntegral ms / 1000
