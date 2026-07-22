{-# LANGUAGE OverloadedStrings #-}
-- | The write-side interaction-bridge MCP tools, exposed through the
-- @agda-explore@ server when started with @--enable-interact@.
--
-- These talk to a long-lived @agda --interaction-json@ session
-- ('AgdaInteract.Session') rather than the static dependency-graph
-- snapshot — they reflect live on-disk file state and so deliberately
-- bypass @ensureFresh@.
--
-- The catalogue is 11 tools: single-operation mutators sit behind
-- @op@-dispatched batchers, keeping the handful agents reach for flat and
-- prominent. Three families:
--
--   * /read-only/ — @load@, @goal_brief@ (one-call goal orientation:
--     type + context + candidate lemmas), @inspect@ (@op@ =
--     type|context|infer|normalize over a live goal), @check@ (validate a
--     file/proposed content → structured errors + warnings + open goals),
--     @lemmas@ (goal-directed lemma search wired off a live goal's type).
--   * /hole-driven mutators/ — @auto@ (Mimer at one goal) and @construct@
--     (a heterogeneous batch of give/refine/case_split/auto steps against
--     one warm load; a @goal:"*"@ auto step runs Mimer over every open goal).
--     Each returns a unified diff and (with
--     @write:true@) optionally applies it and reloads.
--   * /file authoring + repair/ — @new_module@ (scaffold a validated module
--     skeleton, resolving imports off the dependency graph), @give_file@
--     (validate whole-file or appended content under the zero-axiom
--     contract → diff), @scratch@ (@op@ = open|promote|discard staging
--     lifecycle), and @repair@ (interpret the compiler's diagnostics to add
--     missing imports / fix misspelled references, graph-backed and
--     spec-preserving → diff).
module AgdaInteract.Tools
  ( interactTools
  , closeAllSessions
  , reapIdleSessions
  , autoAllCore
  , applyOrDiff
  , runRepair
  ) where

import           Control.Concurrent      (threadDelay)
import           Control.Concurrent.MVar (modifyMVar, modifyMVar_, readMVar)
import           Control.Exception       (SomeException, try)
import           Control.Monad           (foldM, forM, forM_, forever, when)
import           Data.Aeson              (FromJSON (..), Value, object, withObject,
                                          (.:), (.=))
import           Data.Aeson.Types        (parseMaybe)
import           Data.IORef              (newIORef, readIORef, writeIORef)
import           Data.List               (isPrefixOf, nub, partition, sortOn, stripPrefix)
import qualified Data.Map.Strict         as M
import qualified Data.Set                as Set
import           Data.Maybe              (fromMaybe, isJust, isNothing,
                                          mapMaybe)
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.IO            as TIO
import           Data.Time.Clock         (diffUTCTime, getCurrentTime)
import           Data.Word               (Word64)
import           System.Directory        (createDirectoryIfMissing,
                                          listDirectory, removePathForcibly)
import           System.FilePath         (dropExtension, dropExtensions, isAbsolute,
                                          makeRelative, normalise, takeDirectory,
                                          takeFileName, (</>))
import           System.IO               (hPutStrLn, stderr)
import           Text.Read               (readMaybe)

import           AgdaGraph.Interaction.Iotcm
import           AgdaGraph.Interaction.Protocol
import           AgdaGraph.Schema        (Definition, defModule)
import           AgdaInteract.Annotate   (holeHints)
import           AgdaInteract.AutoReport
import           AgdaInteract.Batch
import           AgdaInteract.Edit
import           AgdaInteract.GoalId
import           AgdaInteract.Guard
import           AgdaInteract.Literate
import           AgdaInteract.Registry
import           AgdaInteract.Session
import           AgdaMcp.Inspect         (GoalLite (..), InspectEvent (..),
                                          emitInspect)
import           AgdaMcp.Query           (queryFindLemma, goalHintCands)
import           AgdaMcp.State
import           AgdaMcp.ToolDef
import qualified AgdaRepair.Diagnostic   as RD
import qualified AgdaRepair.Edit         as RE
import qualified AgdaRepair.Strategy     as RS

-- ---------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------

interactTools :: [Tool]
interactTools =
  [ Tool "load"
      "Load (or reload) an Agda module into a live interaction session and \
      \list its open goals — each with an id (g0, g1, …) and its source \
      \(line:col). The id maps to Agda's interaction hole and keeps its \
      \value across a reload while the hole's position is unchanged, but \
      \applying an edit can renumber goals — so after applying a diff, \
      \re-`load` and pick goals from the FRESH list (matching on (line:col) \
      \is most robust; don't cache an id across an edit). Use the ids with \
      \the other interaction tools. Reflects live on-disk file state (not \
      \the dependency-graph snapshot). Required before goal_type/infer/etc."
      (objSchema [ ("file", sp "Path to the .agda / .lagda.md module (relative to the project root, or absolute).") ]
                 ["file"])
      runLoad

  , Tool "goal_brief"
      "One-call orientation on an open goal: its type + in-scope context and the \
      \top reusable lemmas whose conclusion resembles it. Lead with this after \
      \`load`; read-only."
      (objSchema [ goalProp, fileProp
                 , ("limit", ip "Max candidate lemmas (default 5).")
                 , ("kind", sp "Restrict lemma candidates to a kind: function|projection|datatype|record|constructor|postulate|primitive|other.")
                 , ("module_prefix", sp "Only lemma candidates whose module starts with this prefix.")
                 , ("min_sim", np "Minimum lemma similarity 0..1 (default 0.3).")
                 ] ["goal"])
      runGoalBrief

  , Tool "inspect"
      "Read-only live-goal query (batcher): `op` picks what to read at an open \
      \goal — `type` (goal type + in-scope context, the interaction-hole \
      \analogue of `type_of`), `context` (just the visible binders and their \
      \types), `infer` (the inferred type of `expr` in the goal's context), \
      \`normalize` (compute/normalise `expr`). `expr` is required for \
      \infer/normalize and ignored otherwise. `load` the module first."
      (objSchema [ goalProp
                 , ("op", ep "What to read at the goal." inspectOps)
                 , ("expr", sp "Expression to infer/normalise (required for op=infer|normalize).")
                 , fileProp
                 ] ["goal", "op"])
      runInspect

  , Tool "auto"
      "Mimer proof search for one goal; returns a diff filling the hole, or a \
      \'no solution' note (guide it with `construct` refine/give steps). Plain \
      \Mimer often misses a one-lemma goal, so on failure this seeds Mimer with \
      \the top graph-ranked lemmas for the goal type (the `find_lemma` \
      \machinery) and retries — closing goals like `n + 0 ≡ n` via `+-identityʳ`. \
      \For every goal at once use `construct` with a single `{op:auto, goal:\"*\"}` \
      \step."
      (objSchema [ goalProp
                 , fileProp
                 , ("timeout", ip "Mimer budget in seconds (default 5).")
                 , ("hints", ip "Max lemma hints to try on failure (default 6; 0 = plain Mimer).")
                 , ("write", writeArg)
                 ] ["goal"])
      runAuto

  , Tool "construct"
      "Drive holes with a SEQUENCE of steps against one warm load — the primary \
      \hole-filling interface. `steps` is a list of {op, goal, …} with op = give \
      \(needs `term`) / refine (needs `expr`) / case_split (needs `var`) / auto. \
      \One combined diff; each step targets an ORIGINAL-load goal (won't fill \
      \holes an earlier step introduced); a rejected step aborts naming the \
      \offender. A single `{op:auto, goal:\"*\"}` step runs Mimer over EVERY open \
      \goal; the `*` wildcard is valid for `auto` only."
      (objSchema [ ("steps", stepsSchema)
                 , fileProp
                 , ("write", writeArg)
                 , ("annotate", annotateArg)
                 ] ["steps"])
      runConstruct

  , Tool "scratch"
      "Scratch-module lifecycle (batcher): `op:open` opens an ephemeral SCRATCH \
      \module (under .agda-explore/scratch/) to build a NEW definition in \
      \isolation — the real module isn't left half-written and each re-check is \
      \tiny (optional `target` seeds imports + names the eventual destination); \
      \`op:promote` splices the scratch's def(s) into the real `target` (merging \
      \imports) and re-validates the WHOLE target (needs `scratch` + `target`, \
      \honours `write`); `op:discard` closes the session and deletes the scratch \
      \(needs `scratch`). Build inside the scratch with the usual tools, then \
      \promote or discard."
      (objSchema [ ("op", ep "Lifecycle step." scratchOps)
                 , ("target", sp "Real module: for op=open seeds imports + the promote destination (optional); for op=promote the splice destination (required).")
                 , ("scratch", sp "Scratch file path returned by op=open (required for op=promote|discard).")
                 , ("write", writeArg)
                 ] ["op"])
      runScratch

  , Tool "check"
      "[prove] Type-check a module in the live session → ✓/✗, every error and warning, \
      \and open goals with stable ids + (line:col); when goals remain it probes \
      \them with Mimer and reports ready-made solutions inline. Pass `content` \
      \to dry-run proposed text without writing. Use instead of `agda <file>`. \
      \When a goal is stuck, reach for `lemmas` (find a reusable lemma), `auto` \
      \(Mimer with graph-ranked hints), or a `construct` case_split/refine step \
      \BEFORE writing the term by hand — that is exactly when these tools pay off."
      (objSchema [ ("file", sp "Path to the .agda / .lagda.md module (relative to the project root, or absolute).")
                 , ("content", sp "Proposed full file text to validate instead of the on-disk file (dry-run; nothing is written).")
                 ] ["file"])
      runCheck

  , Tool "give_file"
      "Author a WHOLE definition or file — the validated, zero-axiom counterpart \
      \to a blind `Write`. Supply EXACTLY ONE of `content` (full file text; also \
      \creates a new file) or `append` (a def block spliced onto the end). \
      \Guarded + type-checked; returns a diff, or the localized errors unchanged."
      (objSchema [ ("file", sp "Target module file (created if it doesn't exist, in `content` mode).")
                 , ("content", sp "Full proposed file text. Mutually exclusive with `append`.")
                 , ("append", sp "A definition block to append to the existing file. Mutually exclusive with `content`.")
                 , ("write", writeArg)
                 ] ["file"])
      runGiveFile

  , Tool "new_module"
      "Scaffold a NEW, validated Agda module: derives the `module … where` header \
      \from `path`, literate fences for a .lagda.md path, resolves bare `imports` \
      \names to `open import` lines off the graph, and turns each `defs` \
      \{name,type} into a hole. Type-checked before it is returned."
      (objSchema [ ("path", sp "File to create, e.g. `Protocol/Jolteon/Foo.agda` or `Foo.lagda.md` (relative to the project root, or absolute).")
                 , ("imports", arrOfStr "Bare names you need in scope; each is resolved to its defining module via the graph. Unresolved names are reported, not invented.")
                 , ("defs", defsSchema)
                 , ("open", bp "Emit `open import` (default true) vs bare `import`.")
                 , ("write", bp "Create and load the file (default false → return the validated content).")
                 ] ["path"])
      runNewModule

  , Tool "lemmas"
      "Goal-directed lemma search for a LIVE goal: reads the goal's type and \
      \finds definitions whose conclusion resembles it, to fill via a \
      \`construct` give/refine step instead of re-deriving. The live-goal \
      \front-end to `find_lemma`."
      (objSchema [ goalProp, fileProp
                 , ("kind", sp "Restrict candidates to a kind: function|projection|datatype|record|constructor|postulate|primitive|other.")
                 , ("module_prefix", sp "Only candidates whose module starts with this prefix.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.3).")
                 ] ["goal"])
      runLemmas

  , Tool "repair"
      "Repair an almost-correct Agda file by interpreting the compiler's \
      \diagnostics: add missing imports (resolved off the dependency graph — \
      \operators and constructors included) and fix misspelled references, \
      \driving the file to a typechecking state. Every candidate is \
      \Agda-validated by recompiling; signatures/theorem statements are never \
      \edited and semantic errors (type mismatch, termination) are refused, not \
      \faked (zero-axiom contract). Returns a report + unified diff; `write:true` \
      \applies + reloads. Import repair needs a graph covering the file's \
      \dependencies (e.g. `--overlay-graph` for stdlib)."
      (objSchema [ ("file", sp "Path to the .agda / .lagda.md module to repair.")
                 , ("content", sp "Optional: repair this proposed text instead of the on-disk file (dry-run; never written).")
                 , ("write", writeArg)
                 , ("max_iter", ip "Max repair iterations (default 8).")
                 ] ["file"])
      runRepair
  ]

-- | The shared @write@ boolean argument schema for the mutating tools.
writeArg :: Value
writeArg = bp "Apply the edit to the file and reload, returning the refreshed \
              \goals — instead of only returning a diff for you to apply \
              \(default false; the bridge does not write unless asked)."

-- | The @annotate@ flag (only meaningful for a @{op:auto, goal:\"*\"}@ step):
-- leave a strippable, idempotent @{- agda-auto/1 … -}@ marker inside each hole
-- Mimer could not close, recording the goal type + the ranked lemmas to reach
-- for (with import lines for out-of-scope ones). Default off.
annotateArg :: Value
annotateArg = bp "With a `{op:auto, goal:\"*\"}` step: annotate every hole Mimer \
                 \could not close with a marker comment recording the goal type \
                 \and the lemmas to try (default false; re-running replaces the \
                 \marker rather than stacking it)."

-- | The @goal@ and @file@ properties shared by (almost) every interaction
-- tool — defined once; the goal-id lifecycle lives in the skill.
goalProp, fileProp :: (Text, Value)
goalProp = ("goal", sp "Stable goal id from `load` (e.g. `g0`).")
fileProp = ("file", sp "Loaded module file (needed only if several are loaded).")

-- | A JSON-schema for an array-of-strings argument.
arrOfStr :: Text -> Value
arrOfStr d = object
  [ "type"        .= ("array" :: Text)
  , "description" .= d
  , "items"       .= object ["type" .= ("string" :: Text)]
  ]

-- | Schema for the @defs@ array of @{name, type}@ stubs ('new_module').
defsSchema :: Value
defsSchema = object
  [ "type"        .= ("array" :: Text)
  , "description" .= ("Definitions to stub as holes — a list of \
                      \{\"name\":\"foo\",\"type\":\"A → B\"} objects, each \
                      \emitted as `foo : A → B` / `foo = ?`." :: Text)
  , "items" .= object
      [ "type"       .= ("object" :: Text)
      , "properties" .= object
          [ "name" .= sp "Definition name."
          , "type" .= sp "Its type signature." ]
      , "required" .= (["name", "type"] :: [Text])
      ]
  ]

-- | Schema for the @steps@ array ('construct').
stepsSchema :: Value
stepsSchema = object
  [ "type"        .= ("array" :: Text)
  , "description" .= ("Ordered steps. Each is {\"op\":..., \"goal\":\"g0\", …}: \
                      \op `give` takes `term`, `refine` takes `expr`, \
                      \`case_split` takes `var`, `auto` takes nothing. Use \
                      \`goal`:\"*\" with op `auto` (only) as the sole step to run \
                      \Mimer over every open goal." :: Text)
  , "items" .= object
      [ "type"       .= ("object" :: Text)
      , "properties" .= object
          [ "op"   .= sp "give | refine | case_split | auto."
          , "goal" .= sp "Stable goal id, e.g. g0 (or \"*\" = every open goal, op=auto only)."
          , "term" .= sp "Term to give (op=give)."
          , "expr" .= sp "Refinement hint (op=refine)."
          , "var"  .= sp "Variable(s) to split on (op=case_split)." ]
      , "required" .= (["op", "goal"] :: [Text])
      ]
  ]

-- ---------------------------------------------------------------------
-- Tool runners
-- ---------------------------------------------------------------------

runLoad :: ToolRunner
runLoad ss a = case argText a "file" of
  Nothing -> pure (Left "load requires a `file` argument.")
  Just f  -> do
    r <- doLoad ss (absFile ss f)
    case r of
      Left err            -> pure (Left err)
      Right (_, _, es, fp) -> do
        emitGoals ss fp es
        pure (Right (renderGoals fp es))

-- | Broadcast a module's on-disk body + open goals to the web inspector's
-- editing view (a no-op when @--inspect@ is off). Best-effort: an unreadable
-- file just yields empty content.
emitGoals :: ServerState -> FilePath -> [GoalEntry] -> IO ()
emitGoals ss fp es = case ssInspect ss of
  -- Inspector off (the default): skip the whole-file read entirely.
  Nothing  -> pure ()
  Just hub -> do
    ec <- readFileSafe fp
    emitInspect (Just hub) $ EvGoals
      { evFile    = T.pack fp
      , evContent = either (const "") id ec
      , evGoals   = map toGoalLite es
      }
  where
    toGoalLite e =
      let (ln, col) = case geRange e of
            Just (GoalRange s _) -> (Just (rpLine s), Just (rpCol s))
            Nothing              -> (Nothing, Nothing)
      in GoalLite (renderStableId (geStable e)) (geType e) ln col

-- | Broadcast a proposed edit (the on-disk body before the edit + the
-- unified diff) to the web inspector's editing view. The bridge never
-- writes the file, so @old@ remains the live disk state. No-op when
-- @--inspect@ is off.
emitEdit :: ServerState -> FilePath -> Text -> String -> IO ()
emitEdit ss file old diff =
  emitInspect (ssInspect ss) $ EvEdit
    { evFile = T.pack file, evContent = old, evDiff = T.pack diff }

-- | Read-only goal-info renderers (inspect op=type / op=context): resolve
-- the session + goal, run @Cmd_goal_type_context@, render with the supplied
-- function.
runGoalInfo :: (GoalInfo -> Text) -> ToolRunner
runGoalInfo render ss a =
  withGoal ss a $ \sess file _e iid ->
    runCmd sess (iotcmGoalTypeContext file Simplified iid) (fmap render . firstGoalInfo)

-- | Expression readers (inspect op=infer / op=normalize): resolve session +
-- goal, run the supplied command with the goal's context, render the reply.
runExpr :: (FilePath -> Int -> String -> String) -> ToolRunner
runExpr mkCmd ss a = case argText a "expr" of
  Nothing   -> pure (Left "this tool requires an `expr` argument.")
  Just expr ->
    withGoal ss a $ \sess file _e iid ->
      runCmd sess (mkCmd file iid (T.unpack expr)) (fmap renderGoalInfoExpr . firstGoalInfo)

-- | Read-only live-goal query batcher: dispatch @op@ to the goal-info /
-- expression readers.
runInspect :: ToolRunner
runInspect ss a = case checkInspectArgs (argText a "op") (argText a "expr") of
  Left err -> pure (Left err)
  Right op -> case op of
    "type"    -> runGoalInfo renderGoalTypeFull ss a
    "context" -> runGoalInfo renderContextOnly ss a
    "infer"   -> runExpr (\f iid e -> iotcmInfer f Simplified iid e) ss a
    _         -> runExpr (\f iid e -> iotcmCompute f DefaultCompute iid e) ss a  -- normalize

-- | The @write@ boolean off a tool's arguments (default false).
writeFlag :: Value -> Bool
writeFlag a = argBool a "write" False

-- | One @{goal, term}@ fill request for 'runGiveMany' (also the shape the
-- all-@give@ 'construct' fast path synthesises).
data GiveSpec = GiveSpec !Text !Text
instance FromJSON GiveSpec where
  parseJSON = withObject "give" $ \o -> GiveSpec <$> o .: "goal" <*> o .: "term"

-- | Fill several goals in one live session. Agda keeps a session's
-- surviving interaction ids stable across gives (no reload between them),
-- so we resolve every goal from the one loaded goal map, give each in
-- turn against the live state, accumulate the edits, and emit ONE combined
-- diff. Atomic w.r.t. disk: on any failure the session is marked dirty
-- (so the partial in-session gives are dropped on the next load) and
-- nothing is written.
runGiveMany :: ToolRunner
runGiveMany ss a = case argLookup a "gives" >>= parseMaybe parseJSON of
  Nothing    -> pure (Left "give_many requires a `gives` array of \
                           \{\"goal\":\"g0\",\"term\":\"…\"} objects.")
  Just []    -> pure (Left "give_many: `gives` is empty.")
  Just specs ->
    -- Fail fast: run the no-postulate guard on every term before touching agda.
    case [ (g, why) | GiveSpec g t <- specs, Rejected why <- [checkGiveInput t] ] of
      ((g, why):_) -> pure (Left ("give_many refused " <> g <> ": " <> why))
      [] -> do
        r <- resolveLoaded ss (argText a "file")
        case r of
          Left err -> pure (Left err)
          Right (file, sess, gm) -> do
            ef <- readSourceStamped ss file
            case ef of
              Left e     -> pure (Left e)
              Right orig -> do
                res <- giveLoop sess file gm (codeBlocksFor file orig) specs []
                markSessionDirty ss file        -- drop the in-session state; we serve disk
                case res of
                  Left err    -> pure (Left err)
                  Right edits -> case spliceRanges orig edits of
                    Left ov   -> pure (Left ov)
                    Right new
                      | writeFlag a -> applyOrDiff ss True file orig new
                      | otherwise   -> do
                          let d = unifiedDiff file orig new
                          emitEdit ss file orig d
                          pure (Right (batchMsg (length edits) d))

-- | The replacement text a give\/refine reply asks for: either an explicit
-- string, or the caller's input optionally parenthesised.
giveReplacement :: GiveResult -> Text -> Text
giveReplacement gr inp = case gr of
  GiveStr s   -> s
  GiveParen p -> if p then "(" <> inp <> ")" else inp

-- | Validate + give each spec against the live session, accumulating
-- (start, end, replacement) edits. Stops at the first failure.
giveLoop :: Session -> FilePath -> GoalMap -> CodeBlocks -> [GiveSpec]
         -> [(Int, Int, Text)] -> IO (Either Text [(Int, Int, Text)])
giveLoop _    _    _  _  []                 acc = pure (Right (reverse acc))
giveLoop sess file gm cb (GiveSpec g t : rest) acc =
  case parseStableId g >>= \sid -> (,) sid <$> lookupStable gm sid of
    Nothing          -> pure (Left ("give_many: not an open goal id: " <> g))
    Just (_sid, e)   -> case (geIid e, geRange e) of
      (Just iid, Just (GoalRange s en))
        | not (isInsideCode cb (rpPos s)) ->
            pure (Left (g <> ": the hole is not inside an Agda code block."))
        | otherwise -> do
            out <- runRaw sess (iotcmGive file iid (T.unpack t))
            case out of
              Left err -> pure (Left ("give_many: session error on " <> g <> ": " <> err))
              Right rs -> case firstError rs of
                Just m  -> pure (Left ("give_many: agda rejected " <> g
                                         <> " — nothing applied:\n" <> m))
                Nothing -> case [gr | ReplyGiveAction _ gr <- rs] of
                  (gr:_) ->
                    let repl = giveReplacement gr t
                    in giveLoop sess file gm cb rest ((rpPos s, rpPos en, repl) : acc)
                  [] -> pure (Left ("give_many: no give action for " <> g))
      _ -> pure (Left (g <> ": not an open goal."))

batchMsg :: Int -> String -> Text
batchMsg n diff =
  "Filled " <> showT n <> " goal(s) in one session load (diff only — "
    <> "`write:true` to apply + reload):\n\n" <> T.pack diff

runAuto :: ToolRunner
runAuto ss a = withGoal ss a $ \sess file e iid -> do
  let secs = max 1 (argInt a "timeout" 5)
      k    = max 0 (argInt a "hints" 6)
  -- One graph snapshot + import scope (1c) for hint ranking, then the goal's
  -- live context types (1d): fetch 2k candidates, probe the first k in-scope,
  -- report the out-of-scope remainder with import lines.
  (mLd, inScope)         <- hintScopeFor ss file
  (probeCands, oosCands) <- goalProbeHints mLd inScope k sess file e
  let hints   = map fst probeCands
      batchOK = not (cfgNoHintBatch (ssConfig ss))
  res <- autoSolve (allTiers batchOK) sess file iid secs hints
  case res of
    AutoGive mh s -> fmap (headline mh <>) <$> applyHoleEdit ss (writeFlag a) file e s
    -- No solution: surface Agda's error if the plain probe sent one, else
    -- the no-solution note (listing the hints we tried), then flag the
    -- out-of-scope candidates (pre-filtered here, plus any a probe bounced).
    AutoNone mErr bounced ->
      pure (Left (fromMaybe (noSolution hints) mErr
                    <> oosNote "auto" (probeCands ++ oosCands)
                               (nub (map fst oosCands ++ bounced))))
    -- Budget expiry / session death: the session is reset.
    AutoAbort m -> pure (Left m)
  where
    headline Plain         = "Mimer filled the goal:\n\n"
    headline (ViaHint h)   = "Mimer filled the goal via lemma `" <> h <> "`:\n\n"
    headline (ViaBatch hs) = "Mimer filled the goal via graph hints ("
                               <> codeList hs <> "):\n\n"
    noSolution hs =
      "auto/Mimer found no solution for this goal"
        <> (if null hs then ""
            else " (tried lemma hints: " <> codeList hs <> ")")
        <> " — guide it with a `construct` case_split/refine step, `lemmas goal=…`, \
           \or `construct` an explicit give."

-- | The "hint is in the file's import scope" predicate (Phase-1c), built ONCE
-- from the file's source text and module map — both loop-invariant across a
-- file's goals, so 'runAutoAll' builds this before its per-goal loop.
-- Conservative: a candidate is out of scope only when the file neither names
-- it (a @using@\/@renaming@ entry or a top-level def, via 'RS.inScopeNames')
-- nor opens its defining module at all ('RS.importedModules'), nor is that
-- module defined in the file itself. An unrestricted @open import M@ therefore
-- reads as in-scope, so the costly error (a false "out of scope", which would
-- drop a usable hint) is avoided; a @using@ list that happens to exclude the
-- name only costs one fast bounced probe, exactly as today.
hintInScope :: Maybe Loaded -> FilePath -> Text -> (Text, Definition) -> Bool
hintInScope mLd file src = inScope
  where
    named    = RS.inScopeNames src
    imported = Set.fromList (RS.importedModules src)
    fileMods = case mLd of
      Just ld -> Set.fromList [ m | (m, f) <- M.toList (ldModFiles ld), f == file ]
      Nothing -> Set.empty
    inScope (nm, d) =
         nm            `Set.member` named
      || defModule d   `Set.member` imported
      || defModule d   `Set.member` fileMods

-- | Rank and scope-partition a goal's Mimer hint candidates. Ranks via
-- 'goalHintCands' (Phase 1a/1b through the shared ranker; @ctxTypes@ is 1d),
-- then fetches @2k@ candidates and keeps the first @k@ __in-scope__ to probe
-- (1c), returning the out-of-scope remainder to report. The scope predicate is
-- built once by the caller ('hintInScope'); 'Nothing' (no source text) ⇒ the
-- top @k@ unpartitioned (today's behaviour). No snapshot ⇒ no hints.
prepGoalHints :: Maybe Loaded -> Maybe ((Text, Definition) -> Bool) -> Int -> [Text] -> Text
              -> ([(Text, Definition)], [(Text, Definition)])
prepGoalHints mLd mInScope k ctxTypes goalTy
  | k <= 0    = ([], [])
  | otherwise =
      let cands = maybe [] (\ld -> goalHintCands ld (2 * k) goalTy ctxTypes) mLd
      in case mInScope of
           Just inScope -> let (inS, oos) = partition inScope cands in (take k inS, oos)
           Nothing      -> (take k cands, [])

-- | The loop-invariant hint machinery for a file: the current snapshot's index
-- (for ranking) and the file's import-scope predicate (1c). Read once per
-- @auto@ / check call, then reused across the file's goals via 'goalProbeHints'.
-- No snapshot ⇒ 'Nothing' (⇒ plain probe); no source text ⇒ no scope predicate.
hintScopeFor :: ServerState -> FilePath
             -> IO (Maybe Loaded, Maybe ((Text, Definition) -> Bool))
hintScopeFor ss file = do
  mLd  <- either (const Nothing) (Just . fst) <$> ensureFresh ss
  msrc <- either (const Nothing) Just <$> readSourceStamped ss file
  pure (mLd, hintInScope mLd file <$> msrc)

-- | Rank + scope-partition one goal's Mimer hint candidates in a live session:
-- fetch the goal's live context types (1d) and hand them to 'prepGoalHints'
-- (rank 1a\/1b + scope-partition 1c). The single seam @runAuto@\/@runAutoAll@\/
-- the check probe share, so their hint seeding stays in lockstep. Skips the
-- 'ctxTypesOf' session round-trip when there is nothing to rank against
-- (@k <= 0@ or no snapshot) — 'prepGoalHints' would discard @ctxTypes@ there.
goalProbeHints :: Maybe Loaded -> Maybe ((Text, Definition) -> Bool) -> Int
               -> Session -> FilePath -> GoalEntry
               -> IO ([(Text, Definition)], [(Text, Definition)])
goalProbeHints mLd mInScope k sess file e
  | k <= 0 || isNothing mLd = pure ([], [])
  | otherwise = do
      ctxTypes <- maybe (pure []) (ctxTypesOf sess file) (geIid e)
      pure (prepGoalHints mLd mInScope k ctxTypes (geType e))

-- 'HintProv' (Plain / ViaHint / ViaBatch — which probe closed the goal, for
-- the headline) now lives in "AgdaInteract.AutoReport" (State-free, so the
-- offline suite can pin the rendering).

-- | Outcome of a (possibly hint-guided) Mimer search at one goal.
data AutoResult
  = AutoGive HintProv Text      -- ^ term found; the 'HintProv' says how.
  | AutoNone (Maybe Text) [Text]
      -- ^ nothing found; @Just@ = an Agda error from the plain probe, plus
      --   the hints whose probe Agda rejected as out of scope (in try order).
  | AutoAbort !Text
      -- ^ the probe exceeded its wall budget or the session died: the
      --   session is dead, remaining hints were skipped, the message says so.

-- | One probe's outcome (internal to 'autoSolve').
data ProbeResult
  = PGive  !Text            -- ^ Mimer returned a term
  | PNone  !(Maybe Text)    -- ^ no term; optional Agda error
  | PAbort !Text            -- ^ wall-budget expiry / session death

-- | Which probe tiers 'autoSolve' runs. @auto@ / @auto_all@ run all three
-- ('allTiers'); the check-time probe (Phase 4, 'autoHints') drops the per-hint
-- tier to bound routine-check latency — the batch already tries the same
-- lemmas, and more powerfully (it can combine them).
data AutoTiers = AutoTiers
  { atPlain   :: !Bool  -- ^ tier 1: the unhinted probe (off in the ladder's hinted pass, Phase 3b).
  , atBatch   :: !Bool  -- ^ tier 2: the in-scope hint batch in one call (@--no-hint-batch@ clears it).
  , atPerHint :: !Bool  -- ^ tier 3: the per-hint fallback.
  }

-- | The @auto@ / @auto_all@ tier set: plain + per-hint always, batch unless the
-- @--no-hint-batch@ A/B toggle cleared it.
allTiers :: Bool -> AutoTiers
allTiers batchOK = AutoTiers { atPlain = True, atBatch = batchOK, atPerHint = True }

-- | Max hints in the Phase-3a batch call. Small on purpose (see 'autoSolve'):
-- big batches abort on a single mis-scoped hint; 2–4 combine reliably.
autoBatchMax :: Int
autoBatchMax = 4

-- | Mimer at one goal, in three probe tiers (Phase-3a):
--
--   1. __plain__, full budget — closes trivial holes fast. Skipped when
--      @'atPlain'@ is 'False' (the 'runAutoAll' hinted pass, where a cheap plain
--      pass already failed — Phase 3b, so plain is not re-run).
--   2. __batch__: the top @'autoBatchMax'@ @hints@ in ONE call, full budget
--      (skipped when @'atBatch'@ is 'False' — the @--no-hint-batch@ A/B toggle).
--      The @hints@ are pre-validated in-scope short names (Phase-1c
--      'prepGoalHints'), so the call does not abort, and this is the only tier
--      that lets Mimer /combine/ two lemmas — sequential probes structurally
--      cannot. Verified on Agda 2.8 (a multi-hint in-scope call returns a
--      @GiveAction@; a single out-of-scope name still errors @[NotInScope]@,
--      hence tier 3).
--   3. __per-hint fallback__: each hint alone, smaller budget — catches a batch
--      abort from a hint the scope parser wrongly validated, and pins the OOS
--      hints for reporting. Skipped when @'atPerHint'@ is 'False' (the check
--      probe, which trades this salvage tier for bounded latency).
--
-- Stops at the first 'GiveAction'. Every probe is wall-clock-bounded
-- ('probeBudgetMicros'), so a diverging normalization resets the session
-- instead of wedging it.
autoSolve :: AutoTiers -> Session -> FilePath -> Int -> Int -> [Text] -> IO AutoResult
autoSolve tiers sess file iid secs hints = do
    r0 <- if atPlain tiers then probe secs ("-t " ++ show secs) else pure (PNone Nothing)
    case r0 of
      PGive t    -> pure (AutoGive Plain t)
      PAbort m   -> pure (AutoAbort m)
      PNone mErr
        | null hints        -> pure (AutoNone mErr [])
        | not (atBatch tiers) -> perHint mErr      -- --no-hint-batch: skip tier 2
        | otherwise    -> do
            rB <- probe secs ("-t " ++ show secs ++ " " ++ unwords (map T.unpack batch))
            case rB of
              PGive t  -> pure (AutoGive (ViaBatch batch) t)
              PAbort m -> pure (AutoAbort m)
              PNone _  -> perHint mErr
  where
    -- Tier 3, or a clean "no solution" when the check probe disabled it.
    perHint mErr
      | atPerHint tiers = tryHints hints [] mErr
      | otherwise       = pure (AutoNone mErr [])
    -- Batch only the top few hints, not all k: the scope parser (Phase 1c) is
    -- approximate, and ONE false-in-scope name aborts the whole batch call
    -- (verified: an out-of-scope hint errors [NotInScope] before search). A
    -- small, best-ranked batch keeps "all truly in-scope" likely so Mimer can
    -- combine them (verified: `trans' eq1 eq2` solves what no single hint does);
    -- the per-hint fallback below still tries all k regardless.
    batch    = take autoBatchMax hints
    hintSecs = max 1 (min 3 secs)
    tryHints []       oos mErr = pure (AutoNone mErr (reverse oos))
    tryHints (h : hs) oos mErr = do
      r <- probe hintSecs ("-t " ++ show hintSecs ++ " " ++ T.unpack h)
      case r of
        PGive t   -> pure (AutoGive (ViaHint h) t)
        PAbort m  -> pure (AutoAbort m)
        PNone hErr -> tryHints hs (if maybe False (RD.hintOutOfScope h) hErr
                                     then h : oos else oos) mErr
    probe secsUsed opts = do
      out <- sendIotcmBudget (probeBudgetMicros secsUsed) sess (iotcmAutoOne file AsIs iid opts)
      pure $ case out of
        SendTimeout _  -> PAbort (budgetMsg secsUsed)
        SendDied _ err -> PAbort (autoDiedMsg err)
        SendOk rs      -> case [gr | ReplyGiveAction _ gr <- rs] of
          (GiveStr t : _) -> PGive t
          _               -> PNone (firstError rs)

-- | Message for a Mimer probe that blew its wall budget.
budgetMsg :: Int -> Text
budgetMsg secs =
  "Mimer/goal work exceeded its " <> showT secs <> "s+" <> showT probeGraceSecs
    <> "s wall budget — the Agda session was reset and reloads on the next \
       \command; retry with a larger `timeout`, or guide the goal with a \
       \`construct` refine/case_split step or `lemmas goal=…`."

autoDiedMsg :: Text -> Text
autoDiedMsg err =
  "the Agda session ended during Mimer search (" <> err
    <> "); it reloads on the next command."

-- | Mimer over every open goal of a module in one call: no goal ids, one
-- combined diff for the solved goals (or apply + reload with @write:true@),
-- the survivors listed. The one-shot shape for "just close what's easy";
-- the per-goal @auto@ remains for targeted work.
--
-- Thin over 'autoAllCore': render the structured 'AutoAllOutcome'
-- ('renderAutoAll') and, for a run that produced edits, append @applyOrDiff@'s
-- diff / apply-and-reload report. @agda-auto@ calls 'autoAllCore' directly for
-- its own report + exit code.
runAutoAll :: ToolRunner
runAutoAll ss a = do
  eo <- autoAllCore ss a
  case eo of
    Left err -> pure (Left err)
    Right o  -> case aoNew o of
      Nothing  -> pure (Right (renderAutoAll o))
      Just new -> fmap (renderAutoAll o <>) <$> applyOrDiff ss (writeFlag a) (aoFile o) (aoOrig o) new

-- | The @auto_all@ ladder as a structured result: resolve + load the file,
-- probe every open goal (Phase-3b two-pass ladder unless @--no-auto-ladder@),
-- splice the solved gives against the ORIGINAL text, and package everything
-- 'renderAutoAll' / the @agda-auto@ report need into an 'AutoAllOutcome'. Marks
-- the session dirty (the in-session gives diverge from unchanged disk). Does
-- NOT write or diff — the caller does, keyed on 'aoNew' ('Nothing' ⇒ nothing
-- to apply). Splitting the rendering off is what makes the pure prose
-- pin-testable and gives @agda-auto@ per-goal data.
autoAllCore :: ServerState -> Value -> IO (Either Text AutoAllOutcome)
autoAllCore ss a = do
  r0 <- case argText a "file" of
    Just f  -> pure (Right (absFile ss f))
    Nothing -> do
      -- Mirror 'resolveLoaded's "sole loaded module" convenience.
      m <- readMVar (ssSessions ss)
      pure $ case M.keys m of
        [k] -> Right k
        []  -> Left "auto_all: no module loaded; pass `file=<path>`."
        _   -> Left "auto_all: multiple modules are loaded; pass `file=<path>`."
  case r0 of
    Left err   -> pure (Left err)
    Right file -> do
      r <- doLoad ss file
      case r of
        Left err -> pure (Left err)
        Right (sess, _, es, _)
          | null es   -> pure (Right (noGoalsOutcome file))
          | otherwise -> do
              ef <- readSourceStamped ss file
              case ef of
                Left e     -> pure (Left e)
                Right orig -> do
                  let secs = max 1 (argInt a "timeout" 5)
                      k    = max 0 (argInt a "hints" 6)
                      -- Annotate unsolved holes with a marker (opt-in; default
                      -- off, so the MCP surface is unchanged unless
                      -- `annotate:true` is passed — agda-auto passes it).
                      annotate = argBool a "annotate" False
                      cb   = codeBlocksFor file orig
                      cfg  = ssConfig ss
                      batchOK = not (cfgNoHintBatch cfg)
                  mLd <- either (const Nothing) (Just . fst) <$> ensureFresh ss
                  let inScope = Just (hintInScope mLd file orig)
                      -- Per goal: live context types (1d) + rank (1a/1b) +
                      -- scope-partition (1c) into in-scope probe hints + the OOS
                      -- remainder, PLUS the hole's own hints (probed first).
                      -- The one expensive-per-goal step.
                      fetchHints e = do
                        (probe, oos) <- goalProbeHints mLd inScope k sess file e
                        pure (GoalHints e (holeHints (holeTextOf orig e)) probe oos)
                  -- Probe. 'recs1' is the first (or only) pass over all goals;
                  -- 'recs2' the ladder's hinted pass over the survivors (empty
                  -- in the no-ladder path — its single pass IS the hinted one).
                  (recs1, recs2, mAbort) <-
                    if cfgNoAutoLadder cfg
                      then do
                        -- Phase-3b OFF: one full-budget pass (fetch every goal's
                        -- hints, then plain+batch+per-hint at the full budget).
                        per        <- forM es fetchHints
                        (recs, ab) <- probeGoals (allTiers batchOK) sess file cb secs per
                        pure (recs, [], ab)
                      else do
                        -- Phase-3b ladder. PASS 1: plain only, cheap 1 s over ALL
                        -- goals, NO hints — closes trivial holes without the
                        -- per-goal context round-trip + ranking, fails the rest
                        -- fast so the full budget hits only the residue.
                        (r1, ab1) <-
                          probeGoals (allTiers batchOK) sess file cb 1 (map noHints es)
                        let surv1 = [ grcEntry g | g <- r1, isNothing (grcEdit g) ]
                        -- PASS 2: hinted (skip plain — pass 1 ran it), full
                        -- budget, over the SURVIVORS only; fetch hints lazily. A
                        -- pass-1 abort skips pass 2 and leaves the survivors
                        -- unsolved (synthesised, no hints) so the aggregates
                        -- match the no-ladder path's.
                        (r2, ab2) <-
                          if isJust ab1
                            then pure ([ unsolvedRec e | e <- surv1 ], Nothing)
                            else do
                              per <- forM surv1 fetchHints
                              probeGoals ((allTiers batchOK) { atPlain = False }) sess file cb secs per
                        pure (r1, r2, maybe ab2 Just ab1)
                  -- The in-session gives diverge from disk (which stays
                  -- untouched unless write:true) — reload on next use.
                  markSessionDirty ss file
                  -- Solves come from BOTH passes (pass1 ++ pass2 order — not
                  -- input order, hence 'renderAutoAll' reads these aggregates,
                  -- not 'aoGoals'). The OOS / survivors reporting comes from the
                  -- HINTED pass (recs2 with the ladder, recs1 without).
                  let hintedRecs = if cfgNoAutoLadder cfg then recs1 else recs2
                      edits      = recEdits recs1 ++ recEdits recs2
                      solved     = solvedIds recs1 ++ solvedIds recs2
                      -- In the no-ladder path recs2 is empty, and
                      -- @mergeGoalRecs recs1 [] == map grcReport recs1@, so the
                      -- merge covers both paths.
                      goals      = mergeGoalRecs recs1 recs2
                      -- Solved gives + (opt-in) annotation markers on the
                      -- unsolved holes are edits on DISJOINT ranges — one splice
                      -- keeps them from shifting each other.
                      allEdits = edits ++ annotationEdits annotate secs orig goals
                      mkOutcome mNew = AutoAllOutcome
                        { aoFile      = file
                        , aoOrig      = orig
                        , aoNew       = mNew
                        , aoNoGoals   = False
                        , aoGoalCount = length es
                        , aoSecs      = secs
                        , aoSolved    = solved
                        , aoUnsolved  = unsolvedIds hintedRecs
                        , aoAbort     = mAbort
                        , aoAllCands  = recAllCands hintedRecs
                        , aoOosNames  = nub (recPreOosNames hintedRecs ++ recBounced hintedRecs)
                        , aoGoals     = goals
                        }
                  case if null allEdits then Right Nothing else Just <$> spliceRanges orig allEdits of
                    Left ov    -> pure (Left ov)
                    Right mNew -> pure (Right (mkOutcome mNew))

-- | Internal per-goal probing record: the original entry, its structured
-- 'GoalReport', and (when solved inside a code block) the ORIGINAL-offset
-- give edit @(start, end, term)@.
data GoalRec = GoalRec
  { grcEntry  :: !GoalEntry
  , grcReport :: !GoalReport
  , grcEdit   :: !(Maybe (Int, Int, Text))
  }

-- | One goal's fetched hints: names read from the hole itself (probed first —
-- user intent outranks the ranker), the graph-ranked in-scope
-- candidates, and the out-of-scope remainder (reported with import lines).
data GoalHints = GoalHints
  { ghGoal  :: !GoalEntry
  , ghHole  :: ![Text]               -- ^ hole-derived hint names.
  , ghGraph :: ![(Text, Definition)] -- ^ graph-ranked in-scope candidates.
  , ghOos   :: ![(Text, Definition)] -- ^ out-of-scope candidates.
  }

-- | An empty hint set for a goal (the ladder's plain pass 1 / abort survivors).
noHints :: GoalEntry -> GoalHints
noHints e = GoalHints e [] [] []

-- | The hole's full source text (@{! … !}@ / @?@) sliced from @orig@ at the
-- goal's 1-based half-open range; @""@ when the goal has no range.
holeTextOf :: Text -> GoalEntry -> Text
holeTextOf orig e = case geRange e of
  Just (GoalRange s en) -> let a = rpPos s; b = rpPos en
                           in T.take (b - a) (T.drop (a - 1) orig)
  Nothing               -> ""

-- | Build a 'GoalReport' for one goal.
mkGoalReport :: GoalEntry -> GoalOutcome
             -> [(Text, Definition)] -> [(Text, Definition)] -> [Text] -> [Text] -> GoalReport
mkGoalReport e outc probe oos bounced hole = GoalReport
  { grId         = renderStableId (geStable e)
  , grType       = geType e
  , grRange      = geRange e
  , grOutcome    = outc
  , grProbeHints = probe
  , grOosHints   = oos
  , grBounced    = bounced
  , grHoleHints  = hole
  }

-- | An unprobed goal recorded unsolved (no hints) — used for the ladder's
-- pass-1-abort survivors, which pass 2 never reaches.
unsolvedRec :: GoalEntry -> GoalRec
unsolvedRec e = GoalRec e (mkGoalReport e (GUnsolved Nothing) [] [] [] []) Nothing

-- | The probe hint-name list: hole hints first (user intent), then the
-- graph-ranked in-scope names, deduped (first occurrence wins).
probeNames :: GoalHints -> [Text]
probeNames gh = nub (ghHole gh ++ map fst (ghGraph gh))

-- | Probe each goal with Mimer against the one live load, in input order,
-- building a 'GoalRec' per goal. The in-session gives never move the on-disk
-- text, so edits accumulate in ORIGINAL offsets and merge with 'spliceRanges'.
-- Continue-on-failure — an unsolved goal is a /result/, not an abort — except
-- a session death ('AutoAbort'), which stops the run: the current goal and the
-- rest are recorded unsolved (carrying their fetched hints, so the OOS
-- aggregate is unchanged) and the message returned.
probeGoals :: AutoTiers -> Session -> FilePath -> CodeBlocks -> Int
           -> [GoalHints]
           -> IO ([GoalRec], Maybe Text)
probeGoals tiers sess file cb secs = go []
  where
    report e outc gh bounced =
      mkGoalReport e outc (ghGraph gh) (ghOos gh) bounced (ghHole gh)
    go acc [] = pure (reverse acc, Nothing)
    go acc (gh : rest) = let e = ghGoal gh in case (geIid e, geRange e) of
      (Just iid, Just (GoalRange s en))
        | isInsideCode cb (rpPos s) -> do
            res <- autoSolve tiers sess file iid secs (probeNames gh)
            case res of
              AutoGive prov t ->
                go (GoalRec e (report e (GSolved t prov) gh [])
                              (Just (rpPos s, rpPos en, t)) : acc) rest
              AutoNone mErr hoos ->
                go (GoalRec e (report e (GUnsolved mErr) gh hoos) Nothing : acc) rest
              -- Session dead: stop. Current + rest recorded unsolved; the rest
              -- keep their fetched hints so 'recAllCands' matches a full run.
              AutoAbort m ->
                let here     = GoalRec e (report e (GUnsolved Nothing) gh []) Nothing
                    restRecs = [ GoalRec (ghGoal g) (report (ghGoal g) (GUnsolved Nothing) g []) Nothing
                               | g <- rest ]
                in pure (reverse (here : acc) ++ restRecs, Just m)
      _ -> go (GoalRec e (report e GSkipped gh []) Nothing : acc) rest

-- | Merge the ladder's two passes into the final per-goal reports, in input
-- order: a goal solved in pass 1 keeps its pass-1 report; a survivor takes its
-- pass-2 report (recs2 has exactly one entry per survivor, in order). The
-- fall-through keeps the pass-1 report if recs2 is unexpectedly short (never
-- happens — recs2 covers every survivor).
mergeGoalRecs :: [GoalRec] -> [GoalRec] -> [GoalReport]
mergeGoalRecs []            _   = []
mergeGoalRecs (r1 : rest1) rs2
  | isJust (grcEdit r1)      = grcReport r1 : mergeGoalRecs rest1 rs2
  | (r2 : rest2) <- rs2      = grcReport r2 : mergeGoalRecs rest1 rest2
  | otherwise                = grcReport r1 : mergeGoalRecs rest1 []

-- Aggregate views over a pass's 'GoalRec's (see 'autoAllCore').
recEdits :: [GoalRec] -> [(Int, Int, Text)]
recEdits recs = [ ed | GoalRec _ _ (Just ed) <- recs ]

solvedIds, unsolvedIds :: [GoalRec] -> [Text]
solvedIds   recs = [ grId (grcReport g) | g <- recs, isJust    (grcEdit g) ]
unsolvedIds recs = [ grId (grcReport g) | g <- recs, isNothing (grcEdit g) ]

recAllCands :: [GoalRec] -> [(Text, Definition)]
recAllCands recs = concat [ grProbeHints r ++ grOosHints r | g <- recs, let r = grcReport g ]

recPreOosNames :: [GoalRec] -> [Text]
recPreOosNames recs = [ n | g <- recs, (n, _) <- grOosHints (grcReport g) ]

recBounced :: [GoalRec] -> [Text]
recBounced recs = concat [ grBounced (grcReport g) | g <- recs ]

-- ---------------------------------------------------------------------
-- Scratch / staging buffer (op = open / promote / discard)
-- ---------------------------------------------------------------------

-- | Scratch-module lifecycle batcher: dispatch @op@ to the staging runners.
runScratch :: ToolRunner
runScratch ss a = case checkScratchOp (argText a "op") of
  Left err  -> pure (Left err)
  Right op  -> case op of
    "open"    -> runStage ss a
    "promote" -> runPromote ss a
    _         -> runDiscard ss a  -- discard

-- | Absolute scratch directory. @cfgOutDir@ can be relative (e.g. the
-- default ".agda-explore" in preloaded mode), so anchor it under the
-- project root — the same base @absFile@ resolves against — so the
-- absolute scratch path we hand back round-trips through later tool calls.
scratchSubdir :: ServerState -> FilePath
scratchSubdir ss =
  let c  = ssConfig ss
      od = cfgOutDir c
  in (if isAbsolute od then od else cfgProjectRoot c </> od) </> "scratch"

-- | Include dirs for loading @file@. A staged scratch module and the
-- promote-validation temp live under the scratch subdir with a *bare*
-- top-level module name, outside the project's include roots — so Agda
-- rejects them (@ModuleNameDoesntMatchFileName@) unless their own directory
-- is itself an include root. Add it for exactly those bridge-generated files;
-- every normal project module resolves through @cfgIncludes@ unchanged.
loadIncludes :: ServerState -> FilePath -> [FilePath]
loadIncludes ss file =
  let base = cfgIncludes (ssConfig ss)
      d    = normalise (takeDirectory file)
  in if d == normalise (scratchSubdir ss)
        || d == normalise (scratchSubdir ss </> ".validate")
       then d : base
       else base

-- | The one heavy real-target recheck happens here, so be generous.
validateTimeoutMicros :: Int
validateTimeoutMicros = 600 * 1000000

runStage :: ToolRunner
runStage ss a = do
  let dir = scratchSubdir ss
  createDirectoryIfMissing True dir
  existing <- either (const []) id <$>
                (try (listDirectory dir) :: IO (Either SomeException [FilePath]))
  let used    = mapMaybe (\f -> stripPrefix "Scratch" (dropExtension f) >>= readMaybe) existing :: [Int]
      n       = if null used then 0 else maximum used + 1
      modName = "Scratch" ++ show n
      file    = dir </> (modName ++ ".agda")
  seed <- case argText a "target" of
    Nothing -> pure ""
    Just t  -> do
      r <- readFileSafe (absFile ss t)
      pure $ case r of
        Right txt -> T.unlines (importLines txt)
        Left _    -> ""
  let content = T.pack ("module " ++ modName ++ " where\n\n") <> seed
                  <> "\n" <> seedComment <> "\n"
  w <- try (TIO.writeFile file content) :: IO (Either SomeException ())
  pure $ case w of
    Left e  -> Left ("could not create scratch module: " <> T.pack (show e))
    Right _ -> Right ("Staged scratch module:\n  " <> T.pack file
                        <> "\n\nAdd your `sig : T` + `def = ?`, `load` this file, and \
                           \build with `inspect` / `construct`. When it type-checks, \
                           \`scratch op=promote` it into a real module (scratch=" <> T.pack file
                        <> ", target=<module>), or `scratch op=discard` it.")

-- | Marker line written into a fresh scratch so the user knows where to type
-- (and 'scratchDefBody' can drop it).
seedComment :: Text
seedComment = "-- Add `name : Type` and `name = ?` below, then `load` this file."

runDiscard :: ToolRunner
runDiscard ss a = case argText a "scratch" of
  Nothing -> pure (Left "discard requires a `scratch` file argument.")
  Just sc -> do
    let file = absFile ss sc
    modifyMVar_ (ssSessions ss) $ \m -> case M.lookup file m of
      Just e  -> closeSession (seSession e) >> pure (M.delete file m)
      Nothing -> pure m
    _ <- try (removePathForcibly file) :: IO (Either SomeException ())
    pure (Right ("Discarded scratch " <> T.pack file <> "."))

runPromote :: ToolRunner
runPromote ss a = case (argText a "scratch", argText a "target") of
  (Just sc, Just tg) -> do
    let scratchFile = absFile ss sc
        targetFile  = absFile ss tg
    escr <- readFileSafe scratchFile
    etgt <- readFileSafe targetFile
    case (escr, etgt) of
      (Left e, _)            -> pure (Left e)
      (_, Left e)            -> pure (Left e)
      (Right scr, Right tgt) ->
        let missing = [ l | l <- importLines scr, l `notElem` importLines tgt ]
            body    = scratchDefBody scr
        in if T.null (T.strip body)
             then pure (Left "promote: the scratch module has no definitions to promote yet.")
             else case checkFileInput body of
               Rejected why -> pure (Left ("promote refused: " <> why))
               Allowed      -> do
                 let candidate = buildCandidate targetFile tgt missing body
                 v <- validateCandidate ss targetFile candidate
                 case v of
                   Left err -> pure (Left ("promote: the spliced definition does not typecheck in "
                                       <> T.pack (takeFileName targetFile)
                                       <> " — nothing changed:\n" <> err))
                   Right () -> applyOrDiff ss (writeFlag a) targetFile tgt candidate
  _ -> pure (Left "promote requires both `scratch` and `target` file arguments.")

-- | Lines that are Agda imports (`import` / `open import`), leading-trimmed.
importLines :: Text -> [Text]
importLines = filter isImp . map T.stripStart . T.splitOn "\n"
  where isImp l = "import " `T.isPrefixOf` l || "open import " `T.isPrefixOf` l

isModuleHeader :: Text -> Bool
isModuleHeader l = "module " `T.isPrefixOf` T.stripStart l

-- | Rename the first top-level (column-0) @module … where@ header to
-- @newName@, leaving inner/indented submodules and everything else intact.
renameTopModule :: Text -> Text -> Text
renameTopModule newName = T.intercalate "\n" . go . T.splitOn "\n"
  where
    go [] = []
    go (l:rest)
      | "module " `T.isPrefixOf` l = rewrite l : rest   -- first col-0 module decl
      | otherwise                  = l : go rest
    rewrite l = case T.words l of
      ("module" : _old : more) -> T.unwords ("module" : newName : more)
      _                        -> l

-- | The definition block of a scratch module: everything after the
-- `module … where` header, minus the import preamble and the seed comment.
scratchDefBody :: Text -> Text
scratchDefBody scr =
  let afterModule = drop 1 (dropWhile (not . isModuleHeader) (T.splitOn "\n" scr))
      defs = [ l | l <- afterModule
                 , let s = T.stripStart l
                 , not ("import " `T.isPrefixOf` s)
                 , not ("open import " `T.isPrefixOf` s)
                 , s /= seedComment ]
  in T.strip (T.intercalate "\n" defs)

-- | Build the candidate target: missing imports right after the target's
-- `module … where` header, scratch defs appended at the end of the last code
-- region (EOF for .agda; inside the last ```agda fence for a literate file).
-- Best-effort placement — 'validateCandidate' is the guard.
buildCandidate :: FilePath -> Text -> [Text] -> Text -> Text
buildCandidate targetFile tgt missing body =
  let ls1   = insertAfterModule (T.splitOn "\n" tgt) missing
      block = ["", body, ""]
  in T.intercalate "\n" $
       if isLiterate targetFile
         then insertBeforeLastFenceClose ls1 block
         else ls1 ++ block

insertAfterModule :: [Text] -> [Text] -> [Text]
insertAfterModule ls extra
  | null extra = ls
  | otherwise  = case break isModuleHeader ls of
      (pre, h:rest) -> pre ++ (h : extra) ++ rest
      (_, [])       -> extra ++ ls

insertBeforeLastFenceClose :: [Text] -> [Text] -> [Text]
insertBeforeLastFenceClose ls block =
  case lastFence of
    Just i  -> let (pre, post) = splitAt i ls in pre ++ block ++ post
    Nothing -> ls ++ block
  where
    lastFence = case [ i | (i, l) <- zip [0 ..] ls, "```" `T.isPrefixOf` T.stripStart l ] of
      [] -> Nothing
      is -> Just (last is)

-- | Load arbitrary candidate text under a FRESH top-level module name in a
-- throwaway session, returning the raw reply burst. The rename matters
-- (see 'validateCandidate'); the @suffix@ keeps the temp's extension so a
-- literate candidate is read as literate. A 'Left' is a /setup/ failure
-- (couldn't write, no agda binary, agda wouldn't start); a 'Right' carries
-- whatever Agda said — interpret it with 'interpretLoad' (pass/fail) or
-- 'interpretCheck' (full diagnostics). The temp dir is always cleaned up.
loadRenamedTemp :: ServerState -> FilePath -> Text -> IO (Either Text SendOutcome)
loadRenamedTemp ss targetFile candidate = do
  let c          = ssConfig ss
      tmpDir     = scratchSubdir ss </> ".validate"
      newMod     = "AgdaExploreValidate"
      suffix     = dropWhile (/= '.') (takeFileName targetFile)  -- ".agda" / ".lagda.md"
      tmpFile    = tmpDir </> (newMod ++ suffix)
      candidate' = renameTopModule (T.pack newMod) candidate
  createDirectoryIfMissing True tmpDir
  ew <- try (TIO.writeFile tmpFile candidate') :: IO (Either SomeException ())
  r <- case ew of
    Left e  -> pure (Left ("could not stage the validation copy: " <> T.pack (show e)))
    Right _ -> do
      mbin <- findBin "agda" (cfgAgdaBin c) "AGDA_BIN"
      case mbin of
        Nothing  -> pure (Left "could not locate the agda binary for validation.")
        Just bin -> do
          es <- startSession (SessionConfig bin (heapRtsArgs (cfgInteractHeapMb c)) (cfgInteractArgs c) validateTimeoutMicros) tmpFile
          case es of
            Left e     -> pure (Left ("agda could not start: " <> e))
            Right sess -> do
              out <- sendIotcm sess (iotcmLoad tmpFile (loadIncludes ss tmpFile))
              closeSession sess
              pure (Right out)
  _ <- try (removePathForcibly tmpDir) :: IO (Either SomeException ())
  pure r

-- | Pass/fail validation of candidate text (used by @promote@): 'Right ()'
-- iff it type-checks (remaining holes are fine). Built on 'loadRenamedTemp'.
validateCandidate :: ServerState -> FilePath -> Text -> IO (Either Text ())
validateCandidate ss targetFile candidate = do
  r <- loadRenamedTemp ss targetFile candidate
  pure $ case r of
    Left e    -> Left e
    Right out -> either Left (const (Right ())) (interpretLoad out)

-- | Splice @repl@ over the hole's range, guarding that the hole is inside a
-- code block. Marks the session dirty (its in-memory state has diverged
-- from disk, which the bridge does not write — the next query reloads).
applyHoleEdit :: ServerState -> Bool -> FilePath -> GoalEntry -> Text -> IO (Either Text Text)
applyHoleEdit ss write file e repl = case geRange e of
  Nothing              -> pure (Left "goal has no source range; cannot edit.")
  Just (GoalRange s en) -> withSourceGuarded ss file (rpPos s) $ \old -> do
    let new = spliceRange old (rpPos s) (rpPos en) repl
    applyOrDiff ss write file old new

-- | Realise an edit: compute the diff between the on-disk @old@ text and
-- the proposed @new@, broadcast it to the inspector, then either
--
--   * @write = False@ (the bridge default): mark the session dirty and
--     return the diff for the caller to apply — the bridge does not write;
--   * @write = True@: write the file, reload the module, and return the
--     diff plus the /refreshed/ goal list, so an interactive step becomes
--     one round-trip with strictly more information than a shell recompile.
--
-- A no-op edit (empty diff) short-circuits without writing in either mode.
applyOrDiff :: ServerState -> Bool -> FilePath -> Text -> Text -> IO (Either Text Text)
applyOrDiff ss write file old new
  | null d    = pure (Right "No change (agda's result matched the source already).")
  | otherwise = do
      emitEdit ss file old d
      if not write
        then markSessionDirty ss file >> pure (Right (diffMsg d))
        else do
          -- Write-time recheck: the edit was computed against @old@; if disk
          -- moved since (an external edit, or a slow validate/promote phase),
          -- refuse rather than clobber it. An unreadable file with a
          -- non-empty @old@ is the same hazard; @old == ""@ is the legitimate
          -- new-file creation path (give_file).
          nowTxt <- readFileSafe file
          case nowTxt of
            Right cur | contentStamp cur /= contentStamp old ->
              pure (Left "the file changed on disk while the edit was being prepared — \
                          \nothing written; re-run the tool.")
            Left _ | not (T.null old) ->
              pure (Left "the file became unreadable while the edit was being prepared — \
                          \nothing written; re-run the tool.")
            _ -> do
              w <- try (TIO.writeFile file new) :: IO (Either SomeException ())
              case w of
                Left e   -> pure (Left ("could not write " <> T.pack file <> ": " <> showT e))
                Right () -> do
                  r <- doLoadAfterWrite ss (contentStamp new) file
                  case r of
                    Left err            ->
                      pure (Right (wroteMsg file d <> "\n\n⚠ reloaded with a problem: " <> err))
                    Right (_, _, es, fp) -> do
                      emitGoals ss fp es
                      pure (Right (wroteMsg file d <> "\n\n" <> renderGoals fp es))
  where
    d = unifiedDiff file old new

wroteMsg :: FilePath -> String -> Text
wroteMsg file d =
  "Wrote the edit to " <> T.pack file <> " and reloaded. Applied diff:\n\n" <> T.pack d

-- | Read the source and run the edit only if the target offset is inside
-- an Agda code block (a no-op for plain @.agda@; a guard for @.lagda.md@).
withSourceGuarded :: ServerState -> FilePath -> Int -> (Text -> IO (Either Text Text)) -> IO (Either Text Text)
withSourceGuarded ss file pos act = do
  efile <- readSourceStamped ss file
  case efile of
    Left err  -> pure (Left err)
    Right old
      | isInsideCode (codeBlocksFor file old) pos -> act old
      | otherwise -> pure (Left "refusing to edit: the hole is not inside an Agda code block \
                                \(literate-Markdown prose).")

diffMsg :: String -> Text
diffMsg diff
  | null diff = "No change (agda's result matched the source already)."
  | otherwise = "(diff only — `write:true` to apply + reload):\n\n" <> T.pack diff

markSessionDirty :: ServerState -> FilePath -> IO ()
markSessionDirty ss file =
  modifyMVar_ (ssSessions ss) (pure . M.adjust (\e -> e { seDirty = True }) file)

readFileSafe :: FilePath -> IO (Either Text Text)
readFileSafe fp = do
  r <- try (TIO.readFile fp) :: IO (Either SomeException Text)
  pure (either (Left . ("cannot read source: " <>) . T.pack . show) Right r)

-- | 'contentStamp' of a file's current on-disk content, or 'Nothing' if it
-- cannot be read.
stampOf :: FilePath -> IO (Maybe Word64)
stampOf fp = either (const Nothing) (Just . contentStamp) <$> readFileSafe fp

-- | Read a mutation's source file and refuse when it no longer matches the
-- session's load stamp — an external edit since the goals were computed, so
-- the cached hole offsets no longer describe this content. A file with
-- no registered session (e.g. @give_file@ on an unloaded path) is read
-- as-is. An unknown load stamp (file changed while loading) also refuses.
readSourceStamped :: ServerState -> FilePath -> IO (Either Text Text)
readSourceStamped ss file = do
  eTxt <- readFileSafe file
  case eTxt of
    Left err  -> pure (Left err)
    Right txt -> do
      m <- readMVar (ssSessions ss)
      pure $ case M.lookup file m of
        Nothing -> Right txt
        Just e  -> case seLoadHash e of
          Just h | h == contentStamp txt -> Right txt
          Just _  -> Left staleDiskMsg
          Nothing -> Left "the file was changing on disk while it was loaded — \
                          \re-run `load file=…` before mutating it."

-- | The current load stamp of a registered file (for a mid-batch re-check).
currentStamp :: ServerState -> FilePath -> IO (Maybe Word64)
currentStamp ss file = do
  m <- readMVar (ssSessions ss)
  pure (M.lookup file m >>= seLoadHash)

staleDiskMsg :: Text
staleDiskMsg =
  "the file changed on disk since this session's last load — re-run \
  \`load file=…` and pick goals from the fresh list (ids may have been \
  \renumbered); nothing was changed."

-- | Send one command to an already-resolved session and return its reply
-- burst, or a session-level error.
runRaw :: Session -> String -> IO (Either Text [Reply])
runRaw sess cmd = do
  out <- sendIotcm sess cmd
  pure $ case out of
    SendTimeout _  -> Left "agda timed out (session reset); reload and retry."
    SendDied _ err -> Left ("agda session ended: " <> err)
    SendOk rs      -> Right rs

-- | 'runRaw' with a hard wall-clock budget (µs) — for a Mimer step that must
-- not wedge a @construct@ batch on a pathological goal.
runRawBudget :: Int -> Session -> String -> IO (Either Text [Reply])
runRawBudget budget sess cmd = do
  out <- sendIotcmBudget budget sess cmd
  pure $ case out of
    SendTimeout _  -> Left "agda exceeded its wall budget on this step (session reset); \
                           \reload and retry, or raise the goal's `timeout`."
    SendDied _ err -> Left ("agda session ended: " <> err)
    SendOk rs      -> Right rs

-- ---------------------------------------------------------------------
-- Session registry + load
-- ---------------------------------------------------------------------

sessionTimeoutMicros :: Int
sessionTimeoutMicros = 60 * 1000000

-- | Fixed grace added on top of a Mimer probe's own @-t@ budget to bound the
-- /whole/ call as wall-clock: Mimer's @-t@ bounds only its search, not
-- the goal-type normalization Agda does first, so a pathological goal
-- (@2 ^ n@-style) would otherwise wedge the serial session for the full
-- 'sessionTimeoutMicros'. The grace covers command dispatch, scope
-- resolution, and modest normalization; anything past it is the wedge this
-- kills — the session is reset and the caller told to retry.
probeGraceSecs :: Int
probeGraceSecs = 5

-- | Wall-clock budget (µs) for a Mimer probe whose search budget is @secs@.
probeBudgetMicros :: Int -> Int
probeBudgetMicros secs = (max 1 secs + probeGraceSecs) * 1000000

-- | Mimer search budget (seconds) for a lone @construct@ auto step: a quick
-- probe (a real hint solves near-instantly), wrapped as a wall-clock bound by
-- 'probeBudgetMicros'. A longer hunt belongs in the `auto` tool.
constructAutoSecs :: Int
constructAutoSecs = 5

-- | Resolve a user file argument to an absolute, normalised path under the
-- project root.
absFile :: ServerState -> Text -> FilePath
absFile ss t =
  let raw = T.unpack t
  in normalise (if isAbsolute raw then raw else cfgProjectRoot (ssConfig ss) </> raw)

-- | (Re)load a module: ensure a live session (spawn if absent/dead), send
-- @Cmd_load@, reconcile the stable-goal map, store the entry, and return
-- the raw reply burst alongside. The single place a @Cmd_load@ is issued +
-- reconciled; 'doLoad' and 'runCheck' read different things off it. On a
-- load that yields goals the stable-goal map is re-synced; on a load error
-- the prior map is preserved (so a transient error doesn't drop stable ids).
loadAndSync :: ServerState -> Maybe Word64 -> FilePath
            -> IO (Either Text (Session, GoalMap, [GoalEntry], SendOutcome))
loadAndSync ss mExpect file = modifyMVar (ssSessions ss) $ \m -> do
  eSess <- getLiveSession ss m file
  case eSess of
    Left err   -> pure (m, Left err)
    Right sess -> do
      let mPrev = M.lookup file m
          gm0   = maybe emptyGoalMap seGoalMap mPrev
      -- Bracket Cmd_load with two reads: read-before is fail-safe against an
      -- edit landing after our read; read-after alone would be unsound (an
      -- edit between Agda's read and ours would falsely match). A change
      -- during the load makes the bracket unstable → stamp unknown → the
      -- entry is dirty and mutators refuse until a clean reload.
      preH  <- stampOf file
      out   <- sendIotcm sess (iotcmLoad file (loadIncludes ss file))
      postH <- stampOf file
      now   <- getCurrentTime
      -- Reuse the existing last-used cell when reloading a known file (so its
      -- idle clock is reset, not orphaned); otherwise mint a fresh one.
      luRef <- maybe (newIORef now) (\e -> seLastUsed e <$ writeIORef (seLastUsed e) now)
                     mPrev
      let stamp     = if preH == postH then preH else Nothing
          gmBase    = if shouldKeepGoalIds mExpect (seLoadHash =<< mPrev) stamp
                        then gm0 else dropEntriesKeepNext gm0
          (gm1, es) = case interpretLoad out of
                        Right goals -> syncGoals gmBase goals
                        Left _      -> (gmBase, [])
          m1        = M.insert file (SessionEntry sess gm1 (isNothing stamp) luRef stamp) m
      m2 <- capSessions (cfgMaxSessions (ssConfig ss)) file m1
      pure (m2, Right (sess, gm1, es, out))

-- | (Re)load a module, returning the session, the new goal map, the goal
-- entries, and the file path — or the load error. Wraps 'loadAndSync',
-- returning 'Left' on a load error. Offset-keyed goal ids are reset unless
-- the content is unchanged since the prior load.
doLoad :: ServerState -> FilePath -> IO (Either Text (Session, GoalMap, [GoalEntry], FilePath))
doLoad ss = doLoadWith ss Nothing

-- | 'doLoad' after a bridge-initiated write of content hashing to @h@: since
-- the bridge knows the exact new layout, offset-keyed goal-id reuse stays
-- allowed as long as disk still matches what was written.
doLoadAfterWrite :: ServerState -> Word64 -> FilePath
                 -> IO (Either Text (Session, GoalMap, [GoalEntry], FilePath))
doLoadAfterWrite ss h = doLoadWith ss (Just h)

doLoadWith :: ServerState -> Maybe Word64 -> FilePath
           -> IO (Either Text (Session, GoalMap, [GoalEntry], FilePath))
doLoadWith ss mExpect file = do
  r <- loadAndSync ss mExpect file
  pure $ case r of
    Left err                  -> Left err
    Right (sess, gm, es, out) -> case interpretLoad out of
      Left lerr -> Left lerr
      Right _   -> Right (sess, gm, es, file)

-- | RTS flags that cap a spawned @agda@'s heap (@+RTS -M<n>m -RTS@), or none
-- when the cap is @<= 0@. Bounds the worst-case footprint of a single
-- interaction load: a runaway whole-project elaboration fails with a clean
-- heap-overflow instead of being OOM-killed. Driven by @interaction-heap-mb@.
heapRtsArgs :: Int -> [String]
heapRtsArgs mb
  | mb <= 0   = []
  | otherwise = ["+RTS", "-M" ++ show mb ++ "m", "-RTS"]

-- | Bound the number of live sessions (one idle @agda@ process each) to
-- @cap@ ('cfgMaxSessions'). When over the cap, close sessions other than the
-- one just loaded — not strict LRU, but a deterministic bound, logged so the
-- eviction is never silent.
capSessions :: Int -> FilePath -> M.Map FilePath SessionEntry -> IO (M.Map FilePath SessionEntry)
capSessions cap keep m
  | M.size m <= cap' = pure m
  | otherwise =
      let victims = take (M.size m - cap') [ k | k <- M.keys m, k /= keep ]
      in foldM evict m victims
  where
    cap' = max 1 cap   -- always keep at least the just-loaded session
    evict acc v = do
      maybe (pure ()) (closeSession . seSession) (M.lookup v acc)
      hPutStrLn stderr ("agda-explore: interaction-session cap reached; closed session for " ++ v)
      pure (M.delete v acc)

-- | Close every live interaction session — called on daemon shutdown so the
-- child @agda@ processes are reaped rather than orphaned.
closeAllSessions :: ServerState -> IO ()
closeAllSessions ss = do
  m <- readMVar (ssSessions ss)
  mapM_ (closeSession . seSession) (M.elems m)

-- | How often the idle-session reaper wakes to scan.
reaperTickMicros :: Int
reaperTickMicros = 60 * 1000000  -- 60s

-- | Background loop (forked from "Main" only when @interaction-idle-timeout >
-- 0@) that closes interaction sessions idle longer than 'cfgSessionIdleSecs',
-- freeing the multi-GB @agda@ process an agent walked away from. A reaped
-- session reloads (cold) on next use — the @load@ tool already instructs
-- clients to re-load and re-read goal ids, so this is behaviourally safe.
--
-- Safety: a session is reaped only when 'sessionTryReserve' succeeds (no
-- @sendIotcm@ in flight). The keep/reap decision runs under the 'ssSessions'
-- lock so a query cannot fetch a session mid-reap; the actual 'closeSession'
-- (which can block up to ~2s reaping the OS process) runs /after/ the lock is
-- released, against entries already removed from the registry.
reapIdleSessions :: ServerState -> IO ()
reapIdleSessions ss = forever $ do
  threadDelay reaperTickMicros
  let idle = cfgSessionIdleSecs (ssConfig ss)
  when (idle > 0) $ do
    now <- getCurrentTime
    victims <- modifyMVar (ssSessions ss) $ \m -> do
      decided <- forM (M.toList m) $ \fe@(_, e) -> do
        lu <- readIORef (seLastUsed e)
        if realToFrac (diffUTCTime now lu) > (fromIntegral idle :: Double)
          then do
            free <- sessionTryReserve (seSession e)  -- skip if mid-command
            pure (if free then Right fe else Left fe)
          else pure (Left fe)
      let keep = M.fromList [ fe | Left  fe <- decided ]
          vics =            [ fe | Right fe <- decided ]
      pure (keep, vics)
    forM_ victims $ \(f, e) -> do
      closeSession (seSession e)
      hPutStrLn stderr ("agda-explore: closed interaction session idle > "
                          ++ show idle ++ "s: " ++ f)

-- | A live session for @file@: reuse the registered one if still alive,
-- otherwise close the dead one and spawn a fresh process. Does not mutate
-- the registry — the caller stores the resulting entry.
getLiveSession :: ServerState -> M.Map FilePath SessionEntry -> FilePath -> IO (Either Text Session)
getLiveSession ss m file = case M.lookup file m of
  Just e -> do
    alive <- sessionAlive (seSession e)
    if alive then pure (Right (seSession e))
             else closeSession (seSession e) >> spawn
  Nothing -> spawn
  where
    spawn = do
      mbin <- findBin "agda" (cfgAgdaBin (ssConfig ss)) "AGDA_BIN"
      case mbin of
        Nothing  -> pure (Left "could not locate the agda binary (set AGDA_BIN or pass --agda-bin).")
        Just bin -> startSession (SessionConfig bin (heapRtsArgs (cfgInteractHeapMb (ssConfig ss))) (cfgInteractArgs (ssConfig ss)) sessionTimeoutMicros) file

-- | Resolve the target session for a goal command, reloading if the entry
-- was marked dirty by the watcher or its process died. Runs the action
-- with the resolved file, current goal map, and the goal's Agda
-- interaction id (translated from the client's stable id).
withGoal
  :: ServerState -> Value
  -> (Session -> FilePath -> GoalEntry -> Int -> IO (Either Text Text))
  -> IO (Either Text Text)
withGoal ss a act = case argScalarText a "goal" of
  Nothing      -> pure (Left "this tool requires a `goal` argument — a stable id like `g0` \
                              \(a bare integer such as 0 also works).")
  Just goalArg -> case parseStableId goalArg of
    Nothing  -> pure (Left ("not a goal id: " <> goalArg <> " (expected `g0`, `g1`, …)."))
    Just sid -> do
      r <- resolveLoaded ss (argText a "file")
      case r of
        Left err -> pure (Left err)
        Right (file, sess, gm) -> case lookupStable gm sid of
          Just e | Just iid <- geIid e -> act sess file e iid
          _ -> pure (Left (renderStableId sid <> " is not an open goal (it may have been \
                            \solved, the file may have changed on disk and ids were \
                            \renumbered, or the module needs `load`)."))

-- | Pick the session to use (by explicit @file@, or the sole loaded one),
-- reloading it when dirty/dead so a query after a source edit just works.
resolveLoaded :: ServerState -> Maybe Text -> IO (Either Text (FilePath, Session, GoalMap))
resolveLoaded ss mFileArg = do
  m <- readMVar (ssSessions ss)
  case pickFile m of
    Left err   -> pure (Left err)
    Right file -> do
      let e = m M.! file
      alive <- sessionAlive (seSession e)
      if seDirty e || not alive
        then do
          r <- doLoad ss file
          pure $ case r of
            Left err              -> Left err
            Right (s, gm, _, _)   -> Right (file, s, gm)
        else do
          -- Reusing a live session: refresh its idle clock so the reaper
          -- doesn't close a session that is actively serving goal commands.
          writeIORef (seLastUsed e) =<< getCurrentTime
          pure (Right (file, seSession e, seGoalMap e))
  where
    pickFile m = case mFileArg of
      Just f  -> let af = absFile ss f
                 in if M.member af m then Right af
                    else Left ("no loaded session for " <> f <> "; call `load` first.")
      Nothing -> case M.keys m of
        [k] -> Right k
        []  -> Left "no module loaded; call `load <file>` first."
        _   -> Left "multiple modules are loaded; pass `file=<path>` to choose one."

-- | Run one command against an already-resolved session and interpret its
-- reply burst.
runCmd :: Session -> String -> ([Reply] -> Either Text Text) -> IO (Either Text Text)
runCmd sess cmd interpret = either Left interpret <$> runRaw sess cmd

-- ---------------------------------------------------------------------
-- Reply interpretation
-- ---------------------------------------------------------------------

-- | The first Error message in a burst, if any. Agda's error reply shadows
-- the other replies: a half-checked load emits an empty AllGoalsWarnings
-- *and* an Error, and a rejected give emits an Error with no GiveAction —
-- in both cases the message is what the caller wants.
firstError :: [Reply] -> Maybe Text
firstError rs = case [m | ReplyDisplayInfo (ErrorReply m) <- rs] of
  (m:_) -> Just m
  _     -> Nothing

-- | A load burst: an Error wins over goals.
interpretLoad :: SendOutcome -> Either Text [Goal]
interpretLoad out = case out of
  SendTimeout _  -> Left "agda timed out during load (session reset)."
  SendDied _ err -> Left ("agda session ended during load: " <> err)
  SendOk rs      -> case firstError rs of
    Just m  -> Left m
    Nothing -> Right (concat [gs | ReplyDisplayInfo (AllGoalsWarnings gs _ _) <- rs])

-- | The full diagnostics of a load — every error, every warning, and the
-- open goals — for the @check@ tool. Where 'interpretLoad' keeps only the
-- first error or else the goals, this keeps them all so @check@ can report
-- a complete picture in one call.
data CheckOutcome = CheckOutcome
  { coErrors   :: ![Text]
  , coWarnings :: ![Text]
  , coGoals    :: ![Goal]
  }

interpretCheck :: SendOutcome -> CheckOutcome
interpretCheck out = case out of
  SendTimeout _  -> CheckOutcome ["agda timed out during load (session reset)."] [] []
  SendDied _ err -> CheckOutcome ["agda session ended during load: " <> err] [] []
  SendOk rs      ->
    let agws = [ (gs, es, ws) | ReplyDisplayInfo (AllGoalsWarnings gs es ws) <- rs ]
        hard = [ m | ReplyDisplayInfo (ErrorReply m) <- rs ]
    in CheckOutcome (hard ++ concat [ es | (_, es, _) <- agws ])
                    (concat [ ws | (_, _, ws) <- agws ])
                    (concat [ gs | (gs, _, _) <- agws ])

-- | The first GoalSpecific goal-info in a burst (Error wins).
firstGoalInfo :: [Reply] -> Either Text GoalInfo
firstGoalInfo rs = case firstError rs of
  Just m  -> Left m
  Nothing -> case [gi | ReplyDisplayInfo (GoalSpecific _ gi) <- rs] of
    (gi:_) -> Right gi
    []     -> Left "agda returned no goal info (is the goal id still open?)."

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

renderGoals :: FilePath -> [GoalEntry] -> Text
renderGoals file es
  | null es   = "Loaded " <> T.pack file <> " — no open goals."
  | otherwise =
      "Loaded " <> T.pack file <> " — " <> showT (length es) <> " open goal(s):\n"
        <> T.unlines [ "  " <> renderStableId (geStable e) <> "  : " <> geType e <> posNote e | e <- es ]
        <> goalsFooter es

-- | The next-step routing footer appended wherever open goals are listed
-- (load / check / a @write:true@ reload). Names the first goal concretely
-- so the suggested calls are copy-pasteable.
goalsFooter :: [GoalEntry] -> Text
goalsFooter []      = ""
goalsFooter (e : _) =
  let g = renderStableId (geStable e)
  in "→ next: `auto goal=" <> g <> " write:true` (Mimer proof search) · \
     \`construct steps=[{op:auto,goal:\"*\"}]` (Mimer on every goal) · \
     \`inspect op=type goal=" <> g <> "` (type + context) · a `construct` \
     \case_split/give step · `lemmas goal=" <> g
     <> "` (find a reusable lemma)."

posNote :: GoalEntry -> Text
posNote e = case geRange e of
  Just (GoalRange s _) -> "   (" <> showT (rpLine s) <> ":" <> showT (rpCol s) <> ")"
  Nothing              -> ""

renderGoalTypeFull :: GoalInfo -> Text
renderGoalTypeFull gi = case gi of
  GiGoalType ty ctx ->
    "Goal: " <> ty <> (if null ctx then "" else "\n" <> renderContext ctx)
  other -> renderGoalInfoExpr other

renderContextOnly :: GoalInfo -> Text
renderContextOnly gi = case gi of
  GiGoalType _ ctx
    | null ctx  -> "(no binders in scope)"
    | otherwise -> renderContext ctx
  other -> renderGoalInfoExpr other

renderContext :: [ContextEntry] -> Text
renderContext ctx = T.intercalate "\n"
  [ "  " <> ceName e <> " : " <> ceType e
       <> (if ceInScope e then "" else "   (not in scope)")
  | e <- ctx ]

renderGoalInfoExpr :: GoalInfo -> Text
renderGoalInfoExpr gi = case gi of
  GiInferredType e -> e
  GiNormalForm e   -> e
  GiGoalType ty _  -> ty
  GiOther k        -> "(unrecognised goal-info kind: " <> k <> ")"

-- ---------------------------------------------------------------------
-- check  (structured validate + diagnostics)
-- ---------------------------------------------------------------------

-- | Validate a module and report a ✓/✗ verdict with every error/warning
-- and the open goals — the bridge analogue of @agda <File>@ over the warm
-- session. @content@ dry-runs proposed text (under a throwaway module name,
-- nothing written); otherwise the on-disk file is loaded in the live
-- session (also refreshing its stable-goal map). Read-only.
runCheck :: ToolRunner
runCheck ss a = case argText a "file" of
  Nothing -> pure (Left "check requires a `file` argument.")
  Just f  ->
    let file = absFile ss f in
    case argText a "content" of
      Just content -> do
        r <- loadRenamedTemp ss file content
        pure $ case r of
          Left err  -> Left err
          Right out -> Right (renderCheckDry file (interpretCheck out))
      Nothing -> do
        r <- loadAndSync ss Nothing file
        case r of
          Left err                 -> pure (Left err)
          Right (sess, _, es, out) -> do
            emitGoals ss file es
            (hints, mNote) <- autoHints ss sess file es
            pure (Right (renderCheckLive file (interpretCheck out) es hints mNote))

-- | Speculative Mimer probe over the first few open goals after a live
-- @check@: report ready-made solutions inline so the agent sees the payoff
-- of proof search without having to remember @auto@ exists — the check path is
-- the surface agents actually use, so this is where the ranker's hints are
-- delivered (Phase 4). Each goal is probed via 'autoSolve': plain, then the top
-- @'cfgAutoHintsLemmas'@ in-scope graph hints as one batch (the same seeding
-- 'runAuto' does — snapshot rank 1a\/1b, live context 1d, scope partition 1c),
-- and the per-hint fallback tier is dropped so a routine @check@ stays bounded.
-- @cfgAutoHintsLemmas = 0@ ⇒ plain Mimer; no snapshot ⇒ plain too.
-- The 'HintProv' rides back so a hint that closed a goal is named to the agent.
--
-- Each probe is wall-clock-bounded ('probeBudgetMicros' over 'cfgAutoHintsSecs'),
-- so a pathological goal can't wedge a routine @check@ — on budget expiry
-- (or session death) probing stops and a note is returned; capped at
-- 'cfgAutoHintsLimit' goals; @--no-auto-hints@ disables. A successful probe
-- solves the meta in Agda's /session/ state (the file is untouched), so any
-- success marks the session dirty — the next interaction reloads from
-- unchanged disk.
autoHints :: ServerState -> Session -> FilePath -> [GoalEntry]
          -> IO ([(GoalEntry, Text, HintProv)], Maybe Text)
autoHints ss sess file es
  | not (cfgAutoHints c) || null cands = pure ([], Nothing)
  | otherwise = do
      -- Loop-invariant hint machinery, built once and only when seeding hints
      -- (@nHints = 0@ ⇒ no snapshot ⇒ 'goalProbeHints' yields no hints ⇒ plain).
      (mLd, mInScope) <- if nHints <= 0 then pure (Nothing, Nothing)
                                        else hintScopeFor ss file
      let probeAll [] acc = pure (reverse acc, Nothing)
          probeAll ((e, iid) : rest) acc = do
            (probeCands, _) <- goalProbeHints mLd mInScope nHints sess file e
            res <- autoSolve tiers sess file iid secs (map fst probeCands)
            case res of
              AutoGive prov t -> probeAll rest ((e, t, prov) : acc)
              AutoNone _ _    -> probeAll rest acc
              AutoAbort _     -> pure (reverse acc, Just (abortNote (renderStableId (geStable e))))
      (hints, mNote) <- probeAll cands []
      when (not (null hints)) (markSessionDirty ss file)
      pure (hints, mNote)
  where
    c       = ssConfig ss
    secs    = max 1 (cfgAutoHintsSecs c)
    nHints  = max 0 (cfgAutoHintsLemmas c)
    -- Plain + batch, no per-hint fallback: the batch already tries these lemmas
    -- (more powerfully), so the third tier is pure latency on a routine check.
    tiers   = AutoTiers { atPlain = True
                        , atBatch = not (cfgNoHintBatch c)
                        , atPerHint = False }
    cands = take (max 0 (cfgAutoHintsLimit c)) [ (e, iid) | e <- es, Just iid <- [geIid e] ]
    abortNote gid =
      "(auto-hints probe exceeded its " <> showT secs <> "s+" <> showT probeGraceSecs
        <> "s budget on " <> gid <> "; remaining goals were not probed — the Agda \
           \session was reset and reloads on the next command.)"

checkVerdict :: FilePath -> CheckOutcome -> Text
checkVerdict file co =
  (if null (coErrors co) then "✓ type-checks" else "✗ does not type-check")
    <> " — " <> T.pack file
    <> " (" <> (let n = length (coGoals co)
                in if n == 0 then "no open goals" else showT n <> " open goal(s)")
    <> ", " <> showT (length (coErrors co)) <> " error(s), "
    <> showT (length (coWarnings co)) <> " warning(s))."

renderDiagnostics :: CheckOutcome -> Text
renderDiagnostics co = errBlock <> warnBlock
  where
    errBlock  = if null (coErrors co) then ""
                else "\n\nErrors:\n"   <> T.unlines [ "  • " <> e | e <- coErrors co ]
    warnBlock = if null (coWarnings co) then ""
                else "\n\nWarnings:\n" <> T.unlines [ "  • " <> w | w <- coWarnings co ]

-- | @check@ of the on-disk file: goals carry stable ids (from the live
-- session's reconciled map) and source positions. @hints@ are the
-- speculative Mimer solutions from 'autoHints' — surfaced inline so the
-- agent sees the payoff of proof search without having had to ask for it. Each
-- carries a 'HintProv': when a graph-ranked lemma closed the goal it is named
-- ("via lemma …"), which teaches the agent the lemma exists (value beyond the
-- filled hole).
renderCheckLive :: FilePath -> CheckOutcome -> [GoalEntry] -> [(GoalEntry, Text, HintProv)] -> Maybe Text -> Text
renderCheckLive file co es hints mNote =
  checkVerdict file co <> renderDiagnostics co
    <> (if null es then ""
        else "\n\nOpen goals:\n"
               <> T.unlines [ "  " <> renderStableId (geStable e) <> "  : " <> geType e <> posNote e | e <- es ]
               <> mimerBlock
               <> goalsFooter es)
    <> maybe "" ("\n" <>) mNote            -- auto-hints budget/reset note
  where
    mimerBlock = case hints of
      []          -> ""
      [(e, t, p)] ->
        "Mimer already finds a term for " <> renderStableId (geStable e)
          <> provNote p <> ": `" <> t <> "` — accept with `auto goal="
          <> renderStableId (geStable e) <> " write:true`.\n"
      _           ->
        "Mimer already finds terms for " <> showT (length hints) <> " of these:\n"
          <> T.unlines [ "  " <> renderStableId (geStable e) <> " ← " <> t <> provNote p
                       | (e, t, p) <- hints ]
          <> "Accept them in one call with `construct steps=[{op:auto,goal:\"*\"}] write:true`.\n"
    -- Name the lemma(s) a hint tier used; blank for a plain (unhinted) solve.
    provNote Plain         = ""
    provNote (ViaHint h)   = " (via lemma `" <> h <> "`)"
    provNote (ViaBatch hs) = " (via " <> codeList hs <> ")"

-- | @check content=…@: a dry-run has no stable-goal map (the text isn't
-- loaded as the real module), so goals are shown by raw index + position
-- into the proposed text.
renderCheckDry :: FilePath -> CheckOutcome -> Text
renderCheckDry file co =
  "(dry-run of proposed content — nothing written)\n"
    <> checkVerdict file co <> renderDiagnostics co
    <> (if null (coGoals co) then ""
        else "\n\nOpen goals:\n"
               <> T.unlines [ "  ?" <> showT i <> "  : " <> goalType g <> goalPosNote g
                            | (i, g) <- zip [0 :: Int ..] (coGoals co) ])
    <> "\n(Positions index the proposed text; apply it, then `load` for stable goal ids.)"

goalPosNote :: Goal -> Text
goalPosNote g = case goalRange g of
  Just (GoalRange s _) -> "   (" <> showT (rpLine s) <> ":" <> showT (rpCol s) <> ")"
  Nothing              -> ""

-- ---------------------------------------------------------------------
-- repair  (graph-backed, spec-preserving repair loop)
-- ---------------------------------------------------------------------

-- | What the loop did, rendered into the tool result.
data RepairReport = RepairReport
  { rrApplied   :: ![Text]  -- ^ applied fixes, in order
  , rrRefused   :: ![Text]  -- ^ diagnostics declined (semantic / unknown)
  , rrRemaining :: ![Text]  -- ^ errors still present at the end
  , rrGoals     :: ![Text]  -- ^ open goal types remaining
  , rrIters     :: !Int
  , rrCompiles  :: !Int
  , rrDone      :: !Bool    -- ^ typechecks (no errors) at the end
  }

-- | Interpret a candidate text by recompiling it under a throwaway module.
validateText :: ServerState -> FilePath -> Text -> IO (Either Text CheckOutcome)
validateText ss file text = fmap (fmap interpretCheck) (loadRenamedTemp ss file text)

runRepair :: ToolRunner
runRepair ss a = case argText a "file" of
  Nothing -> pure (Left "repair requires a `file` argument.")
  Just f  -> do
    let file     = absFile ss f
        mContent = argText a "content"
        -- `content` is a dry-run of proposed text: never write, always diff.
        write    = argBool a "write" False && isNothing mContent
        maxIter  = max 1 (argInt a "max_iter" 8)
    eOrig <- case mContent of
               Just c  -> pure (Right c)
               Nothing -> readFileSafe file
    case eOrig of
      Left err   -> pure (Left err)
      Right orig -> do
        -- The graph is the scope oracle (read-only, like any read tool); the
        -- file itself is validated through the live session. A missing graph
        -- degrades to typo-only repair, not a failure.
        eLd <- ensureFresh ss
        let mld = either (const Nothing) (Just . fst) eLd
            env = RS.buildEnv (maybe [] ldRealDefs mld) (maybe M.empty ldAliases mld)
        (final, rep0) <- repairLoop ss file env maxIter orig
        -- Remaining-error text comes from the throwaway validation module;
        -- map its path/name back to the real file so the report reads cleanly.
        let suffix   = dropWhile (/= '.') (takeFileName file)
            tmpPath  = scratchSubdir ss </> ".validate" </> ("AgdaExploreValidate" ++ suffix)
            -- full temp path first (it still contains the module name), then
            -- any bare module-name token left in the prose.
            sanitize = T.replace "AgdaExploreValidate" (T.pack (dropExtensions (takeFileName file)))
                     . T.replace (T.pack tmpPath) (T.pack file)
            rep      = rep0 { rrRemaining = map sanitize (rrRemaining rep0) }
            banner = renderRepairReport rep
        if final == orig
          then pure (Right (banner <> "\n\n(no change applied — file left as-is)"))
          else do
            r <- applyOrDiff ss write file orig final
            pure $ case r of
              Left e  -> Left e
              Right d -> Right (banner <> "\n\n" <> d)

-- | The monotone repair driver. Each round: validate the current text,
-- classify the diagnostics, try candidate import edits against the
-- first actionable diagnostic, accept the first that resolves it without
-- raising the error count or touching a signature, and recurse. Terminates at
-- a clean typecheck, when nothing is actionable (refuse), or at @max_iter@.
repairLoop :: ServerState -> FilePath -> RS.Env -> Int -> Text
           -> IO (Text, RepairReport)
repairLoop ss file env maxIter orig = do
  -- One compile of the original; thereafter each iteration reuses the outcome
  -- 'firstWorking' already computed for the candidate it accepted (no re-check).
  e0 <- validateText ss file orig
  case e0 of
    Left setupErr -> pure (orig, mkReport False 0 1 [] ["could not validate: " <> setupErr] Nothing)
    Right co0     -> go 0 1 [] orig co0
  where
    go :: Int -> Int -> [Text] -> Text -> CheckOutcome -> IO (Text, RepairReport)
    go iter compiles applied text co
      | null (coErrors co) = pure (text, mkReport True iter compiles applied [] (Just co))
      | iter >= maxIter    = pure (text, mkReport False iter compiles applied ["reached max_iter"] (Just co))
      | otherwise =
          let diags      = RD.classify (coErrors co)
              actionable = filter isActionable diags
          in if null actionable
               then pure (text, mkReport False iter compiles applied (refusalMsgs diags) (Just co))
               else do
                 (mstep, dc) <- firstWorking ss file env co text actionable
                 case mstep of
                   Just (text', desc, co') ->
                     go (iter + 1) (compiles + dc) (applied ++ [desc]) text' co'
                   Nothing ->
                     let names   = map diagName actionable
                         suggFor n = RS.nearMissSuggestions env text n
                         suggMsgs = [ n <> " (did you mean: " <> T.intercalate ", " s <> "?)"
                                    | n <- names, let s = suggFor n, not (null s) ]
                         note = if null suggMsgs then ""
                                else " — closest existing names: " <> T.intercalate "; " suggMsgs
                                       <> " (repair does not rename; fix the spelling, or add the \
                                          \missing import/definition by hand)"
                     in pure (text, mkReport False iter (compiles + dc) applied
                                ["no candidate resolved: " <> T.intercalate ", " names <> note]
                                (Just co))

    mkReport done iter compiles applied refused mco = RepairReport
      { rrApplied   = applied
      , rrRefused   = refused
      , rrRemaining = maybe [] coErrors mco
      , rrGoals     = maybe [] (map goalType . coGoals) mco
      , rrIters     = iter
      , rrCompiles  = compiles
      , rrDone      = done
      }

-- | The not-in-scope name a scope/parse diagnostic targets ('Nothing' for the
-- classes the loop only reports — incomplete/refuse). One source for both
-- "is this actionable" and "name it in the report".
scopeName :: RD.Diagnostic -> Maybe Text
scopeName (RD.DScope n) = Just n
scopeName (RD.DParse n) = Just n
scopeName _             = Nothing

isActionable :: RD.Diagnostic -> Bool
isActionable = isJust . scopeName

diagName :: RD.Diagnostic -> Text
diagName = fromMaybe "?" . scopeName

-- | Human-readable notes for the diagnostics we decline to touch.
refusalMsgs :: [RD.Diagnostic] -> [Text]
refusalMsgs diags =
  [ "refused [" <> tag <> "] — semantic/unknown class, left untouched" | RD.DRefuse tag _ <- diags ]
  ++ [ "incomplete pattern match — `construct` a case_split step on the scrutinee" | RD.DIncomplete <- diags ]

-- | Try each candidate for each actionable diagnostic; return the first that
-- is accepted (its text, a description, and the 'CheckOutcome' the acceptance
-- test already computed — so the caller need not re-validate it), plus the
-- number of validation compiles spent (charged to the loop's budget regardless
-- of success).
firstWorking :: ServerState -> FilePath -> RS.Env -> CheckOutcome -> Text
             -> [RD.Diagnostic] -> IO (Maybe (Text, Text, CheckOutcome), Int)
firstWorking ss file env co text diags = go 0 flat
  where
    sigs0 = RE.signatures text
    -- Bound the per-round work: a parse dump can over-collect names, and each
    -- candidate costs a full throwaway-agda validate. Symbolic-first ordering
    -- (from parseErrorNames) means the cap bites the speculative alphabetic
    -- tail; Env-miss tokens already contribute no candidates.
    flat  = take 16 [ (d, cand) | d <- diags, cand <- RS.candidatesFor env text d ]
    go dc [] = pure (Nothing, dc)
    go dc ((d, cand) : rest) =
      case RE.applyEdits text cand of
        Nothing    -> go dc rest                            -- no-op edit
        Just text'
          | RE.signatures text' /= sigs0 -> go dc rest      -- would change a signature: refuse
          | otherwise -> case checkFileInputFor file text' of
              Rejected _ -> go dc rest                      -- zero-axiom guard
              Allowed    -> do
                r <- validateText ss file text'
                let dc' = dc + 1
                case r of
                  Left _                       -> go dc' rest
                  Right co' | accepts co co' d -> pure (Just (text', describeEdits cand, co'), dc')
                            | otherwise        -> go dc' rest

-- | Accept a candidate iff it compiles clean, or it resolves the targeted
-- name without raising the error count. Because imports only grow scope
-- (repair is import-only), each accepted round adds a new distinct import
-- line, so this is monotone — the loop cannot oscillate. @stillMissing@ comes
-- from the shared 'RD.stillMissingNames', which subtracts in-scope grammar
-- operators, so an operator that framed a parse error but is itself in scope
-- doesn't keep 'targetResolved' false.
accepts :: CheckOutcome -> CheckOutcome -> RD.Diagnostic -> Bool
accepts co co' d
  | null (coErrors co') = True
  | otherwise           = targetResolved && length (coErrors co') <= length (coErrors co)
  where
    joined = T.intercalate "\n" (coErrors co')
    stillMissing = RD.stillMissingNames joined
    targetResolved =
      maybe True (\n -> not (any (`elem` stillMissing) (RD.nameKeys n))) (scopeName d)

describeEdits :: [RE.Edit] -> Text
describeEdits = T.intercalate " + " . map one
  where
    one (RE.EAddImport l) = "added `" <> l <> "`"

renderRepairReport :: RepairReport -> Text
renderRepairReport rr =
  headline
    <> section "Applied fixes"   (rrApplied rr)
    <> section "Refused / notes" (rrRefused rr)
    <> section "Errors remaining" (rrRemaining rr)
    <> section "Open goals"      (rrGoals rr)
    <> goalFooter
    <> "\n(" <> showT (rrIters rr) <> " iteration(s), " <> showT (rrCompiles rr) <> " validation compile(s))"
  where
    headline
      | rrDone rr = "✓ repaired — file now type-checks."
      | null (rrApplied rr) = "✗ no repair applied."
      | otherwise = "◑ partially repaired — " <> showT (length (rrApplied rr))
                      <> " fix(es) applied, errors remain."
    section _ []  = ""
    section h xs  = "\n\n" <> h <> ":\n" <> T.unlines [ "  • " <> x | x <- xs ]
    -- repair fills scope/parse errors; goal-filling is delegated (a repair
    -- must not fabricate a proof) — route to the goal-driven tools.
    goalFooter
      | null (rrGoals rr) = ""
      | otherwise = "→ open goal(s) remain: fill with `construct steps=[{op:auto,goal:\"*\"}]` \
                    \(Mimer) / `lemmas goal=…` (reuse a lemma) / a `construct` case_split step."

-- ---------------------------------------------------------------------
-- give_file  (validated whole-file / append authoring)
-- ---------------------------------------------------------------------

-- | Author whole-file or appended content through the bridge: guard the
-- whole text (zero-axiom contract), type-check it, and on success return a
-- diff (or apply + reload with @write:true@). On a type error nothing
-- changes. The validated, contract-honouring counterpart to a blind
-- @Write@.
runGiveFile :: ToolRunner
runGiveFile ss a = case argText a "file" of
  Nothing -> pure (Left "give_file requires a `file` argument.")
  Just f  ->
    let file  = absFile ss f
        write = writeFlag a
    in case (argText a "content", argText a "append") of
         (Nothing, Nothing) ->
           pure (Left "give_file requires `content` (full file text) or `append` (a definition block).")
         (Just _, Just _) ->
           pure (Left "give_file takes `content` or `append`, not both.")
         (Just content, _) -> proceedGiveFile ss write file content
         (_, Just app)      -> do
           eold <- readFileSafe file
           case eold of
             Left e    -> pure (Left ("give_file append: cannot read target " <> T.pack file <> ": " <> e))
             Right old -> proceedGiveFile ss write file (buildCandidate file old [] app)

-- | Guard, validate, then diff/apply a fully-formed candidate file body.
proceedGiveFile :: ServerState -> Bool -> FilePath -> Text -> IO (Either Text Text)
proceedGiveFile ss write file candidate = case checkFileInputFor file candidate of
  Rejected why -> pure (Left ("give_file refused: " <> why))
  Allowed      -> do
    v <- loadRenamedTemp ss file candidate
    case v of
      Left err  -> pure (Left err)
      Right out ->
        let co = interpretCheck out in
        if not (null (coErrors co))
          then pure (Left ("give_file: the proposed content does not type-check — nothing changed:"
                             <> renderDiagnostics co))
          else do
            eold <- readFileSafe file
            let old = either (const "") id eold
            res <- applyOrDiff ss write file old candidate
            -- When we actually wrote, fold the authored file into the graph
            -- synchronously (the kick): a brand-new file's concrete defs are
            -- queryable as this call returns; an edited existing file's entry
            -- is re-run selectively. Best-effort (no-op if the write failed).
            case res of
              Right _ | write -> kickRebuild ss file
              _               -> pure ()
            pure (fmap (<> remainingGoalsNote co) res)

-- | A trailing "(N goals / M warnings remain)" note for 'runGiveFile'.
remainingGoalsNote :: CheckOutcome -> Text
remainingGoalsNote co =
  "\n\n" <> showT (length (coGoals co)) <> " open goal(s) after this change"
    <> (if null (coWarnings co) then "" else ", " <> showT (length (coWarnings co)) <> " warning(s)")
    <> "."

-- ---------------------------------------------------------------------
-- new_module  (scaffold a validated skeleton)
-- ---------------------------------------------------------------------

-- | One @{name, type}@ stub for 'runNewModule'.
data DefStub = DefStub !Text !Text
instance FromJSON DefStub where
  parseJSON = withObject "def" $ \o -> DefStub <$> o .: "name" <*> o .: "type"

-- | Scaffold a new module at @path@: a header matching the path, literate
-- fences for a @.lagda*@ path, graph-resolved imports, and a hole per stub
-- — type-checked before it is returned (or written + loaded with
-- @write:true@).
runNewModule :: ToolRunner
runNewModule ss a = case argText a "path" of
  Nothing -> pure (Left "new_module requires a `path` argument (the file to create).")
  Just p  -> do
    let file    = absFile ss p
        write   = argBool a "write" False
        openImp = argBool a "open" True
        lit     = isLiterate file
        modName = modNameFromPath ss file
        imports = fromMaybe [] (argLookup a "imports" >>= parseMaybe parseJSON)
        defs    = fromMaybe [] (argLookup a "defs" >>= parseMaybe parseJSON)
    -- Import resolution wants the graph index; ensureFresh seeds the
    -- preloaded snapshot (and serves-stale in live mode). Best-effort: a
    -- cold/failed index just yields no resolutions (every import unresolved).
    mld <- either (const Nothing) (Just . fst) <$> ensureFresh ss
    let env   = RS.buildEnv (maybe [] ldRealDefs mld) (maybe M.empty ldAliases mld)
        hints = [ ty | DefStub _ ty <- defs ]        -- stub types drive carrier affinity
        (impLines, unresolved) = resolveImports env hints openImp imports
        content                = buildModuleContent lit modName impLines defs
    case checkFileInputFor file content of
      Rejected why -> pure (Left ("new_module refused: " <> why))
      Allowed      -> do
        v <- loadRenamedTemp ss file content
        let vmsg = case v of
              Left err  -> "⚠ could not validate the scaffold: " <> err
              Right out -> let c = interpretCheck out
                           in if null (coErrors c)
                                then "✓ scaffold type-checks (" <> showT (length (coGoals c)) <> " hole(s))"
                                else "✗ scaffold does not type-check yet:" <> renderDiagnostics c
            unresNote = if null unresolved then ""
                        else "\n\nUnresolved imports (no defining module in the graph — add by hand): "
                               <> T.intercalate ", " unresolved
        if write
          then do
            ew <- try (do createDirectoryIfMissing True (takeDirectory file)
                          TIO.writeFile file content) :: IO (Either SomeException ())
            case ew of
              Left e   -> pure (Left ("new_module: could not write " <> T.pack file <> ": " <> showT e))
              Right () -> do
                -- Fold the new module into the read-side graph synchronously
                -- (the kick), so it is queryable the moment this call
                -- returns instead of only after the async watcher rebuild.
                kickRebuild ss file
                r <- doLoadAfterWrite ss (contentStamp content) file
                case r of
                  Left err             ->
                    pure (Right ("Created " <> T.pack file <> " (module " <> modName <> ").\n"
                                   <> vmsg <> unresNote <> "\n\n⚠ reload: " <> err))
                  Right (_, _, es, fp) -> do
                    emitGoals ss fp es
                    pure (Right ("Created " <> T.pack file <> " (module " <> modName <> ").\n\n"
                                   <> renderGoals fp es <> unresNote))
          else pure (Right ("Proposed module " <> modName <> " → " <> T.pack file <> "\n" <> vmsg <> unresNote
                              <> "\n\nWrite this content (or re-run with write=true), then `load`:\n\n"
                              <> contentFrame content))

-- | Frame proposed content between rules for the human/agent to copy when
-- @write@ is off.
contentFrame :: Text -> Text
contentFrame c = rule <> "\n" <> c <> (if "\n" `T.isSuffixOf` c then "" else "\n") <> rule
  where rule = "----------------------------------------"

-- | Resolve bare names to @open import <Module>@ (or @import@) lines via the
-- graph-backed 'RS.resolveImportModules' (alias-aware and
-- carrier-ranked by the stub types, so a constructor resolves to its
-- parent module and a @ℕ@ goal prefers @Data.Nat@). Names with no candidate
-- come back unresolved (reported, never invented). Deduped, input order
-- preserved.
resolveImports :: RS.Env -> [Text] -> Bool -> [Text] -> ([Text], [Text])
resolveImports env hints openImp names =
  let kw = if openImp then "open import " else "import "
      step nm = case RS.resolveImportModules env hints nm of
        (m:_) -> Left (kw <> m)
        []    -> Right nm
      rs = map step names
  in (nub [ l | Left l <- rs ], [ n | Right n <- rs ])

-- | Derive a @module … where@ name from a file path: relativise against the
-- most specific include root (else the project root), drop the
-- extension(s), and turn @/@ into @.@.
modNameFromPath :: ServerState -> FilePath -> Text
modNameFromPath ss file =
  let bases = cfgIncludes (ssConfig ss) ++ [cfgProjectRoot (ssConfig ss)]
      rels  = [ r | b <- bases, let r = makeRelative b file
                  , r /= file, not (".." `isPrefixOf` r) ]
      rel   = case sortOn length rels of { (x:_) -> x; [] -> takeFileName file }
  in T.replace "/" "." (T.pack (dropExtensions rel))

-- | Assemble the scaffold text: header + import block + a `name : T` /
-- `name = ?` hole per stub, wrapped in a ```agda fence for a literate file.
buildModuleContent :: Bool -> Text -> [Text] -> [DefStub] -> Text
buildModuleContent lit modName imps defs =
  let header   = "module " <> modName <> " where"
      impBlock = if null imps then [] else "" : imps
      defBlock = concat [ ["", n <> " : " <> ty, n <> " = ?"] | DefStub n ty <- defs ]
      body     = T.unlines (header : impBlock ++ defBlock)
  in if lit then "# " <> modName <> "\n\n```agda\n" <> body <> "```\n" else body

-- ---------------------------------------------------------------------
-- construct  (heterogeneous batch of steps against one warm load)
-- ---------------------------------------------------------------------
-- The 'Step' shape and its wildcard / all-@give@ discriminators
-- ('wildcardCheck', 'allGiveSteps') are the pure logic in 'AgdaInteract.Batch'.

-- | Drive holes with a SEQUENCE of steps against one warm load, accumulating
-- one combined diff. Two shortcuts route to the existing single-load paths:
-- a lone @{op:auto, goal:"*"}@ delegates to @auto_all@ (Mimer over every
-- goal), and an all-@give@ batch delegates to @give_many@ (one load, atomic).
-- Anything else runs 'constructLoop' (per-step reload). See the tool
-- description for the (deliberate) limits.
runConstruct :: ToolRunner
runConstruct ss a = case argLookup a "steps" >>= parseMaybe parseJSON of
  Nothing    -> pure (Left "construct requires a `steps` array of {op, goal, …} objects \
                           \(op = give|refine|case_split|auto; goal \"*\" = every open goal, auto only).")
  Just []    -> pure (Left "construct: `steps` is empty.")
  Just steps -> case wildcardCheck steps of
    Left err   -> pure (Left err)
    Right True -> runAutoAll ss a                       -- {op:auto, goal:"*"} ≡ auto_all
    Right False
      | allGiveSteps steps -> allGiveFastPath ss a steps
      | otherwise          -> constructMany ss a steps

-- | All steps are @give@: route through @give_many@'s single-load atomic path
-- (one module load for N gives) rather than 'constructLoop's per-step reload,
-- which only structural steps (case_split/refine) need. Synthesises the
-- @gives@ argument @give_many@ expects, so its guard + diff are reused verbatim.
allGiveFastPath :: ServerState -> Value -> [Step] -> IO (Either Text Text)
allGiveFastPath ss a steps =
  case [ stepLabel s | s@(Step _ _ marg) <- steps, isNothing marg ] of
    (lbl:_) -> pure (Left ("construct: " <> lbl <> ": give needs a `term`."))
    []      -> runGiveMany ss givesArg
  where
    givesArg = object $
      ("gives" .= [ object ["goal" .= g, "term" .= t] | Step _ g (Just t) <- steps ])
        : ("write" .= writeFlag a)
        : [ "file" .= f | Just f <- [argText a "file"] ]

-- | The general construct path: guard give/refine terms, then run every step
-- against a warm load via 'constructLoop', merging the edits into one diff.
constructMany :: ServerState -> Value -> [Step] -> IO (Either Text Text)
constructMany ss a steps =
  -- Fail fast: guard give/refine terms before touching agda.
  case [ (stepLabel s, why) | s@(Step op _ marg) <- steps
                            , op `elem` ["give", "refine"]
                            , Just t <- [marg]
                            , Rejected why <- [checkGiveInput t] ] of
    ((lbl, why):_) -> pure (Left ("construct refused " <> lbl <> ": " <> why))
    [] -> do
      r0 <- resolveLoaded ss (argText a "file")
      case r0 of
        Left err           -> pure (Left err)
        Right (file, _, _) -> do
          eold <- readSourceStamped ss file
          case eold of
            Left e     -> pure (Left e)
            Right orig -> do
              res <- constructLoop ss file orig (contentStamp orig) (codeBlocksFor file orig) steps []
              markSessionDirty ss file
              case res of
                Left err    -> pure (Left err)
                Right edits -> case spliceRanges orig edits of
                  Left ov   -> pure (Left ov)
                  Right new -> do
                    r <- applyOrDiff ss (writeFlag a) file orig new
                    pure (fmap (("Ran " <> showT (length edits) <> " construct step(s).\n\n") <>) r)

-- | Run each step against a fresh reload of the (unchanged-on-disk)
-- original, collecting one @(start, end, replacement)@ edit per step in
-- ORIGINAL offsets. Reloading per step resets Agda's in-session hole state
-- so a structural step (case_split\/refine) never invalidates a later
-- step's interaction id, and every edit is computed against pristine goals
-- — 'spliceRanges' then merges them (and rejects overlaps).
constructLoop :: ServerState -> FilePath -> Text -> Word64 -> CodeBlocks -> [Step]
              -> [(Int, Int, Text)] -> IO (Either Text [(Int, Int, Text)])
constructLoop _  _    _    _        _  []       acc = pure (Right (reverse acc))
constructLoop ss file orig origStamp cb (s:rest) acc = do
  r <- doLoad ss file
  case r of
    Left err -> pure (Left ("construct: " <> stepLabel s <> ": load failed: " <> err))
    Right (sess, gm, _, _) -> do
      -- The per-step reload re-stamps to disk; if that no longer matches the
      -- text the edits are computed against, an external edit landed mid-batch
      -- — abort rather than splice ORIGINAL-offset edits into new content.
      cur <- currentStamp ss file
      if cur /= Just origStamp
        then pure (Left "construct: the file changed on disk mid-batch — nothing applied; re-run load.")
        else case parseStableId (stepGoal s) >>= \sid -> (,) sid <$> lookupStable gm sid of
          Nothing     -> pure (Left ("construct: " <> stepLabel s <> ": not an open goal id: " <> stepGoal s))
          Just (_, e) -> case (geIid e, geRange e) of
            (Just iid, Just (GoalRange gs ge))
              | not (isInsideCode cb (rpPos gs)) ->
                  pure (Left (stepLabel s <> ": the hole is not inside an Agda code block."))
              | otherwise -> do
                  stepE <- runStepEdit sess file orig iid (rpPos gs) (rpPos ge) s
                  case stepE of
                    Left err -> pure (Left err)
                    Right ed -> constructLoop ss file orig origStamp cb rest (ed : acc)
            _ -> pure (Left (stepLabel s <> ": not an open goal."))

-- | Execute one construct step against the live session, returning its edit
-- in ORIGINAL-text offsets: give\/refine\/auto replace the hole range;
-- case_split replaces the clause line.
runStepEdit :: Session -> FilePath -> Text -> Int -> Int -> Int -> Step
            -> IO (Either Text (Int, Int, Text))
runStepEdit sess file orig iid holeS holeE s@(Step op _ marg) =
  let lbl       = stepLabel s
      giveStep  = giveStepEdit (runRaw sess) lbl holeS holeE
      -- A lone auto step is a Mimer probe: budget it as wall-clock so it can't
      -- wedge the batch for the full session timeout. give/refine keep
      -- the session default (a heavy but legitimate post-give elaboration).
      autoStep  = giveStepEdit (runRawBudget (probeBudgetMicros constructAutoSecs) sess) lbl holeS holeE
  in case op of
       "give" -> case marg of
         Nothing -> pure (Left (lbl <> ": give needs a `term`."))
         Just t  -> giveStep (iotcmGive file iid (T.unpack t)) t
       "refine" ->
         let hint = fromMaybe "" marg
         in giveStep (iotcmRefineOrIntro file iid (T.unpack hint)) hint
       "auto" -> autoStep (iotcmAutoOne file AsIs iid "") ""
       "case_split" -> case marg of
         Nothing  -> pure (Left (lbl <> ": case_split needs a `var`."))
         Just var -> do
           out <- runRaw sess (iotcmMakeCase file iid (T.unpack var))
           case out of
             Left err -> pure (Left ("construct: " <> lbl <> ": " <> err))
             Right rs -> case firstError rs of
               Just m  -> pure (Left ("construct: agda rejected " <> lbl <> " — nothing applied:\n" <> m))
               Nothing -> case [cs | ReplyMakeCase _ _ cs <- rs] of
                 (clauses:_) ->
                   let (lineStart, nlP) = lineSpanAt orig holeS
                       indent           = lineIndentAt orig holeS
                       contentStart     = lineStart + indent
                       replTxt          = renderClausesAt (indent + 1) clauses
                   in pure (Right (contentStart, nlP, replTxt))
                 [] -> pure (Left (lbl <> ": agda returned no clauses (is the variable in a pattern position?)."))
       other -> pure (Left ("construct: unknown op `" <> other <> "` (use give|refine|case_split|auto)."))

-- | The shared give/refine/auto step: run the command, and on a
-- 'ReplyGiveAction' return the replacement over the hole range @[holeS,
-- holeE)@. An agda error (or no give-action) aborts the whole batch.
giveStepEdit :: (String -> IO (Either Text [Reply])) -> Text -> Int -> Int -> String -> Text
             -> IO (Either Text (Int, Int, Text))
giveStepEdit runCmd' lbl holeS holeE cmd parenInput = do
  out <- runCmd' cmd
  case out of
    Left err -> pure (Left ("construct: " <> lbl <> ": " <> err))
    Right rs -> case firstError rs of
      Just m  -> pure (Left ("construct: agda rejected " <> lbl <> " — nothing applied:\n" <> m))
      Nothing -> case [gr | ReplyGiveAction _ gr <- rs] of
        (gr:_) -> pure (Right (holeS, holeE, giveReplacement gr parenInput))
        []     -> pure (Left ("construct: no give action for " <> lbl
                                <> " (auto/Mimer may have found nothing)."))

-- ---------------------------------------------------------------------
-- lemmas  (goal-directed lemma search off a live goal)
-- ---------------------------------------------------------------------

-- | Take an open goal's type and run the read-side 'queryFindLemma' in
-- free-text mode over the current graph snapshot, so a proving agent can
-- reuse an existing lemma. Reads 'ssLoaded' directly (no rebuild) — the
-- interaction bridge deliberately bypasses 'ensureFresh'.
runLemmas :: ToolRunner
runLemmas ss a = withGoal ss a $ \sess file e iid -> do
  -- Live goal context (binder types like `n : ℕ`) steers carrier affinity
  -- so the goal's actual carrier instance outranks same-shaped ones from
  -- other number types; degrade to [] if the goal query fails.
  ctxTypes <- ctxTypesOf sess file iid
  ef <- ensureFresh ss
  case ef of
    Left err      -> pure (Left ("graph index unavailable: " <> T.pack err))
    Right (ld, _) ->
      let goalTy = geType e
          out    = queryFindLemma ld (argInt a "limit" 10) (argDouble a "min_sim" 0.3)
                     (argText a "kind") (argText a "module_prefix") (Just goalTy) Nothing ctxTypes
      in pure (Right ("Goal " <> renderStableId (geStable e) <> "  : " <> goalTy <> "\n\n" <> out
                       <> "\n\n(Reuse a candidate with a `construct` give/refine step. Recall-first name/shape \
                          \overlap — a suggestion, not a proof it applies; for WL type-shape \
                          \matching pass an `anchor` to the read-side `find_lemma`.)"))

-- | The in-scope context binder types of a goal (@[ceType | ceInScope]@),
-- fetched live off the session. @[]@ on any non-goal-type reply or error —
-- callers use it only to enrich lemma-carrier ranking, so a miss just falls
-- back to goal-string tokens.
ctxTypesOf :: Session -> FilePath -> Int -> IO [Text]
ctxTypesOf sess file iid = do
  eRaw <- runRaw sess (iotcmGoalTypeContext file Simplified iid)
  pure $ case eRaw of
    Right rs | Right (GiGoalType _ ces) <- firstGoalInfo rs
             -> [ ceType c | c <- ces, ceInScope c ]
    _        -> []

-- | Orientation bundle for a live goal: its live type + context (as
-- `inspect op=type`) then the top reusable lemmas (as `lemmas`) — the
-- write-side analogue of `brief`. Resolves the session/goal once; read-only.
-- The lemma search uses the goal's cached type ('geType'), matching `lemmas`.
runGoalBrief :: ToolRunner
runGoalBrief ss a = withGoal ss a $ \sess file e iid -> do
  eRaw <- runRaw sess (iotcmGoalTypeContext file Simplified iid)
  case eRaw >>= firstGoalInfo of
    Left err -> pure (Left err)
    Right gi -> do
      let info     = renderGoalTypeFull gi
          ctxTypes = case gi of
            GiGoalType _ ces -> [ ceType c | c <- ces, ceInScope c ]
            _                -> []
      ef <- ensureFresh ss
      let lemmaBlock = case ef of
            Left err'     -> "(lemma search unavailable: " <> T.pack err' <> ")"
            Right (ld, _) ->
              queryFindLemma ld (argInt a "limit" 5) (argDouble a "min_sim" 0.3)
                (argText a "kind") (argText a "module_prefix") (Just (geType e)) Nothing ctxTypes
      pure (Right (T.stripEnd info
                    <> "\n\n── candidate lemmas ──\n" <> T.stripEnd lemmaBlock
                    <> "\n\n(Fill with `auto goal=" <> renderStableId (geStable e)
                    <> " write:true`, or a `construct` give/refine step from a candidate above.)"))

showT :: Show a => a -> Text
showT = T.pack . show
