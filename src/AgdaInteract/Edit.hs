{-# LANGUAGE OverloadedStrings #-}
-- | Source-edit helpers for the interaction bridge: splice a replacement
-- at a hole, locate the clause line for a case-split, re-indent generated
-- clauses, and render a unified diff.
--
-- The bridge __returns__ these diffs to the client and never writes the
-- file itself — consistent with the rest of @agda-explore@, which only
-- writes its own @.agda-explore/@ artifacts. All offsets are Agda's
-- 1-based __character__ positions (not bytes), so everything works in
-- 'Data.Text' character space.
module AgdaInteract.Edit
  ( spliceRange
  , lineSpanAt
  , lineIndentAt
  , renderClausesAt
  , unifiedDiff
  ) where

import           Data.Text ( Text )
import qualified Data.Text as T

-- | @spliceRange txt start end repl@ replaces the characters in the
-- 1-based half-open range @[start, end)@ with @repl@.
spliceRange :: Text -> Int -> Int -> Text -> Text
spliceRange txt start end repl =
  T.take (start - 1) txt <> repl <> T.drop (end - 1) txt

-- | The 1-based half-open span @[lineStart, newlinePos)@ of the line
-- containing the given 1-based character offset — i.e. the line's
-- content, excluding its trailing newline. Used to replace a whole
-- clause line for @make_case@.
lineSpanAt :: Text -> Int -> (Int, Int)
lineSpanAt txt pos =
  let idx0   = max 0 (pos - 1)
      before = T.take idx0 txt
      start  = case T.findIndex (== '\n') (T.reverse before) of
                 Just k  -> idx0 - k + 1            -- 1-based pos after the prev '\n'
                 Nothing -> 1
      after  = T.drop idx0 txt
      endOff = case T.findIndex (== '\n') after of
                 Just k  -> pos + k                 -- 1-based pos of the '\n'
                 Nothing -> T.length txt + 1
  in (start, endOff)

-- | The number of leading spaces on the line containing the given
-- offset — the column (0-based) at which the clause starts.
lineIndentAt :: Text -> Int -> Int
lineIndentAt txt pos =
  let (start, end) = lineSpanAt txt pos
      line = T.take (end - start) (T.drop (start - 1) txt)
  in T.length (T.takeWhile (== ' ') line)

-- | Render case-split clauses for splicing at a clause whose first
-- column is @col@ (1-based). The first clause is emitted bare (the
-- splice point is already at @col@); continuation clauses are indented
-- to @col@ so they line up. Joined by newlines, no trailing newline.
renderClausesAt :: Int -> [Text] -> Text
renderClausesAt col clauses = case clauses of
  []     -> ""
  (c:cs) -> T.intercalate "\n" (c : map (indent <>) cs)
  where
    indent = T.replicate (max 0 (col - 1)) " "

-- | A minimal single-hunk unified diff between two texts. Computes the
-- common leading\/trailing lines and emits one hunk for the changed
-- middle, with up to 3 lines of context — enough for the bridge's
-- localized edits (which always change one contiguous region).
unifiedDiff :: FilePath -> Text -> Text -> String
unifiedDiff path old new
  | old == new = ""
  | otherwise  = unlines (header ++ hunk)
  where
    oldLs = T.lines old
    newLs = T.lines new
    p = commonPrefix oldLs newLs
    s = commonSuffix (drop p oldLs) (drop p newLs)
    oldMid = take (length oldLs - p - s) (drop p oldLs)
    newMid = take (length newLs - p - s) (drop p newLs)
    ctx = 3
    preStart = max 0 (p - ctx)
    pre  = take (p - preStart) (drop preStart oldLs)
    post = take ctx (drop (length oldLs - s) oldLs)
    oldStart = preStart + 1
    newStart = preStart + 1
    oldCount = length pre + length oldMid + length post
    newCount = length pre + length newMid + length post
    header =
      [ "--- " ++ path
      , "+++ " ++ path
      , "@@ -" ++ show oldStart ++ "," ++ show oldCount
            ++ " +" ++ show newStart ++ "," ++ show newCount ++ " @@"
      ]
    hunk = map ((' ' :) . T.unpack) pre
        ++ map (('-' :) . T.unpack) oldMid
        ++ map (('+' :) . T.unpack) newMid
        ++ map ((' ' :) . T.unpack) post

commonPrefix :: Eq a => [a] -> [a] -> Int
commonPrefix (x:xs) (y:ys) | x == y = 1 + commonPrefix xs ys
commonPrefix _ _ = 0

commonSuffix :: Eq a => [a] -> [a] -> Int
commonSuffix xs ys = commonPrefix (reverse xs) (reverse ys)
