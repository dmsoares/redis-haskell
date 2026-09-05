module Redis.Domain.Result where

import Data.ByteString (ByteString)

data Result
    = Echo ByteString
    | Pong
    | SetOK
    | GetNull
    | GetValue ByteString
    deriving (Show)
