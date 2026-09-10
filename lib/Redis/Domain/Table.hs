module Redis.Domain.Table where

import Data.ByteString (ByteString)
import Data.Time (NominalDiffTime, UTCTime)

type Key = ByteString
type Value = ByteString
type ExpiryTime = NominalDiffTime
type Milliseconds = Int

data RedisTable = RedisTable
    { redisSet :: Key -> Value -> SetOptions -> IO ()
    , redisGet :: Key -> IO (Maybe Value)
    }

data RedisRecord = RedisRecord
    { rValue :: Value
    , rInsertedAt :: UTCTime
    , rExpiryTime :: Maybe ExpiryTime
    }
    deriving (Show)

data SetOptions = SetOptions
    { expiryTime :: Maybe ExpiryTime
    }
    deriving (Show)

data SetResult = SetOK
    deriving (Show)
data GetResult = GetNull | GetValue ByteString
    deriving (Show)
