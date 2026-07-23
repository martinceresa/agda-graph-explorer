{-# LANGUAGE OverloadedStrings #-}
-- | Entry point for @agda-auto@: a batch CLI that fills every open hole in an
-- Agda file using @agda-explore@'s Mimer + graph-hint ladder, printing a diff
-- (or applying it under @--write@). It links no Agda; it drives a live
-- @agda --interaction-json@ session exactly as the interactive bridge does,
-- but from the terminal with no MCP transport.
--
-- Merge order: defaults → @.agda-auto.yml@ → CLI (the standard per-executable
-- config pattern). See "AgdaAuto.CLI" for the flag surface and "AgdaAuto.Run"
-- for the ladder invocation.
module Main (main) where

import           Control.Monad      ( when )
import           System.Environment ( getArgs )
import           System.Exit        ( ExitCode(..), exitSuccess, exitWith )
import           System.IO          ( hPutStrLn, stderr )

import           AgdaAuto.CLI       ( AutoOpts(..), defaultOpts, defaultsYaml,
                                      parseArgs, preprocess, usage )
import           AgdaAuto.Config    ( applyConfig, discoverConfigPath, loadConfig )
import           AgdaAuto.Run       ( runAuto )
import           AgdaGraph.ConfigCore ( extractConfigFlag )
import           AgdaGraph.Version  ( numericVersion, versionLine )
import qualified BuildInfo

versionStr :: String
versionStr = versionLine "agda-auto" ++ " — batch hole-filling for Agda\n"
          ++ BuildInfo.buildFingerprint

main :: IO ()
main = do
  argv <- getArgs
  -- `--numeric-version` / `--show-defaults` short-circuit BEFORE any config
  -- discovery/load — so they work with no project and even when a broken
  -- .agda-auto.yml is present. (`--version` / `-V` flows through the parser so
  -- it also reports the build fingerprint.)
  when ("--numeric-version" `elem` argv) (putStrLn numericVersion >> exitSuccess)
  when ("--show-defaults" `elem` argv) (putStr defaultsYaml >> exitSuccess)
  -- Lift --config out before the parser (after the --key=value splitter, so
  -- only the space-separated form reaches here).
  let (mCfgArg, argv') = extractConfigFlag (preprocess argv)
  (seed, mApplied) <- loadSeed mCfgArg
  case parseArgs argv' seed of
    Left e -> hPutStrLn stderr ("agda-auto: " ++ e)
           >> hPutStrLn stderr "Try 'agda-auto --help'." >> exitWith (ExitFailure 2)
    Right o
      | aoHelp o  -> putStr usage >> exitSuccess
      | aoVer o   -> putStrLn versionStr >> exitSuccess
      | otherwise -> do
          maybe (pure ())
                (\p -> hPutStrLn stderr ("agda-auto: applied config from " ++ p))
                mApplied
          runAuto o >>= exitWith'

-- | 'exitWith' rejects 'ExitSuccess' via @ExitFailure 0@ semantics, so route
-- success through 'exitSuccess'.
exitWith' :: ExitCode -> IO ()
exitWith' ExitSuccess = exitSuccess
exitWith' code        = exitWith code

-- | Discover + load @.agda-auto.yml@ and overlay it onto 'defaultOpts',
-- returning the seed and the applied path (for the stderr breadcrumb). A
-- config that fails to parse is fatal (exit 2) — a silently-ignored config is
-- worse than a clear error.
loadSeed :: Maybe FilePath -> IO (AutoOpts, Maybe FilePath)
loadSeed mCfgArg = do
  mPath <- discoverConfigPath mCfgArg
  case mPath of
    Nothing -> pure (defaultOpts, Nothing)
    Just p  -> do
      r <- loadConfig p
      case r of
        Left err -> do
          hPutStrLn stderr ("agda-auto: config " ++ p ++ ":\n" ++ err)
          exitWith (ExitFailure 2)
        Right fc -> pure (applyConfig fc defaultOpts, Just p)
