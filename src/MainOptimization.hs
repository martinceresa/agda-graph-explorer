-- | @agda-optimization@ entry point. Thin shim around
-- 'AgdaOptimization.CLI.run' so the executable stays cabal-friendly
-- (one @main-is@ + everything else in @other-modules@).
module Main where

import qualified AgdaOptimization.CLI as CLI

main :: IO ()
main = CLI.run
