module Redis.Data.Store where

import Data.ByteString (ByteString)
import Data.Time (NominalDiffTime)

type Key = ByteString
type Value = ByteString

data RedisStore = RedisStore
    { redisSet :: Key -> Value -> SetOptions -> IO ()
    , redisGet :: Key -> IO (Maybe Value)
    }

data SetOptions = SetOptions
    { expiryTime :: Maybe NominalDiffTime
    }
    deriving (Show)
