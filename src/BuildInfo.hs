{-# LANGUAGE CPP             #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Compile-time build identity for the @agda-explore@ MCP server (the
-- only executable in this package that links it). A sibling copy lives
-- in the @agda-deps@ producer repo, where the fingerprint is labelled
-- @agda-deps@ instead.
--
-- Answers /which source was this running binary built from?/ in one
-- @--version@ / @status@ call, instead of @ps@ + @\/proc\/<pid>\/exe@ +
-- @git log@ forensics — the failure mode being a launcher that pins a
-- stale build after a GHC bump.
--
-- The fingerprint combines four things, each of which independently
-- distinguishes one build from another:
--
--   * the cabal package version (@Paths_agda_graph_explorer@);
--   * the git revision at build time (best-effort; @"unknown"@ for a
--     tarball build, a @"+"@ suffix for a dirty tree);
--   * the compile date\/time (baked in via the C preprocessor);
--   * the compiling GHC.
module BuildInfo
  ( buildFingerprint
  , gitRevision
  , buildDate
  , packageVersion
  , ghcVersion
  ) where

import           Data.Version    (showVersion)
import           System.Info     (compilerVersion)

import           BuildInfoTH               (gitRevisionE)
import           Paths_agda_graph_explorer (version)

-- | The cabal package version, e.g. @"1.1"@.
packageVersion :: String
packageVersion = showVersion version

-- | The GHC that compiled this binary, e.g. @"ghc 9.14"@.
ghcVersion :: String
ghcVersion = "ghc " ++ showVersion compilerVersion

-- | Compile date and time, captured by the C preprocessor when this
-- module is built. Recaptured on any rebuild that recompiles this
-- module (always the case for a GHC bump); a rebuild that only touches
-- other modules leaves it unchanged, so prefer the binary mtime
-- ('AgdaMcp.State.binaryIdent') as the authoritative build signal.
buildDate :: String
buildDate = __DATE__ ++ " " ++ __TIME__

-- | Best-effort git revision captured at compile time. @"unknown"@ when
-- there's no git checkout (a source tarball); a trailing @"+"@ marks a
-- dirty working tree.
gitRevision :: String
gitRevision = $(gitRevisionE)

-- | The one-line build fingerprint surfaced by @--version@ and the first
-- line of the MCP @status@ tool, and stamped into @graph.json@ as
-- @"producer"@ so a graph\/binary mismatch is visible too.
buildFingerprint :: String
buildFingerprint =
  "agda-explore " ++ packageVersion
    ++ " (git " ++ gitRevision
    ++ ", built " ++ buildDate
    ++ ", " ++ ghcVersion ++ ")"
