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
    -- * Formatting
  , showD3
    -- * JSON output
  , emitJsonReport
    -- * Human output (with optional file redirect)
  , withHumanOutput
  , withHumanReport
  ) where

import           Control.Exception    ( bracket, finally )
import           Control.Monad        ( when )
import qualified Data.Aeson           as A
import qualified Data.ByteString.Lazy as BL
import           Data.List            ( transpose )
import           GHC.IO.Handle        ( hDuplicate, hDuplicateTo )
import           System.IO            ( IOMode(..), hClose, hFlush, stdout
                                      , withFile )

import           AgdaOptimization.Legend ( renderLegend )

-- | Output channel preference, threaded through every analysis. The
-- CLI ('AgdaOptimization.CLI') re-exports it.
data OutFormat = OutHuman | OutJson
  deriving (Show, Eq)

-- | Global per-invocation options (output format + destination path).
-- Held here so analysis modules can import it without depending on
-- 'AgdaOptimization.CLI', which depends on each analysis in turn.
data GlobalOpts = GlobalOpts
  { gOutFormat :: !OutFormat
  , gOutPath   :: !(Maybe FilePath)
  , gExplain   :: !Bool
    -- ^ Append the subcommand's @## How to read this@ legend to a human
    -- report. On by default: a report file is read by someone who did
    -- not run it, and the column names alone don't carry their meaning.
    -- Human format only — the JSON payload is self-describing already.
  } deriving (Show)

defaultGlobalOpts :: GlobalOpts
defaultGlobalOpts = GlobalOpts
  { gOutFormat = OutHuman
  , gOutPath   = Nothing
  , gExplain   = True
  }

-- | Render a header row + body rows as a simple aligned text table.
-- Borderless; one space between columns, one newline between rows.
-- Returns a final newline at the end so it can be 'putStr'd directly.
renderTable :: [String] -> [[String]] -> String
renderTable header rows =
  let allRows = header : rows
      padded  = padRows allRows
      widths  = map (maximum . map length) (transpose padded)
      padRows xs = map (pad (length header)) xs
      pad n xs   = take n (xs ++ repeat "")
      padCell w s = s ++ replicate (w - length s) ' '
      renderRow r = unwords (zipWith padCell widths r)
  in unlines (map renderRow padded)

-- | Format a 'Double' to exactly three decimal places without pulling
-- in a @printf@ dependency. Negative values keep their sign; the
-- integer part is never truncated. Shared by the analyses that emit
-- fixed-precision score columns (basket, concept-bundle, entwine,
-- fiedler) so they agree by construction.
showD3 :: Double -> String
showD3 d =
  let n  = round (d * 1000) :: Integer
      s  = show (abs n)
      sn = if n < 0 then "-" else ""
      padded = replicate (max 0 (4 - length s)) '0' ++ s
      (intPart, fracPart) = splitAt (length padded - 3) padded
  in sn ++ intPart ++ "." ++ fracPart

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
-- | 'withHumanOutput' plus the trailing @## How to read this@ legend for
-- @sub@ (see 'AgdaOptimization.Legend'), suppressed by @--no-explain@.
--
-- Every analysis' @OutHuman@ branch goes through this rather than
-- calling 'withHumanOutput' and the legend separately, so a report
-- cannot ship without its legend and the legend cannot land outside the
-- @--out FILE@ redirect. @sub@ is the subcommand name, except for the
-- one analysis with two output shapes ('silhouette', whose
-- no-provenance path passes @silhouette-fallback@).
--
-- Degenerate paths that print a one-line "empty graph" notice keep
-- calling 'withHumanOutput' directly: there is no table there to explain.
withHumanReport :: GlobalOpts -> String -> IO () -> IO ()
withHumanReport gOpts sub act =
  withHumanOutput (gOutPath gOpts) $ do
    act
    when (gExplain gOpts) $ putStr (renderLegend sub)

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
