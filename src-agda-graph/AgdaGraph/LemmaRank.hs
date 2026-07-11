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
-- coverage/Jaccard pair is the historically-tuned primary signal (the
-- @find_lemma@ 10/10 micro-bench) and is left untouched.
--
-- Layered on top is a __carrier-module affinity__ tie-breaker (arena R20).
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
-- signature-less graph) affinity is 0 everywhere and the ranking is
-- byte-identical to the pre-R20 behaviour.
module AgdaGraph.LemmaRank
  ( RankEnv(..)
  , LemmaScore
  , rankLemmaCandidates
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
import           AgdaGraph.GoalCanon ( conclusionOf, matchTokens, nameTokens
                                     , shapeTokens, weightedCoverage
                                     , tokenJaccard, isOpToken )

-- | Everything the ranker needs from a loaded graph snapshot, as plain
-- data (no @Loaded@ / @AgdaMcp.State@ dependency, so it is testable).
data RankEnv = RankEnv
  { reDefs    :: ![Definition]       -- ^ the snapshot's real defs (@ldRealDefs@).
  , reAliases :: !(Map Text Text)    -- ^ @renaming@ re-export aliases (@ldAliases@); may be empty.
  }

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
rankLemmaCandidates env candKeep minSim goal ctxTypes =
  sortBy (comparing (\(sc, d) -> (Down sc, defName d)))
    [ (sc, d)
    | d <- reDefs env, candKeep d
    , Just sig <- [defSig d]
    , let bag = matchTokens keep (conclusionOf sig) `Set.union` nameTokens (defName d)
          cov = weightedCoverage gtoks bag
          jac = tokenJaccard gtoks bag
          aff = Set.size (Set.intersection carrierSegs (moduleSegments (defModule d)))
          sc  = (cov, jac, aff, negate (Set.size bag))
    , cov >= minSim ]
  where
    keep t      = t `Set.member` vocab
    vocab       = envVocab env
    gtoks       = matchTokens keep concl `Set.union` shapeTokens concl
    concl       = conclusionOf goal
    carrierSegs = goalCarrierSegments env goal ctxTypes

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
    [ Map.singleton (baseName (defName d)) (Set.singleton (defModule d))
    | d <- reDefs, defKind d `elem` [KConstructor, KDatatype, KRecord] ]
    ++
    [ Map.singleton (baseName k) (Set.singleton (moduleOf k))
    | k <- Map.keys reAliases ]

envVocab :: RankEnv -> Set Text
envVocab env = Set.fromList [ baseName (defName d) | d <- reDefs env ]

-- | Final dotted component of a (possibly qualified) name
-- (@Data.Nat.Properties.+-comm@ → @+-comm@).
baseName :: Text -> Text
baseName = snd . T.breakOnEnd "."

-- | The module part of a fully-qualified node key: everything before the
-- final dotted component (@Data.Nat.Base.ℕ@ → @Data.Nat.Base@). @""@ when
-- unqualified.
moduleOf :: Text -> Text
moduleOf qn = case fst (T.breakOnEnd "." qn) of
  pre | T.null pre -> ""              -- unqualified: no module part
      | otherwise  -> T.dropEnd 1 pre  -- strip the trailing '.'
