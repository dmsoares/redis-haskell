{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Redis.Data.Command where

import Control.Applicative (Alternative (..))
import Control.Applicative.Combinators (choice)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text, toLower)
import Data.Text.Encoding (decodeASCII)

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
    , value :: [ByteString]
    }
    deriving (Show)

-- Serialization
fromResp :: Resp -> Maybe Command
fromResp resp = flip runParser resp $ choice [pPing, pEcho, pGet, pSet, pRPush]

parseSetOptions :: [ByteString] -> [SetOption]
parseSetOptions ("EX" : s : dts) = SetOptionEX (parseInt s) : parseSetOptions dts
parseSetOptions ("PX" : ms : dts) = SetOptionPX (parseInt ms) : parseSetOptions dts
parseSetOptions _ = []

parseInt :: ByteString -> Int
parseInt bs = maybe (-1) fst (BC.readInt bs)

-- Lexer
commandTokens :: Resp -> Maybe [ByteString]
commandTokens (Array elems) = traverse bulk elems
  where
    bulk (BulkString bytes) = Just bytes
    bulk _ = Nothing
commandTokens _ = Nothing

-- Parser
newtype Parser a = Parser {runCmd :: [ByteString] -> Maybe (a, [ByteString])}
    deriving (Functor)

instance Applicative Parser where
    pure x = Parser $ \bs -> (Just (x, bs))

    p1 <*> p2 = Parser $ \bs -> do
        (f, bs') <- runCmd p1 bs
        (a, bs'') <- runCmd p2 bs'
        pure $ (f a, bs'')

instance Alternative Parser where
    empty = Parser $ const Nothing

    p1 <|> p2 = Parser $ \bs ->
        case runCmd p1 bs of
            Just x -> pure x
            Nothing -> runCmd p2 bs

instance Monad Parser where
    p >>= k = Parser $ \bs -> do
        (a, bs') <- runCmd p bs
        runCmd (k a) bs'

token :: Parser ByteString
token = Parser $ \case
    (b : bs) -> Just (b, bs)
    _ -> Nothing

runParser :: Parser Command -> Resp -> Maybe Command
runParser p bs = do
    ts <- commandTokens bs
    (cmd, _) <- runCmd p ts
    pure cmd

pPing :: Parser Command
pPing = do
    _ <- pCommandName "ping"
    pure Ping

pEcho :: Parser Command
pEcho = do
    _ <- pCommandName "echo"
    msg <- token
    pure $ Echo (EchoPayload msg)

pGet :: Parser Command
pGet = do
    _ <- pCommandName "get"
    k <- token
    pure $ Get (GetPayload k)

pSet :: Parser Command
pSet = do
    _ <- pCommandName "set"
    k <- token
    v <- token
    opts <- many token
    pure $ Set (SetPayload k v (parseSetOptions opts))

pRPush :: Parser Command
pRPush = do
    _ <- pCommandName "rpush"
    k <- token
    vs <- some token
    pure $ RPush (RPushPayload k vs)

pCommandName :: Text -> Parser ByteString
pCommandName name = do
    t <- token
    if toLower (decodeASCII t) == toLower name
        then pure t
        else empty
