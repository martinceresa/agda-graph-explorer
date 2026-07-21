{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | The shared free-text goal→lemma ranking core, factored out of
-- @AgdaMcp.Query@ so the interaction-spec test-suite can reach it (that
-- suite depends on this @agda-graph@ library but cannot compile
-- @AgdaMcp.Query@, which drags in the fsnotify/process-heavy
-- @AgdaMcp.State@).
--
-- The ranker scores every signature-carrying definition by how much of a
-- goal's conclusion tokens it covers (operator-weighted 'weightedCoverage',
-- see 'AgdaGraph.GoalCanon'), then breaks ties by 'tokenJaccard'. This
-- coverage/Jaccard pair is the primary signal (tuned on the @find_lemma@
-- 10/10 micro-bench).
--
-- Layered on top is a __carrier-module affinity__ tie-breaker.
-- A goal like @n + zero ≡ n@ tokenises identically for
-- @Data.Nat.Properties.+-identityʳ@ and @Data.Integer.Properties.+-identityʳ@
-- (qualifier-strip erases @Data.Nat@ vs @Data.Integer@), so the two land in a
-- complete coverage/Jaccard tie and the alphabetically-first (@Data.Integer@)
-- wins — burying the instance whose carrier type the goal actually uses.
-- Affinity looks up the modules that /define/ the goal's value/type tokens
-- (@zero@, @ℕ@) and boosts candidates whose own module shares a non-generic
-- path segment (@Nat@). It sits __after__ Jaccard in the sort key, so it only
-- reorders otherwise-exact ties — the coverage number a client sees is
-- unchanged. When nothing resolves (no carrier defs, no aliases, a
-- signature-less graph) affinity is 0 everywhere and the ranking is the
-- plain coverage/Jaccard order.
module AgdaGraph.LemmaRank
  ( RankEnv(..)
  , mkRankEnv
  , RankOpts(..)
  , defaultRankOpts
  , LemmaScore
  , rankLemmaCandidates
  , rankLemmaCandidatesWith
  , computeIdf
  , goalCarrierSegments
  , carrierSegmentsFor
  , carrierMap
  , envVocab
  , moduleSegments
  , genericSegments
  ) where

import           Data.List        ( sortBy )
import qualified Data.Map.Strict  as Map
import           Data.Map.Strict  ( Map )
import           Data.Ord         ( Down(..), comparing )
import           Data.Set         ( Set )
import qualified Data.Set         as Set
import           Data.Text        ( Text )
import qualified Data.Text        as T

import           AgdaGraph.Schema    ( Definition(..), Kind(..) )
import           AgdaGraph.GoalCanon ( conclusionOf, headSymbol, matchTokens
                                     , nameTokens, goalFeatures, weightedCoverageIdf
                                     , idfOf, tokenJaccard, isOpToken
                                     , baseComponent, moduleComponent )

