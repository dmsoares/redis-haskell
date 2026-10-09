{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | A real @redis-server@, owned and driven by the test suite.

This module exists to keep the genuinely awkward parts of differential testing in
one place -- process lifecycle, state reset between runs, and deciding where one
reply ends -- so the properties that use it stay readable.

'ModelServer' is deliberately __opaque__. The only way to obtain one is
'withModelServer', so holding one is evidence that a live, ready server exists;
and because the socket is not reachable, 'runSequence' is the only way to talk to
it. That matters: a caller with the raw socket could skip the state reset, the
timeout, or the frame-completeness loop, which is every mistake this module was
written to prevent.

Two things are deliberately __not__ shared with the code under test:

* requests are encoded by 'encodeCommand' rather than @Resp.toBytes@. If
  @toBytes@ were wrong we would send malformed bytes to both implementations and
  they might agree -- masking the very bug we are hunting.

* reply boundaries are found by 'completeFrame' rather than @Resp.fromBytes@.
  An oracle that frames replies with the parser under test can be misled by a bug
  in it.

Both are small enough that duplicating them is cheaper than the coupling.
-}
module Redis.ModelServer (
    -- * Handle
    ModelServer,
    withModelServer,
    modelAvailable,

    -- * Talking to it
    Reply (..),
    runSequence,

    -- * Exposed for its own tests
    encodeCommand,
    completeFrame,
) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Network.Socket (
    Family (AF_INET),
    SockAddr (SockAddrInet),
    SocketOption (ReuseAddr),
    SocketType (Stream),
    bind,
    close,
    defaultProtocol,
    setSocketOption,
    socket,
    socketPort,
    tupleToHostAddress,
 )
import qualified Network.Simple.TCP as TCP
import System.Directory (findExecutable)
import System.IO (IOMode (WriteMode), openFile)
import System.Process (
    CreateProcess (std_err, std_out),
    StdStream (UseHandle),
    createProcess,
    proc,
    terminateProcess,
    waitForProcess,
 )
import System.Timeout (timeout)

-- | An opaque handle to a running server. See the module header for why.
data ModelServer = ModelServer
    { msSocket :: TCP.Socket
    , msLeftover :: IORef ByteString
    }

{- | What came back for one command.

A sum type rather than a sentinel 'ByteString', so "no reply" cannot be silently
compared against real reply bytes.
-}
data Reply
    = Reply ByteString
    | -- | nothing arrived within 'replyTimeoutMicros'; an empty array draws no reply at all
      NoReply
    | -- | the server hung up, as it does after a protocol error
      Closed
    deriving (Eq, Show)

-- | One second. Generous for a loopback request, short enough to fail fast.
replyTimeoutMicros :: Int
replyTimeoutMicros = 1000000

-- | Is a model available at all? Suites use this to skip rather than fail.
modelAvailable :: IO Bool
modelAvailable = isJust <$> findExecutable "redis-server"

{- | Start a server, hand it over, shut it down.

Spawned on an __ephemeral__ port rather than a fixed one. A fixed port means a
stray server from an earlier run silently answers your queries with its own
accumulated state -- which has happened, cost an afternoon, and made @--seed@
reproductions stop reproducing. It also means an orphaned server (from, say, a
@timeout@-killed test runner, which no @bracket@ can defend against) is harmless:
the next run picks a different port and this one persists nothing.
-}
withModelServer :: (ModelServer -> IO a) -> IO a
withModelServer action = do
    mExe <- findExecutable "redis-server"
    exe <- maybe (fail "redis-server is not on PATH -- run inside `nix develop`") pure mExe
    p <- freePort
    bracket (spawn exe p) shutdown $ \_ -> do
        waitUntilListening p attempts
        TCP.connect "127.0.0.1" (show p) $ \(sock, _) -> do
            leftover <- newIORef BS.empty
            action (ModelServer sock leftover)
  where
    attempts = 150 :: Int

    spawn exe p = do
        -- Redis logs on startup and we do not want it in the test output. Note
        -- this must not be CreatePipe-and-ignore: an undrained pipe deadlocks
        -- the child once its buffer fills.
        outNull <- openFile "/dev/null" WriteMode
        errNull <- openFile "/dev/null" WriteMode
        createProcess
            (proc exe ["--port", show p, "--save", "", "--appendonly", "no"])
                { std_out = UseHandle outNull
                , std_err = UseHandle errNull
                }

    shutdown (_, _, _, ph) = terminateProcess ph >> void (waitForProcess ph)

    -- createProcess returns once the process exists, not once it is listening.
    -- Polling a connect beats scraping "Ready to accept connections" from the
    -- log, which would couple us to redis's log format.
    waitUntilListening p n
        | n <= 0 = fail ("redis-server never started listening on port " <> show p)
        | otherwise = do
            r <- try (TCP.connect "127.0.0.1" (show p) (const (pure ())))
            case r of
                Right () -> pure ()
                Left (_ :: IOException) -> threadDelay 20000 >> waitUntilListening p (n - 1)

