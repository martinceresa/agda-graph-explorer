{-# LANGUAGE OverloadedStrings #-}
-- | Tiny shared helpers for the optimisation analyses: ANSI-table
-- formatting and JSON-report writing. Deliberately minimal — analyses
-- own their own data shapes and call these only at the edges.
--
-- Each subcommand emits its own self-describing JSON object when
-- @--json@ is in effect; see the schemas documented next to each
-- analysis' 'Options' record. Every payload starts with
-- @"subcommand": "<name>"@ and @"options": { ... }@ so downstream
-- tooling can route on the subcommand string and reproduce the run.
module AgdaOptimization.Report
  ( -- * Global output config (re-exported by 'AgdaOptimization.CLI')
    OutFormat(..)
  , GlobalOpts(..)
  , defaultGlobalOpts
    -- * Tables
  , renderTable
    -- * JSON output
  , writeJsonReport
  , emitJsonReport
    -- * Human output (with optional file redirect)
  , withHumanOutput
  ) where

import           Control.Exception    ( bracket, finally )
import qualified Data.Aeson           as A
import qualified Data.ByteString.Lazy as BL
import           Data.List            ( transpose )
import           GHC.IO.Handle        ( hDuplicate, hDuplicateTo )
import           System.IO            ( IOMode(..), hClose, hFlush, stdout
                                      , withFile )

-- | Output channel preference, threaded through every analysis. The
-- CLI ('AgdaOptimization.CLI') re-exports this so existing callers
-- don't notice the module move.
data OutFormat = OutHuman | OutJson
  deriving (Show, Eq)

-- | Global per-invocation options (output format + destination path).
-- Held here so analysis modules can import it without depending on
-- 'AgdaOptimization.CLI', which depends on each analysis in turn.
data GlobalOpts = GlobalOpts
  { gOutFormat :: !OutFormat
  , gOutPath   :: !(Maybe FilePath)
  } deriving (Show)

defaultGlobalOpts :: GlobalOpts
defaultGlobalOpts = GlobalOpts
  { gOutFormat = OutHuman
  , gOutPath   = Nothing
  }

-- | Render a header row + body rows as a simple aligned text table.
-- Borderless; one space between columns, one newline between rows.
-- Returns a final newline at the end so it can be 'putStr'd directly.
renderTable :: [String] -> [[String]] -> String
renderTable header rows =
  let allRows = header : rows
      widths  = map (maximum . map length) (transpose (padRows allRows))
      padRows xs = map (pad (length header)) xs
      pad n xs   = take n (xs ++ repeat "")
      padCell w s = s ++ replicate (w - length s) ' '
      renderRow r = unwords (zipWith padCell widths (pad (length header) r))
  in unlines (map renderRow allRows)

-- | Pretty-print a JSON value to a file. Uses 'A.encode' (compact);
-- consumers can pipe through 'jq' if they want indentation.
writeJsonReport :: FilePath -> A.Value -> IO ()
writeJsonReport path v = BL.writeFile path (A.encode v)

-- | Emit a JSON value either to the given file path or to stdout.
-- Compact encoding via 'A.encode'; a single trailing newline so the
-- stdout case plays nicely with line-oriented downstream tools.
emitJsonReport :: Maybe FilePath -> A.Value -> IO ()
emitJsonReport Nothing  v = BL.putStr (A.encode v) >> putStrLn ""
emitJsonReport (Just p) v = writeJsonReport p v

-- | Run a human-output IO action with stdout transparently redirected
-- to @FILE@ when @--out FILE@ was passed. Existing 'putStr'/'putStrLn'
-- calls inside the action go to the file without code changes;
-- diagnostic 'hPutStrLn stderr' messages keep going to stderr.
--
-- 'bracket' restores the original 'stdout' even if the action throws,
-- so a partially-written file is acceptable but the calling shell
-- still sees a clean stdout.
withHumanOutput :: Maybe FilePath -> IO () -> IO ()
withHumanOutput Nothing  act = act
withHumanOutput (Just p) act =
  withFile p WriteMode $ \h ->
    bracket
      (do saved <- hDuplicate stdout
          hDuplicateTo h stdout
          pure saved)
      (\saved -> do
         hFlush stdout
         hDuplicateTo saved stdout
         hClose saved)
      (\_ -> act `finally` hFlush stdout)
