{-# LANGUAGE OverloadedStrings #-}
-- | Graph-backed candidate generation: a 'Diagnostic' plus the dependency graph
-- become a ranked list of 'Candidate' import bundles for the loop to validate.
-- Every scope question is a lookup over the graph's defs (and its @renaming@
-- re-export aliases), not a text search:
--
--   * which module exports @X@ — look up the underscore-stripped base name,
--     read the def's 'defModule' (a constructor resolves to its datatype-parent
--     module; 'defOrigin' marks an overlay def) __or__ an alias's host module,
--     so a name in scope only via @open import M public renaming (a to b)@
--     resolves too (e.g. @combine@ → @Reexports@, @ℕ@ → @Data.Nat.Base@);
--   * closest name to a typo — edit distance over in-scope + graph names, used
--     only to /suggest/ (repair never renames).
--
-- Candidates are ranked (already-imported module first, carrier-affinity next
-- so a bare @ℕ@/@+-comm@ prefers its carrier module, then shorter/less-exotic
-- paths), but correctness rests on the loop's recompile-validate, so
-- over-generation is safe. This module is State-free (plain defs + alias map in,
-- no @AgdaMcp.State@) so the offline suite can exercise it.
module AgdaRepair.Strategy
  ( Candidate
  , Env
  , EnvEntry(..)
  , buildEnv
  , candidatesFor
  , nearMissSuggestions
  , inScopeNames
  , importCandidates
  , resolveImportModules
  , importLineFor
  ) where

import           Data.Char        (isDigit)
import           Data.List        (nub, sortOn)
import qualified Data.Map.Strict  as M
import           Data.Map.Strict  (Map)
import           Data.Maybe       (mapMaybe)
import           Data.Ord         (Down (..))
import           Data.Set         (Set)
import qualified Data.Set         as Set
import           Data.Text        (Text)
import qualified Data.Text        as T

import           AgdaGraph.Schema     (Access (..), Definition (..), Kind (..))
import qualified AgdaGraph.LemmaRank  as LR

import           AgdaRepair.Diagnostic (Diagnostic (..), stripUnderscores)
import           AgdaRepair.Edit       (Edit (..), isSigLine)

-- | A candidate is a bundle of edits validated together. Import-only.
type Candidate = [Edit]

-- | One thing that could bring a name into scope: either a real graph def, or
-- a @renaming@ re-export alias (its in-scope short name + the host module that
-- re-exports it). An alias never fabricates a 'Definition' — its host is where
-- the name is actually in scope, which is all the import line needs.
data EnvEntry
  = EntryDef   !Definition   -- ^ a real graph def
  | EntryAlias !Text !Text   -- ^ (alias short name, host module) e.g. (@combine@, @Reexports@)
  deriving (Show)

-- | Loop-invariant scope oracle: entries indexed by underscore-stripped base
-- name (so a bare @×@ finds @_×_@ and a bare @ℕ@ finds an alias @ℕ@), plus the
-- carrier map / vocab (lazily built once, forced only when carrier ranking is
-- used). Empty without a graph → no import candidates (imports need the graph).
data Env = Env
  { envByBase     :: !(Map Text [EnvEntry])
  , envCarrierMap :: Map Text (Set Text)   -- ^ lazy (LemmaRank carrier map)
  , envVocab      :: Set Text              -- ^ lazy (LemmaRank vocab)
  }

-- | Build the oracle from the snapshot's real defs and its @renaming@ alias
-- map (@ldRealDefs@ + @ldAliases@; the latter keyed @Host.alias@ → canonical).
buildEnv :: [Definition] -> Map Text Text -> Env
buildEnv defs aliases = Env
  { envByBase     = M.fromListWith (++) (defEntries ++ aliasEntries)
  , envCarrierMap = LR.carrierMap rankEnv
  , envVocab      = LR.envVocab rankEnv
  }
  where
    rankEnv      = LR.RankEnv defs aliases
    defEntries   = [ (stripUnderscores (baseName d), [EntryDef d]) | d <- defs ]
    aliasEntries = [ (stripUnderscores alias, [EntryAlias alias host])
                   | qkey <- M.keys aliases, let (alias, host) = splitHostAlias qkey ]

