{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | YAML configuration for @agda-auto@ — the fifth of the per-executable
-- @Config@ modules, sharing the discovery + decode plumbing in
-- "AgdaGraph.ConfigCore".
--
-- Discovery (first match wins): @--config=PATH@ > @$AGDA_AUTO_CONFIG@ >
-- @./.agda-auto.{yml,yaml}@ > nearest @*.agda-lib@ ancestor. Merge:
-- defaults → config → CLI. Top-level YAML keys are kebab-case mirrors of the
-- 'AgdaAuto.CLI' long flags; every field is 'Maybe' so a partial config only
-- overrides what it names.
module AgdaAuto.Config
  ( FileConfig(..)
  , emptyFileConfig
  , applyConfig
  , discoverConfigPath
  , loadConfig
  ) where

import           Data.Aeson           ( FromJSON(..), (.:?), withObject )
import           Data.Maybe           ( fromMaybe )
import           Data.Text            ( Text )

import           AgdaAuto.CLI         ( AutoOpts(..) )
import           AgdaGraph.ConfigCore ( DiscoverSpec(..), discoverWith, loadYamlConfig
                                      , checkKnownKeysP )

-- | A parsed @.agda-auto.yml@. Every field 'Maybe'/absent-tolerant so an
-- unset key leaves the seed untouched.
data FileConfig = FileConfig
  { fcWrite         :: !(Maybe Bool)
  , fcAnnotate      :: !(Maybe Bool)
  , fcTimeout       :: !(Maybe Int)
  , fcHints         :: !(Maybe Int)
  , fcGraph         :: !(Maybe FilePath)
  , fcOverlays      :: !(Maybe [FilePath])
  , fcJson          :: !(Maybe Bool)
  , fcIncludes      :: !(Maybe [FilePath])
  , fcAgdaBin       :: !(Maybe FilePath)
  , fcAgdaArgs      :: !(Maybe [String])
  , fcPremiseSelect :: !(Maybe Bool)
  , fcRankIdf       :: !(Maybe Bool)
  , fcNoHintBatch   :: !(Maybe Bool)
  , fcNoAutoLadder  :: !(Maybe Bool)
  , fcProject       :: !(Maybe FilePath)
  , fcWallBudget    :: !(Maybe Int)
  , fcRepair        :: !(Maybe Bool)
  , fcFixpoint      :: !(Maybe Bool)
  , fcLedger        :: !(Maybe FilePath)
  } deriving (Show)

-- | The all-unset config (a no-op under 'applyConfig'). A record-update base
-- for tests and callers that build a config programmatically.
emptyFileConfig :: FileConfig
emptyFileConfig = FileConfig
  Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  Nothing Nothing Nothing

-- | Every key the instance below reads, aliases included. Keep the two in
-- step: a key here with no @.:?@ silently does nothing, and a @.:?@ missing
-- from here is rejected as unknown. (The @--show-defaults@ round-trip in
-- test/Spec.hs decodes the emitted skeleton, so a key the dump advertises but
-- this list omits fails the suite.)
knownKeys :: [Text]
knownKeys =
  [ "write", "annotate", "timeout", "hints", "graph", "overlay-graphs"
  , "json", "format", "include-paths", "agda-bin", "agda-args"
  , "premise-select", "rank-idf", "no-hint-batch", "no-auto-ladder"
  , "project", "wall-budget", "repair", "fixpoint", "ledger" ]

instance FromJSON FileConfig where
  parseJSON = withObject "agda-auto config" $ \o -> do
    checkKnownKeysP "agda-auto config" knownKeys o
    fcWrite         <- o .:? "write"
    fcAnnotate      <- o .:? "annotate"
    fcTimeout       <- o .:? "timeout"
    fcHints         <- o .:? "hints"
    fcGraph         <- o .:? "graph"
    fcOverlays      <- o .:? "overlay-graphs"
    -- Output: canonical `format: human|json` wins over the `json: bool` alias.
    fcJson          <- do
      j   <- o .:? "json"
      fmt <- o .:? "format"
      case (fmt :: Maybe String) of
        Just "json"  -> pure (Just True)
        Just "human" -> pure (Just False)
        Just other   -> fail ("unknown format: " ++ other ++ " (want human|json)")
        Nothing      -> pure j
    fcIncludes      <- o .:? "include-paths"
    fcAgdaBin       <- o .:? "agda-bin"
    fcAgdaArgs      <- o .:? "agda-args"
    fcPremiseSelect <- o .:? "premise-select"
    fcRankIdf       <- o .:? "rank-idf"
    fcNoHintBatch   <- o .:? "no-hint-batch"
    fcNoAutoLadder  <- o .:? "no-auto-ladder"
    fcProject       <- o .:? "project"
    fcWallBudget    <- o .:? "wall-budget"
    fcRepair        <- o .:? "repair"
    fcFixpoint      <- o .:? "fixpoint"
    fcLedger        <- o .:? "ledger"
    pure FileConfig{..}

-- | Overlay a 'FileConfig' onto an 'AutoOpts' seed (normally 'defaultOpts').
-- Scalars replace; the repeatable list fields append onto the seed so a later
-- CLI @-i@/@--overlay-graph@/@--agda-arg@ accumulates after the config's — the
-- same base-then-CLI order the @agda-explore@ layer uses.
applyConfig :: FileConfig -> AutoOpts -> AutoOpts
applyConfig FileConfig{..} o = o
  { aoWrite         = fromMaybe (aoWrite o)         fcWrite
  , aoAnnotate      = fromMaybe (aoAnnotate o)      fcAnnotate
  , aoTimeout       = fromMaybe (aoTimeout o)       fcTimeout
  , aoHints         = fromMaybe (aoHints o)         fcHints
  , aoGraph         = maybe (aoGraph o) Just        fcGraph
  , aoOverlays      = aoOverlays o ++ fromMaybe []  fcOverlays
  , aoJson          = fromMaybe (aoJson o)          fcJson
  , aoIncludes      = aoIncludes o ++ fromMaybe []  fcIncludes
  , aoAgdaBin       = maybe (aoAgdaBin o) Just      fcAgdaBin
  , aoAgdaArgs      = aoAgdaArgs o ++ fromMaybe []  fcAgdaArgs
  , aoPremiseSelect = fromMaybe (aoPremiseSelect o) fcPremiseSelect
  , aoRankIdf       = fromMaybe (aoRankIdf o)       fcRankIdf
  , aoNoHintBatch   = fromMaybe (aoNoHintBatch o)   fcNoHintBatch
  , aoNoAutoLadder  = fromMaybe (aoNoAutoLadder o)  fcNoAutoLadder
  , aoProject       = maybe (aoProject o) Just      fcProject
  , aoWallBudget    = fromMaybe (aoWallBudget o)    fcWallBudget
  , aoRepair        = fromMaybe (aoRepair o)        fcRepair
  , aoFixpoint      = fromMaybe (aoFixpoint o)      fcFixpoint
  , aoLedger        = maybe (aoLedger o) Just       fcLedger
  }

-- | Resolve a @.agda-auto.yml@ path with the shared precedence.
discoverConfigPath :: Maybe FilePath -> IO (Maybe FilePath)
discoverConfigPath = discoverWith DiscoverSpec
  { dsEnvVar    = "AGDA_AUTO_CONFIG"
  , dsBaseNames = [ ".agda-auto.yml", ".agda-auto.yaml" ]
  }

loadConfig :: FilePath -> IO (Either String FileConfig)
loadConfig = loadYamlConfig
