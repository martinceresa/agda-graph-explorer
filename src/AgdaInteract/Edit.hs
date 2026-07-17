{-# LANGUAGE BangPatterns      #-}
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
  , spliceRanges
  , lineSpanAt
  , lineIndentAt
  , renderClausesAt
  , unifiedDiff
  ) where

import           Data.List ( sortBy )
import           Data.Ord  ( comparing )
import           Data.Text ( Text )
import qualified Data.Text as T

-- | @spliceRange txt start end repl@ replaces the characters in the
-- 1-based half-open range @[start, end)@ with @repl@.
spliceRange :: Text -> Int -> Int -> Text -> Text
spliceRange txt start end repl =
  T.take (start - 1) txt <> repl <> T.drop (end - 1) txt

-- | Apply several replacements (1-based half-open @[start, end)@ char
-- ranges) to a text in one shot, bottom-up so an earlier edit never
-- shifts a later one's offsets. 'Left' if any two ranges overlap — the
-- caller is splicing independent holes, so an overlap is a bug worth
-- surfacing rather than silently corrupting.
spliceRanges :: Text -> [(Int, Int, Text)] -> Either Text Text
spliceRanges txt edits =
  case overlap sorted of
    Just (a, b) -> Left ("refusing to apply overlapping edits (ranges "
                           <> tshow a <> " and " <> tshow b <> ")")
    Nothing     -> Right (T.concat (build 1 txt sorted))
  where
    sorted = sortBy (comparing (\(s, _, _) -> s)) edits
    -- One left-to-right assembly over the ascending ranges using ORIGINAL
    -- offsets (so an earlier edit never shifts a later one), concatenated once.
    build _   t []               = [t]
    build pos t ((s, e, r) : rest) =
      let (before, afterStart) = T.splitAt (s - pos) t  -- gap chars [pos, s)
          afterRange           = T.drop (e - s) afterStart  -- skip [s, e)
      in before : r : build e afterRange rest
    overlap (x@(_, e1, _) : y@(s2, _, _) : rest)
      | e1 > s2   = Just (x, y)
      | otherwise = overlap (y : rest)
    overlap _ = Nothing
    tshow (s, e, _) = "[" <> T.pack (show s) <> "," <> T.pack (show e) <> ")"

-- | The 1-based half-open span @[lineStart, newlinePos)@ of the line
-- containing the given 1-based character offset — i.e. the line's
-- content, excluding its trailing newline. Used to replace a whole
-- clause line for @make_case@.
lineSpanAt :: Text -> Int -> (Int, Int)
lineSpanAt txt pos =
  let idx0   = max 0 (pos - 1)
      before = T.take idx0 txt
      -- chars after the last '\n' in @before@ = the current line's prefix;
      -- scanning backward avoids reversing the whole prefix.
      start  = idx0 - T.length (T.takeWhileEnd (/= '\n') before) + 1
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
commonPrefix = go 0
  where
    go !n (x:xs) (y:ys) | x == y = go (n + 1) xs ys
    go !n _      _               = n

commonSuffix :: Eq a => [a] -> [a] -> Int
commonSuffix xs ys = commonPrefix (reverse xs) (reverse ys)