-- | Everything the ranker needs from a loaded graph snapshot, as plain
-- data (no @Loaded@ / @AgdaMcp.State@ dependency, so it is testable).
data RankEnv = RankEnv
  { reDefs    :: ![Definition]         -- ^ the snapshot's real defs (@ldRealDefs@).
  , reAliases :: !(Map Text Text)      -- ^ @renaming@ re-export aliases (@ldAliases@); may be empty.
  , reIdf     :: !(Map Text Double)    -- ^ per-token IDF weights ('computeIdf'); __empty__ = plain
                                       -- coverage (today's behaviour, so existing callers are unchanged).
  }

-- | A 'RankEnv' with no IDF weighting — the common case (every caller bar the
-- daemon's IDF path). Set 'reIdf' with a record update when a graph carries an
-- IDF map. Keeps a new 'RankEnv' field from rippling to every call site.
mkRankEnv :: [Definition] -> Map Text Text -> RankEnv
mkRankEnv defs aliases = RankEnv defs aliases Map.empty

-- | Ranking knobs that select between Phase-1 experiments and the shipped
-- default. Head-symbol handling (1b) lives here rather than in 'RankEnv'
-- because it is a sort-only concern, not corpus data; IDF (1a) lives in
-- 'RankEnv' because it is derived from the corpus.
data RankOpts = RankOpts
  { roHeadDemote :: !Bool
    -- ^ Demote (never drop) candidates whose conclusion head symbol differs
    -- from the goal's — a leading tier above coverage. Unknown head on either
    -- side never demotes.
  , roHeadFilter :: !Bool
    -- ^ Hard-drop head-mismatched candidates instead of merely demoting them
    -- (the stricter 1b variant; measured against 'roHeadDemote').
  } deriving (Show)

-- | The shipped ranker's behaviour: no head-symbol demotion or filtering.
-- Combined with an empty 'reIdf', 'rankLemmaCandidates' is byte-for-byte the
-- pre-Phase-1 ranker.
defaultRankOpts :: RankOpts
defaultRankOpts = RankOpts { roHeadDemote = False, roHeadFilter = False }

-- | @(weightedCoverage, tokenJaccard, carrierAffinity, negate bagSize)@.
-- Sorted descending (via 'Down'), so higher coverage — then higher Jaccard,
-- then higher affinity, then a tighter signature — ranks first.
type LemmaScore = (Double, Double, Int, Int)

-- | Rank every @candKeep@ definition carrying a signature against the goal,
-- keeping those with coverage @>= minSim@. The @[Text]@ is the goal's live
-- context types (binder types like @ℕ@); it feeds carrier affinity __only__,
-- never the coverage/Jaccard bag. Empty on the read side.
rankLemmaCandidates
  :: RankEnv -> (Definition -> Bool) -> Double -> Text -> [Text]
  -> [(LemmaScore, Definition)]
rankLemmaCandidates = rankLemmaCandidatesWith defaultRankOpts

-- | 'rankLemmaCandidates' generalised over 'RankOpts' — the entry point the
-- @hint-bench@ Phase-1 strategies vary. Coverage uses 'weightedCoverageIdf'
-- with @'reIdf' env@ (empty ⇒ plain coverage, so the returned 'LemmaScore' a
-- client sees is unchanged when IDF is off). Head-symbol handling is a
-- __sort-only__ tier: with 'roHeadDemote', a leading @headMatches@ boolean
-- floats head-matching candidates above mismatched ones without touching the
-- coverage number; with 'roHeadFilter', mismatched candidates are dropped
-- outright. An unknown head on either side never demotes or drops.
rankLemmaCandidatesWith
  :: RankOpts -> RankEnv -> (Definition -> Bool) -> Double -> Text -> [Text]
  -> [(LemmaScore, Definition)]
rankLemmaCandidatesWith ropts env candKeep minSim goal ctxTypes =
  sortBy (comparing sortKey)
    [ (sc, d)
    | d <- reDefs env, candKeep d
    , Just sig <- [defSig d]
    , let bag = defBag keep (defName d) sig
          cov = weightedCoverageIdf idf gtoks bag
          jac = tokenJaccard gtoks bag
          aff = Set.size (Set.intersection carrierSegs (moduleSegments (defModule d)))
          sc  = (cov, jac, aff, negate (Set.size bag))
    , cov >= minSim
    , not (roHeadFilter ropts) || headMatches (candHead d) ]
  where
    keep t      = t `Set.member` vocab
    vocab       = envVocab env
    idf         = reIdf env
    gtoks       = goalFeatures keep goal
    concl       = conclusionOf goal
    gHead       = headSymbol concl
    carrierSegs = goalCarrierSegments env goal ctxTypes
    candHead d  = defSig d >>= (headSymbol . conclusionOf)
    -- True (no demotion / no drop) when either head is unknown, else head equality.
    headMatches ch = case (gHead, ch) of
      (Just a, Just b) -> a == b
      _                -> True
    -- Head-match tier, ahead of coverage. Off ⇒ the boolean is a constant
    -- 'True' and @||@ short-circuits, so 'candHead' is never forced (zero
    -- head-symbol cost) and the order falls through to @Down sc@ — identical
    -- to today.
    sortKey (sc, d) =
      ( Down (not (roHeadDemote ropts) || headMatches (candHead d))
      , Down sc, defName d )

-- | Per-token inverse document frequency over a def list's signature token
-- bags, keyed by base-name token. @idf t = 1 + log (N / df t)@ where @N@ is
-- the number of signature-carrying defs and @df t@ how many of their bags
-- contain @t@: a token in every def keeps weight 1 (no boost, none dropped),
-- a rare token is boosted, and a token absent from the corpus resolves to the
-- 1.0 default. The bag matches 'rankLemmaCandidatesWith' exactly
-- (@matchTokens ∪ nameTokens@) so the weighting lines up with what is scored.
-- Empty def list ⇒ empty map ⇒ plain coverage.
computeIdf :: [Definition] -> Map Text Double
computeIdf defs = idfOf [ defBag keep (defName d) sig | d <- defs, Just sig <- [defSig d] ]
  where keep t = t `Set.member` vocabOf defs

-- | The retrieval token bag of a definition: its conclusion's match tokens
-- (qualifier-stripped, @keep@-filtered) unioned with its name tokens. The one
-- definition shared by 'rankLemmaCandidatesWith' (what is scored) and
-- 'computeIdf' (what IDF weights), so the two cannot drift.
defBag :: (Text -> Bool) -> Text -> Text -> Set Text
defBag keep name sig =
  matchTokens keep (conclusionOf sig) `Set.union` nameTokens name

-- | The base-name vocabulary of a def list (what 'matchTokens' keeps).
vocabOf :: [Definition] -> Set Text
vocabOf defs = Set.fromList [ baseComponent (defName d) | d <- defs ]

-- | The non-generic module-path segments implied by a goal's carrier
-- tokens: the value/type identifiers of its conclusion (and of each live
-- context type) that name a real definition, resolved to the segments of
-- their defining modules. E.g. @n + zero ≡ n@ → carrier token @zero@ →
-- module @Agda.Builtin.Nat@ → segment @Nat@. Empty when no carrier token
-- resolves. Exposed for the renderer (the @[carrier: …]@ marker) and tests.
goalCarrierSegments :: RankEnv -> Text -> [Text] -> Set Text
goalCarrierSegments env = carrierSegmentsFor (carrierMap env) (envVocab env)

-- | 'goalCarrierSegments' with the (expensive) carrier map and vocab passed
-- in, so a caller that ranks many names against one graph builds them once.
-- The write-side resolvers ('AgdaRepair.Strategy') reuse this so a bare
-- @ℕ@/@+-comm@ resolves to its carrier module.
carrierSegmentsFor :: Map Text (Set Text) -> Set Text -> Text -> [Text] -> Set Text
carrierSegmentsFor cmap vocab goal ctxTypes =
  Set.unions [ segsFor tok | tok <- Set.toList carrierToks ]
  where
    keep t      = t `Set.member` vocab
    -- carrier tokens: vocab-kept, NON-operator identifiers of the goal
    -- conclusion plus each context type. shapeTokens are deliberately
    -- excluded (a `RightIdentity` combinator must not drive the carrier).
    carrierToks = Set.unions
      ( valueToks (conclusionOf goal)
      : [ valueToks ct | ct <- ctxTypes ] )
    valueToks t = Set.filter (not . isOpToken) (matchTokens keep t)
    segsFor tok = case Map.lookup tok cmap of
      Just mods -> Set.unions (map moduleSegments (Set.toList mods))
      Nothing   -> Set.empty

-- | The dot-separated segments of a module path, minus the generic ones
-- (see 'genericSegments'): @"Data.Nat.Properties"@ → @{"Nat"}@.
moduleSegments :: Text -> Set Text
moduleSegments m =
  Set.fromList (T.splitOn "." m) `Set.difference` genericSegments

-- | Module-path segments that carry no carrier signal — organisational
-- namespace components common to many unrelated types. Kept small and
-- explicit; a missed generic segment would let unrelated candidates match.
-- The empty string is included so a leading/trailing dot never yields a
-- spurious match.
genericSegments :: Set Text
genericSegments = Set.fromList
  [ ""
  , "Data", "Agda", "Builtin", "Base", "Properties", "Core"
  , "Relation", "Binary", "Unary", "Nullary"
  , "Algebra", "Structures", "Definitions", "Bundles", "Morphism"
  , "Construct", "Codata", "Musical", "Sized"
  , "Function", "Level", "Prelude", "Instances", "Literals", "Effect"
  , "Primitive", "Foreign", "Reflection", "System", "IO"
  ]

-- ---------------------------------------------------------------------
-- internals
-- ---------------------------------------------------------------------

-- | base-name → the modules that define a carrier of that name. Restricted
-- to constructors / datatypes / records (value and type carriers) so the
-- module set stays principled, plus any @renaming@ alias's host module.
carrierMap :: RankEnv -> Map Text (Set Text)
carrierMap RankEnv{..} =
  Map.unionsWith Set.union $
    [ Map.singleton (baseComponent (defName d)) (Set.singleton (defModule d))
    | d <- reDefs, defKind d `elem` [KConstructor, KDatatype, KRecord] ]
    ++
    [ Map.singleton (baseComponent k) (Set.singleton (moduleComponent k))
    | k <- Map.keys reAliases ]

envVocab :: RankEnv -> Set Text
envVocab = vocabOf . reDefs

