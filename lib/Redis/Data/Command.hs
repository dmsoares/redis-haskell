{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Redis.Data.Command where

import Control.Applicative (Alternative (..))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C8
import qualified Data.Char as Char
import qualified Data.List as List
import Prelude hiding (fail)

import Control.Applicative.Combinators (choice)
import qualified Data.ByteString as BS
import Redis.Data.Error (RedisError (InvalidExpireTimeInSetCommand, NotAnInteger, SyntaxError, UnknownCommand, WrongNumberOfArguments))
import Resp (Resp (..))

data Command
    = Ping
    | Echo EchoPayload
    | Set SetPayload
    | Get GetPayload
    | RPush RPushPayload
    | LPush LPushPayload
    | LRange LRangePayload
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

data LPushPayload = LPushPayload
    { key :: ByteString
    , values :: [ByteString]
    }
    deriving (Show)

data LRangePayload = LRangePayload
    { key :: ByteString
    , start :: Int
    , stop :: Int
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
        "lpush" -> pLPush
        "lrange" -> pLRange
        _ -> fail $ UnknownCommand t

token :: Parser ByteString
token = Parser $ \case
    (b : bs) -> Right (b, bs)
    _ -> Left SyntaxError

eof :: Parser ()
eof = Parser $ \case
    [] -> Right ((), [])
    _ -> Left SyntaxError

lookahead :: Parser a -> Parser a
lookahead p = Parser $ \str ->
    case runCmd p str of
        Left err -> Left err
        Right (res, _) -> Right (res, str)

arityGuard :: Maybe Int -> Maybe Int -> ByteString -> Parser ()
arityGuard minArgs maxArgs name = lookahead $ do
    tks <- many token
    let l = length tks
    let valid = case (minArgs, maxArgs) of
            (Just min', Just max') -> l >= min' && l <= max'
            (Just min', _) -> l >= min'
            (_, Just max') -> l <= max'
            _ -> True
    if valid then pure () else fail $ WrongNumberOfArguments name

withError :: RedisError -> Parser a -> Parser a
withError e p = Parser $ \bs ->
    case runCmd p bs of
        Left _ -> Left e
        r -> r

pDecimal :: Parser Int
pDecimal = do
    t <- token
    maybe (fail NotAnInteger) (pure . fst) $ do
        n <- guardLiteral t
        C8.readInt n
  where
    guardLiteral bs
        | BS.all (`BS.elem` literals) bs = Just bs
        | otherwise = Nothing
    literals = C8.pack $ '-' : concatMap show [0 :: Int .. 9]

pPing :: Parser Command
pPing = pure Ping

pEcho :: Parser Command
pEcho = do
    _ <- arityGuard (pure 1) (pure 1) "echo"
    msg <- token
    pure $ Echo (EchoPayload msg)

pGet :: Parser Command
pGet = do
    _ <- arityGuard (pure 1) (pure 1) "get"
    k <- token
    pure $ Get (GetPayload k)

pSet :: Parser Command
pSet = do
    _ <- arityGuard (pure 2) Nothing "set"
    (k, v) <- liftA2 (,) token token
    opts <- pSetOptions
    pure $ Set (SetPayload k v opts)

pRPush :: Parser Command
pRPush = do
    _ <- arityGuard (pure 2) Nothing "rpush"
    k <- token
    vs <- many token
    case vs of
        [] -> empty
        _ -> pure $ RPush (RPushPayload k vs)

pLPush :: Parser Command
pLPush = do
    _ <- arityGuard (pure 2) Nothing "lpush"
    k <- token
    vs <- many token
    case vs of
        [] -> empty
        _ -> pure $ LPush (LPushPayload k vs)

pLRange :: Parser Command
pLRange = do
    _ <- arityGuard (pure 3) (pure 3) "lrange"
    k <- token
    start <- pDecimal
    stop <- pDecimal
    pure $ LRange $ LRangePayload k start stop

pSetOptions :: Parser [SetOption]
pSetOptions = do
    opts <-
        many . choice $
            [ ("EX" :: String,) <$> (pName "EX" >> pDecimal)
            , ("PX",) <$> (pName "PX" >> pDecimal)
            ]
    eof

    let exs = byLabel "EX" opts
    let pxs = byLabel "PX" opts

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
    idxs = fmap fst
    partition pxs = List.partition ((> 0) . snd) (zip [0 :: Int ..] pxs)
    byLabel label = map snd . filter ((== label) . fst)

pName :: ByteString -> Parser ByteString
pName name = do
    t <- lower <$> token
    if t == lower name
        then pure t
        else empty

lower :: ByteString -> ByteString
lower = C8.map Char.toLower

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