-- | Split a host-qualified alias key @Host.alias@ into (@alias@, @Host@). The
-- alias short name is the final dotted component (may itself be mixfix, e.g.
-- @Host._∔_@ → (@_∔_@, @Host@)); the host is everything before it.
splitHostAlias :: Text -> (Text, Text)
splitHostAlias qkey =
  let (pre, alias) = T.breakOnEnd "." qkey
  in (alias, if T.null pre then "" else T.dropEnd 1 pre)

-- | Ranked candidates for one diagnostic. Import-only: a scope or parse
-- error is resolved by bringing the missing name into scope, never by renaming
-- — a rename can rewrite a theorem's meaning to silence a scope error (e.g.
-- @ℕ@ → @_#_@). A misspelling that no import fixes is reported with
-- 'nearMissSuggestions' instead of silently rewritten.
candidatesFor :: Env -> Text -> Diagnostic -> [Candidate]
candidatesFor env src d = case d of
  DScope name -> imports name
  -- A parse-error token that is already in scope (the file's own def or a var
  -- over-collected from the dump) needs no import; skip it so a full validate
  -- isn't wasted.
  DParse name
    | name `Set.member` scope -> []
    | otherwise               -> imports name
  _           -> []                                 -- goals/incomplete/refuse: loop-handled
  where
    scope     = inScopeNames src
    segs      = fileCarrierSegments env src
    imports n = [ [EAddImport l] | l <- importCandidates env segs src n ]

-- | Closest existing names to a not-in-scope token — reported (never applied)
-- when no import resolves it, so a genuine typo still gets a hint without
-- repair ever rewriting code. Draws from the file's in-scope names and the
-- graph's names, nearest first, capped.
nearMissSuggestions :: Env -> Text -> Text -> [Text]
nearMissSuggestions env src name =
  take 3 (nub (nearMatches name (Set.toList (inScopeNames src))
                 ++ map entryBaseName (graphNearMatches env name)))

-- | Import lines that would bring @name@ into scope, ranked. @segs@ are the
-- carrier-affinity segments of the surrounding context (empty to disable it).
-- Empty without a graph.
importCandidates :: Env -> Set Text -> Text -> Text -> [Text]
importCandidates env segs src name =
  take 6 . nub . concatMap entryImportLines $
    rankedEntries env segs (importedModules src) name

-- | Modules that would bring @name@ into scope, ranked most-likely first — for
-- @new_module@'s bare-name import resolution (which emits @open import M@, no
-- @using@). Carrier hints (@stub-type strings@) break ties toward the carrier
-- module. A constructor's parent module ranks ahead of its raw module (so a
-- type @ℕ → ℕ@ never resolves to a broken @open import Agda.Builtin.Nat.Nat@).
resolveImportModules :: Env -> [Text] -> Text -> [Text]
resolveImportModules env hints name =
  take 6 . nub . concatMap entryModules $
    rankedEntries env (carrierSegmentsFromTypes env hints) [] name

-- | Entries for @name@ (by underscore-stripped base name), ranked by
-- 'rankEntry'. The fetch-and-rank skeleton shared by both resolvers, which
-- differ only in the projection off each entry and how @segs@/@already@ are
-- derived. Empty without a graph.
rankedEntries :: Env -> Set Text -> [Text] -> Text -> [EnvEntry]
rankedEntries env segs already name =
  sortOn (rankEntry segs already)
         (M.findWithDefault [] (stripUnderscores name) (envByBase env))

