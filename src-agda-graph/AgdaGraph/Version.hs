-- | Single source of the package version for every executable's
-- @--version@ / @--numeric-version@. All binaries read the same
-- @Paths_agda_graph_explorer.version@ (the cabal @version:@ field), so
-- their version strings cannot disagree — the invariant the CI
-- version-sync step asserts against @plugin.json@.
module AgdaGraph.Version
  ( numericVersion
  , versionLine
  ) where

import           Data.Version            ( showVersion )
import qualified Paths_agda_graph_explorer as Paths

-- | The bare semantic version (@X.Y.Z@), for @--numeric-version@.
numericVersion :: String
numericVersion = showVersion Paths.version

-- | @"<name> <version>"@, for @--version@ (e.g. @"agda-unused 1.1"@).
versionLine :: String -> String
versionLine name = name ++ " " ++ numericVersion
