{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- | YAML config-file support for the @agda-explore@ MCP daemon.
--
-- For parity with the other binaries (@agda-deps@ / @agda-unused@ /
-- @agda-optimization@) the server reads an optional @.agda-explore.yml@
-- (or @.agda-explore.yaml@). Every field is a kebab-cased mirror of a CLI
-- flag (literal flag spelling minus the leading @--@, so @--no-watch@ ↔
-- @no-watch@). Discovery and merge order mirror "AgdaDeps.Config":
--
--   * discovery (highest first): @--config=PATH@ \> @$AGDA_EXPLORE_CONFIG@
--     \> @./.agda-explore.yml@ (or @.yaml@) \> walk up from cwd to the
--     first ancestor holding a @*.agda-lib@ and look there;
--   * merge: defaults \< config \< CLI.
--
-- The merge is realised in "Main" (the @agda-explore@ entry point) by
-- overlaying 'applyConfig' onto the default 'Opts' /before/ the CLI parse
-- layers on top — exactly the seed pattern the other binaries use. This
-- module is otherwise self-contained: 'discoverConfigPath' / 'loadConfig'
-- do the IO, 'applyConfig' is a pure record overlay, and 'extractConfigArg'
-- lifts @--config@ out of argv before the hand-rolled option parser sees it.
module AgdaMcp.Config
  ( FileConfig(..)
  , defaultFileConfig
  , Opts(..)
  , discoverConfigPath
  , loadConfig
  , applyConfig
  , extractConfigArg
  , orderNub
  ) where

import           Control.Exception (SomeException, displayException, try)
import           Data.Aeson        (FromJSON (..), withObject, (.:?))
import           Data.Maybe        (fromMaybe)
import qualified Data.Yaml         as Y
import           System.Directory  (doesFileExist, getCurrentDirectory)
import           System.Environment (lookupEnv)
import           System.Exit       (die)

import           AgdaGraph.ConfigCore (DiscoverSpec (..), discoverInDir)

-- ---------------------------------------------------------------------
-- The Opts record the CLI parser fills.
-- ---------------------------------------------------------------------

-- | Parsed CLI options for @agda-explore@. Defined here (rather than in
-- "Main") so the config layer can overlay onto it without an import
-- cycle; "Main" re-exports the field accessors it needs. Mirrors the
-- 'Config' the daemon ultimately runs with, one field per CLI flag.
data Opts = Opts
  { oGraph    :: Maybe FilePath
  , oEntries  :: [FilePath]
    -- ^ Agda entry modules (repeatable @--entry@; appended, exactly like
    -- @-i@). @[]@ = none given on the CLI/config. Several entries union
    -- their import closures into one graph (see "AgdaGraph.Union").
  , oIncl     :: [FilePath]
  , oProj     :: Maybe FilePath
  , oOut      :: Maybe FilePath
  , oDeps     :: Maybe FilePath
  , oUnused   :: Maybe FilePath
  , oHashes   :: Bool
  , oSigs     :: Bool
  , oNormSigs :: Bool
  , oShowImpl :: Bool
  , oMinDepth :: Int
  , oAuto     :: Bool
  , oWatch    :: Bool
  , oQueryLog :: Bool
  , oAutoResolve :: Bool
  , oEnableInteract :: Bool
    -- ^ expose the write-side interaction-bridge tools (@--enable-interact@).
  , oAgdaBin   :: Maybe FilePath
    -- ^ explicit @agda@ binary for interaction sessions (@--agda-bin@).
  , oInteractArgs :: [String]
    -- ^ extra flags for @agda --interaction-json@ (repeatable @--agda-arg@).
  , oHelp     :: Bool
  , oVer      :: Bool
  }

-- ---------------------------------------------------------------------
-- YAML payload
-- ---------------------------------------------------------------------

-- | YAML config payload. Every field is 'Maybe' so an empty file (@{}@)
-- is valid and individual omissions leave the underlying default in
-- place. The @no-*@ fields mirror the negative CLI flags literally
-- (matching @agda-deps@' @no-externals@ convention).
data FileConfig = FileConfig
  { fcEntry         :: Maybe FilePath
    -- ^ Back-compat scalar @entry:@ key (one module). Unioned with
    -- 'fcEntries' in 'applyConfig'.
  , fcEntries       :: Maybe [FilePath]
    -- ^ New list @entries:@ key. Unioned with the scalar @entry:@.
  , fcInclude       :: Maybe [FilePath]
  , fcGraph         :: Maybe FilePath
  , fcProject       :: Maybe FilePath
  , fcOutDir        :: Maybe FilePath
  , fcDepsBin       :: Maybe FilePath
  , fcUnusedBin     :: Maybe FilePath
  , fcNoTermHashes  :: Maybe Bool
  , fcNoSignatures  :: Maybe Bool
  , fcNormaliseSigs :: Maybe Bool
  , fcShowImplicit  :: Maybe Bool
  , fcMinTermDepth  :: Maybe Int
  , fcNoAutoRebuild :: Maybe Bool
  , fcNoWatch       :: Maybe Bool
  , fcNoQueryLog    :: Maybe Bool
  , fcNoAutoResolve :: Maybe Bool
  , fcEnableInteract :: Maybe Bool
  , fcAgdaBin        :: Maybe FilePath
  , fcInteractArgs   :: Maybe [String]
  }

defaultFileConfig :: FileConfig
defaultFileConfig = FileConfig
  { fcEntry         = Nothing
  , fcEntries       = Nothing
  , fcInclude       = Nothing
  , fcGraph         = Nothing
  , fcProject       = Nothing
  , fcOutDir        = Nothing
  , fcDepsBin       = Nothing
  , fcUnusedBin     = Nothing
  , fcNoTermHashes  = Nothing
  , fcNoSignatures  = Nothing
  , fcNormaliseSigs = Nothing
  , fcShowImplicit  = Nothing
  , fcMinTermDepth  = Nothing
  , fcNoAutoRebuild = Nothing
  , fcNoWatch       = Nothing
  , fcNoQueryLog    = Nothing
  , fcNoAutoResolve = Nothing
  , fcEnableInteract = Nothing
  , fcAgdaBin        = Nothing
  , fcInteractArgs   = Nothing
  }

instance FromJSON FileConfig where
  parseJSON = withObject "agda-explore config" $ \o -> do
    fcEntry         <- o .:? "entry"
    fcEntries       <- o .:? "entries"
    fcInclude       <- o .:? "include"
    fcGraph         <- o .:? "graph"
    fcProject       <- o .:? "project"
    fcOutDir        <- o .:? "out-dir"
    fcDepsBin       <- o .:? "agda-deps-bin"
    fcUnusedBin     <- o .:? "agda-unused-bin"
    fcNoTermHashes  <- o .:? "no-term-hashes"
    fcNoSignatures  <- o .:? "no-signatures"
    fcNormaliseSigs <- o .:? "normalise-signatures"
    fcShowImplicit  <- o .:? "show-implicit"
    fcMinTermDepth  <- o .:? "min-term-depth"
    fcNoAutoRebuild <- o .:? "no-auto-rebuild"
    fcNoWatch       <- o .:? "no-watch"
    fcNoQueryLog    <- o .:? "no-query-log"
    fcNoAutoResolve <- o .:? "no-auto-resolve"
    fcEnableInteract <- o .:? "enable-interact"
    fcAgdaBin        <- o .:? "agda-bin"
    fcInteractArgs   <- o .:? "agda-arg"
    pure FileConfig{..}

-- ---------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------

-- | Overlay a 'FileConfig' onto an 'Opts' seed: each 'Just' field
-- replaces the corresponding slot, each 'Nothing' leaves it alone. The
-- @no-*@ fields invert (a YAML @no-term-hashes: true@ clears the
-- on-by-default @oHashes@), matching the CLI flag's effect.
--
-- Applied to the /default/ 'Opts' so the subsequent CLI parse layers on
-- top (defaults \< config \< CLI). CLI @-i@ then /appends/ to any config
-- includes, and CLI @--entry@ likewise appends to any config @entry:@ /
-- @entries:@ (so the union covers config + CLI entries); an explicit CLI
-- @--project@/@--graph@/etc. replaces.
applyConfig :: FileConfig -> Opts -> Opts
applyConfig FileConfig{..} o = o
  { oEntries  = if null cfgEntries then oEntries o else cfgEntries
  , oIncl     = fromMaybe (oIncl o) fcInclude
  , oGraph    = fcGraph            `orKeep` oGraph o
  , oProj     = fcProject          `orKeep` oProj o
  , oOut      = fcOutDir           `orKeep` oOut o
  , oDeps     = fcDepsBin          `orKeep` oDeps o
  , oUnused   = fcUnusedBin        `orKeep` oUnused o
  , oHashes   = maybe (oHashes o) not fcNoTermHashes
  , oSigs     = maybe (oSigs o)   not fcNoSignatures
  , oNormSigs = fromMaybe (oNormSigs o) fcNormaliseSigs
  , oShowImpl = fromMaybe (oShowImpl o) fcShowImplicit
  , oMinDepth = fromMaybe (oMinDepth o) fcMinTermDepth
  , oAuto     = maybe (oAuto o)  not fcNoAutoRebuild
  , oWatch    = maybe (oWatch o) not fcNoWatch
  , oQueryLog = maybe (oQueryLog o) not fcNoQueryLog
  , oAutoResolve = maybe (oAutoResolve o) not fcNoAutoResolve
  , oEnableInteract = fromMaybe (oEnableInteract o) fcEnableInteract
  , oAgdaBin     = fcAgdaBin `orKeep` oAgdaBin o
  , oInteractArgs = fromMaybe (oInteractArgs o) fcInteractArgs
  }
  where
    -- A present config value wins over the (default) seed; 'Maybe' field.
    orKeep (Just v) _ = Just v
    orKeep Nothing  k = k
    -- Union the back-compat scalar @entry:@ and the new list @entries:@,
    -- entry-first then the list, deduped order-preserving. Becomes the
    -- seed @oEntries@ so a later CLI @--entry@ appends on top (mirrors the
    -- @-i@ append contract). Empty when neither key is present, so the
    -- seed's existing @oEntries@ is kept (the @if null@ guard above).
    cfgEntries = orderNub (maybe [] pure fcEntry ++ fromMaybe [] fcEntries)

-- | Order-preserving dedup (first occurrence wins). Shared with "Main"
-- (the @agda-explore@ entry point) so the config-merge here and the
-- CLI/env assembly there dedup entry/include lists identically.
orderNub :: Eq a => [a] -> [a]
orderNub = go []
  where
    go _    []       = []
    go seen (x : xs)
      | x `elem` seen = go seen xs
      | otherwise     = x : go (x : seen) xs

-- ---------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------

-- | Resolve which config file (if any) to load. Precedence (highest
-- first): explicit @--config@ path (missing is an error), then
-- @$AGDA_EXPLORE_CONFIG@ (missing is an error), then @./.agda-explore.yml@
-- / @.yaml@, then a walk up from cwd to the nearest @*.agda-lib@
-- directory and the same two filenames there. 'Nothing' = no config.
discoverConfigPath :: Maybe FilePath -> IO (Maybe FilePath)
discoverConfigPath (Just p) = do
  exists <- doesFileExist p
  if exists then pure (Just p)
            else die ("agda-explore: --config: file not found: " ++ p)
discoverConfigPath Nothing = do
  mEnv <- lookupEnv "AGDA_EXPLORE_CONFIG"
  case mEnv of
    Just p | not (null p) -> do
      exists <- doesFileExist p
      if exists then pure (Just p)
                else die ("agda-explore: $AGDA_EXPLORE_CONFIG: file not found: " ++ p)
    _ -> getCurrentDirectory >>= discoverInDir discoverSpec

-- | The cwd / walk-up tail of discovery, shared with the other
-- binaries via "AgdaGraph.ConfigCore". The MCP daemon layers its own
-- @die@-on-missing handling of @--config@ / @$AGDA_EXPLORE_CONFIG@ on
-- top (above).
discoverSpec :: DiscoverSpec
discoverSpec = DiscoverSpec
  { dsEnvVar    = "AGDA_EXPLORE_CONFIG"
  , dsBaseNames = [ ".agda-explore.yml", ".agda-explore.yaml" ]
  }

-- | Parse a YAML config file; dies with a diagnostic naming the path on
-- a read or parse failure.
loadConfig :: FilePath -> IO FileConfig
loadConfig path = do
  res <- try (Y.decodeFileEither path)
           :: IO (Either SomeException (Either Y.ParseException FileConfig))
  case res of
    Left exc          -> die $ "agda-explore: failed to read config file "
                            ++ path ++ ":\n  " ++ displayException exc
    Right (Left perr) -> die $ "agda-explore: failed to parse config file "
                            ++ path ++ ":\n  " ++ Y.prettyPrintParseException perr
    Right (Right cfg) -> pure cfg

-- ---------------------------------------------------------------------
-- argv helper
-- ---------------------------------------------------------------------

-- | Strip the @--config PATH@ token pair out of argv (run /after/ the
-- @--key=value@ splitter, so only the space-separated form appears here),
-- returning the path and the cleaned argv. Last occurrence wins.
extractConfigArg :: [String] -> (Maybe FilePath, [String])
extractConfigArg = go Nothing []
  where
    go acc keep [] = (acc, reverse keep)
    go acc keep (a : rest)
      | a == "--config" = case rest of
          (v : rest') -> go (Just v) keep rest'
          []          -> (acc, reverse keep)   -- malformed; drop it
      | otherwise = go acc (a : keep) rest