-- | Ranking key shared by both resolvers: prefer an already-imported module,
-- then public over private, then higher carrier affinity, then a
-- less-exotic / shorter module path.
rankEntry :: Set Text -> [Text] -> EnvEntry -> (Down Bool, Bool, Down Int, Bool, Int)
rankEntry segs already e =
  ( Down (m `elem` already)
  , entryPrivate e
  , Down (Set.size (Set.intersection segs (LR.moduleSegments m)))
  , exotic m
  , T.length m )
  where
    m = entryModule e
    exotic mod' = any (`T.isPrefixOf` mod')
                    ["Codata", "Algebra.Solver", "Relation.Binary.Construct", "Tactic"]

-- ---------------------------------------------------------------------
-- EnvEntry accessors
-- ---------------------------------------------------------------------

-- | The name as written in a @using (…)@ list (mixfix form: @_×_@, @ℕ@, @combine@).
entryBaseName :: EnvEntry -> Text
entryBaseName (EntryDef d)     = baseName d
entryBaseName (EntryAlias a _) = a

-- | Modules that could bring the entry into scope, most-likely first. A
-- constructor offers its datatype-parent module then its raw module; an alias
-- is in scope only via its host.
entryModules :: EnvEntry -> [Text]
entryModules (EntryDef d)        = moduleCandidates d
entryModules (EntryAlias _ host) = [host]

-- | The primary (first-ranked) module of an entry.
entryModule :: EnvEntry -> Text
entryModule e = case entryModules e of { (m:_) -> m; [] -> "" }

-- | Import lines for an entry (one per candidate module).
entryImportLines :: EnvEntry -> [Text]
entryImportLines e =
  [ "open import " <> m <> " using (" <> entryBaseName e <> ")" | m <- entryModules e ]

-- | An entry whose import can't work because the def is private. A re-export
-- alias is public by construction.
entryPrivate :: EnvEntry -> Bool
entryPrivate (EntryDef d)     = defAccess d == Private
entryPrivate (EntryAlias _ _) = False

-- ---------------------------------------------------------------------
-- Carrier affinity (R25b): a bare `ℕ` / `+-comm` prefers its carrier module.
-- ---------------------------------------------------------------------

-- | Carrier segments implied by a file's top-level signature types (repair):
-- e.g. a file with @f : ℕ → ℕ@ yields segment @Nat@, so an import of @+-comm@
-- prefers @Data.Nat.Properties@ over @Data.Integer.Properties@.
fileCarrierSegments :: Env -> Text -> Set Text
fileCarrierSegments env = carrierSegmentsFromTypes env . sigTypeStrings

-- | Carrier segments implied by a list of type strings (the ctxTypes slot of
-- the shared ranker). Used by both resolvers.
carrierSegmentsFromTypes :: Env -> [Text] -> Set Text
carrierSegmentsFromTypes env =
  LR.carrierSegmentsFor (envCarrierMap env) (envVocab env) ""

-- | The type (RHS of @:@) of each top-level @name : Type@ line. Shares the
-- signature-line predicate with 'AgdaRepair.Edit.signatures' (the loop's
-- spec-preservation invariant) so the two notions can't drift.
sigTypeStrings :: Text -> [Text]
sigTypeStrings src =
  [ T.drop 1 (snd (T.breakOn ":" l)) | l <- T.lines src, isSigLine l ]

-- ---------------------------------------------------------------------
-- Definition helpers (import line for a Definition — used by oosNote too)
-- ---------------------------------------------------------------------

importLineFor :: Definition -> Text
importLineFor d = "open import " <> primaryModule d <> " using (" <> baseName d <> ")"

-- | Modules that could bring @d@ into scope, most-likely first.
moduleCandidates :: Definition -> [Text]
moduleCandidates d
  | defKind d == KConstructor = [moduleParent (defModule d), defModule d]
  | otherwise                 = [defModule d]

primaryModule :: Definition -> Text
primaryModule d = case moduleCandidates d of
  (m:_) -> m
  []    -> defModule d

-- | Drop the last dotted component of a module name (@A.B.C@ ↦ @A.B@).
moduleParent :: Text -> Text
moduleParent m = case T.breakOnEnd "." m of
  (pre, _) | not (T.null pre) -> T.dropEnd 1 pre
  _                           -> m

