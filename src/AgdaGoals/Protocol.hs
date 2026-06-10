{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
-- | Parser for the line-delimited JSON replies emitted by
-- @agda --interaction-json@.
--
-- The protocol streams one JSON object per line, optionally prefixed
-- by the @JSON> @ prompt. The object's @kind@ field discriminates
-- between message types; only the @DisplayInfo@ variants that carry
-- goal-type information are modelled. Anything else parses to
-- 'OtherReply'.
--
-- The @AllGoalsWarnings@ display info fires once after @Cmd_load@: it
-- carries an array of @visibleGoals@, each an @OfType@ payload with a
-- string-valued @type@ field. It covers every hole at load time.
--
-- @--interaction-json@ is not officially versioned; the parser is
-- intentionally lenient (unknown kinds become 'OtherReply').
module AgdaGoals.Protocol
  ( -- * Parsed wire shapes
    Reply(..)
  , DisplayInfo(..)
  , Goal(..)
  , GoalRange(..)
  , RangePos(..)

    -- * Parsing
  , parseReply
  , parseReplyLines
  , stripPromptPrefix
  ) where

import qualified Data.Aeson          as A
import           Data.Aeson          ( (.:), (.:?), (.!=) )
import qualified Data.Aeson.Types    as A
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.Text           ( Text )
import qualified Data.Text           as T

----------------------------------------------------------------------
-- Wire shapes.

-- | Top-level reply parsed from one line of @agda --interaction-json@
-- output. We only model the variants the driver consumes; everything
-- else is 'OtherReply'.
data Reply
  = ReplyDisplayInfo !DisplayInfo
    -- ^ @{"kind":"DisplayInfo", "info": ...}@ — the only variant we
    -- destructure.
  | OtherReply !Text
    -- ^ Any other @kind@ value. Carries the kind tag so callers can
    -- log a hint without keeping the full payload around.
  deriving (Show)

-- | The interesting @DisplayInfo@ variants. Anything else (e.g.
-- @CurrentGoal@, @ModuleContents@) collapses to 'OtherDisplayInfo'.
data DisplayInfo
  = AllGoalsWarnings
      { agwVisibleGoals :: ![Goal]
      , agwErrors       :: ![Text]
      , agwWarnings     :: ![Text]
      }
    -- ^ Fired once after @Cmd_load@ — enumerates every visible goal
    -- in the loaded module with its rendered type.
  | ErrorReply !Text
    -- ^ Fired when type checking failed before reaching the goal pass
    -- — e.g. a parse error or an ambiguous import. Carries the
    -- rendered error message from @info.error.message@. We surface
    -- this to the user instead of silently reporting "no goals".
  | OtherDisplayInfo !Text
    -- ^ The display-info @kind@ string; payload discarded.
  deriving (Show)

-- | One unsolved goal at a hole. The @type@ field holds the
-- /rendered/ goal type as a string — i.e. what the user sees in the
-- editor, not an internal 'Term'. See 'AgdaGoals.Canon' for the
-- canonicalisation we apply.
data Goal = Goal
  { goalType  :: !Text
    -- ^ Rendered goal type, e.g. @"Nat"@ or @"List A → List A"@.
  , goalRange :: !(Maybe GoalRange)
    -- ^ Source range of the @?@ hole, if the reply carried one. The
    -- @AllGoalsWarnings@ variant nests this inside a
    -- @constraintObj.range[0]@ pair; @OfType@ + @Cmd_goal_type@
    -- variants put it directly on the goal.
  , goalKind  :: !Text
    -- ^ The @kind@ field on the goal payload (@OfType@ /
    -- @JustType@). Retained for diagnostic dumps.
  } deriving (Show)

-- | Source range of a goal — start and end positions. Agda's wire
-- format carries this as a one-element array on @constraintObj.range@.
data GoalRange = GoalRange
  { grStart :: !RangePos
  , grEnd   :: !RangePos
  } deriving (Show)

data RangePos = RangePos
  { rpLine :: !Int
  , rpCol  :: !Int
  , rpPos  :: !Int
  } deriving (Show)

----------------------------------------------------------------------
-- Parsers.

-- | Strip the leading @JSON> @ prompt (if present) plus any
-- surrounding whitespace from one line of helper output. The prompt
-- appears on the first line of every reply burst; subsequent lines
-- arrive bare.
stripPromptPrefix :: BL.ByteString -> BL.ByteString
stripPromptPrefix bs =
  let trimmed = BLC.dropWhile (`elem` (" \t\r" :: String)) bs
  in case BL.stripPrefix (BLC.pack "JSON> ") trimmed of
       Just rest -> rest
       Nothing   -> trimmed

-- | Parse one line of helper output into a 'Reply'. Returns 'Left' on
-- aeson decode failure, with the offending bytes attached for
-- diagnostics. Empty / whitespace-only lines parse to 'Right Nothing'
-- so callers can filter them out without retrying the parse.
parseReply :: BL.ByteString -> Either String (Maybe Reply)
parseReply raw =
  let stripped = stripPromptPrefix raw
  in if BL.null (BLC.dropWhile (`elem` (" \t\r\n" :: String)) stripped)
       then Right Nothing
       else case A.eitherDecode stripped of
              Left err -> Left $
                "json decode failed: " ++ err ++ "\n  input: "
                  ++ BLC.unpack (BL.take 200 stripped)
              Right v  -> case A.parseEither replyParser v of
                Left err -> Left ("schema mismatch: " ++ err)
                Right r  -> Right (Just r)

-- | Parse a whole burst of helper output by splitting on newlines and
-- decoding each non-empty line. Decode failures are accumulated and
-- returned per-line; the successful 'Reply's come back in stream
-- order.
parseReplyLines :: BL.ByteString -> ([String], [Reply])
parseReplyLines bs =
  let ls0 = BLC.lines bs
      go [] !errs !okR = (reverse errs, reverse okR)
      go (l:ls) !errs !okR = case parseReply l of
        Left e          -> go ls (e : errs) okR
        Right Nothing   -> go ls errs       okR
        Right (Just r)  -> go ls errs       (r : okR)
  in go ls0 [] []

----------------------------------------------------------------------
-- aeson wiring.

replyParser :: A.Value -> A.Parser Reply
replyParser = A.withObject "Reply" $ \o -> do
  k <- o .: "kind"
  case (k :: Text) of
    "DisplayInfo" -> do
      info <- o .: "info"
      ReplyDisplayInfo <$> displayInfoParser info
    other         -> pure (OtherReply other)

displayInfoParser :: A.Value -> A.Parser DisplayInfo
displayInfoParser = A.withObject "DisplayInfo" $ \o -> do
  k <- o .: "kind"
  case (k :: Text) of
    "AllGoalsWarnings" -> do
      gs    <- o .:? "visibleGoals" .!= []
      errs  <- o .:? "errors"       .!= []
      warns <- o .:? "warnings"     .!= []
      pure AllGoalsWarnings
        { agwVisibleGoals = gs
        , agwErrors       = map textyShow errs
        , agwWarnings     = map textyShow warns
        }
    "Error" -> do
      -- Top-level Error info: nested @error.message@ string. Older
      -- protocol variants used a flat @"message"@ — accept both.
      mNested <- o .:? "error"
      msg <- case mNested of
        Just inner -> A.withObject "error" (\e -> e .: "message") inner
        Nothing    -> o .:? "message" .!= ("(agda reported an error with no message)" :: Text)
      pure (ErrorReply msg)
    other              -> pure (OtherDisplayInfo other)

-- | Errors / warnings in @AllGoalsWarnings@ can be either strings or
-- objects depending on the upstream Agda version. 'textyShow' grabs
-- the string form when available and falls back to a tagged encode
-- for objects.
textyShow :: A.Value -> Text
textyShow = \case
  A.String t -> t
  v          -> T.pack (BLC.unpack (A.encode v))

instance A.FromJSON Goal where
  parseJSON = A.withObject "Goal" $ \o -> do
    k  <- o .:? "kind"  .!= ("OfType" :: Text)
    ty <- o .:? "type"  .!= ""
    mr <- parseGoalRange o
    pure Goal
      { goalType  = ty
      , goalRange = mr
      , goalKind  = k
      }

-- | The @AllGoalsWarnings@ wire format nests the range inside
-- @constraintObj.range[0]@; @Cmd_goal_type_context@ replies put it
-- directly on the goal as @range[0]@. Try both and accept the first
-- that decodes.
parseGoalRange :: A.Object -> A.Parser (Maybe GoalRange)
parseGoalRange o = do
  fromTop <- (o .:? "range") :: A.Parser (Maybe [GoalRange])
  case fromTop of
    Just (r:_) -> pure (Just r)
    _          -> do
      cobj <- o .:? "constraintObj"
      case cobj of
        Nothing -> pure Nothing
        Just c  -> do
          rs <- (c .:? "range") .!= []
          case (rs :: [GoalRange]) of
            (r:_) -> pure (Just r)
            _     -> pure Nothing

instance A.FromJSON GoalRange where
  parseJSON = A.withObject "GoalRange" $ \o -> GoalRange
    <$> o .: "start"
    <*> o .: "end"

instance A.FromJSON RangePos where
  parseJSON = A.withObject "RangePos" $ \o -> RangePos
    <$> o .: "line"
    <*> o .: "col"
    <*> o .: "pos"
