{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
-- | YAML configuration support for @agda-optimization@.
--
-- A config file holds per-subcommand defaults that override
-- 'defaultOptions' but are themselves overridden by CLI flags. The
-- merge order, executed in 'AgdaOptimization.CLI.runSubcommand', is:
--
--   1. @<Subcmd>.defaultOptions@
--   2. config's @<subcmd>:@ section (each present key overrides)
--   3. argv parsed by @<Subcmd>.parseOptions seed argv@
--
-- The config file's wire schema is documented in @README.md@ and the
-- per-subcommand @applyConfig@ helpers; this module is purely the
-- discovery / load / route plumbing.
--
-- Discovery order, computed by 'discoverConfigPath':
--
--   1. Explicit @--config=PATH@ (passed in as @Just p@).
--   2. @$AGDA_OPTIMIZATION_CONFIG@.
--   3. @./.agda-optimization.yml@ or @./.agda-optimization.yaml@.
--   4. Walk up from cwd until a @*.agda-lib@ file is found; look for
--      the config in that directory.
--   5. 'Nothing' — no config applied.
module AgdaOptimization.Config
  ( -- * Loaded configuration
    Config(..)
    -- * Discovery / load
  , discoverConfigPath
  , loadConfig
    -- * Subcommand routing
  , subSectionFor
  , globalSection
  , applyGlobal
  , globalGraph
    -- * Unknown-key rejection
  , globalConfigKeys
  , checkConfigKeys
    -- * Helpers re-used by per-subcommand 'applyConfig'
  , lookupKey
  , lookupKeyEnum
  , lookupKeyTextList
  ) where

import           Control.Exception       ( IOException, try )
import qualified Data.Aeson              as A
import qualified Data.Aeson.KeyMap       as KM
import qualified Data.Aeson.Key          as K
import           Data.Aeson.Types        ( parseEither )
import qualified Data.ByteString         as BS
import           Data.Text               ( Text )
import qualified Data.Text               as T
import qualified Data.Yaml               as Y

import           AgdaGraph.ConfigCore    ( DiscoverSpec(..), discoverWith
                                         , checkKnownKeys )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..) )

----------------------------------------------------------------------
-- Loaded shape
----------------------------------------------------------------------

-- | A successfully-loaded YAML config. The top-level value MUST decode
-- as an 'A.Object' — a YAML scalar / list at the top is rejected by
-- 'loadConfig' with a clean error.
--
-- 'cfgSource' is the absolute path the YAML came from, used purely for
-- diagnostics (so the user sees the file/section/key triple when a
-- per-subcommand 'applyConfig' rejects a bad value type).
data Config = Config
  { cfgSource :: !FilePath
  , cfgRoot   :: !A.Object
  } deriving (Show)

----------------------------------------------------------------------
-- Discovery
----------------------------------------------------------------------

-- | Resolve the config path according to the documented discovery
-- order. The optional 'Just p' argument is the @--config=PATH@ value;
-- when supplied we honour it verbatim — a missing file at that path is
-- a hard error reported by 'loadConfig', not by the discovery layer.
-- A thin wrapper over "AgdaGraph.ConfigCore".
discoverConfigPath :: Maybe FilePath -> IO (Maybe FilePath)
discoverConfigPath = discoverWith DiscoverSpec
  { dsEnvVar    = "AGDA_OPTIMIZATION_CONFIG"
  , dsBaseNames = [ ".agda-optimization.yml", ".agda-optimization.yaml" ]
  }

----------------------------------------------------------------------
-- Load
----------------------------------------------------------------------

