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
import qualified Data.Char as Char
import qualified Data.List as List
import Data.Text (Text)
import Prelude hiding (fail)

import Redis.Data.Error (RedisError (InvalidExpireTimeInSetCommand, NotAnInteger, SyntaxError, UnknownCommand, WrongNumberOfArguments))
import Resp (Resp (..))

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
fromResp resp = flip runParser resp $ pCommand

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

pCommand :: Parser Command
pCommand = do
    t <- token
    case lower t of
        "ping" -> pure Ping
        "echo" -> pEcho
        "get" -> pGet
        "set" -> pSet
        "rpush" -> pRPush
        _ -> fail $ UnknownCommand t

token :: Parser ByteString
token = Parser $ \case
    (b : bs) -> Right (b, bs)
    _ -> Left SyntaxError

eof :: Parser ()
eof = Parser $ \case
    [] -> Right ((), [])
    _ -> Left SyntaxError

withError :: RedisError -> Parser a -> Parser a
withError e p = Parser $ \bs ->
    case runCmd p bs of
        Left _ -> Left e
        r -> r

pInt :: Parser Int
pInt = do
    t <- token
    maybe
        (fail NotAnInteger)
        (pure . fst)
        (BC.readInt t)

pPing :: Parser Command
pPing = pure Ping

pEcho :: Parser Command
pEcho = do
    msg <- withE token
    withE eof
    pure $ Echo (EchoPayload msg)
  where
    withE = withError (WrongNumberOfArguments "echo")

pGet :: Parser Command
pGet = do
    k <- withE token
    withE eof
    pure $ Get (GetPayload k)
  where
    withE = withError (WrongNumberOfArguments "get")

pSet :: Parser Command
pSet = do
    (k, v) <- withE $ liftA2 (,) token token
    opts <- pSetOptions
    eof
    pure $ Set (SetPayload k v opts)
  where
    withE = withError (WrongNumberOfArguments "set")

pRPush :: Parser Command
pRPush = do
    k <- withE token
    vs <- many token
    case vs of
        [] -> withE empty
        _ -> pure $ RPush (RPushPayload k vs)
  where
    withE = withError (WrongNumberOfArguments "rpush")

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

pName :: ByteString -> Parser ByteString
pName name = do
    t <- lower <$> token
    if t == lower name
        then pure t
        else empty

lower :: ByteString -> ByteString
lower = BC.map Char.toLower

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
