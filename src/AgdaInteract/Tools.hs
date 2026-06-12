{-# LANGUAGE OverloadedStrings #-}
-- | The write-side interaction-bridge MCP tools, exposed through the
-- @agda-explore@ server when started with @--enable-interact@.
--
-- These talk to a long-lived @agda --interaction-json@ session
-- ('AgdaInteract.Session') rather than the static dependency-graph
-- snapshot — they reflect live on-disk file state and so deliberately
-- bypass @ensureFresh@. This phase ships the read-only surface (@load@,
-- @goal_type@, @goal_context@, @infer@, @normalize@); the mutating tools
-- (@case_split@ / @refine@ / @give@ / @auto@) are added on top.
module AgdaInteract.Tools
  ( interactTools
  , closeAllSessions
  ) where

import           Control.Concurrent.MVar (modifyMVar, modifyMVar_, readMVar)
import           Control.Exception       (SomeException, try)
import           Control.Monad           (foldM)
import           Data.Aeson              (Value)
import qualified Data.Map.Strict         as M
import           Data.Maybe              (fromMaybe)
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.IO            as TIO
import           System.FilePath         (isAbsolute, normalise, (</>))
import           System.IO               (hPutStrLn, stderr)

import           AgdaGraph.Interaction.Iotcm
import           AgdaGraph.Interaction.Protocol
import           AgdaInteract.Edit
import           AgdaInteract.GoalId
import           AgdaInteract.Guard
import           AgdaInteract.Literate
import           AgdaInteract.Registry
import           AgdaInteract.Session
import           AgdaMcp.State
import           AgdaMcp.ToolDef

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

  , Tool "goal_type"
      "The type of an open goal, plus its in-scope context (binders and \
      \their types) — the interaction-hole analogue of `type_of`. Takes a \
      \stable goal id from `load` (e.g. `g0`)."
      (objSchema [ ("goal", sp "Stable goal id from `load`, e.g. `g0`.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal"])
      (runGoalInfo renderGoalTypeFull)

  , Tool "goal_context"
      "The in-scope context at an open goal: every visible binder and its \
      \type. Takes a stable goal id from `load`."
      (objSchema [ ("goal", sp "Stable goal id from `load`, e.g. `g0`.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal"])
      (runGoalInfo renderContextOnly)

  , Tool "infer"
      "Infer the type of an expression in a goal's context (Cmd_infer). \
      \Read-only: does not modify the goal or the file."
      (objSchema [ ("goal", sp "Stable goal id whose context to use, e.g. `g0`.")
                 , ("expr", sp "The expression to infer the type of.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal", "expr"])
      (runExpr (\f iid e -> iotcmInfer f Simplified iid e))

  , Tool "normalize"
      "Normalise (compute) an expression in a goal's context (Cmd_compute). \
      \Read-only."
      (objSchema [ ("goal", sp "Stable goal id whose context to use, e.g. `g0`.")
                 , ("expr", sp "The expression to normalise.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal", "expr"])
      (runExpr (\f iid e -> iotcmCompute f DefaultCompute iid e))

  , Tool "case_split"
      "Case-split a goal on one or more pattern variables (Agda's \
      \`Cmd_make_case`). Returns a unified diff that replaces the clause \
      \with the generated clauses. The bridge does NOT write the file — \
      \apply the diff yourself, then call `load` to refresh the goals."
      (objSchema [ ("goal", sp "Stable goal id to split, e.g. `g0`.")
                 , ("var", sp "Variable(s) to split on (space-separated), e.g. `n` or `xs ys`.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal", "var"])
      runCaseSplit

  , Tool "refine"
      "Refine a goal by a head symbol — fill it with `f ?` for the given \
      \head `f`, leaving fresh subgoals (Agda's `Cmd_refine_or_intro`; an \
      \empty hint does `intro`). Returns a unified diff; the bridge does \
      \NOT write the file. The hint is checked against the no-postulate \
      \contract before Agda sees it."
      (objSchema [ ("goal", sp "Stable goal id to refine, e.g. `g0`.")
                 , ("expr", sp "Head symbol / refinement hint (may be empty to intro).")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal"])
      runRefine

  , Tool "give"
      "Fill a goal with a complete term, Agda-validated (`Cmd_give`): a \
      \term that does not typecheck returns the localized Agda error and \
      \the file is left untouched. On success returns a unified diff \
      \replacing the hole. The bridge does NOT write the file. The term is \
      \rejected up front if it uses `postulate`, a termination/coverage/\
      \OPTIONS pragma, or another escape hatch (zero-axiom contract)."
      (objSchema [ ("goal", sp "Stable goal id to fill, e.g. `g0`.")
                 , ("term", sp "The term to fill the hole with.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal", "term"])
      runGive

  , Tool "auto"
      "Search for a term that solves the goal (Agda's Mimer / auto). On \
      \success returns a diff filling the hole. NOTE: Agda 2.9.0's \
      \interaction reader rejects the auto command, so on that version this \
      \reports auto as unavailable — use `refine` / `give` instead. Kept so \
      \the tool lights up automatically on an Agda that accepts it."
      (objSchema [ ("goal", sp "Stable goal id to solve, e.g. `g0`.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal"])
      runAuto
  ]

-- ---------------------------------------------------------------------
-- Tool runners
-- ---------------------------------------------------------------------

runLoad :: ToolRunner
runLoad ss a = case argText a "file" of
  Nothing -> pure (Left "load requires a `file` argument.")
  Just f  -> do
    r <- doLoad ss (absFile ss f)
    pure $ case r of
      Left err            -> Left err
      Right (_, _, es, fp) -> Right (renderGoals fp es)

-- | Read-only goal-info tools (goal_type / goal_context): resolve the
-- session + goal, run @Cmd_goal_type_context@, render with the supplied
-- function.
runGoalInfo :: (GoalInfo -> Text) -> ToolRunner
runGoalInfo render ss a =
  withGoal ss a $ \sess file _e iid ->
    runCmd sess (iotcmGoalTypeContext file Simplified iid) (fmap render . firstGoalInfo)

-- | Expression tools (infer / normalize): resolve session + goal, run the
-- supplied command with the goal's context, render the goal info.
runExpr :: (FilePath -> Int -> String -> String) -> ToolRunner
runExpr mkCmd ss a = case argText a "expr" of
  Nothing   -> pure (Left "this tool requires an `expr` argument.")
  Just expr ->
    withGoal ss a $ \sess file _e iid ->
      runCmd sess (mkCmd file iid (T.unpack expr)) (fmap renderGoalInfoExpr . firstGoalInfo)

-- ---------------------------------------------------------------------
-- Mutating tools (case_split / refine / give)
-- ---------------------------------------------------------------------

runGive :: ToolRunner
runGive ss a = withGoal ss a $ \sess file e iid ->
  case argText a "term" of
    Nothing   -> pure (Left "give requires a `term` argument.")
    Just term -> case checkGiveInput term of
      Rejected why -> pure (Left ("give refused: " <> why))
      Allowed      -> do
        out <- runRaw sess (iotcmGive file iid (T.unpack term))
        mutateFromGive ss file e (Just term) out

runRefine :: ToolRunner
runRefine ss a = withGoal ss a $ \sess file e iid -> do
  let hint = fromMaybe "" (argText a "expr")
  case checkGiveInput hint of
    Rejected why -> pure (Left ("refine refused: " <> why))
    Allowed      -> do
      out <- runRaw sess (iotcmRefineOrIntro file iid (T.unpack hint))
      mutateFromGive ss file e (Just hint) out

runCaseSplit :: ToolRunner
runCaseSplit ss a = withGoal ss a $ \sess file e iid ->
  case argText a "var" of
    Nothing  -> pure (Left "case_split requires a `var` argument (the variable to split on).")
    Just var -> do
      out <- runRaw sess (iotcmMakeCase file iid (T.unpack var))
      mutateFromMakeCase ss file e out

runAuto :: ToolRunner
runAuto ss a = withGoal ss a $ \sess file e iid -> do
  out <- runRaw sess (iotcmAutoOne file iid "")
  case out of
    Left err -> pure (Left err)
    Right rs -> case [gr | ReplyGiveAction _ gr <- rs] of
      (GiveStr s : _) -> applyHoleEdit ss file e s
      -- No GiveStr give-action: surface Agda's error if it sent one, else
      -- the degradation note — on Agda 2.9.0 the IOTCM reader rejects the
      -- auto command (a non-JSON "cannot read" line the parser drops), so
      -- the burst is empty.
      _ -> pure (Left (fromMaybe autoUnavailable (firstError rs)))
  where
    autoUnavailable = "auto/Mimer is not reachable via this agda's \
                      \--interaction-json reader (Cmd_autoOne is rejected on \
                      \Agda 2.9.0). Use `refine` or `give` instead."

-- | Turn a give\/refine reply burst into an edit diff. An Error means the
-- term was rejected and the file is untouched; a GiveAction carries the
-- replacement (either an explicit string, or the user's input optionally
-- parenthesised).
mutateFromGive :: ServerState -> FilePath -> GoalEntry -> Maybe Text -> Either Text [Reply] -> IO (Either Text Text)
mutateFromGive _  _    _ _      (Left err) = pure (Left err)
mutateFromGive ss file e mInput (Right rs) = case firstError rs of
  Just m  -> pure (Left ("agda rejected the term — file unchanged:\n" <> m))
  Nothing -> case [gr | ReplyGiveAction _ gr <- rs] of
    (gr:_) ->
      let repl = case gr of
            GiveStr s   -> s
            GiveParen p -> let inp = fromMaybe "" mInput
                           in if p then "(" <> inp <> ")" else inp
      in applyHoleEdit ss file e repl
    [] -> pure (Left "agda returned no give action (unexpected protocol shape).")

-- | Turn a make_case reply into a diff that replaces the clause line with
-- the generated clauses, re-indented to the clause's column.
mutateFromMakeCase :: ServerState -> FilePath -> GoalEntry -> Either Text [Reply] -> IO (Either Text Text)
mutateFromMakeCase _  _    _ (Left err) = pure (Left err)
mutateFromMakeCase ss file e (Right rs) = case firstError rs of
  Just m  -> pure (Left m)
  Nothing -> case [cs | ReplyMakeCase _ _ cs <- rs] of
      (clauses:_) -> case geRange e of
        Nothing               -> pure (Left "goal has no source range; cannot edit.")
        Just (GoalRange s _)  -> withSourceGuarded file (rpPos s) $ \old -> do
          let holePos          = rpPos s
              (lineStart, nlP)  = lineSpanAt old holePos
              indent            = lineIndentAt old holePos
              contentStart      = lineStart + indent
              replTxt           = renderClausesAt (indent + 1) clauses
              new               = spliceRange old contentStart nlP replTxt
          markSessionDirty ss file
          pure (Right (diffMsg (unifiedDiff file old new)))
      [] -> pure (Left "agda returned no clauses (is the variable in a pattern position?).")

-- | Splice @repl@ over the hole's range, guarding that the hole is inside a
-- code block. Marks the session dirty (its in-memory state has diverged
-- from disk, which the bridge does not write — the next query reloads).
applyHoleEdit :: ServerState -> FilePath -> GoalEntry -> Text -> IO (Either Text Text)
applyHoleEdit ss file e repl = case geRange e of
  Nothing              -> pure (Left "goal has no source range; cannot edit.")
  Just (GoalRange s en) -> withSourceGuarded file (rpPos s) $ \old -> do
    let new = spliceRange old (rpPos s) (rpPos en) repl
    markSessionDirty ss file
    pure (Right (diffMsg (unifiedDiff file old new)))

-- | Read the source and run the edit only if the target offset is inside
-- an Agda code block (a no-op for plain @.agda@; a guard for @.lagda.md@).
withSourceGuarded :: FilePath -> Int -> (Text -> IO (Either Text Text)) -> IO (Either Text Text)
withSourceGuarded file pos act = do
  efile <- readFileSafe file
  case efile of
    Left err  -> pure (Left err)
    Right old
      | isInsideCode (codeBlocksFor file old) pos -> act old
      | otherwise -> pure (Left "refusing to edit: the hole is not inside an Agda code block \
                                \(literate-Markdown prose).")

diffMsg :: String -> Text
diffMsg diff
  | null diff = "No change (agda's result matched the source already)."
  | otherwise = "Apply this diff and then call `load` to refresh the goals — the bridge \
                \does not write the file:\n\n" <> T.pack diff

markSessionDirty :: ServerState -> FilePath -> IO ()
markSessionDirty ss file =
  modifyMVar_ (ssSessions ss) (pure . M.adjust (\e -> e { seDirty = True }) file)

readFileSafe :: FilePath -> IO (Either Text Text)
readFileSafe fp = do
  r <- try (TIO.readFile fp) :: IO (Either SomeException Text)
  pure (either (Left . ("cannot read source: " <>) . T.pack . show) Right r)

-- | Send one command to an already-resolved session and return its reply
-- burst, or a session-level error.
runRaw :: Session -> String -> IO (Either Text [Reply])
runRaw sess cmd = do
  out <- sendIotcm sess cmd
  pure $ case out of
    SendTimeout _  -> Left "agda timed out (session reset); reload and retry."
    SendDied _ err -> Left ("agda session ended: " <> err)
    SendOk rs      -> Right rs

-- ---------------------------------------------------------------------
-- Session registry + load
-- ---------------------------------------------------------------------

sessionTimeoutMicros :: Int
sessionTimeoutMicros = 60 * 1000000

-- | Resolve a user file argument to an absolute, normalised path under the
-- project root.
absFile :: ServerState -> Text -> FilePath
absFile ss t =
  let raw = T.unpack t
  in normalise (if isAbsolute raw then raw else cfgProjectRoot (ssConfig ss) </> raw)

-- | (Re)load a module: ensure a live session (spawn if absent/dead), send
-- @Cmd_load@, reconcile the stable-goal map, and store the entry. Returns
-- the session, the new goal map, the goal entries, and the file path.
doLoad :: ServerState -> FilePath -> IO (Either Text (Session, GoalMap, [GoalEntry], FilePath))
doLoad ss file = modifyMVar (ssSessions ss) $ \m -> do
  eSess <- getLiveSession ss m file
  case eSess of
    Left err -> pure (m, Left err)
    Right sess -> do
      let gm0 = maybe emptyGoalMap seGoalMap (M.lookup file m)
      out <- sendIotcm sess (iotcmLoad file (cfgIncludes (ssConfig ss)))
      case interpretLoad out of
        Left err    ->
          pure (M.insert file (SessionEntry sess gm0 False) m, Left err)
        Right goals -> do
          let (gm1, es) = syncGoals gm0 goals
              m1        = M.insert file (SessionEntry sess gm1 False) m
          m2 <- capSessions file m1
          pure (m2, Right (sess, gm1, es, file))

-- | Bound the number of live sessions (one idle @agda@ process each). When
-- over the cap, close sessions other than the one just loaded — not strict
-- LRU, but a deterministic bound, logged so the eviction is never silent.
maxSessions :: Int
maxSessions = 6

capSessions :: FilePath -> M.Map FilePath SessionEntry -> IO (M.Map FilePath SessionEntry)
capSessions keep m
  | M.size m <= maxSessions = pure m
  | otherwise =
      let victims = take (M.size m - maxSessions) [ k | k <- M.keys m, k /= keep ]
      in foldM evict m victims
  where
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
        Just bin -> startSession (SessionConfig bin (cfgInteractArgs (ssConfig ss)) sessionTimeoutMicros) file

-- | Resolve the target session for a goal command, reloading if the entry
-- was marked dirty by the watcher or its process died. Runs the action
-- with the resolved file, current goal map, and the goal's Agda
-- interaction id (translated from the client's stable id).
withGoal
  :: ServerState -> Value
  -> (Session -> FilePath -> GoalEntry -> Int -> IO (Either Text Text))
  -> IO (Either Text Text)
withGoal ss a act = case argText a "goal" of
  Nothing      -> pure (Left "this tool requires a `goal` argument (a stable id like `g0`).")
  Just goalArg -> case parseStableId goalArg of
    Nothing  -> pure (Left ("not a goal id: " <> goalArg <> " (expected `g0`, `g1`, …)."))
    Just sid -> do
      r <- resolveLoaded ss (argText a "file")
      case r of
        Left err -> pure (Left err)
        Right (file, sess, gm) -> case lookupStable gm sid of
          Just e | Just iid <- geIid e -> act sess file e iid
          _ -> pure (Left (renderStableId sid <> " is not an open goal (it may have been \
                            \solved, or the module needs `load`)."))

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
        else pure (Right (file, seSession e, seGoalMap e))
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

showT :: Show a => a -> Text
showT = T.pack . show
