{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | YAML configuration for @agda-unused@.
--
-- The shape mirrors the CLI: every CLI long flag has a matching
-- kebab-case YAML field, plus a @roots:@ list for what would
-- otherwise be positional arguments.
--
-- Discovery order (first match wins):
--
--   1. @--config=PATH@ (explicit CLI).
--   2. @$AGDA_UNUSED_CONFIG@.
--   3. @./.agda-unused.yml@ or @./.agda-unused.yaml@ in cwd.
--   4. Walk up from cwd; first directory containing a @*.agda-lib@
--      file is the project root — look there.
--   5. None found.
--
-- The resulting 'Config' is folded over 'Options' via 'applyConfig'
-- BEFORE CLI parsing, so explicit CLI flags always win.
module AgdaUnused.Config
  ( Config(..)
  , loadConfig
  , discoverConfigPath
  , applyConfig
  , ConfigTarget(..)
  , parseKindsToken
  ) where

import           Control.Applicative ( (<|>) )
import           Data.Aeson          ( FromJSON(..), (.:?), withObject, withText )
import qualified Data.Aeson.Types    as A
import           Data.Foldable       ( toList )
import qualified Data.Text           as T

import           AgdaGraph.ConfigCore ( DiscoverSpec(..), discoverWith, loadYamlConfig
                                      , checkKnownKeysP )
import           AgdaUnused.Analysis ( FindingKind(..), GroupBy, parseGroupBy )

-- | Externally-supplied configuration. Every field is 'Maybe' so a
-- partial config only overrides what the user actually set.
data Config = Config
  { cfgJson      :: !(Maybe FilePath)
  , cfgRelTo     :: !(Maybe FilePath)
  , cfgJsonOut   :: !(Maybe Bool)
  , cfgKinds     :: !(Maybe [FindingKind])
  , cfgRoots     :: !(Maybe [FilePath])
  , cfgExclude   :: !(Maybe [String])
  , cfgGroupBy   :: !(Maybe GroupBy)
  , cfgCountOnly :: !(Maybe Bool)
  } deriving (Show)

-- | Drop-target for 'applyConfig'. We don't import the @Options@
-- type from "MainUnused" because that would create a cyclic
-- dependency; the caller threads in field-setters via this record.
data ConfigTarget a = ConfigTarget
  { ctSetJson      :: FilePath      -> a -> a
  , ctSetRelTo     :: FilePath      -> a -> a
  , ctSetJsonOut   :: Bool          -> a -> a
  , ctSetKinds     :: [FindingKind] -> a -> a
  , ctSetRoots     :: [FilePath]    -> a -> a
  , ctSetExclude   :: [String]      -> a -> a
  , ctSetGroupBy   :: GroupBy       -> a -> a
  , ctSetCountOnly :: Bool          -> a -> a
  }

-- | Apply a 'Config' to an arbitrary @Options@-shaped value using
-- the supplied setters. Each field is only touched when the
-- corresponding 'Maybe' is 'Just'.
applyConfig :: ConfigTarget a -> Config -> a -> a
applyConfig ConfigTarget{..} Config{..} = id
  . maybe id ctSetJson      cfgJson
  . maybe id ctSetRelTo     cfgRelTo
  . maybe id ctSetJsonOut   cfgJsonOut
  . maybe id ctSetKinds     cfgKinds
  . maybe id ctSetRoots     cfgRoots
  . maybe id ctSetExclude   cfgExclude
  . maybe id ctSetGroupBy   cfgGroupBy
  . maybe id ctSetCountOnly cfgCountOnly

-- | 'FromJSON' for the 'cfgKinds' field. Accepts EITHER a YAML
-- scalar (@kinds: "using,blanket"@) or a YAML list
-- (@kinds: [using, blanket]@). Each token is expanded via
-- 'parseKindsToken' so aliases like @\"defined\"@ still work in a
-- list element.
-- | Every key the instance below reads, aliases included. Keep the two in
-- step: a key here with no @.:?@ silently does nothing, and a @.:?@ missing
-- from here is rejected as unknown.
knownKeys :: [T.Text]
knownKeys =
  [ "graph", "json", "rel-to", "format", "json-out", "kinds", "roots"
  , "exclude", "group-by", "count-only" ]

instance FromJSON Config where
  parseJSON = withObject "agda-unused config" $ \o -> do
    checkKnownKeysP "agda-unused config" knownKeys o
    -- Input graph: canonical `graph:` wins over the legacy `json:` alias.
    cfgJson      <- (\g j -> g <|> j) <$> o .:? "graph" <*> o .:? "json"
    cfgRelTo     <- o .:? "rel-to"
    -- Output format: canonical `format: human|json` wins over `json-out:`.
    fmtKey       <- o .:? "format"
    jsonOutKey   <- o .:? "json-out"
    cfgJsonOut   <- case fmtKey of
                      Just t  -> Just <$> parseFormatField t
                      Nothing -> pure jsonOutKey
    rawKinds     <- o .:? "kinds"
    cfgKinds     <- traverse parseKindsField rawKinds
    cfgRoots     <- o .:? "roots"
    cfgExclude   <- o .:? "exclude"
    rawGroupBy   <- o .:? "group-by"
    cfgGroupBy   <- traverse parseGroupByField rawGroupBy
    cfgCountOnly <- o .:? "count-only"
    return Config{..}
    where
      parseFormatField :: T.Text -> A.Parser Bool
      parseFormatField t = case T.unpack t of
        "json"  -> pure True
        "human" -> pure False
        other   -> fail ("unknown format: " ++ other ++ " (want human|json)")
      parseGroupByField :: A.Value -> A.Parser GroupBy
      parseGroupByField = withText "group-by" $ \t ->
        case parseGroupBy (T.unpack t) of
          Left e  -> fail e
          Right g -> return g
      parseKindsField :: A.Value -> A.Parser [FindingKind]
      parseKindsField = \case
        A.String t -> case parseKindsCSV (T.unpack t) of
          Left e   -> fail e
          Right ks -> return ks
        A.Array xs -> do
          parts <- mapM (withText "kind" (return . T.unpack)) (toList xs)
          case mapM parseKindsToken parts of
            Left e   -> fail e
            Right ks -> return (concat ks)
        v -> A.typeMismatch "String or [String] for 'kinds'" v

-- | Parse a comma-separated kind list (CLI / scalar-YAML form).
parseKindsCSV :: String -> Either String [FindingKind]
parseKindsCSV = fmap concat . mapM parseKindsToken . splitComma
  where
    splitComma s = case break (== ',') s of
      (a, "")     -> [trim a]
      (a, _:rest) -> trim a : splitComma rest
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse

-- | Parse a single kind token. Mirrors 'MainUnused.parseKinds' one-arm.
parseKindsToken :: String -> Either String [FindingKind]
parseKindsToken "using"         = Right [UnusedInUsing]
parseKindsToken "blanket"       = Right [UnusedBlanketOpen]
parseKindsToken "defined"       = Right [DefinedDead, DefinedInternalOnly]
parseKindsToken "dead"          = Right [DefinedDead]
parseKindsToken "internal-only" = Right [DefinedInternalOnly]
parseKindsToken "public"        = Right [PublicWithoutDownstream]
parseKindsToken "duplicate"     = Right [DuplicateUsingForModule]
parseKindsToken "all"           = Right
  [ UnusedInUsing, UnusedBlanketOpen
  , DefinedDead, DefinedInternalOnly
  , PublicWithoutDownstream, DuplicateUsingForModule
  ]
parseKindsToken s = Left $ "unknown kind: " ++ s

-- | Locate a config file. Returns the first hit in the discovery
-- order documented at the module header, or 'Nothing' if no config
-- can be found. A thin wrapper over "AgdaGraph.ConfigCore".
discoverConfigPath :: Maybe FilePath -> IO (Maybe FilePath)
discoverConfigPath = discoverWith DiscoverSpec
  { dsEnvVar    = "AGDA_UNUSED_CONFIG"
  , dsBaseNames = [ ".agda-unused.yml", ".agda-unused.yaml" ]
  }

-- | Load and parse the config file. Returns @Left@ with a clean,
-- single-line error on parse failure.
loadConfig :: FilePath -> IO (Either String Config)
loadConfig = loadYamlConfig
