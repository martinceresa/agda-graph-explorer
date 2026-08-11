{-# LANGUAGE ScopedTypeVariables #-}
-- | Shared config-file discovery + raw-load plumbing for the four
-- per-executable @Config@ modules (@agda-unused@ / @agda-goals@ /
-- @agda-optimization@ / @agda-explore@), which share one discovery
-- contract:
--
--   * precedence @--config=PATH@ \> @$ENV@ \> @./.agda-\<bin\>.{yml,yaml}@
--     in cwd \> walk up to the first ancestor directory containing a
--     @*.agda-lib@ file and look there.
--
-- Per-executable differences (env-var name, base filename(s)) are captured
-- by 'DiscoverSpec'. Wrappers thread it through 'discoverWith' (verbatim
-- explicit/env precedence) or compose 'discoverInDir' with their own
-- explicit/env handling (the MCP daemon @die@s on a missing
-- explicit/@$ENV@ path). 'loadYamlConfig' is the shared decode-and-pretty-
-- print core.
module AgdaGraph.ConfigCore
  ( DiscoverSpec(..)
  , discoverWith
  , discoverInDir
  , firstExisting
  , loadYamlConfig
  , extractConfigFlag
  , extractValueFlag
  , isAgdaSourceFile
  , splitEqFlags
    -- * Unknown-key rejection
  , unknownKeys
  , unknownKeyError
  , checkKnownKeys
  , checkKnownKeysP
  , nearestKey
  ) where

import           Control.Exception  ( IOException, catch )
import           Data.Aeson         ( FromJSON, Object )
import qualified Data.Aeson.Key     as K
import qualified Data.Aeson.KeyMap  as KM
import qualified Data.Aeson.Types   as A
import           Data.List          ( intercalate, isPrefixOf, isSuffixOf
                                    , minimumBy, sort, sortOn, stripPrefix )
import           Data.Ord           ( comparing )
import           Data.Text          ( Text )
import qualified Data.Text          as T
import qualified Data.Yaml          as Y

import           System.Directory   ( doesDirectoryExist, doesFileExist
                                    , getCurrentDirectory, listDirectory )
import           System.Environment ( lookupEnv )
import           System.FilePath    ( (</>), takeDirectory, takeExtension )

-- | Per-executable parameters of the otherwise-identical discovery
-- contract: the environment variable consulted after @--config@ and the
-- base filename(s) tried in each candidate directory (@.yml@ then
-- @.yaml@, in order).
data DiscoverSpec = DiscoverSpec
  { dsEnvVar    :: String       -- ^ e.g. @"AGDA_UNUSED_CONFIG"@.
  , dsBaseNames :: [FilePath]   -- ^ e.g. @[".agda-unused.yml", ".agda-unused.yaml"]@.
  }

-- | Resolve a config path with the common precedence: an explicit
-- @--config@ ('Just') wins verbatim; otherwise a non-empty @$ENV@ wins
-- verbatim; otherwise 'discoverInDir' from cwd (cwd base names, then the
-- walk-up to the first @*.agda-lib@ ancestor). 'Nothing' = no config.
-- (The @agda-explore@ daemon needs to @die@ on a missing explicit/@$ENV@
-- path, so it builds its own explicit/env layer over 'discoverInDir'.)
discoverWith :: DiscoverSpec -> Maybe FilePath -> IO (Maybe FilePath)
discoverWith _    (Just p) = pure (Just p)
discoverWith spec Nothing  = do
  mEnv <- lookupEnv (dsEnvVar spec)
  case mEnv of
    Just p | not (null p) -> pure (Just p)
    _                     -> getCurrentDirectory >>= discoverInDir spec

-- | The flag/env-independent tail of discovery: try 'dsBaseNames' in
-- @start@, and on a miss walk up to the first ancestor directory holding
-- a @*.agda-lib@ file and try the base names there.
discoverInDir :: DiscoverSpec -> FilePath -> IO (Maybe FilePath)
discoverInDir spec start = do
  mHere <- tryDir start
  case mHere of
    Just p  -> pure (Just p)
    Nothing -> walkUp start
  where
    tryDir d = firstExisting [ d </> b | b <- dsBaseNames spec ]

    walkUp d = do
      hasLib <- dirHasAgdaLib d
      if hasLib
        then tryDir d
        else let parent = takeDirectory d
             in if parent == d
                  then pure Nothing   -- hit filesystem root
                  else walkUp parent

-- | Strip @--config=PATH@ (or @--config PATH@) out of argv before the
-- per-executable option parser runs, returning the path (if any) and the
-- remaining args. A malformed trailing @--config@ with no value is left for
-- the main parser to diagnose.
extractConfigFlag :: [String] -> (Maybe FilePath, [String])
extractConfigFlag = go []
  where
    go acc []       = (Nothing, reverse acc)
    go acc (a:rest)
      | Just v <- stripPrefix "--config=" a = (Just v, reverse acc ++ rest)
      | a == "--config" = case rest of
          (v:rest') -> (Just v, reverse acc ++ rest')
          []        -> (Nothing, reverse acc)
      | otherwise = go (a : acc) rest

-- | Lift a value-taking flag @--name VALUE@ / @--name=VALUE@ out of argv,
-- returning the value (last occurrence wins) and the remaining args with
-- every occurrence removed. Position-independent, so a caller can support a
-- global flag uniformly without threading it through an intricate positional
-- parser (the pattern 'extractConfigFlag' uses for @--config@, generalised).
-- A trailing bare @--name@ with no value is dropped (the caller treats an
-- absent value as "not given").
extractValueFlag :: String -> [String] -> (Maybe String, [String])
extractValueFlag name = go Nothing []
  where
    eq = name ++ "="
    go found acc [] = (found, reverse acc)
    go found acc (a:rest)
      | Just v <- stripPrefix eq a = go (Just v) acc rest
      | a == name = case rest of
          (v:rest') -> go (Just v) acc rest'
          []        -> (found, reverse acc)
      | otherwise = go found (a : acc) rest

-- | Return the first path in the list that exists as a regular file.
firstExisting :: [FilePath] -> IO (Maybe FilePath)
firstExisting []     = pure Nothing
firstExisting (p:ps) = do
  ok <- doesFileExist p
  if ok then pure (Just p) else firstExisting ps

-- | 'True' iff @d@ exists and contains at least one @*.agda-lib@ entry.
-- Uses the filepath-aware @takeExtension@ form and treats an unreadable /
-- missing directory as @False@.
dirHasAgdaLib :: FilePath -> IO Bool
dirHasAgdaLib d = do
  isDir <- doesDirectoryExist d
  if not isDir
    then pure False
    else (any ((== ".agda-lib") . takeExtension) <$> listDirectory d)
           `catch` \(_ :: IOException) -> pure False

-- | 'True' iff the path names an Agda source file (plain or any of the
-- literate flavours). The single shared extension set for the Agda-source
-- directory walkers ("MainMcp", "MainUnused", "AgdaAuto.Run", …), so a new
-- literate flavour is added once here rather than drifting per tool.
isAgdaSourceFile :: FilePath -> Bool
isAgdaSourceFile f = any (`isSuffixOf` f)
  [ ".agda", ".lagda", ".lagda.md", ".lagda.rst", ".lagda.tex", ".lagda.org"
  , ".lagda.tree", ".lagda.typ" ]

-- | Split any @--key=value@ argv token into @[--key, value]@ (leaving other
-- tokens untouched), so a downstream flag parser only sees the separated form.
-- Shared by the hand-rolled executable CLIs (@agda-explore@ / @agda-auto@).
splitEqFlags :: [String] -> [String]
splitEqFlags = concatMap split
  where
    split a
      | "--" `isPrefixOf` a
      , (k, '=' : v) <- break (== '=') a = [k, v]
      | otherwise = [a]

----------------------------------------------------------------------
-- Unknown-key rejection
----------------------------------------------------------------------

-- | Keys present in @obj@ that are not in the known set, ascending.
--
-- The known set is the config-file counterpart of a parser's flag table:
-- a key outside it is a typo or a stale key, and either way the value the
-- user wrote has no effect. Every executable's @Config@ module rejects
-- those rather than dropping them, matching the CLI parsers' treatment of
-- an unknown flag (a hard error, so a typo never silently no-ops).
unknownKeys :: [Text] -> Object -> [Text]
unknownKeys known obj =
  sort [ k | k <- map K.toText (KM.keys obj), k `notElem` known ]

-- | Render the unknown-key diagnostic for a YAML object, or 'Nothing' when
-- every key is recognised. Each offender carries a 'nearestKey' suggestion
-- when one is close enough, so the common case (a one-character typo) names
-- the key the user meant.
unknownKeyError :: String -> [Text] -> Object -> Maybe String
unknownKeyError label known obj = case unknownKeys known obj of
  []  -> Nothing
  bad -> Just $ label <> ": unknown key" <> plural bad <> ": "
             <> intercalate ", " (map describe bad)
  where
    describe k = T.unpack k <> case nearestKey k known of
      Just s  -> " (did you mean " <> T.unpack s <> "?)"
      Nothing -> ""
    plural [_] = ""
    plural _   = "s"

-- | 'Either'-flavoured 'unknownKeyError', for the hand-rolled config
-- readers (@agda-optimization@, whose sections are walked by hand).
checkKnownKeys :: String -> [Text] -> Object -> Either String ()
checkKnownKeys label known obj =
  maybe (Right ()) Left (unknownKeyError label known obj)

-- | 'FromJSON'-flavoured 'unknownKeyError': fails the decode from inside a
-- @withObject@ body, so the tools whose config is one aeson instance reject
-- a stray key with the same wording. Call it as the first statement of the
-- instance, passing the same key strings the @.:?@ lines use.
checkKnownKeysP :: String -> [Text] -> Object -> A.Parser ()
checkKnownKeysP label known obj =
  maybe (pure ()) fail (unknownKeyError label known obj)

-- | The known key the user most likely meant, or 'Nothing' when nothing is
-- close enough — better silence than a misleading suggestion.
--
-- Containment is tried before edit distance so a negated flag spelling finds
-- its key however long the affix is: several toggles share one key under the
-- positive name (CLI @--no-include-postulates@, YAML @include-postulates@),
-- which is far enough in edits to score as unrelated but is the single most
-- predictable mistake in these files. Otherwise it is edit distance within 2
-- (1 for keys too short for 2 edits to still mean the same key).
nearestKey :: Text -> [Text] -> Maybe Text
nearestKey _ []    = Nothing
nearestKey k known
  | (c : _) <- contained = Just c
  | dist <= budget       = Just best
  | otherwise            = Nothing
  where
    -- Longest first, and only when the overlap dominates both strings: `out`
    -- sits inside `timeout` without the two being the same key.
    contained = [ c | c <- sortOn (negate . T.length) known
                    , c `T.isInfixOf` k || k `T.isInfixOf` c
                    , let short = min (T.length c) (T.length k)
                    , let long  = max (T.length c) (T.length k)
                    , short >= 4, 2 * short >= long ]
    scored       = [ (c, editDistance k c) | c <- known ]
    (best, dist) = minimumBy (comparing snd) scored
    budget       = if T.length k <= 4 then 1 else 2

-- | Levenshtein distance over the two short strings a config key can be.
-- Straight dynamic programming on rows; the inputs are key-sized, so the
-- quadratic cost is irrelevant and the clarity is worth more than a
-- band-limited variant.
editDistance :: Text -> Text -> Int
editDistance a b = last (foldl step [0 .. T.length b] (T.unpack a))
  where
    step row@(d : ds) c = scanl next (d + 1) (zip3 (T.unpack b) row ds)
      where next left (cb, diag, up) =
              minimum [ left + 1, up + 1, if c == cb then diag else diag + 1 ]
    step [] _ = []

-- | Read and parse a YAML config file. On a parse failure returns
-- @Left@ with the library's clean, pretty-printed message; on success
-- @Right@ the decoded value. Matches the @loadConfig@ shape used by
-- @agda-unused@ / @agda-goals@.
loadYamlConfig :: FromJSON a => FilePath -> IO (Either String a)
loadYamlConfig p = do
  res <- Y.decodeFileEither p
  pure $ case res of
    Left err -> Left (Y.prettyPrintParseException err)
    Right c  -> Right c
