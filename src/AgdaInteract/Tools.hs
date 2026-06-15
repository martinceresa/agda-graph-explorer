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
import           Data.Aeson              (FromJSON (..), Value, object, withObject,
                                          (.:), (.=))
import           Data.Aeson.Types        (parseMaybe)
import           Data.List               (stripPrefix)
import qualified Data.Map.Strict         as M
import           Data.Maybe              (fromMaybe, mapMaybe)
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.IO            as TIO
import           System.Directory        (createDirectoryIfMissing,
                                          listDirectory, removePathForcibly)
import           System.FilePath         (dropExtension, isAbsolute, normalise,
                                          takeDirectory, takeFileName, (</>))
import           System.IO               (hPutStrLn, stderr)
import           Text.Read               (readMaybe)

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

  , Tool "give_many"
      "Fill SEVERAL open goals in one shot against a single live session — \
      \pays the (possibly expensive) module load ONCE instead of reloading \
      \between each give, so it's the tool for closing many independent \
      \holes in a slow-to-load module. Takes a `gives` list of \
      \{goal, term}; each term is Agda-validated and guarded (no \
      \postulate / escape hatches). Returns ONE combined unified diff for \
      \all the fills (the bridge does not write the file). Atomic: if ANY \
      \term is rejected, NOTHING is applied and the error names the \
      \offending goal. For case-split / refine, or fills that depend on a \
      \previous one, use the single-goal tools."
      (objSchema [ ("gives", givesSchema)
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["gives"])
      runGiveMany

  , Tool "auto"
      "Search for a term that solves the goal with Agda's Mimer (auto). On \
      \success returns a unified diff filling the hole (the bridge does not \
      \write the file); if Mimer finds nothing you get a 'no solution' note \
      \— guide it with `refine`, or `give` an explicit term."
      (objSchema [ ("goal", sp "Stable goal id to solve, e.g. `g0`.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 ] ["goal"])
      runAuto

  , Tool "stage"
      "Open an ephemeral SCRATCH module (under .agda-explore/scratch/, \
      \outside the source tree) for building a *new* definition in \
      \isolation — so the real module isn't left half-written and each \
      \`load` re-checks only the scratch's tiny closure, not the target's. \
      \Optionally seed it with `target`'s imports so scratch scope \
      \approximates the destination. Returns the scratch file path: add \
      \your `name : T` + `name = ?` to it, construct with the usual tools \
      \(`load`/`goal_type`/`case_split`/`refine`/`give`), then `promote` it \
      \into a real module (or `discard`)."
      (objSchema [ ("target", sp "Real module to seed imports from + the eventual promote destination (optional).") ] [])
      runStage

  , Tool "promote"
      "Splice the definition(s) you built in a `stage` scratch into a real \
      \target module: merges any missing imports, appends the defs, then \
      \re-validates the *whole target* in Agda. Returns a unified diff (the \
      \bridge does not write the file) — or, if the spliced result doesn't \
      \typecheck in the target's real scope (instance/scope/ordering facts \
      \the scratch didn't capture), the localized error with nothing \
      \changed. This is where the one expensive real-module recheck happens."
      (objSchema [ ("scratch", sp "The scratch file path returned by `stage`.")
                 , ("target", sp "The real module file to splice into.")
                 ] ["scratch", "target"])
      runPromote

  , Tool "discard"
      "Drop a `stage` scratch buffer: close its session and delete the \
      \scratch file. Use to abandon a dead-end construction."
      (objSchema [ ("scratch", sp "The scratch file path returned by `stage`.") ] ["scratch"])
      runDiscard
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

-- | One @{goal, term}@ fill request for 'runGiveMany'.
data GiveSpec = GiveSpec !Text !Text
instance FromJSON GiveSpec where
  parseJSON = withObject "give" $ \o -> GiveSpec <$> o .: "goal" <*> o .: "term"

-- | JSON schema for the @gives@ array argument.
givesSchema :: Value
givesSchema = object
  [ "type"        .= ("array" :: Text)
  , "description" .= ("Goals to fill, in order — a list of \
                      \{\"goal\":\"g0\",\"term\":\"…\"} objects." :: Text)
  , "items" .= object
      [ "type"       .= ("object" :: Text)
      , "properties" .= object
          [ "goal" .= sp "Stable goal id, e.g. g0."
          , "term" .= sp "Term to fill that goal with." ]
      , "required" .= (["goal", "term"] :: [Text])
      ]
  ]

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
            ef <- readFileSafe file
            case ef of
              Left e     -> pure (Left e)
              Right orig -> do
                res <- giveLoop sess file gm (codeBlocksFor file orig) specs []
                markSessionDirty ss file        -- drop the in-session state; we serve disk
                pure $ case res of
                  Left err    -> Left err
                  Right edits -> case spliceRanges orig edits of
                    Left ov   -> Left ov
                    Right new -> Right (batchMsg (length edits) (unifiedDiff file orig new))

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
                    let repl = case gr of
                          GiveStr st  -> st
                          GiveParen p -> if p then "(" <> t <> ")" else t
                    in giveLoop sess file gm cb rest ((rpPos s, rpPos en, repl) : acc)
                  [] -> pure (Left ("give_many: no give action for " <> g))
      _ -> pure (Left (g <> ": not an open goal."))

batchMsg :: Int -> String -> Text
batchMsg n diff =
  "Filled " <> showT n <> " goal(s) against a single session load. Apply this \
  \combined diff, then `load` to refresh — the bridge does not write the file:\n\n"
    <> T.pack diff

runAuto :: ToolRunner
runAuto ss a = withGoal ss a $ \sess file e iid -> do
  out <- runRaw sess (iotcmAutoOne file AsIs iid "")
  case out of
    Left err -> pure (Left err)
    Right rs -> case [gr | ReplyGiveAction _ gr <- rs] of
      (GiveStr s : _) -> applyHoleEdit ss file e s
      -- No give-action: surface Agda's error if it sent one, else Mimer
      -- simply found no solution.
      _ -> pure (Left (fromMaybe noSolution (firstError rs)))
  where
    noSolution = "auto/Mimer found no solution for this goal — guide it with \
                 \`refine`, or `give` an explicit term."

-- ---------------------------------------------------------------------
-- Scratch / staging buffer (stage / promote / discard)
-- ---------------------------------------------------------------------

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
                           \build with goal_type / case_split / refine / give. When it \
                           \type-checks, `promote` it into a real module (scratch=" <> T.pack file
                        <> ", target=<module>), or `discard` it.")

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
             else do
               let candidate = buildCandidate targetFile tgt missing body
               v <- validateCandidate ss targetFile candidate
               pure $ case v of
                 Left err -> Left ("promote: the spliced definition does not typecheck in "
                                     <> T.pack (takeFileName targetFile)
                                     <> " — nothing changed:\n" <> err)
                 Right () -> Right ("Validated in the real target. Apply this diff and \
                                    \`load` to continue — the bridge does not write the file:\n\n"
                                    <> T.pack (unifiedDiff targetFile tgt candidate))
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

-- | Write the candidate to a temp copy under a FRESH top-level module name
-- and load it through a throwaway agda session. The rename matters: the real
-- target is reachable on the include path, so a temp keeping the target's
-- module name collides (`AmbiguousTopLevelModuleName`). A def's
-- well-typedness doesn't depend on its enclosing module's name, so renaming
-- validates the same thing without the clash. 'Right ()' iff it type-checks
-- (remaining holes are fine — they are not errors).
validateCandidate :: ServerState -> FilePath -> Text -> IO (Either Text ())
validateCandidate ss targetFile candidate = do
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
          es <- startSession (SessionConfig bin (cfgInteractArgs c) validateTimeoutMicros) tmpFile
          case es of
            Left e     -> pure (Left ("agda could not start: " <> e))
            Right sess -> do
              out <- sendIotcm sess (iotcmLoad tmpFile (loadIncludes ss tmpFile))
              closeSession sess
              pure (either Left (const (Right ())) (interpretLoad out))
  _ <- try (removePathForcibly tmpDir) :: IO (Either SomeException ())
  pure r

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
      out <- sendIotcm sess (iotcmLoad file (loadIncludes ss file))
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
