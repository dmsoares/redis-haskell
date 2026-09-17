module Redis.Data.Error (RedisError (..)) where

import Data.ByteString (ByteString)
import Resp.Data (ToResp (..), nullBulkString)

{- | Every way a command can fail, as a domain value rather than a `Nothing`.
  Carrying the reason is the point: `MaybeT` could only ever say "something
  went wrong", which is why both workflows used to end in `UnknownError`.
-}
data RedisError
    = UnknownCommand
    | ConflictingExpiryOptions
    | MalformedExpiry ByteString
    deriving (Show, Eq)

-- Non-orphan: the instance lives with the type, so it is always in scope.
--
-- NOTE: RESP has no error constructor yet, so every failure still renders as
-- `$-1`, exactly as before this refactor. Adding `SimpleError` to `Resp` is
-- what turns these into real `-ERR ...` replies; that is a separate change.
instance ToResp RedisError where
    toResp _ = nullBulkString
