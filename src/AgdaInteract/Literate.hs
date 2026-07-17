{-# LANGUAGE OverloadedStrings #-}
-- | Literate-Markdown awareness for the interaction bridge.
--
-- Agda reports interaction ranges as
-- absolute, 1-based __character__ offsets into the /full/ on-disk file —
-- prose included (the literate preprocessor blanks non-code regions in
-- place rather than stripping them). So range translation is the
-- identity and no offset map is needed.
--
-- What remains is a safety guard: before the bridge splices a @give@ /
-- @make_case@ result into the source it confirms the target offset
-- falls inside a fenced @```agda@ code block, so a protocol-skew bug can
-- never write Agda syntax into the surrounding prose. For a plain
-- @.agda@ file the whole file is code and the check is a no-op.
module AgdaInteract.Literate
  ( CodeBlocks
  , isLiterate
  , codeBlocksFor
  , scanCodeBlocks
  , wholeFileCode
  , isInsideCode
  , codeSlices
  ) where

import           Data.Text ( Text )
import qualified Data.Text as T

-- | Disjoint character spans (1-based 'pos', end-exclusive) that hold
-- Agda code within a source file.
newtype CodeBlocks = CodeBlocks [(Int, Int)]
  deriving (Show, Eq)

-- | Is this a literate source file? (Any @.lagda*@ extension.)
isLiterate :: FilePath -> Bool
isLiterate fp = ".lagda" `T.isInfixOf` T.pack fp

-- | Code blocks for a file: the whole file for a plain @.agda@, the
-- fenced @```agda@ blocks for a literate file.
codeBlocksFor :: FilePath -> Text -> CodeBlocks
codeBlocksFor fp txt
  | isLiterate fp = scanCodeBlocks txt
  | otherwise     = wholeFileCode txt

-- | A single span covering the entire file.
wholeFileCode :: Text -> CodeBlocks
wholeFileCode txt = CodeBlocks [(1, T.length txt + 1)]

-- | Scan Markdown for fenced code blocks. A line whose first
-- non-whitespace is three backticks toggles in\/out of a block; the
-- fence lines themselves are not code. (We treat every fenced block as
-- Agda code — Agda's literate-md reader keys on the @```@ fence.)
scanCodeBlocks :: Text -> CodeBlocks
scanCodeBlocks txt = CodeBlocks (merge (go 0 False (T.splitOn "\n" txt) []))
  where
    go _   _      []       acc = reverse acc
    go off inCode (l:rest) acc =
      let len     = T.length l
          off'    = off + len + 1                       -- +1 for the '\n'
          isFence = "```" `T.isPrefixOf` T.stripStart l
      in if isFence
           then go off' (not inCode) rest acc
           else if inCode && len > 0
                  then go off' inCode rest ((off + 1, off + 1 + len) : acc)
                  else go off' inCode rest acc

    -- Coalesce vertically-adjacent code-line spans.
    merge [] = []
    merge [s] = [s]
    merge ((a, b) : (c, d) : rest)
      | c <= b    = merge ((a, max b d) : rest)
      | otherwise = (a, b) : merge ((c, d) : rest)

-- | Is the 1-based character offset inside a code block?
isInsideCode :: CodeBlocks -> Int -> Bool
isInsideCode (CodeBlocks spans) pos = any (\(s, e) -> pos >= s && pos < e) spans

-- | The code-region text of a file, one 'Text' per span in order (1-based,
-- end-exclusive char indexing). For a plain @.agda@ file that is the whole
-- file as a singleton; for a literate file it is one slice per code line
-- (spans are per-line — see 'scanCodeBlocks'), so a caller rejoins with
-- @"\n"@ to reconstruct multi-line pragmas\/comments faithfully. Used by the
-- guard to scan only a literate file's Agda code, never its prose.
codeSlices :: CodeBlocks -> Text -> [Text]
codeSlices (CodeBlocks spans) txt = go 1 txt spans
  where
    -- Walk the file once: spans are ascending and disjoint, so advance from
    -- the previous span's end rather than re-dropping @s-1@ chars from the
    -- start for each span (which was O(spans·n) on a large literate file).
    go _   _ []            = []
    go pos t ((s, e) : rest) =
      let t'            = T.drop (s - pos) t   -- advance to this span's start
          (slice, rem') = T.splitAt (e - s) t'
      in slice : go e rem' rest
