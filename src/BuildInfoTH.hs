{-# LANGUAGE ScopedTypeVariables #-}

-- | Template-Haskell helper behind "BuildInfo". Lives in its own module
-- because GHC's stage restriction forbids a top-level splice from using
-- a generator defined in the same module.
--
-- 'gitRevisionE' shells out to @git@ once at build time and lifts the
-- short revision into a string literal, registering @.git/HEAD@ and the
-- resolved ref as dependent files so a checkout retriggers
-- recompilation. Any git failure degrades to @"unknown"@ — never a
-- build failure (tarball builds have no @.git@).
module BuildInfoTH
  ( gitRevisionE
  ) where

import           Control.Exception          (SomeException, catch, try)
import           Control.Monad              (filterM)
import           Language.Haskell.TH         (Exp, Q, runIO)
import           Language.Haskell.TH.Syntax  (addDependentFile, lift)
import           System.Directory            (doesFileExist)
import           System.Exit                 (ExitCode (..))
import           System.Process              (readProcessWithExitCode)

-- | Capture the git revision at compile time as a string-literal 'Exp'.
gitRevisionE :: Q Exp
gitRevisionE = do
  files <- runIO listGitFiles
  mapM_ addDependentFile files
  rev <- runIO captureGit
  lift rev

-- | @.git/HEAD@ plus the file the symbolic ref points at, when they
-- exist. Used purely for 'addDependentFile' recompilation tracking.
listGitFiles :: IO [FilePath]
listGitFiles = do
  let headFile = ".git/HEAD"
  he <- doesFileExist headFile
  if not he
    then pure []
    else do
      contents <- readFile headFile `catch` \(_ :: SomeException) -> pure ""
      let refFile = case words contents of
            ["ref:", r] -> [".git/" ++ r]
            _           -> []
      refs <- filterM doesFileExist refFile
      pure (headFile : refs)

-- | Run a @git@ command at build time, returning its stdout on success
-- and 'Nothing' on any failure (no git, no repo, non-zero exit). Never
-- throws — a tarball build just gets 'Nothing'.
runGit :: [String] -> IO (Maybe String)
runGit args = do
  r <- try (readProcessWithExitCode "git" args "")
         :: IO (Either SomeException (ExitCode, String, String))
  pure $ case r of
    Right (ExitSuccess, out, _) -> Just out
    _                           -> Nothing

-- | The short revision, with a @+@ suffix when the tree is dirty.
captureGit :: IO String
captureGit = do
  mrev <- runGit ["rev-parse", "--short=12", "HEAD"]
  case mrev of
    Nothing  -> pure "unknown"
    Just rev -> do
      dirty <- gitDirty
      pure (trim rev ++ if dirty then "+" else "")
  where
    trim = reverse . dropWhile (`elem` (" \r\n\t" :: String)) . reverse

-- | True when @git status --porcelain@ reports any change.
gitDirty :: IO Bool
gitDirty = maybe False (not . all (`elem` (" \r\n\t" :: String))) <$> runGit ["status", "--porcelain"]
