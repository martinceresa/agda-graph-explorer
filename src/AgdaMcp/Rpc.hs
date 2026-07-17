{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Minimal, hand-rolled MCP (Model Context Protocol) plumbing over a
-- JSON-RPC 2.0 stdio transport. No SDK: the wire format is
-- newline-delimited JSON objects on stdin/stdout (logs go to stderr).
--
-- This module is transport-only. It decodes each line into an 'RpcMsg',
-- hands it to a caller-supplied dispatcher, and writes back whatever the
-- dispatcher returns (a 'Nothing' result means "this was a notification,
-- send no reply"). Lifecycle (@initialize@ / @ping@ / @tools\/list@ /
-- @tools\/call@) is implemented by the dispatcher in "AgdaMcp.Tools",
-- not here, so this stays a dumb pipe.
module AgdaMcp.Rpc
  ( RpcMsg(..)
  , resultResponse
  , errorResponse
  , runStdioLoop
  , protocolVersionDefault
    -- * JSON-RPC error codes
  , codeParseError
  , codeMethodNotFound
  , codeInvalidParams
  , codeInternalError
  ) where

import           Control.Exception    (IOException, catch)
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BL
import           Data.Aeson           (Value (..), eitherDecodeStrict', encode,
                                       object, (.=))
import qualified Data.Aeson.KeyMap    as KM
import           Data.Text            (Text)
import           System.IO            (BufferMode (..), hFlush, hSetBuffering,
                                       hSetEncoding, stderr, stdin, stdout, utf8)

-- | The MCP protocol revision we advertise when the client does not pin
-- one. Version negotiation in practice is "echo the client's requested
-- version" (see "AgdaMcp.Tools"); this default only fires for a client
-- that omits @protocolVersion@ from @initialize@.
protocolVersionDefault :: Text
protocolVersionDefault = "2025-06-18"

codeParseError, codeMethodNotFound, codeInvalidParams, codeInternalError :: Int
codeParseError     = -32700
codeMethodNotFound = -32601
codeInvalidParams  = -32602
codeInternalError  = -32603

-- | A decoded JSON-RPC request or notification. A request carries an
-- @id@ (and expects a reply); a notification has 'rpcId' = 'Nothing'.
data RpcMsg = RpcMsg
  { rpcId     :: !(Maybe Value) -- ^ 'Nothing' for notifications.
  , rpcMethod :: !(Maybe Text)
  , rpcParams :: !Value         -- ^ 'Null' when @params@ is absent.
  }

parseRpcMsg :: BS.ByteString -> Either String RpcMsg
parseRpcMsg bs = case eitherDecodeStrict' bs of
  Left e           -> Left e
  Right (Object o) -> Right RpcMsg
    { rpcId     = KM.lookup "id" o
    , rpcMethod = case KM.lookup "method" o of
                    Just (String m) -> Just m
                    _               -> Nothing
    , rpcParams = maybe Null id (KM.lookup "params" o)
    }
  Right _          -> Left "JSON-RPC message is not an object"

-- | Build a successful JSON-RPC response @{jsonrpc, id, result}@.
resultResponse :: Value -> Value -> Value
resultResponse i r =
  object ["jsonrpc" .= ("2.0" :: Text), "id" .= i, "result" .= r]

-- | Build a JSON-RPC error response @{jsonrpc, id, error:{code,message}}@.
errorResponse :: Value -> Int -> Text -> Value
errorResponse i code msg =
  object [ "jsonrpc" .= ("2.0" :: Text)
         , "id"      .= i
         , "error"   .= object ["code" .= code, "message" .= msg]
         ]

-- | Read newline-delimited JSON-RPC messages from stdin until EOF,
-- dispatching each. The dispatcher returns 'Just' a response value to
-- send, or 'Nothing' for notifications (no reply on the wire).
runStdioLoop :: (RpcMsg -> IO (Maybe Value)) -> IO ()
runStdioLoop dispatch = do
  hSetBuffering stdin  (BlockBuffering Nothing)
  hSetBuffering stdout (BlockBuffering Nothing)
  hSetBuffering stderr LineBuffering
  hSetEncoding  stderr utf8
  loop
  where
    loop = do
      ml <- (Just <$> BS.hGetLine stdin)
              `catch` \(_ :: IOException) -> pure Nothing  -- EOF / closed pipe
      case ml of
        Nothing -> pure ()
        Just bs
          | BS.all isWsByte bs -> loop          -- skip blank keep-alive lines
          | otherwise -> do
              case parseRpcMsg bs of
                Left _    -> writeMsg (errorResponse Null codeParseError "parse error")
                Right msg -> dispatch msg >>= maybe (pure ()) writeMsg
              loop

    isWsByte w = w == 32 || w == 9 || w == 13 || w == 10

    writeMsg v = do
      -- One buffered put (encoded reply + newline) rather than two; the
      -- per-reply flush stays so the client sees each response promptly.
      BL.hPut stdout (encode v <> "\n")
      hFlush  stdout