{- | Ask the kernel for an unused port by binding to 0, then release it.

There is a window between releasing and redis binding it. In practice that is
fine, and it trades a tiny race for the removal of a whole class of
cross-contamination bug.
-}
freePort :: IO Int
freePort = bracket (socket AF_INET Stream defaultProtocol) close $ \s -> do
    setSocketOption s ReuseAddr 1
    bind s (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
    fromIntegral <$> socketPort s

{- | Run a sequence of commands and collect one 'Reply' each, in order.

The @FLUSHALL@ is done here rather than left to callers because forgetting it is
invisible and poisonous: our own store is rebuilt per run while this server is
long-lived, so without a reset, run 12 compares a fresh store against a model
that still remembers runs 1-11.
-}
runSequence :: ModelServer -> [[ByteString]] -> IO [Reply]
runSequence ms frames = do
    _ <- exchange ms ["FLUSHALL"]
    traverse (exchange ms) frames

exchange :: ModelServer -> [ByteString] -> IO Reply
exchange ms ts = do
    TCP.send (msSocket ms) (encodeCommand ts)
    readOneReply ms

{- | Read exactly one reply, buffering whatever arrived beyond it.

The leftover buffer is not paranoia: a @recv@ can return bytes belonging to the
next reply, and discarding them would shift every subsequent reply by one -- a
failure that looks like a pile of unrelated divergences.
-}
readOneReply :: ModelServer -> IO Reply
readOneReply ms = readIORef (msLeftover ms) >>= go
  where
    go buf = case completeFrame buf of
        Just n -> do
            writeIORef (msLeftover ms) (BS.drop n buf)
            pure (Reply (BS.take n buf))
        Nothing -> do
            mChunk <- timeout replyTimeoutMicros (TCP.recv (msSocket ms) 4096)
            case mChunk of
                Nothing -> writeIORef (msLeftover ms) buf >> pure NoReply
                Just Nothing -> writeIORef (msLeftover ms) buf >> pure Closed
                Just (Just chunk) -> go (buf <> chunk)

{- | Encode a command the way a client does: an array of bulk strings.

Independent of @Resp.toBytes@ on purpose -- see the module header.
-}
encodeCommand :: [ByteString] -> ByteString
encodeCommand ts = "*" <> int (length ts) <> crlf <> BS.concat (bulk <$> ts)
  where
    bulk t = "$" <> int (BS.length t) <> crlf <> t <> crlf
    int = C8.pack . show
    crlf = "\r\n"

{- | How many leading bytes of the buffer form one complete RESP value, if any.

'Nothing' means "not yet" -- either genuinely truncated, or not RESP at all, in
which case the caller's timeout is what eventually ends the wait.

Independent of @Resp.Serialization@ on purpose -- see the module header. It only
needs to find boundaries, never to interpret values, which is why it is this
short.
-}
completeFrame :: ByteString -> Maybe Int
completeFrame buf = case BS.uncons buf of
    Nothing -> Nothing
    Just (c, _)
        | c `BS.elem` "+-:" -> lineEnd 0
        | c == 36 -> bulkString -- '$'
        | c == 42 -> array -- '*'
        | otherwise -> Nothing
  where
    -- Offset just past the CRLF ending the line that starts at i.
    lineEnd i = (+ 2) <$> findCrlf i
    findCrlf i
        | i + 1 >= BS.length buf = Nothing
        | BS.index buf i == 13 && BS.index buf (i + 1) == 10 = Just i
        | otherwise = findCrlf (i + 1)

    -- The declared length, and where the header line ends.
    header = do
        hdrEnd <- lineEnd 0
        n <- fst <$> C8.readInt (BS.take (hdrEnd - 3) (BS.drop 1 buf))
        pure (n, hdrEnd)

    bulkString = do
        (n, hdrEnd) <- header
        if n < 0
            then pure hdrEnd -- $-1, no body follows
            else
                let total = hdrEnd + n + 2
                 in if BS.length buf >= total then pure total else Nothing

    array = do
        (n, hdrEnd) <- header
        if n <= 0
            then pure hdrEnd -- *0 and *-1 have no elements
            else countElements n hdrEnd

    countElements 0 off = pure off
    countElements k off = do
        used <- completeFrame (BS.drop off buf)
        countElements (k - 1 :: Int) (off + used)
