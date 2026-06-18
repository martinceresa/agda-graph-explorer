{-# LANGUAGE OverloadedStrings #-}
-- | The write-side interaction-bridge MCP tools, exposed through the
-- @agda-explore@ server when started with @--enable-interact@.
--
-- These talk to a long-lived @agda --interaction-json@ session
-- ('AgdaInteract.Session') rather than the static dependency-graph
-- snapshot — they reflect live on-disk file state and so deliberately
-- bypass @ensureFresh@.
--
-- Three families:
--
--   * /read-only/ — @load@, @goal_type@, @goal_context@, @infer@,
--     @normalize@, @check@ (validate a file/proposed content → structured
--     errors + warnings + open goals), @lemmas@ (goal-directed lemma
--     search wired off a live goal's type).
--   * /hole-driven mutators/ — @case_split@ / @refine@ / @give@ /
--     @give_many@ / @auto@, and @construct@ (a heterogeneous batch of
--     those against one warm load). Each returns a unified diff and (with
--     @write:true@) optionally applies it and reloads.
--   * /file authoring/ — @new_module@ (scaffold a validated module
--     skeleton, resolving imports off the dependency graph), @give_file@
--     (validate whole-file or appended content under the zero-axiom
--     contract → diff), and @stage@ / @promote@ / @discard@.
module AgdaInteract.Tools
  ( interactTools
  , closeAllSessions
  , reapIdleSessions
  ) where

import           Control.Concurrent      (forkIO, threadDelay)
import           Control.Concurrent.MVar (modifyMVar, modifyMVar_, readMVar)
import           Control.Exception       (SomeException, try)
import           Control.Monad           (foldM, forM, forM_, forever, void, when)
import           Data.Aeson              (FromJSON (..), Value, object, withObject,
                                          (.:), (.:?), (.=))
import           Data.Aeson.Types        (parseMaybe)
import           Data.IORef              (newIORef, readIORef, writeIORef)
import           Data.List               (isPrefixOf, nub, sortOn, stripPrefix)
import qualified Data.Map.Strict         as M
import           Data.Maybe              (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import           Data.Ord                (Down (..))
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.IO            as TIO
import           Data.Time.Clock         (diffUTCTime, getCurrentTime)
import           System.Directory        (createDirectoryIfMissing,
                                          listDirectory, removePathForcibly)
import           System.FilePath         (dropExtension, dropExtensions, isAbsolute,
                                          makeRelative, normalise, takeDirectory,
                                          takeFileName, (</>))
import           System.IO               (hPutStrLn, stderr)
import           Text.Read               (readMaybe)

import           AgdaGraph.Interaction.Iotcm
import           AgdaGraph.Interaction.Protocol
import           AgdaGraph.Schema        (defModule, defName)
import           AgdaInteract.Edit
import           AgdaInteract.GoalId
import           AgdaInteract.Guard
import           AgdaInteract.Literate
import           AgdaInteract.Registry
import           AgdaInteract.Session
import           AgdaMcp.Inspect         (GoalLite (..), InspectEvent (..),
                                          emitInspect)
import           AgdaMcp.Query           (queryFindLemma)
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
                 , ("write", writeArg)
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
                 , ("write", writeArg)
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
                 , ("write", writeArg)
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
                 , ("write", writeArg)
                 ] ["gives"])
      runGiveMany

  , Tool "auto"
      "Search for a term that solves the goal with Agda's Mimer (auto). On \
      \success returns a unified diff filling the hole (the bridge does not \
      \write the file); if Mimer finds nothing you get a 'no solution' note \
      \— guide it with `refine`, or `give` an explicit term."
      (objSchema [ ("goal", sp "Stable goal id to solve, e.g. `g0`.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 , ("write", writeArg)
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
                 , ("write", writeArg)
                 ] ["scratch", "target"])
      runPromote

  , Tool "discard"
      "Drop a `stage` scratch buffer: close its session and delete the \
      \scratch file. Use to abandon a dead-end construction."
      (objSchema [ ("scratch", sp "The scratch file path returned by `stage`.") ] ["scratch"])
      runDiscard

  , Tool "check"
      "Type-check a module in the live session and report STRUCTURED \
      \diagnostics: a ✓/✗ verdict, every error and warning (not just the \
      \first), and the list of open goals with stable ids + (line:col). \
      \This is the bridge analogue of running `agda <File>` in a shell, but \
      \it reuses the warm session (and its .agdai cache) and hands the goals \
      \straight back so you can pivot to `give`/`refine`/`auto`. Pass \
      \`content` to DRY-RUN proposed full file text WITHOUT writing (it is \
      \validated under a throwaway module name); omit it to check the file \
      \as it is on disk. Read-only: never writes."
      (objSchema [ ("file", sp "Path to the .agda / .lagda.md module (relative to the project root, or absolute).")
                 , ("content", sp "Proposed full file text to validate instead of the on-disk file (dry-run; nothing is written).")
                 ] ["file"])
      runCheck

  , Tool "give_file"
      "Author a WHOLE definition or file through the bridge — the validated, \
      \zero-axiom counterpart to a blind `Write`. Supply EXACTLY ONE of: \
      \`content` (the full new text of `file`, also used to create a new \
      \file) or `append` (a definition block to splice onto the end of an \
      \existing module, after any imports it needs). The whole proposed text \
      \is run through the no-postulate / no-escape-hatch guard, then \
      \type-checked; on success you get a unified diff (and, with \
      \`write:true`, it is applied and the module reloaded so you see the \
      \remaining goals); on failure the localized errors with NOTHING \
      \changed. Use this instead of `Write` when the file must honour the \
      \--safe / 0-postulate contract."
      (objSchema [ ("file", sp "Target module file (created if it doesn't exist, in `content` mode).")
                 , ("content", sp "Full proposed file text. Mutually exclusive with `append`.")
                 , ("append", sp "A definition block to append to the existing file. Mutually exclusive with `content`.")
                 , ("write", writeArg)
                 ] ["file"])
      runGiveFile

  , Tool "new_module"
      "Scaffold a NEW, validated Agda module so a fresh file isn't a blank \
      \page with no holes to drive. Give a `path` (the file to create); the \
      \tool derives a correct `module … where` header matching the path, \
      \emits literate ```agda fences for a .lagda.md path, and — uniquely — \
      \resolves `imports` (a list of bare names you need, e.g. `Fin`, `_≤_`) \
      \to `open import <Module>` lines by looking each up in the dependency \
      \graph. Each `defs` entry {name,type} becomes a `name : type` / \
      \`name = ?` hole. The scaffold is type-checked before it is returned. \
      \With `write:true` the file is created and loaded (returning its \
      \goals); otherwise the validated content is returned for you to write."
      (objSchema [ ("path", sp "File to create, e.g. `Protocol/Jolteon/Foo.agda` or `Foo.lagda.md` (relative to the project root, or absolute).")
                 , ("imports", arrOfStr "Bare names you need in scope; each is resolved to its defining module via the graph and emitted as an import. Unresolved names are reported, not invented.")
                 , ("defs", defsSchema)
                 , ("open", bp "Emit `open import` (default true) vs bare `import`.")
                 , ("write", bp "Create and load the file (default false → return the validated content to write yourself).")
                 ] ["path"])
      runNewModule

  , Tool "construct"
      "Run a SEQUENCE of hole-driven steps against one warm load — the \
      \heterogeneous sibling of `give_many`, for when you have a plan for \
      \several goals. `steps` is a list of {op, goal, …}: op = `give` \
      \(+`term`), `refine` (+`expr`), `case_split` (+`var`), or `auto`. Each \
      \step is validated and guarded; the edits are accumulated into ONE \
      \combined diff (and applied + reloaded with `write:true`). Each step \
      \targets a goal from the ORIGINAL load and the edits must not overlap, \
      \so this does NOT fill holes that an earlier step introduced — run \
      \`construct` again (or `load`) for those. Atomic: any rejected step \
      \applies nothing and names the offender."
      (objSchema [ ("steps", stepsSchema)
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 , ("write", writeArg)
                 ] ["steps"])
      runConstruct

  , Tool "lemmas"
      "Goal-directed lemma search wired to a LIVE goal: takes the type of an \
      \open goal (from `load`) and finds existing definitions whose \
      \conclusion resembles it, so you can `give`/`refine` with a lemma \
      \instead of re-deriving it. A convenience front-end to the read-side \
      \`find_lemma` (free-text mode) that reads the goal's type for you. \
      \Ranks by identifier-token overlap over canonicalised conclusions (a \
      \name-overlap proxy, NOT WL); `kind`/`module_prefix` filter candidates. \
      \Reads the current graph snapshot (does not trigger a rebuild)."
      (objSchema [ ("goal", sp "Stable goal id whose type to search for, e.g. `g0`.")
                 , ("file", sp "Module file, if more than one is loaded (else inferred).")
                 , ("kind", sp "Restrict candidates to a structural kind: function|projection|datatype|record|constructor|postulate|primitive|other.")
                 , ("module_prefix", sp "Only consider candidates whose module starts with this prefix.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.3).")
                 ] ["goal"])
      runLemmas
  ]

-- | The shared @write@ boolean argument schema for the mutating tools.
writeArg :: Value
writeArg = bp "Apply the edit to the file and reload, returning the refreshed \
              \goals — instead of only returning a diff for you to apply \
              \(default false; the bridge does not write unless asked)."

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
                      \`case_split` takes `var`, `auto` takes nothing." :: Text)
  , "items" .= object
      [ "type"       .= ("object" :: Text)
      , "properties" .= object
          [ "op"   .= sp "give | refine | case_split | auto."
          , "goal" .= sp "Stable goal id, e.g. g0."
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
emitGoals ss fp es = do
  ec <- readFileSafe fp
  emitInspect (ssInspect ss) $ EvGoals
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
        mutateFromGive ss (writeFlag a) file e (Just term) out

runRefine :: ToolRunner
runRefine ss a = withGoal ss a $ \sess file e iid -> do
  let hint = fromMaybe "" (argText a "expr")
  case checkGiveInput hint of
    Rejected why -> pure (Left ("refine refused: " <> why))
    Allowed      -> do
      out <- runRaw sess (iotcmRefineOrIntro file iid (T.unpack hint))
      mutateFromGive ss (writeFlag a) file e (Just hint) out

runCaseSplit :: ToolRunner
runCaseSplit ss a = withGoal ss a $ \sess file e iid ->
  case argText a "var" of
    Nothing  -> pure (Left "case_split requires a `var` argument (the variable to split on).")
    Just var -> do
      out <- runRaw sess (iotcmMakeCase file iid (T.unpack var))
      mutateFromMakeCase ss (writeFlag a) file e out

-- | The @write@ boolean off a tool's arguments (default false).
writeFlag :: Value -> Bool
writeFlag a = argBool a "write" False

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
  "Filled " <> showT n <> " goal(s) against a single session load. Apply this \
  \combined diff, then `load` to refresh — the bridge does not write the file:\n\n"
    <> T.pack diff

runAuto :: ToolRunner
runAuto ss a = withGoal ss a $ \sess file e iid -> do
  out <- runRaw sess (iotcmAutoOne file AsIs iid "")
  case out of
    Left err -> pure (Left err)
    Right rs -> case [gr | ReplyGiveAction _ gr <- rs] of
      (GiveStr s : _) -> applyHoleEdit ss (writeFlag a) file e s
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

-- | Write the candidate to a temp copy under a FRESH top-level module name
-- and load it through a throwaway agda session. The rename matters: the real
-- target is reachable on the include path, so a temp keeping the target's
-- module name collides (`AmbiguousTopLevelModuleName`). A def's
-- well-typedness doesn't depend on its enclosing module's name, so renaming
-- validates the same thing without the clash. 'Right ()' iff it type-checks
-- (remaining holes are fine — they are not errors).
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

-- | Turn a give\/refine reply burst into an edit diff. An Error means the
-- term was rejected and the file is untouched; a GiveAction carries the
-- replacement (either an explicit string, or the user's input optionally
-- parenthesised).
mutateFromGive :: ServerState -> Bool -> FilePath -> GoalEntry -> Maybe Text -> Either Text [Reply] -> IO (Either Text Text)
mutateFromGive _  _     _    _ _      (Left err) = pure (Left err)
mutateFromGive ss write file e mInput (Right rs) = case firstError rs of
  Just m  -> pure (Left ("agda rejected the term — file unchanged:\n" <> m))
  Nothing -> case [gr | ReplyGiveAction _ gr <- rs] of
    (gr:_) ->
      let repl = giveReplacement gr (fromMaybe "" mInput)
      in applyHoleEdit ss write file e repl
    [] -> pure (Left "agda returned no give action (unexpected protocol shape).")

-- | Turn a make_case reply into a diff that replaces the clause line with
-- the generated clauses, re-indented to the clause's column.
mutateFromMakeCase :: ServerState -> Bool -> FilePath -> GoalEntry -> Either Text [Reply] -> IO (Either Text Text)
mutateFromMakeCase _  _     _    _ (Left err) = pure (Left err)
mutateFromMakeCase ss write file e (Right rs) = case firstError rs of
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
          applyOrDiff ss write file old new
      [] -> pure (Left "agda returned no clauses (is the variable in a pattern position?).")

-- | Splice @repl@ over the hole's range, guarding that the hole is inside a
-- code block. Marks the session dirty (its in-memory state has diverged
-- from disk, which the bridge does not write — the next query reloads).
applyHoleEdit :: ServerState -> Bool -> FilePath -> GoalEntry -> Text -> IO (Either Text Text)
applyHoleEdit ss write file e repl = case geRange e of
  Nothing              -> pure (Left "goal has no source range; cannot edit.")
  Just (GoalRange s en) -> withSourceGuarded file (rpPos s) $ \old -> do
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
          w <- try (TIO.writeFile file new) :: IO (Either SomeException ())
          case w of
            Left e   -> pure (Left ("could not write " <> T.pack file <> ": " <> showT e))
            Right () -> do
              r <- doLoad ss file
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
-- @Cmd_load@, reconcile the stable-goal map, store the entry, and return
-- the raw reply burst alongside. The single place a @Cmd_load@ is issued +
-- reconciled; 'doLoad' and 'runCheck' read different things off it. On a
-- load that yields goals the stable-goal map is re-synced; on a load error
-- the prior map is preserved (so a transient error doesn't drop stable ids).
loadAndSync :: ServerState -> FilePath -> IO (Either Text (Session, GoalMap, [GoalEntry], SendOutcome))
loadAndSync ss file = modifyMVar (ssSessions ss) $ \m -> do
  eSess <- getLiveSession ss m file
  case eSess of
    Left err   -> pure (m, Left err)
    Right sess -> do
      let gm0 = maybe emptyGoalMap seGoalMap (M.lookup file m)
      out <- sendIotcm sess (iotcmLoad file (loadIncludes ss file))
      now <- getCurrentTime
      -- Reuse the existing last-used cell when reloading a known file (so its
      -- idle clock is reset, not orphaned); otherwise mint a fresh one.
      luRef <- maybe (newIORef now) (\e -> seLastUsed e <$ writeIORef (seLastUsed e) now)
                     (M.lookup file m)
      let (gm1, es) = case interpretLoad out of
                        Right goals -> syncGoals gm0 goals
                        Left _      -> (gm0, [])
          m1        = M.insert file (SessionEntry sess gm1 False luRef) m
      m2 <- capSessions (cfgMaxSessions (ssConfig ss)) file m1
      pure (m2, Right (sess, gm1, es, out))

-- | (Re)load a module, returning the session, the new goal map, the goal
-- entries, and the file path — or the load error. The classic interface
-- on top of 'loadAndSync', preserving the old Left-on-load-error semantics.
doLoad :: ServerState -> FilePath -> IO (Either Text (Session, GoalMap, [GoalEntry], FilePath))
doLoad ss file = do
  r <- loadAndSync ss file
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
        r <- loadAndSync ss file
        case r of
          Left err              -> pure (Left err)
          Right (_, _, es, out) -> do
            emitGoals ss file es
            pure (Right (renderCheckLive file (interpretCheck out) es))

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
-- session's reconciled map) and source positions.
renderCheckLive :: FilePath -> CheckOutcome -> [GoalEntry] -> Text
renderCheckLive file co es =
  checkVerdict file co <> renderDiagnostics co
    <> if null es then ""
       else "\n\nOpen goals:\n"
              <> T.unlines [ "  " <> renderStableId (geStable e) <> "  : " <> geType e <> posNote e | e <- es ]

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
proceedGiveFile ss write file candidate = case checkFileInput candidate of
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
    let (impLines, unresolved) = resolveImports mld openImp imports
        content                = buildModuleContent lit modName impLines defs
    case checkFileInput content of
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
                r <- doLoad ss file
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

-- | Resolve bare names to @open import <Module>@ (or @import@) lines via
-- the loaded snapshot's index; names with no defining module come back as
-- unresolved (reported, never invented). Deduped, input order preserved.
resolveImports :: Maybe Loaded -> Bool -> [Text] -> ([Text], [Text])
resolveImports mld openImp names =
  let kw = if openImp then "open import " else "import "
      step nm = case mld >>= \ld -> resolveModuleFor ld nm of
        Just m  -> Left (kw <> m)
        Nothing -> Right nm
      rs = map step names
  in (nub [ l | Left l <- rs ], [ n | Right n <- rs ])

-- | The most common defining module among defs whose name matches @nm@
-- (exact, dotted-suffix, or last component); ties broken by module name.
-- Best-effort import resolution.
resolveModuleFor :: Loaded -> Text -> Maybe Text
resolveModuleFor ld nm =
  case sortOn (\(m, c) -> (Down c, m)) (M.toList counts) of
    []          -> Nothing
    ((m, _) : _) -> Just m
  where
    counts = M.fromListWith (+)
               [ (defModule d, 1 :: Int) | d <- ldRealDefs ld, nameMatches d ]
    nameMatches d = let dn = defName d
                    in dn == nm || ("." <> nm) `T.isSuffixOf` dn || lastCompT dn == nm

lastCompT :: Text -> Text
lastCompT t = let (_, suf) = T.breakOnEnd "." t in if T.null suf then t else suf

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

-- | One construct step: an op (@give@/@refine@/@case_split@/@auto@), the
-- target goal id, and the op's optional argument (term\/expr\/var).
data Step = Step !Text !Text !(Maybe Text)
instance FromJSON Step where
  parseJSON = withObject "step" $ \o -> do
    op <- o .:  "op"
    g  <- o .:  "goal"
    mt <- o .:? "term"
    me <- o .:? "expr"
    mv <- o .:? "var"
    pure (Step op g (listToMaybe (catMaybes [mt, me, mv])))

stepLabel :: Step -> Text
stepLabel (Step op g _) = op <> " " <> g

stepGoal :: Step -> Text
stepGoal (Step _ g _) = g

-- | Run a sequence of hole-driven steps against one warm load, accumulating
-- one combined diff. See the tool description for the (deliberate) limits.
runConstruct :: ToolRunner
runConstruct ss a = case argLookup a "steps" >>= parseMaybe parseJSON of
  Nothing    -> pure (Left "construct requires a `steps` array of {op, goal, …} objects (op = give|refine|case_split|auto).")
  Just []    -> pure (Left "construct: `steps` is empty.")
  Just steps ->
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
            eold <- readFileSafe file
            case eold of
              Left e     -> pure (Left e)
              Right orig -> do
                res <- constructLoop ss file orig (codeBlocksFor file orig) steps []
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
constructLoop :: ServerState -> FilePath -> Text -> CodeBlocks -> [Step]
              -> [(Int, Int, Text)] -> IO (Either Text [(Int, Int, Text)])
constructLoop _  _    _    _  []       acc = pure (Right (reverse acc))
constructLoop ss file orig cb (s:rest) acc = do
  r <- doLoad ss file
  case r of
    Left err -> pure (Left ("construct: " <> stepLabel s <> ": load failed: " <> err))
    Right (sess, gm, _, _) ->
      case parseStableId (stepGoal s) >>= \sid -> (,) sid <$> lookupStable gm sid of
        Nothing     -> pure (Left ("construct: " <> stepLabel s <> ": not an open goal id: " <> stepGoal s))
        Just (_, e) -> case (geIid e, geRange e) of
          (Just iid, Just (GoalRange gs ge))
            | not (isInsideCode cb (rpPos gs)) ->
                pure (Left (stepLabel s <> ": the hole is not inside an Agda code block."))
            | otherwise -> do
                stepE <- runStepEdit sess file orig iid (rpPos gs) (rpPos ge) s
                case stepE of
                  Left err -> pure (Left err)
                  Right ed -> constructLoop ss file orig cb rest (ed : acc)
          _ -> pure (Left (stepLabel s <> ": not an open goal."))

-- | Execute one construct step against the live session, returning its edit
-- in ORIGINAL-text offsets: give\/refine\/auto replace the hole range;
-- case_split replaces the clause line.
runStepEdit :: Session -> FilePath -> Text -> Int -> Int -> Int -> Step
            -> IO (Either Text (Int, Int, Text))
runStepEdit sess file orig iid holeS holeE s@(Step op _ marg) =
  let lbl       = stepLabel s
      giveStep  = giveStepEdit sess lbl holeS holeE
  in case op of
       "give" -> case marg of
         Nothing -> pure (Left (lbl <> ": give needs a `term`."))
         Just t  -> giveStep (iotcmGive file iid (T.unpack t)) t
       "refine" ->
         let hint = fromMaybe "" marg
         in giveStep (iotcmRefineOrIntro file iid (T.unpack hint)) hint
       "auto" -> giveStep (iotcmAutoOne file AsIs iid "") ""
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
giveStepEdit :: Session -> Text -> Int -> Int -> String -> Text
             -> IO (Either Text (Int, Int, Text))
giveStepEdit sess lbl holeS holeE cmd parenInput = do
  out <- runRaw sess cmd
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
runLemmas ss a = withGoal ss a $ \_sess _file e _iid -> do
  ef <- ensureFresh ss
  case ef of
    Left err      -> pure (Left ("graph index unavailable: " <> T.pack err))
    Right (ld, _) ->
      let goalTy = geType e
          out    = queryFindLemma ld (argInt a "limit" 10) (argDouble a "min_sim" 0.3)
                     (argText a "kind") (argText a "module_prefix") (Just goalTy) Nothing
      in pure (Right ("Goal " <> renderStableId (geStable e) <> "  : " <> goalTy <> "\n\n" <> out
                       <> "\n\n(Reuse a candidate with `give`/`refine`. This matches conclusion \
                          \tokens — a name-overlap proxy; for WL shape matching pass an `anchor` \
                          \to the read-side `find_lemma`.)"))

showT :: Show a => a -> Text
showT = T.pack . show