-- | The last dotted component with the @\@line@ helper tag stripped: the name
-- as it would be written in a @using (…)@ list.
baseName :: Definition -> Text
baseName = lastComponent . stripLineTag . defName

lastComponent :: Text -> Text
lastComponent = T.takeWhileEnd (/= '.')

stripLineTag :: Text -> Text
stripLineTag t = case T.breakOnEnd "@" t of
  (pre, suf) | not (T.null pre), not (T.null suf), T.all isDigit suf
             -> T.dropEnd 1 pre
  _          -> t

-- ---------------------------------------------------------------------
-- Near-match (typo) helpers — suggestion-only (repair never renames)
-- ---------------------------------------------------------------------

-- | In-scope names within edit distance ≤ 2 of a not-in-scope token, closest
-- first.
nearMatches :: Text -> [Text] -> [Text]
nearMatches name = map snd . sortOn fst . mapMaybe score
  where
    score c = let dcost = lev name c
              in if c /= name && dcost <= 2 then Just (dcost, c) else Nothing

-- | Graph entries whose base name is a near-match. Ranges over the (deduped)
-- base-name keys, so the edit-distance scan is over distinct names; one
-- representative entry per key. Empty without a graph.
graphNearMatches :: Env -> Text -> [EnvEntry]
graphNearMatches env name =
  [ e | k <- sortOn (lev name) nearKeys, e <- take 1 (M.findWithDefault [] k byBase) ]
  where
    byBase   = envByBase env
    nearKeys = [ k | k <- M.keys byBase, k /= name, lev name k <= 2 ]

-- | Levenshtein distance, short-circuited when the length gap alone exceeds 2
-- (all the near-match threshold needs).
lev :: Text -> Text -> Int
lev a b
  | abs (T.length a - T.length b) > 2 = 99
  | otherwise = last (foldl transform [0 .. length ys] xs)
  where
    xs = T.unpack a
    ys = T.unpack b
    transform prev x = case prev of
      (p0 : ps) -> scanl compute (p0 + 1) (zip3 prev ps ys)
      []        -> []
      where compute left (diag, up, y) = minimum [ up + 1, left + 1, diag + fromEnum (x /= y) ]

-- ---------------------------------------------------------------------
-- Scope of a file
-- ---------------------------------------------------------------------

-- | Names in scope in a file: everything in its @open import … using (…)@
-- lists (and @renaming (x to y)@ targets) plus its own top-level definitions.
inScopeNames :: Text -> Set Text
inScopeNames src = Set.fromList (concatMap fromLine (T.lines src))
  where
    fromLine l
      | "open import" `T.isPrefixOf` l = usingNames l ++ renamingTargets l
      | otherwise                      = localDef l
    usingNames l = case T.breakOn "using (" l of
      (_, rest) | not (T.null rest) ->
        let inside = T.takeWhile (/= ')') (T.drop 7 rest)
        in map T.strip (T.splitOn ";" inside)
      _ -> []
    renamingTargets l = case T.breakOn "renaming (" l of
      (_, rest) | not (T.null rest) ->
        let inside = T.takeWhile (/= ')') (T.drop 10 rest)
        in [ T.strip (T.drop 2 aft)
           | seg <- T.splitOn ";" inside
           , let (_, aft) = T.breakOn " to " seg
           , not (T.null aft) ]
      _ -> []
    localDef l = case T.uncons l of
      Just (c, _) | c /= ' ', c /= '\t' ->
        case T.words l of
          (w:_) | w `notElem` kw -> [w]
          _                      -> []
      _ -> []
    kw = ["open","import","module","record","data","postulate","infix","infixl"
         ,"infixr","private","variable","syntax","{-#"]

-- | Modules the file already opens (for import ranking).
importedModules :: Text -> [Text]
importedModules src =
  [ T.takeWhile (/= ' ') rest
  | l <- T.lines src
  , Just rest <- [T.stripPrefix "open import " l] ]
