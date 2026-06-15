{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A localhost web inspector for the @agda-explore@ daemon (opt-in via
-- @--inspect@). It is a /side channel/, completely independent of the
-- JSON-RPC stdio transport: a hand-rolled minimal HTTP\/1.1 + Server-Sent
-- Events server (in the same spirit as the hand-rolled "AgdaMcp.Rpc"), so
-- it adds only the small @network@ dependency rather than a web framework.
--
-- The daemon emits 'InspectEvent's at one chokepoint per concern —
-- 'AgdaMcp.Tools.handleCall' (every @tools/call@) and the bridge's
-- diff-producing helpers ("AgdaInteract.Tools") — through 'emitInspect'.
-- When the inspector is off ('Nothing' hub) every emit is a no-op and no
-- socket or thread exists, so the feature is inert unless asked for.
--
-- Invariants:
--
--   * __stdout is sacred__ (it carries JSON-RPC) — this module touches
--     only its own sockets and never writes to stdout.
--   * __emit never blocks the daemon__ — 'emitInspect' is a single STM
--     transaction over an unbounded broadcast channel plus a bounded ring;
--     a slow or absent browser can never stall a query or the stdio loop.
--   * __localhost only__ — binds @127.0.0.1@; it streams your own source,
--     so there is no auth (local debugging only).
module AgdaMcp.Inspect
  ( InspectHub
  , newInspectHub
  , startInspector
  , emitInspect
  , InspectEvent(..)
  , GoalLite(..)
  ) where

import           Control.Concurrent      (forkIO)
import           Control.Concurrent.STM
import           Control.Exception       (SomeException, catch, finally,
                                          onException, try)
import           Control.Monad           (forever, void)
import           Data.Aeson              (Value, encode, object, (.=))
import           Data.Aeson.Types        (Pair)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Char8   as BC
import qualified Data.ByteString.Lazy    as BL
import           Data.Foldable           (toList)
import           Data.Sequence           (Seq)
import qualified Data.Sequence           as Seq
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as TE
import           Data.Time.Clock         (getCurrentTime)
import           Data.Time.Format.ISO8601 (iso8601Show)
import           Network.Socket
import qualified Network.Socket.ByteString as NSB

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------

-- | One activity event broadcast to every connected browser. Stamped with
-- a wall-clock @ts@ in 'emitInspect'.
data InspectEvent
    -- | A @tools/call@ that flowed through 'AgdaMcp.Tools.handleCall' — the
    -- activity feed. Mirrors the existing query-log record plus the result
    -- text.
  = EvTool  { evTool   :: !Text
            , evArgs   :: !Value
            , evDurMs  :: !Double
            , evOk     :: !Bool
            , evStale  :: !Bool
            , evResult :: !Text
            }
    -- | A module @load@: the on-disk file body + its open goals. Appended to
    -- the editing feed as one collapsable @load@ entry.
  | EvGoals { evFile    :: !Text
            , evContent :: !Text
            , evGoals   :: ![GoalLite]
            }
    -- | A proposed edit (give\/refine\/case_split\/auto\/give_many): the
    -- current on-disk file body + the unified diff the bridge produced (the
    -- bridge never writes the file, so @content@ is still the disk state).
    -- Appended to the editing feed as one collapsable @edit@ entry.
  | EvEdit  { evFile    :: !Text
            , evContent :: !Text
            , evDiff    :: !Text
            }

-- | A goal as the editing view needs it: client id, rendered type, and
-- source position.
data GoalLite = GoalLite
  { glId   :: !Text
  , glType :: !Text
  , glLine :: !(Maybe Int)
  , glCol  :: !(Maybe Int)
  }

eventToPairs :: InspectEvent -> [Pair]
eventToPairs ev = case ev of
  EvTool{..}  -> [ "type"   .= ("tool" :: Text)
                 , "tool"   .= evTool,   "args"  .= evArgs
                 , "dur_ms" .= evDurMs,  "ok"    .= evOk
                 , "stale"  .= evStale,  "result" .= evResult ]
  EvGoals{..} -> [ "type"    .= ("goals" :: Text)
                 , "file"    .= evFile,  "content" .= evContent
                 , "goals"   .= map goalLiteJSON evGoals ]
  EvEdit{..}  -> [ "type"    .= ("edit" :: Text)
                 , "file"    .= evFile,  "content" .= evContent
                 , "diff"    .= evDiff ]

goalLiteJSON :: GoalLite -> Value
goalLiteJSON g = object $
  [ "id" .= glId g, "type" .= glType g ]
    ++ maybe [] (\l -> ["line" .= l]) (glLine g)
    ++ maybe [] (\c -> ["col"  .= c]) (glCol g)

-- ---------------------------------------------------------------------
-- Hub
-- ---------------------------------------------------------------------

-- | The event bus: an unbounded broadcast 'TChan' (each SSE client reads a
-- 'dupTChan' of it, so writes are non-blocking) plus a bounded ring of the
-- most recent events so a freshly-opened browser sees recent backlog.
-- Events are stored pre-encoded so each client just copies bytes to its
-- socket.
data InspectHub = InspectHub
  { ihChan :: !(TChan BL.ByteString)
  , ihRing :: !(TVar (Seq BL.ByteString))
  , ihInfo :: !(TVar BL.ByteString)
    -- ^ A pre-encoded @server@ identity frame (project root + bound port)
    -- sent first to every connecting browser, so a page is never anonymous
    -- — with several daemons each on a probed port you can tell which one
    -- you opened. Empty until 'startInspector' sets it.
  }

-- | Recent-history backlog size handed to a newly-connected browser.
ringMax :: Int
ringMax = 200

newInspectHub :: IO InspectHub
newInspectHub =
  InspectHub <$> newBroadcastTChanIO <*> newTVarIO Seq.empty <*> newTVarIO BL.empty

-- | Broadcast one event. A no-op when the inspector is off ('Nothing').
-- Single STM transaction: append to the broadcast channel and the ring
-- atomically, so a client that snapshots the ring and dups the channel in
-- one transaction sees neither a gap nor a duplicate.
emitInspect :: Maybe InspectHub -> InspectEvent -> IO ()
emitInspect Nothing    _  = pure ()
emitInspect (Just hub) ev = do
  now <- getCurrentTime
  let bs = encode (object (("ts" .= iso8601Show now) : eventToPairs ev))
  atomically $ do
    writeTChan (ihChan hub) bs
    modifyTVar' (ihRing hub) (pushBounded ringMax bs)

pushBounded :: Int -> a -> Seq a -> Seq a
pushBounded n x s =
  let s'  = s Seq.|> x
      len = Seq.length s'
  in if len > n then Seq.drop (len - n) s' else s'

-- ---------------------------------------------------------------------
-- Server
-- ---------------------------------------------------------------------

-- | Bind a localhost listening socket (probing upward from @startPort@ so
-- several daemons coexist without a port clash) and fork the accept loop.
-- Returns the port actually bound, or 'Nothing' if none in the probe range
-- was free. @root@ is the project root, recorded in the identity frame so a
-- connecting browser can tell which daemon it opened.
startInspector :: InspectHub -> Int -> FilePath -> IO (Maybe Int)
startInspector hub startPort root = do
  mbound <- bindFirstAvailable startPort
  case mbound of
    Nothing           -> pure Nothing
    Just (sock, port) -> do
      atomically $ writeTVar (ihInfo hub) $ encode $ object
        [ "type" .= ("server" :: Text), "root" .= root, "port" .= port ]
      _ <- forkIO (acceptLoop sock hub `catchAny` const (close sock))
      pure (Just port)

-- | Try @startPort@, @startPort+1@, … up to a small range; the first that
-- binds wins. Each failed attempt closes its half-open socket.
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

acceptLoop :: Socket -> InspectHub -> IO ()
acceptLoop sock hub = forever $ do
  (conn, _) <- accept sock
  void $ forkIO (handleConn conn hub `catchAny` const (pure ()) `finally` close conn)

handleConn :: Socket -> InspectHub -> IO ()
handleConn conn hub = do
  req <- recvHeaders conn
  case parsePath req of
    Just p
      | p == "/"                     -> sendHtml conn pageHtml
      | "/events" `BS.isPrefixOf` p  -> serveEvents conn hub
    _                                -> send404 conn

-- | Read until the end of the HTTP request headers (or EOF / a sane cap).
-- We only need the request line to route, never the body.
recvHeaders :: Socket -> IO BS.ByteString
recvHeaders conn = go BS.empty
  where
    go acc
      | "\r\n\r\n" `BS.isInfixOf` acc = pure acc
      | BS.length acc > 16384         = pure acc
      | otherwise = do
          chunk <- NSB.recv conn 4096
          if BS.null chunk then pure acc else go (acc <> chunk)

-- | The request-target from the first line (@GET \/path HTTP\/1.1@).
parsePath :: BS.ByteString -> Maybe BS.ByteString
parsePath req =
  case BC.words (BC.takeWhile (/= '\r') (BC.takeWhile (/= '\n') req)) of
    (_ : path : _) -> Just path
    _              -> Nothing

sendHtml :: Socket -> Text -> IO ()
sendHtml conn html = do
  let body = TE.encodeUtf8 html
      hdr  = BC.pack ("HTTP/1.1 200 OK\r\n\
                      \Content-Type: text/html; charset=utf-8\r\n\
                      \Content-Length: " ++ show (BS.length body) ++ "\r\n\
                      \Connection: close\r\n\r\n")
  NSB.sendAll conn (hdr <> body)

send404 :: Socket -> IO ()
send404 conn = NSB.sendAll conn
  (BC.pack "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

-- | An SSE stream: send the headers, flush the ring backlog, then forward
-- every subsequent event. The ring snapshot and the channel dup happen in
-- one transaction so there is no gap or overlap between backlog and live.
serveEvents :: Socket -> InspectHub -> IO ()
serveEvents conn hub = do
  NSB.sendAll conn (BC.pack "HTTP/1.1 200 OK\r\n\
                            \Content-Type: text/event-stream\r\n\
                            \Cache-Control: no-cache\r\n\
                            \Connection: keep-alive\r\n\r\n")
  (info, backlog, chan) <- atomically $ do
    i <- readTVar (ihInfo hub)
    b <- readTVar (ihRing hub)
    c <- dupTChan (ihChan hub)
    pure (i, toList b, c)
  if BL.null info then pure () else sendFrame conn info
  mapM_ (sendFrame conn) backlog
  let loop = atomically (readTChan chan) >>= sendFrame conn >> loop
  loop

sendFrame :: Socket -> BL.ByteString -> IO ()
sendFrame conn bs = NSB.sendAll conn (BL.toStrict ("data: " <> bs <> "\n\n"))

catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny = catch

-- ---------------------------------------------------------------------
-- The page (self-contained: no external assets, works offline)
-- ---------------------------------------------------------------------

pageHtml :: Text
pageHtml = T.unlines
  [ "<!doctype html>"
  , "<html><head><meta charset='utf-8'>"
  , "<title>agda-explore inspector</title>"
  , "<style>"
  , "  :root{color-scheme:dark;}"
  , "  *{box-sizing:border-box;}"
  , "  body{margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;"
  , "       font-size:13px;background:#1e1e1e;color:#d4d4d4;height:100vh;display:flex;flex-direction:column;}"
  , "  header{padding:6px 12px;background:#252526;border-bottom:1px solid #333;display:flex;gap:12px;align-items:baseline;}"
  , "  header b{color:#9cdcfe;}"
  , "  #ident{color:#ce9178;}"
  , "  #status{font-size:11px;color:#888;margin-left:auto;}"
  , "  main{flex:1;display:grid;grid-template-columns:minmax(0,2fr) minmax(0,3fr);min-height:0;}"
  , "  section{display:flex;flex-direction:column;min-height:0;min-width:0;border-right:1px solid #333;}"
  , "  section h2{margin:0;padding:5px 10px;font-size:11px;text-transform:uppercase;letter-spacing:.5px;"
  , "             color:#888;background:#252526;border-bottom:1px solid #333;font-weight:600;}"
  , "  #feed,#edits{overflow:auto;padding:4px;}"
  , "  .row{border-bottom:1px solid #2a2a2a;border-left:3px solid transparent;}"
  , "  .row.ok{border-left-color:#4ec9b0;}"
  , "  .row.err{border-left-color:#f48771;}"
  , "  .row.edit{border-left-color:#4ec9b0;}"
  , "  .row.load{border-left-color:#569cd6;}"
  , "  .summary{display:flex;align-items:baseline;gap:6px;padding:3px 6px;cursor:pointer;"
  , "           white-space:nowrap;overflow:hidden;}"
  , "  .summary:hover{background:#2a2d2e;}"
  , "  .caret{color:#666;font-size:10px;display:inline-block;flex:none;transition:transform .1s;}"
  , "  .row.open .caret{transform:rotate(90deg);}"
  , "  .summary .t{color:#666;flex:none;}"
  , "  .summary .tool{color:#dcdcaa;font-weight:600;flex:none;}"
  , "  .summary .kind{font-weight:600;flex:none;text-transform:uppercase;font-size:10px;letter-spacing:.5px;}"
  , "  .summary .kind.edit{color:#4ec9b0;}"
  , "  .summary .kind.load{color:#569cd6;}"
  , "  .summary .preview{color:#9cdcfe;font-size:11px;flex:1;min-width:0;"
  , "                    overflow:hidden;text-overflow:ellipsis;}"
  , "  .summary .dur{color:#666;font-size:11px;flex:none;}"
  , "  .summary .stale{color:#d7ba7d;font-size:11px;flex:none;}"
  , "  .summary .stat{font-size:11px;flex:none;}"
  , "  .summary .stat .sa{color:#4ec9b0;} .summary .stat .sd{color:#f48771;}"
  , "  .summary .gc{color:#ce9178;font-size:11px;flex:none;}"
  , "  .detail{display:none;padding:2px 6px 6px 22px;}"
  , "  .row.open .detail{display:block;}"
  , "  .detail .args{color:#9cdcfe;font-size:11px;word-break:break-all;margin:2px 0;}"
  , "  .detail .res{color:#bbb;white-space:pre-wrap;margin:3px 0 0;max-height:300px;overflow:auto;"
  , "               background:#181818;padding:3px 5px;border-radius:3px;font-size:11px;}"
  , "  .detail .goals{display:flex;flex-wrap:wrap;gap:4px 12px;margin:2px 0 4px;}"
  , "  .goal{color:#ce9178;}"
  , "  .detail .file{margin:3px 0 0;max-height:340px;overflow:auto;background:#181818;padding:4px 0;border-radius:3px;}"
  , "  .ln{display:flex;white-space:pre;}"
  , "  .ln.hl{background:#3a3320;}"
  , "  .ln .num{display:inline-block;width:42px;text-align:right;padding-right:10px;color:#555;flex:none;user-select:none;}"
  , "  .detail .diff{margin:3px 0 0;max-height:220px;overflow:auto;background:#181818;border-radius:3px;}"
  , "  .detail .diff div{white-space:pre;padding:0 8px;}"
  , "  .detail .diff .add{color:#4ec9b0;background:#143b30;}"
  , "  .detail .diff .del{color:#f48771;background:#3b1d18;}"
  , "  .detail .diff .hunk{color:#569cd6;}"
  , "</style></head>"
  , "<body>"
  , "<header><b>agda-explore</b> inspector <span id='ident'></span><span id='status'>connecting…</span></header>"
  , "<main>"
  , "  <section><h2>Activity</h2><div id='feed'></div></section>"
  , "  <section><h2>Editing</h2><div id='edits'></div></section>"
  , "</main>"
  , "<script>"
  , "  const feed=document.getElementById('feed');"
  , "  const edits=document.getElementById('edits');"
  , "  const statusEl=document.getElementById('status');"
  , "  const identEl=document.getElementById('ident');"
  , "  let lastAuto=null;"
  , "  function showServer(ev){"
  , "    const base=(ev.root||'').split('/').filter(Boolean).pop()||ev.root||'';"
  , "    identEl.textContent=base+'  :'+ev.port;"
  , "    identEl.title=ev.root;"
  , "    document.title='agda-explore '+base+' :'+ev.port;"
  , "  }"
  , "  function esc(s){return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}"
  , "  function basename(p){return (p||'').split('/').filter(Boolean).pop()||p||'';}"
  , "  function addTool(ev){"
  , "    const row=document.createElement('div');"
  , "    row.className='row '+(ev.ok?'ok':'err');"
  , "    const args=ev.args?JSON.stringify(ev.args):'';"
  , "    const stale=ev.stale?`<span class='stale'>stale</span>`:'';"
  , "    row.innerHTML=`<div class='summary'>`+"
  , "        `<span class='caret'>▸</span>`+"
  , "        `<span class='t'>${esc((ev.ts||'').slice(11,19))}</span>`+"
  , "        `<span class='tool'>${esc(ev.tool)}</span>`+"
  , "        `<span class='preview'>${esc(args)}</span>`+"
  , "        `<span class='dur'>${(ev.dur_ms||0).toFixed(0)}ms</span>${stale}`+"
  , "      `</div>`+"
  , "      `<div class='detail'>`+"
  , "        (args?`<div class='args'>${esc(args)}</div>`:'')+"
  , "        `<pre class='res'>${esc(ev.result)}</pre>`+"
  , "      `</div>`;"
  , "    feed.prepend(row);"
  , "    while(feed.childNodes.length>300)feed.removeChild(feed.lastChild);"
  , "  }"
  , "  feed.addEventListener('click',e=>{"
  , "    const r=e.target.closest('.row'); if(r)r.classList.toggle('open');"
  , "  });"
  , "  function diffRange(d){"
  , "    const m=/@@ -(\\d+),(\\d+)/.exec(d||'');"
  , "    if(!m)return null; const a=+m[1], b=+m[2]; return [a,a+b];"
  , "  }"
  , "  function diffStat(d){"
  , "    let add=0,del=0;"
  , "    (d||'').split('\\n').forEach(l=>{"
  , "      if(l.startsWith('+')&&!l.startsWith('+++'))add++;"
  , "      else if(l.startsWith('-')&&!l.startsWith('---'))del++;"
  , "    });"
  , "    return [add,del];"
  , "  }"
  , "  function fileHtml(content,hl){"
  , "    return (content||'').split('\\n').map((ln,i)=>{"
  , "      const n=i+1; const on=hl&&n>=hl[0]&&n<hl[1];"
  , "      return `<div class='ln${on?\" hl\":\"\"}'><span class='num'>${n}</span>${esc(ln)||' '}</div>`;"
  , "    }).join('');"
  , "  }"
  , "  function diffHtml(d){"
  , "    return (d||'').split('\\n').map(l=>{"
  , "      let c='';"
  , "      if(l.startsWith('+')&&!l.startsWith('+++'))c='add';"
  , "      else if(l.startsWith('-')&&!l.startsWith('---'))c='del';"
  , "      else if(l.startsWith('@@'))c='hunk';"
  , "      return `<div class='${c}'>${esc(l)||' '}</div>`;"
  , "    }).join('');"
  , "  }"
  , "  function renderEditDetail(row){"
  , "    if(row._rendered)return; row._rendered=true;"
  , "    const ev=row._ev, d=row.querySelector('.detail');"
  , "    let html='';"
  , "    if((ev.goals||[]).length)"
  , "      html+=`<div class='goals'>`+ev.goals.map(g=>"
  , "        `<span class='goal'>${esc(g.id)} : ${esc(g.type)}${g.line?(' @'+g.line+':'+g.col):''}</span>`).join('')+`</div>`;"
  , "    if(ev.diff)html+=`<pre class='diff'>${diffHtml(ev.diff)}</pre>`;"
  , "    html+=`<pre class='file'>${fileHtml(ev.content,ev.diff?diffRange(ev.diff):null)}</pre>`;"
  , "    d.innerHTML=html;"
  , "  }"
  , "  function openEdit(row){row.classList.add('open');renderEditDetail(row);}"
  , "  function addEdit(ev){"
  , "    const isEdit=ev.type==='edit';"
  , "    const row=document.createElement('div');"
  , "    row.className='row '+(isEdit?'edit':'load');"
  , "    row._ev=ev; row._rendered=false;"
  , "    let info;"
  , "    if(isEdit){const s=diffStat(ev.diff);"
  , "      info=`<span class='stat'><span class='sa'>+${s[0]}</span> <span class='sd'>-${s[1]}</span></span>`;}"
  , "    else {const n=(ev.goals||[]).length; info=`<span class='gc'>${n} goal${n===1?'':'s'}</span>`;}"
  , "    row.innerHTML=`<div class='summary'>`+"
  , "        `<span class='caret'>▸</span>`+"
  , "        `<span class='t'>${esc((ev.ts||'').slice(11,19))}</span>`+"
  , "        `<span class='kind ${isEdit?'edit':'load'}'>${isEdit?'edit':'load'}</span>`+"
  , "        `<span class='preview'>${esc(basename(ev.file))}</span>`+"
  , "        info+"
  , "      `</div>`+"
  , "      `<div class='detail'></div>`;"
  , "    edits.prepend(row);"
  , "    if(lastAuto&&lastAuto.isConnected)lastAuto.classList.remove('open');"
  , "    openEdit(row); lastAuto=row;"
  , "    while(edits.childNodes.length>80)edits.removeChild(edits.lastChild);"
  , "  }"
  , "  edits.addEventListener('click',e=>{"
  , "    const r=e.target.closest('.row'); if(!r)return;"
  , "    r.classList.toggle('open');"
  , "    if(r.classList.contains('open'))renderEditDetail(r);"
  , "  });"
  , "  const src=new EventSource('/events');"
  , "  src.onopen=()=>{statusEl.textContent='connected';};"
  , "  src.onerror=()=>{statusEl.textContent='disconnected — retrying';};"
  , "  src.onmessage=(e)=>{"
  , "    let ev; try{ev=JSON.parse(e.data);}catch(_){return;}"
  , "    if(ev.type==='server')showServer(ev);"
  , "    else if(ev.type==='tool')addTool(ev);"
  , "    else if(ev.type==='goals'||ev.type==='edit')addEdit(ev);"
  , "  };"
  , "</script>"
  , "</body></html>"
  ]