-- | Read and parse the file at the given path. Returns:
--
--   * @Right (Just cfg)@ — success.
--   * @Right Nothing@    — no path was given (no config to apply).
--   * @Left err@         — file unreadable, YAML invalid, or root not
--     an object. Message starts with the path for easy grepping.
loadConfig :: Maybe FilePath -> IO (Either String (Maybe Config))
loadConfig Nothing  = pure (Right Nothing)
loadConfig (Just p) = do
  result <- try (BS.readFile p) :: IO (Either IOException BS.ByteString)
  case result of
    Left ioe -> pure $ Left (p <> ": cannot read config: " <> show ioe)
    Right bs -> case Y.decodeEither' bs of
      Left perr -> pure $ Left (p <> ": YAML parse error: "
                                <> Y.prettyPrintParseException perr)
      Right v -> case v of
        A.Object obj -> pure $ Right (Just (Config p obj))
        _            -> pure $ Left (p <> ": expected a YAML mapping at the top level")

----------------------------------------------------------------------
-- Routing
----------------------------------------------------------------------

-- | Look up the kebab-case section for the given subcommand name (e.g.
-- @"load-bearing"@). Returns 'Nothing' if the section is absent OR the
-- value present is not itself a mapping (silently ignored — a YAML
-- scalar in that slot would already have been a strange user error).
subSectionFor :: Config -> String -> Maybe A.Object
subSectionFor cfg sub =
  case KM.lookup (K.fromString sub) (cfgRoot cfg) of
    Just (A.Object o) -> Just o
    _                 -> Nothing

-- | Look up the @global:@ section.
globalSection :: Config -> Maybe A.Object
globalSection cfg = case KM.lookup "global" (cfgRoot cfg) of
  Just (A.Object o) -> Just o
  _                 -> Nothing

----------------------------------------------------------------------
-- Unknown-key rejection
----------------------------------------------------------------------

-- | The keys the @global:@ section accepts. @graph@ is read by
-- 'globalGraph', the other three by 'applyGlobal' — keep this list in step
-- with both (it is the only place the section's vocabulary is enumerated,
-- since the section is hand-walked rather than 'FlagSpec'-driven).
globalConfigKeys :: [Text]
globalConfigKeys = [ "graph", "format", "json", "out" ]

-- | Reject any top-level section, or any key inside a section, that no
-- reader looks up. @sections@ pairs every recognised section name with the
-- keys it accepts; the top-level vocabulary is exactly those names.
--
-- Sections are checked whichever subcommand is running, so a typo in the
-- @ledger:@ block surfaces on the next run of any analysis rather than
-- lying dormant until someone happens to run @ledger@. Errors are prefixed
-- with the config's own path, matching 'loadConfig'.
checkConfigKeys :: Config -> [(String, [Text])] -> Either String ()
checkConfigKeys cfg sections = do
  checkKnownKeys (cfgSource cfg <> ": top level")
                 [ T.pack name | (name, _) <- sections ]
                 (cfgRoot cfg)
  mapM_ checkSection sections
  where
    checkSection (name, known) = case KM.lookup (K.fromString name) (cfgRoot cfg) of
      Just (A.Object o) -> checkKnownKeys (cfgSource cfg <> ": " <> name) known o
      -- A non-mapping (or absent) section contributes no keys; 'subSectionFor'
      -- already ignores it, and a scalar there is the user's own oddity.
      _                 -> Right ()

----------------------------------------------------------------------
-- Helpers re-used by per-subcommand applyConfig
----------------------------------------------------------------------

-- | Read @obj.key@ as a typed value. Returns:
--
--   * @Right Nothing@      — key absent (no override).
--   * @Right (Just a)@     — key present and decoded.
--   * @Left err@           — key present but the value's JSON type
--     does not match 'a'. Error message names the section and key so
--     the user can find the offending line in the YAML file.
lookupKey :: A.FromJSON a => String -> A.Object -> Text -> Either String (Maybe a)
lookupKey section obj key =
  case KM.lookup (K.fromText key) obj of
    Nothing -> Right Nothing
    Just v  -> case parseEither A.parseJSON v of
      Right a  -> Right (Just a)
      Left err -> Left (section <> "." <> T.unpack key <> ": " <> err)

