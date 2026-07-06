{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A localhost control endpoint for the @agda-explore@ daemon (opt-in via
-- @--control-port@). It lets an external process — in practice a Claude Code
-- /PostToolUse hook/ — run the same warm @check@ / @repair@ the MCP tools run,
-- so a text edit to an Agda file can be validated (and a fix suggested) without
-- going through the MCP stdio transport, which the agent harness owns.
--
-- Like "AgdaMcp.Inspect" it is a /side channel/: a hand-rolled minimal
-- HTTP\/1.1 server over the existing @network@ dependency, and it imports no
-- project module — @Main@ hands it the tool callbacks as a plain route table,
-- so there is no import cycle and no second dispatch mechanism.
--
-- Routes:
--
--   * @GET \/check?file=PATH@ — run the check callback; @200@ with its
--     'Right' text (the ✓\/✗ verdict + diagnostics + goals), @500@ with its
--     'Left'.
--   * @GET \/repair?file=PATH@ — run the repair callback (diff-only, never
--     writes); @200@ with the report + proposed diff. Serves the PostToolUse
--     hook's "suggest a fix" step.
--   * @GET \/ping@ — @200 ok@ (hook liveness probe).
--   * anything else — @404@.
--
-- A request that arrives while another is being served gets an immediate
-- @503@ — hooks have timeouts, so "busy" must be a fast, clean signal the
-- hook can degrade on, never a queue behind a minutes-long load.
--
-- Invariants shared with the inspector: __stdout is sacred__ (JSON-RPC
-- lives there; this module only touches its own sockets), and it binds
-- __127.0.0.1 only__ (probing upward from the start port so several
-- daemons coexist). On a successful bind the port is written to
-- @<dir>/control-port@ so the hook can discover it; @Main@ removes the
-- file on shutdown.
module AgdaMcp.Control
  ( startControl
  ) where

import           Control.Concurrent      (forkIO)
import           Control.Concurrent.MVar (MVar, newMVar, putMVar, tryTakeMVar)
import           Control.Exception       (SomeException, catch, finally, onException, try)
import           Control.Monad           (forever, void)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Char8   as BC
import           Data.Char               (chr)
import           Data.Maybe              (listToMaybe)
import           Data.Text               (Text)
import qualified Data.Text.Encoding      as TE
import           Network.Socket
import qualified Network.Socket.ByteString as NSB
import           System.Directory        (createDirectoryIfMissing)
import           System.FilePath         (takeDirectory)

-- | Bind the control socket (probing upward from @startPort@), write the
-- bound port to @portFile@ (creating its directory), and fork the accept
-- loop. Returns the bound port, or 'Nothing' if none in the probe range
-- was free. @runCheck@ is the check action: file path in, verdict text
-- (or an operational error) out.
-- | One @file=…@ route: the path prefix (query marker included, e.g.
-- @\"/check?\"@) and the callback to run with the decoded @file@.
type Route = (BS.ByteString, Text -> IO (Either Text Text))

startControl :: Int -> FilePath -> [Route] -> IO (Maybe Int)
startControl startPort portFile routes = do
  mbound <- bindFirstAvailable startPort
  case mbound of
    Nothing           -> pure Nothing
    Just (sock, port) -> do
      _ <- try (do createDirectoryIfMissing True (takeDirectory portFile)
                   writeFile portFile (show port))
             :: IO (Either SomeException ())
      gate <- newMVar ()
      _ <- forkIO (acceptLoop sock gate routes `catchAny` const (close sock))
      pure (Just port)

-- | Try @startPort@, @startPort+1@, … up to a small range; the first that
-- binds wins (same shape as the inspector's).
bindFirstAvailable :: Int -> IO (Maybe (Socket, Int))
bindFirstAvailable start = go [start .. start + 49]
  where
    go []       = pure Nothing
    go (p : ps) = do
      r <- try (openOn p) :: IO (Either SomeException Socket)
      either (const (go ps)) (\s -> pure (Just (s, p))) r
    openOn p = do
      sock <- socket AF_INET Stream defaultProtocol
      setSocketOption sock ReuseAddr 1
      ( bind sock (SockAddrInet (fromIntegral p) (tupleToHostAddress (127, 0, 0, 1)))
          >> listen sock 16
          >> pure sock )
        `onException` close sock

acceptLoop :: Socket -> MVar () -> [Route] -> IO ()
acceptLoop sock gate routes = forever $ do
  (conn, _) <- accept sock
  void $ forkIO $
    (serve conn gate routes `catchAny` const (pure ()))
      `finally` (close conn `catchAny` const (pure ()))

-- | One request: read the head (requests are tiny; one recv suffices), match it
-- against the route table, respond, close. All @file=…@ routes share the busy
-- gate.
serve :: Socket -> MVar () -> [Route] -> IO ()
serve conn gate routes = do
  raw <- NSB.recv conn 8192
  case parseRequestLine raw of
    Just ("GET", path)
      | path == "/ping"             -> respond conn 200 "ok"
      | Just (q, cb) <- match path  -> gated q cb
    Just _  -> respond conn 404 notFound
    Nothing -> respond conn 400 "bad request"
  where
    match path = listToMaybe [ (q, cb) | (p, cb) <- routes, Just q <- [BS.stripPrefix p path] ]
    notFound   = "not found (routes: "
                   <> BC.intercalate ", " [ p <> "file=PATH" | (p, _) <- routes ]
                   <> ", /ping)"
    gated q cb = case lookup "file" (parseQuery q) of
      Nothing -> respond conn 400 "missing `file` query parameter"
      Just f  -> do
        mheld <- tryTakeMVar gate
        case mheld of
          Nothing -> respond conn 503 "busy: another request is in flight (retry, or fall back)"
          Just () -> do
            r <- cb (TE.decodeUtf8With (\_ _ -> Just '\xFFFD') f) `finally` putMVar gate ()
            case r of
              Right txt -> respond conn 200 (TE.encodeUtf8 txt)
              Left err  -> respond conn 500 (TE.encodeUtf8 err)

-- | The method + path of the request line (query string kept in the path).
parseRequestLine :: BS.ByteString -> Maybe (BS.ByteString, BS.ByteString)
parseRequestLine raw = case BC.words (BC.takeWhile (/= '\r') raw) of
  (m : p : _) -> Just (m, p)
  _           -> Nothing

-- | Split a query string into decoded key\/value pairs.
parseQuery :: BS.ByteString -> [(BS.ByteString, BS.ByteString)]
parseQuery = map pair . BC.split '&'
  where
    pair kv = let (k, v) = BC.break (== '=') kv
              in (urlDecode k, urlDecode (BS.drop 1 v))

-- | Percent-decoding (plus @+@ → space).
urlDecode :: BS.ByteString -> BS.ByteString
urlDecode = BC.pack . go . BC.unpack
  where
    go []               = []
    go ('+' : rest)     = ' ' : go rest
    go ('%' : a : b : rest)
      | Just h <- hex a, Just l <- hex b = chr (h * 16 + l) : go rest
    go (c : rest)       = c : go rest
    hex c | c >= '0' && c <= '9' = Just (fromEnum c - fromEnum '0')
          | c >= 'a' && c <= 'f' = Just (fromEnum c - fromEnum 'a' + 10)
          | c >= 'A' && c <= 'F' = Just (fromEnum c - fromEnum 'A' + 10)
          | otherwise            = Nothing

respond :: Socket -> Int -> BS.ByteString -> IO ()
respond conn code body =
  NSB.sendAll conn $ BS.concat
    [ "HTTP/1.1 ", BC.pack (show code), " ", reason code, "\r\n"
    , "Content-Type: text/plain; charset=utf-8\r\n"
    , "Content-Length: ", BC.pack (show (BS.length body)), "\r\n"
    , "Connection: close\r\n\r\n"
    , body
    ]
  where
    reason 200 = "OK"
    reason 400 = "Bad Request"
    reason 404 = "Not Found"
    reason 503 = "Service Unavailable"
    reason _   = "Internal Server Error"

catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny = catch
