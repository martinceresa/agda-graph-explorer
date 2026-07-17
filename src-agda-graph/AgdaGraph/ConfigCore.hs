{-# LANGUAGE ScopedTypeVariables #-}
-- | Shared config-file discovery + raw-load plumbing for the four
-- per-executable @Config@ modules (@agda-unused@ / @agda-goals@ /
-- @agda-optimization@ / @agda-explore@), which share one discovery
-- contract:
--
--   * precedence @--config=PATH@ \> @$ENV@ \> @./.agda-\<bin\>.{yml,yaml}@
--     in cwd \> walk up to the first ancestor directory containing a
--     @*.agda-lib@ file and look there.
--
-- Per-executable differences (env-var name, base filename(s)) are captured
-- by 'DiscoverSpec'. Wrappers thread it through 'discoverWith' (verbatim
-- explicit/env precedence) or compose 'discoverInDir' with their own
-- explicit/env handling (the MCP daemon @die@s on a missing
-- explicit/@$ENV@ path). 'loadYamlConfig' is the shared decode-and-pretty-
-- print core.
module AgdaGraph.ConfigCore
  ( DiscoverSpec(..)
  , discoverWith
  , discoverInDir
  , firstExisting
  , loadYamlConfig
  , extractConfigFlag
  ) where

import           Control.Exception  ( IOException, catch )
import           Data.Aeson         ( FromJSON )
import           Data.List          ( stripPrefix )
import qualified Data.Yaml          as Y

import           System.Directory   ( doesDirectoryExist, doesFileExist
                                    , getCurrentDirectory, listDirectory )
import           System.Environment ( lookupEnv )
import           System.FilePath    ( (</>), takeDirectory, takeExtension )

-- | Per-executable parameters of the otherwise-identical discovery
-- contract: the environment variable consulted after @--config@ and the
-- base filename(s) tried in each candidate directory (@.yml@ then
-- @.yaml@, in order).
data DiscoverSpec = DiscoverSpec
  { dsEnvVar    :: String       -- ^ e.g. @"AGDA_UNUSED_CONFIG"@.
  , dsBaseNames :: [FilePath]   -- ^ e.g. @[".agda-unused.yml", ".agda-unused.yaml"]@.
  }

-- | Resolve a config path with the common precedence: an explicit
-- @--config@ ('Just') wins verbatim; otherwise a non-empty @$ENV@ wins
-- verbatim; otherwise 'discoverInDir' from cwd (cwd base names, then the
-- walk-up to the first @*.agda-lib@ ancestor). 'Nothing' = no config.
-- (The @agda-explore@ daemon needs to @die@ on a missing explicit/@$ENV@
-- path, so it builds its own explicit/env layer over 'discoverInDir'.)
discoverWith :: DiscoverSpec -> Maybe FilePath -> IO (Maybe FilePath)
discoverWith _    (Just p) = pure (Just p)
discoverWith spec Nothing  = do
  mEnv <- lookupEnv (dsEnvVar spec)
  case mEnv of
    Just p | not (null p) -> pure (Just p)
    _                     -> getCurrentDirectory >>= discoverInDir spec

-- | The flag/env-independent tail of discovery: try 'dsBaseNames' in
-- @start@, and on a miss walk up to the first ancestor directory holding
-- a @*.agda-lib@ file and try the base names there.
discoverInDir :: DiscoverSpec -> FilePath -> IO (Maybe FilePath)
discoverInDir spec start = do
  mHere <- tryDir start
  case mHere of
    Just p  -> pure (Just p)
    Nothing -> walkUp start
  where
    tryDir d = firstExisting [ d </> b | b <- dsBaseNames spec ]

    walkUp d = do
      hasLib <- dirHasAgdaLib d
      if hasLib
        then tryDir d
        else let parent = takeDirectory d
             in if parent == d
                  then pure Nothing   -- hit filesystem root
                  else walkUp parent

-- | Strip @--config=PATH@ (or @--config PATH@) out of argv before the
-- per-executable option parser runs, returning the path (if any) and the
-- remaining args. A malformed trailing @--config@ with no value is left for
-- the main parser to diagnose.
extractConfigFlag :: [String] -> (Maybe FilePath, [String])
extractConfigFlag = go []
  where
    go acc []       = (Nothing, reverse acc)
    go acc (a:rest)
      | Just v <- stripPrefix "--config=" a = (Just v, reverse acc ++ rest)
      | a == "--config" = case rest of
          (v:rest') -> (Just v, reverse acc ++ rest')
          []        -> (Nothing, reverse acc)
      | otherwise = go (a : acc) rest

-- | Return the first path in the list that exists as a regular file.
firstExisting :: [FilePath] -> IO (Maybe FilePath)
firstExisting []     = pure Nothing
firstExisting (p:ps) = do
  ok <- doesFileExist p
  if ok then pure (Just p) else firstExisting ps

-- | 'True' iff @d@ exists and contains at least one @*.agda-lib@ entry.
-- Uses the filepath-aware @takeExtension@ form and treats an unreadable /
-- missing directory as @False@.
dirHasAgdaLib :: FilePath -> IO Bool
dirHasAgdaLib d = do
  isDir <- doesDirectoryExist d
  if not isDir
    then pure False
    else (any ((== ".agda-lib") . takeExtension) <$> listDirectory d)
           `catch` \(_ :: IOException) -> pure False

-- | Read and parse a YAML config file. On a parse failure returns
-- @Left@ with the library's clean, pretty-printed message; on success
-- @Right@ the decoded value. Matches the @loadConfig@ shape used by
-- @agda-unused@ / @agda-goals@.
loadYamlConfig :: FromJSON a => FilePath -> IO (Either String a)
loadYamlConfig p = do
  res <- Y.decodeFileEither p
  pure $ case res of
    Left err -> Left (Y.prettyPrintParseException err)
    Right c  -> Right c