-- | As 'lookupKey' but funnels the decoded 'String' through a parser
-- closure — perfect for the @--direction=outgoing|incoming|both@-style
-- enum flags, which already have a hand-written parser in the
-- subcommand module.
lookupKeyEnum :: String -> A.Object -> Text
              -> (String -> Either String a)
              -> Either String (Maybe a)
lookupKeyEnum section obj key parseEnum = do
  ms <- lookupKey section obj key :: Either String (Maybe String)
  case ms of
    Nothing -> Right Nothing
    Just s  -> case parseEnum s of
      Right a  -> Right (Just a)
      Left err -> Left (section <> "." <> T.unpack key <> ": " <> err)

-- | YAML supports both @key: foo@ (a single string) and @key: [foo, bar]@
-- (a list of strings). 'lookupKeyTextList' accepts either spelling — a
-- single scalar is treated as a one-element list. This matches the
-- convention used by repeatable CLI flags
-- (e.g. @--axiom-module-prefix=A --axiom-module-prefix=B@).
lookupKeyTextList :: String -> A.Object -> Text -> Either String (Maybe [Text])
lookupKeyTextList section obj key =
  case KM.lookup (K.fromText key) obj of
    Nothing -> Right Nothing
    Just (A.String t) -> Right (Just [t])
    Just v -> case parseEither A.parseJSON v of
      Right xs -> Right (Just xs)
      Left err -> Left (section <> "." <> T.unpack key
                        <> ": expected string or list of strings: " <> err)

----------------------------------------------------------------------
-- Global section overlay
----------------------------------------------------------------------

-- | Read the @global: graph:@ key — the /input/ graph path, the config-file
-- spelling of @--graph FILE@ / the positional @\<graph.json\>@ (CLI wins; see
-- 'AgdaOptimization.CLI.dispatch'). Kept out of 'applyGlobal' because
-- 'GlobalOpts' models the output side (format / out path) and the input graph
-- is resolved before any subcommand runs.
globalGraph :: Maybe A.Object -> Either String (Maybe FilePath)
globalGraph Nothing    = Right Nothing
globalGraph (Just obj) = lookupKey "global" obj "graph"

-- | Apply the @global:@ section over a seed 'GlobalOpts'. Recognised
-- keys:
--
--   * @format: human|json@ — sets 'gOutFormat' (canonical).
--   * @json: true|false@   — alias of @format@ (kept for compatibility).
--     Canonical @format@ wins when both are present.
--   * @out: PATH@          — sets 'gOutPath'.
--
-- The section's @graph:@ key is read separately by 'globalGraph' (an input,
-- not a 'GlobalOpts' field); an unrecognised key is rejected up front by
-- 'checkConfigKeys' (see 'globalConfigKeys').
applyGlobal :: Maybe A.Object -> GlobalOpts -> Either String GlobalOpts
applyGlobal Nothing    g = Right g
applyGlobal (Just obj) g0 = do
  let section = "global"
  g1 <- do
    mJson   <- lookupKey section obj "json" :: Either String (Maybe Bool)
    mFormat <- lookupKeyEnum section obj "format" parseFormat
    pure $ case (mFormat, mJson) of
      (Just f,  _)         -> g0 { gOutFormat = f }
      (Nothing, Just True)  -> g0 { gOutFormat = OutJson }
      (Nothing, Just False) -> g0 { gOutFormat = OutHuman }
      (Nothing, Nothing)    -> g0
  g2 <- do
    mOut <- lookupKey section obj "out" :: Either String (Maybe FilePath)
    pure $ case mOut of
      Just p  -> g1 { gOutPath = Just p }
      Nothing -> g1
  pure g2
  where
    parseFormat :: String -> Either String OutFormat
    parseFormat "json"  = Right OutJson
    parseFormat "human" = Right OutHuman
    parseFormat other   = Left ("unknown format: " ++ other ++ " (want human|json)")

