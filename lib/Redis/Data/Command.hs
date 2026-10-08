{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Redis.Data.Command where

import Control.Applicative (Alternative (..))
import Control.Applicative.Combinators (choice)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.List as List
import Data.Text (Text, toLower)
import Data.Text.Encoding (decodeASCII, encodeUtf8)
import Prelude hiding (fail)

import Redis.Data.Error (RedisError (InvalidExpireTimeInSetCommand, SyntaxError, UnknownCommand))
import Resp (Resp (..), toBytes)

data Command
    = Ping
    | Echo EchoPayload
    | Set SetPayload
    | Get GetPayload
    | RPush RPushPayload
    deriving (Show)

newtype EchoPayload = EchoPayload {message :: ByteString}
    deriving (Show)

data SetPayload = SetPayload
    { key :: ByteString
    , value :: ByteString
    , options :: [SetOption]
    }
    deriving (Show)

data SetOption
    = SetOptionEX Int
    | SetOptionPX Int
    deriving (Show)

newtype GetPayload = GetPayload
    { key :: ByteString
    }
    deriving (Show)

data RPushPayload = RPushPayload
    { key :: ByteString
    , values :: [ByteString]
    }
    deriving (Show)

-- Serialization
fromResp :: Resp -> Either RedisError Command
fromResp resp = flip runParser resp $ pCommand -- choice [pPing, pEcho, pGet, pSet, pRPush]

-- Lexer
commandTokens :: Resp -> Either RedisError [ByteString]
commandTokens (Array elems) = traverse bulk elems
  where
    bulk (BulkString bytes) = Right bytes
    bulk _ = Left SyntaxError
commandTokens _ = Left SyntaxError

-- Parser
newtype Parser a = Parser {runCmd :: [ByteString] -> Either RedisError (a, [ByteString])}
    deriving (Functor)

runParser :: Parser a -> Resp -> Either RedisError a
runParser p bs = do
    ts <- commandTokens bs
    (cmd, _) <- runCmd p ts
    pure cmd

instance Applicative Parser where
    pure x = Parser $ \bs -> (Right (x, bs))

    p1 <*> p2 = Parser $ \bs -> do
        (f, bs') <- runCmd p1 bs
        (a, bs'') <- runCmd p2 bs'
        pure $ (f a, bs'')

instance Alternative Parser where
    empty = Parser $ const (Left SyntaxError)

    p1 <|> p2 = Parser $ \bs ->
        case runCmd p1 bs of
            Right x -> pure x
            Left _ -> runCmd p2 bs

instance Monad Parser where
    p >>= k = Parser $ \bs -> do
        (a, bs') <- runCmd p bs
        runCmd (k a) bs'

fail :: RedisError -> Parser a
fail e = Parser $ \_ -> Left e

token :: Parser ByteString
token = Parser $ \case
    (b : bs) -> Right (b, bs)
    _ -> Left SyntaxError

pInt :: Parser Int
pInt = do
    t <- token
    pure $ maybe (-1) fst (BC.readInt t)

pPing :: Parser Command
pPing = do
    _ <- pName "ping"
    pure Ping

pEcho :: Parser Command
pEcho = do
    _ <- pName "echo"
    msg <- token
    pure $ Echo (EchoPayload msg)

pGet :: Parser Command
pGet = do
    _ <- pName "get"
    k <- token
    pure $ Get (GetPayload k)

pSet :: Parser Command
pSet = do
    _ <- pName "set"
    k <- token
    v <- token
    opts <- pSetOptions
    pure $ Set (SetPayload k v opts)

-- >>> fromResp $ Array [BulkString "SET", BulkString "c", BulkString "", BulkString "EX", BulkString "-14", BulkString "EX", BulkString "14", BulkString "EX", BulkString "-14", BulkString "EX", BulkString "14"]
-- Left InvalidExpireTimeInSetCommand

pSetOptions :: Parser [SetOption]
pSetOptions = do
    exps <- many . choice $ [("EX" :: Text,) <$> (pName "EX" >> pInt), ("PX",) <$> (pName "PX" >> pInt)]

    let exs = map snd $ filter ((== "EX") . fst) exps
    let pxs = map snd $ filter ((== "PX") . fst) exps

    case (length exs > 0, length pxs > 0) of
        (True, True) -> empty
        (False, False) -> pure []
        (True, _) -> select SetOptionEX exs
        (_, True) -> select SetOptionPX pxs
  where
    select constructor exps =
        let (valid, invalid) = partition exps
         in case (length valid > 0, length invalid > 0) of
                (False, False) -> pure []
                (False, True) -> fail InvalidExpireTimeInSetCommand
                (True, False) -> pure . pure . constructor . snd . last $ valid
                (True, True) ->
                    if (maximum (idxs valid)) > (maximum (idxs invalid))
                        then pure . pure . constructor . snd . last $ valid
                        else fail InvalidExpireTimeInSetCommand
    idxs xs = fst <$> xs
    partition pxs = List.partition ((> 0) . snd) (zip [0 :: Int ..] pxs)

pRPush :: Parser Command
pRPush = do
    _ <- pName "rpush"
    k <- token
    vs <- many token
    pure $ RPush (RPushPayload k vs)

pName :: Text -> Parser ByteString
pName name = do
    t <- token
    let parsed = toLower (decodeASCII t)
    if parsed == toLower name
        then pure $ encodeUtf8 parsed
        else empty

pCommand :: Parser Command
pCommand = do
    name <- choice $ (pName <$> cmds)
    case name of
        "ping" -> pure Ping
        "echo" -> do msg <- token; pure $ Echo (EchoPayload msg)
        "get" -> do k <- token; pure $ Get (GetPayload k)
        "set" -> do k <- token; v <- token; opts <- pSetOptions; pure $ Set (SetPayload k v opts)
        "rpush" -> do k <- token; vs <- many token; pure $ RPush (RPushPayload k vs)
        _ -> fail UnknownCommand
  where
    cmds :: [Text]
    cmds =
        [ "ping"
        , "echo"
        , "get"
        , "set"
        , "rpush"
        ]
