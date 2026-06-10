{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | YAML configuration for @agda-goals@.
--
-- Discovery order (first match wins):
--
--   1. @--config=PATH@.
--   2. @$AGDA_GOALS_CONFIG@.
--   3. @./.agda-goals.yml@ or @./.agda-goals.yaml@ in cwd.
--   4. Walk up from cwd to the first directory containing a
--      @*.agda-lib@ file and look there.
--
-- Merge: defaults → config → CLI.  Top-level YAML fields are
-- kebab-case mirrors of the CLI long flags.
module AgdaGoals.Config
  ( Config(..)
  , loadConfig
  , discoverConfigPath
  , applyConfig
  , ConfigTarget(..)
  ) where

import           Control.Exception   ( IOException, catch )
import           Data.Aeson          ( FromJSON(..), (.:?), withObject )
import qualified Data.Yaml           as Y
import           Data.List           ( isSuffixOf )

import           System.Directory    ( doesFileExist, getCurrentDirectory
                                     , listDirectory )
import           System.Environment  ( lookupEnv )
import           System.FilePath     ( (</>), takeDirectory )

----------------------------------------------------------------------
-- Config shape.

-- | Externally-supplied configuration. Every field is 'Maybe' so a
-- partial config only overrides what the user set.
data Config = Config
  { cfgAgdaBin     :: !(Maybe FilePath)
  , cfgIncludes    :: !(Maybe [FilePath])
  , cfgExtraArgs   :: !(Maybe [String])
  , cfgFormat      :: !(Maybe String)
    -- ^ Accepted values: @"human"@, @"json"@. Validation lives in
    -- the caller because the OutFormat type is in MainGoals.
  , cfgQuiet       :: !(Maybe Bool)
  , cfgTopN        :: !(Maybe Int)
  , cfgRoots       :: !(Maybe [FilePath])
    -- ^ Source files (or directories) to drive Agda over. Equivalent
    -- to positional arguments on the CLI.
  } deriving (Show)

-- | Setters threaded by the caller so 'applyConfig' doesn't have to
-- import the @main@'s Options type (avoids cyclic deps).
data ConfigTarget a = ConfigTarget
  { ctSetAgdaBin   :: FilePath   -> a -> a
  , ctSetIncludes  :: [FilePath] -> a -> a
  , ctSetExtraArgs :: [String]   -> a -> a
  , ctSetFormat    :: String     -> a -> a
  , ctSetQuiet     :: Bool       -> a -> a
  , ctSetTopN      :: Int        -> a -> a
  , ctSetRoots     :: [FilePath] -> a -> a
  }

-- | Apply a 'Config' to an arbitrary @Options@-shaped value using
-- the supplied setters. Each field is only touched when the
-- corresponding 'Maybe' is 'Just'.
applyConfig :: ConfigTarget a -> Config -> a -> a
applyConfig ConfigTarget{..} Config{..} = id
  . maybe id ctSetAgdaBin   cfgAgdaBin
  . maybe id ctSetIncludes  cfgIncludes
  . maybe id ctSetExtraArgs cfgExtraArgs
  . maybe id ctSetFormat    cfgFormat
  . maybe id ctSetQuiet     cfgQuiet
  . maybe id ctSetTopN      cfgTopN
  . maybe id ctSetRoots     cfgRoots

instance FromJSON Config where
  parseJSON = withObject "agda-goals config" $ \o -> do
    cfgAgdaBin   <- o .:? "agda-bin"
    cfgIncludes  <- o .:? "include-paths"
    cfgExtraArgs <- o .:? "agda-args"
    cfgFormat    <- o .:? "format"
    cfgQuiet     <- o .:? "quiet"
    cfgTopN      <- o .:? "top-n"
    cfgRoots     <- o .:? "roots"
    pure Config{..}

----------------------------------------------------------------------
-- Discovery.

discoverConfigPath :: Maybe FilePath -> IO (Maybe FilePath)
discoverConfigPath explicit = case explicit of
  Just p  -> pure (Just p)
  Nothing -> lookupEnv "AGDA_GOALS_CONFIG" >>= \case
    Just p | not (null p) -> pure (Just p)
    _ -> do
      cwd <- getCurrentDirectory
      tryDir cwd >>= \case
        Just p  -> pure (Just p)
        Nothing -> walkUp cwd
  where
    tryDir d = firstExisting
      [ d </> ".agda-goals.yml"
      , d </> ".agda-goals.yaml"
      ]
    walkUp d = do
      hasLib <- dirHasAgdaLib d
      if hasLib
        then tryDir d
        else let parent = takeDirectory d
             in if parent == d
                  then pure Nothing
                  else walkUp parent
    firstExisting []     = pure Nothing
    firstExisting (p:ps) = do
      ok <- doesFileExist p
      if ok then pure (Just p) else firstExisting ps
    dirHasAgdaLib d =
      (any (".agda-lib" `isSuffixOf`) <$> listDirectory d)
        `catch` \(_ :: IOException) -> pure False

loadConfig :: FilePath -> IO (Either String Config)
loadConfig p = do
  res <- Y.decodeFileEither p
  pure $ case res of
    Left err -> Left (Y.prettyPrintParseException err)
    Right c  -> Right c
