module Redis.Data.Table where

import Data.ByteString (ByteString)
import Data.Time (NominalDiffTime, UTCTime)

type Key = ByteString
type Value = ByteString

data RedisTable = RedisTable
    { redisSet :: Key -> Value -> SetOptions -> IO ()
    , redisGet :: Key -> IO (Maybe Value)
    }

data RedisRecord = RedisRecord
    { rValue :: Value
    , rInsertedAt :: UTCTime
    , rExpiryTime :: Maybe NominalDiffTime
    }
    deriving (Show)

data SetOptions = SetOptions
    { expiryTime :: Maybe NominalDiffTime
    }
    deriving (Show)
