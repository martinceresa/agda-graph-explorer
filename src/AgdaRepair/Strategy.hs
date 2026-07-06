{-# LANGUAGE OverloadedStrings #-}
-- | Graph-backed candidate generation: a 'Diagnostic' plus the dependency graph
-- become a ranked list of 'Candidate' edit bundles for the loop to validate.
-- Every scope question is a lookup over the graph's defs, not a text search:
--
--   * which module exports @X@ — look up the base name, read 'defModule'
--     ('defOrigin' marks an overlay def needing an @open import@). Resolves the
--     re-export cases a source scan cannot (e.g. @ℤ@, re-exported as @Int@);
--   * closest name to a typo — edit distance over the file's in-scope names and
--     the graph's names (which double as import targets).
--
-- Candidates are ranked (already-imported module first, then shorter/less
-- exotic paths), but correctness rests on the loop's recompile-validate, so
-- over-generation is safe.
module AgdaRepair.Strategy
  ( Candidate
  , Env
  , buildEnv
  , candidatesFor
  , inScopeNames
  , importCandidates
  ) where

import           Data.Char        (isDigit)
import           Data.List        (sortOn)
import qualified Data.Map.Strict  as M
import           Data.Map.Strict  (Map)
import           Data.Maybe       (mapMaybe)
import           Data.Ord         (Down (..))
import           Data.Set         (Set)
import qualified Data.Set         as Set
import           Data.Text        (Text)
import qualified Data.Text        as T

import           AgdaGraph.Schema (Access (..), Definition (..), Kind (..))
import           AgdaMcp.State    (Loaded (..))

import           AgdaRepair.Diagnostic (Diagnostic (..), stripUnderscores)
import           AgdaRepair.Edit       (Edit (..))

-- | A candidate is a bundle of edits validated together (e.g. a rename plus
-- the import that brings the corrected name into scope).
type Candidate = [Edit]

-- | Loop-invariant scope oracle: the graph's real defs indexed by
-- underscore-stripped base name (so a bare @×@ finds @_×_@). Built once per
-- repair run — 'candidatesFor' is then an O(1) keyed lookup, not a scan of the
-- whole federated def set on every missing name. Empty without a graph, which
-- degrades to typo-only repair (imports need the graph).
newtype Env = Env (Map Text [Definition])

buildEnv :: Maybe Loaded -> Env
buildEnv Nothing   = Env M.empty
buildEnv (Just ld) = Env (M.fromListWith (++)
  [ (stripUnderscores (baseName d), [d]) | d <- ldRealDefs ld ])

-- | Ranked candidates for one diagnostic. Import candidates come first (the
-- safe, common fix); renames follow (guarded to close-by-edit-distance names,
-- and paired with an import when the target isn't already in scope).
candidatesFor :: Env -> Text -> Diagnostic -> [Candidate]
candidatesFor env src d = case d of
  DScope name -> imports name ++ renames name
  DParse name -> imports name                       -- operator/ctor: import only
  _           -> []                                 -- goals/incomplete/refuse: loop-handled
  where
    scope   = inScopeNames src
    imports = map (\l -> [EAddImport l]) . importCandidates env src
    -- rename to a near-match already in scope, else a graph name + its import.
    renames name =
      let inScope = [ [ERename name r]
                    | r <- nearMatches name (Set.toList scope) ]
          viaGraph = [ [ERename name (baseName g), EAddImport (importLineFor g)]
                     | g <- take 3 (graphNearMatches env name)
                     , baseName g `Set.notMember` scope ]
      in inScope ++ viaGraph

-- | Import lines that would bring @name@ into scope, ranked. Exposed for
-- reuse by the operator/constructor ('DParse') path. Empty without a graph.
importCandidates :: Env -> Text -> Text -> [Text]
importCandidates (Env byBase) src name =
  take 6 . dedupKeep . concatMap importLinesFor . sortOn rank $ defs
  where
    defs    = M.findWithDefault [] (stripUnderscores name) byBase
    already = importedModules src
    -- prefer: a module the file already imports; public over private; shorter,
    -- less-exotic module paths.
    rank d =
      ( Down (defModule d `elem` already)
      , defAccess d == Private
      , exotic (defModule d)
      , T.length (defModule d) )
    exotic m = any (`T.isPrefixOf` m)
                 ["Codata", "Algebra.Solver", "Relation.Binary.Construct", "Tactic"]
    dedupKeep = go []
      where go _ [] = []
            go seen (x:xs) | x `elem` seen = go seen xs
                           | otherwise     = x : go (x : seen) xs

-- | Candidate import lines for a definition. For a constructor — namespaced by
-- the producer under its datatype (@Agda.Builtin.Nat.Nat.suc@ ⇒ module
-- @Agda.Builtin.Nat.Nat@) — the importable module is the /parent/, so we offer
-- both the parent and the raw module; the recompile step picks the one that
-- works. Uses the def's own mixfix base name (so @_×_@ imports as @_×_@, not
-- the bare @×@ the error reported).
importLinesFor :: Definition -> [Text]
importLinesFor d = [ "open import " <> m <> " using (" <> baseName d <> ")" | m <- moduleCandidates d ]

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
-- Near-match (typo) helpers
-- ---------------------------------------------------------------------

-- | In-scope names within edit distance ≤ 2 of a not-in-scope token, closest
-- first — the safe rename targets (no import needed).
nearMatches :: Text -> [Text] -> [Text]
nearMatches name = map snd . sortOn fst . mapMaybe score
  where
    score c = let dcost = lev name c
              in if c /= name && dcost <= 2 then Just (dcost, c) else Nothing

-- | Graph definitions whose base name is a near-match — rename targets that
-- also need an import. Ranges over the index's (deduped) base-name keys, so the
-- edit-distance scan is over distinct names, not every def; one representative
-- def per key. Empty without a graph.
graphNearMatches :: Env -> Text -> [Definition]
graphNearMatches (Env byBase) name =
  [ d | k <- sortOn (lev name) nearKeys, d <- take 1 (M.findWithDefault [] k byBase) ]
  where nearKeys = [ k | k <- M.keys byBase, k /= name, lev name k <= 2 ]

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
