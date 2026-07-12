{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
-- | Parser for the line-delimited JSON replies emitted by
-- @agda --interaction-json@.
--
-- This is the consumer source of truth for the @--interaction-json@
-- wire shape, shared by both @agda-goals@ (which only needs
-- @AllGoalsWarnings@) and @agda-explore@'s write-side interaction
-- bridge (which needs the goal-specific, give, and make-case replies
-- too). @AgdaGoals.Protocol@ re-exports this module.
--
-- The protocol streams one JSON object per line, optionally prefixed
-- by the @JSON> @ readiness prompt. The object's @kind@ field
-- discriminates between message types. The parser is intentionally
-- __lenient__: @--interaction-json@ is not officially versioned, so an
-- unrecognised @kind@ collapses to 'OtherReply' / 'OtherDisplayInfo'
-- rather than failing the decode. The exact shapes are pinned by the
-- golden fixtures in @test/interaction/<version>/@ (see that README).
module AgdaGraph.Interaction.Protocol
  ( -- * Parsed wire shapes
    Reply(..)
  , DisplayInfo(..)
  , GoalInfo(..)
  , ContextEntry(..)
  , GiveResult(..)
  , MakeCaseVariant(..)
  , InteractionPoint(..)
  , Goal(..)
  , GoalRange(..)
  , RangePos(..)

    -- * Parsing
  , parseReply
  , stripPromptPrefix
  , promptToken
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
-- output. Unknown @kind@s collapse to 'OtherReply'.
data Reply
  = ReplyDisplayInfo !DisplayInfo
    -- ^ @{"kind":"DisplayInfo", "info": ...}@.
  | ReplyGiveAction !Int !GiveResult
    -- ^ @{"kind":"GiveAction", "interactionPoint":{"id":N}, "giveResult":...}@.
    -- Emitted by @Cmd_give@ and @Cmd_refine_or_intro@. The 'Int' is the
    -- interaction-point id the action targets.
  | ReplyMakeCase !Int !MakeCaseVariant ![Text]
    -- ^ @{"kind":"MakeCase", "variant":..., "clauses":[...], "interactionPoint":{"id":N}}@.
    -- The clauses are the full replacement clause lines.
  | ReplyInteractionPoints ![InteractionPoint]
    -- ^ @{"kind":"InteractionPoints", "interactionPoints":[{"id":N,"range":..}]}@.
  | OtherReply !Text
    -- ^ Any other @kind@; carries the tag for diagnostics.
  deriving (Show)

-- | The @DisplayInfo@ variants we destructure. Anything else collapses
-- to 'OtherDisplayInfo'.
data DisplayInfo
  = AllGoalsWarnings
      { agwVisibleGoals :: ![Goal]
      , agwErrors       :: ![Text]
      , agwWarnings     :: ![Text]
      }
    -- ^ Fired after @Cmd_load@ (and after a successful @Cmd_give@) —
    -- enumerates every visible goal in the loaded module.
  | GoalSpecific !Int !GoalInfo
    -- ^ @info.kind == "GoalSpecific"@. The 'Int' is
    -- @interactionPoint.id@; the 'GoalInfo' is the @goalInfo@ payload.
    -- Produced by @Cmd_goal_type_context@ / @Cmd_infer@ / @Cmd_compute@.
  | ErrorReply !Text
    -- ^ @info.kind == "Error"@. The rendered message off
    -- @info.error.message@ — for a rejected @give@/@refine@ this is the
    -- localized type error (it embeds the source location). Surfaced to
    -- the user verbatim.
  | OtherDisplayInfo !Text
    -- ^ The display-info @kind@ string; payload discarded.
  deriving (Show)

-- | The @goalInfo@ payload on a 'GoalSpecific' display info.
data GoalInfo
  = GiGoalType !Text ![ContextEntry]
    -- ^ @goalInfo.kind == "GoalType"@: the rendered goal @type@ plus the
    -- in-scope context @entries@.
  | GiInferredType !Text
    -- ^ @goalInfo.kind == "InferredType"@: the inferred @expr@.
  | GiNormalForm !Text
    -- ^ @goalInfo.kind == "NormalForm"@: the computed @expr@.
  | GiOther !Text
    -- ^ Any other @goalInfo.kind@.
  deriving (Show)

-- | One in-scope binder in a goal context.
data ContextEntry = ContextEntry
  { ceName    :: !Text  -- ^ @reifiedName@ (the displayed name).
  , ceType    :: !Text  -- ^ @binding@ (the rendered type).
  , ceInScope :: !Bool
  } deriving (Show)

-- | The @giveResult@ on a 'ReplyGiveAction'.
data GiveResult
  = GiveStr !Text
    -- ^ @{"str": "..."}@ — splice this exact string at the hole
    -- (emitted by @refine@, and by @give@ when Agda reformats).
  | GiveParen !Bool
    -- ^ @{"paren": Bool}@ — splice the /user's/ original input,
    -- parenthesized iff 'True' (emitted by a plain @give@).
  deriving (Show)

data MakeCaseVariant = MCFunction | MCExtendedLambda
  deriving (Show, Eq)

-- | An @{"id":N,"range":[..]}@ entry from an @InteractionPoints@ reply.
data InteractionPoint = InteractionPoint
  { ipId    :: !Int
  , ipRange :: !(Maybe GoalRange)
  } deriving (Show)

-- | One unsolved goal at a hole. The @type@ field holds the /rendered/
-- goal type as a string. See 'AgdaGraph.GoalCanon' for canonicalisation.
data Goal = Goal
  { goalType  :: !Text
    -- ^ Rendered goal type, e.g. @"Nat"@.
  , goalRange :: !(Maybe GoalRange)
    -- ^ Source range of the @?@ hole, if the reply carried one.
  , goalKind  :: !Text
    -- ^ The @kind@ field on the goal payload (@OfType@ / @JustType@).
  , goalId    :: !(Maybe Int)
    -- ^ Agda's current interaction-point integer (@constraintObj.id@).
    -- Renumbered on every reload — see "AgdaInteract.GoalId" for the
    -- stable-id layer built on top of this.
  } deriving (Show)

-- | Source range of a goal — start and end positions.
data GoalRange = GoalRange
  { grStart :: !RangePos
  , grEnd   :: !RangePos
  } deriving (Show)

-- | A position. @rpPos@ is Agda's 1-based __character__ offset into the
-- file (not bytes; @→@ counts as one). For literate files it indexes
-- the full on-disk file, prose included.
data RangePos = RangePos
  { rpLine :: !Int
  , rpCol  :: !Int
  , rpPos  :: !Int
  } deriving (Show)

----------------------------------------------------------------------
-- Parsers.

-- | The readiness prompt Agda prints (without a trailing newline) when
-- it is ready for the next command. Used as a burst delimiter.
promptToken :: BL.ByteString
promptToken = BLC.pack "JSON> "

-- | Strip the leading @JSON> @ prompt (if present) plus surrounding
-- whitespace from one line of helper output.
stripPromptPrefix :: BL.ByteString -> BL.ByteString
stripPromptPrefix bs =
  let trimmed = BLC.dropWhile (`elem` (" \t\r" :: String)) bs
  in case BL.stripPrefix promptToken trimmed of
       Just rest -> rest
       Nothing   -> trimmed

-- | Parse one line of helper output into a 'Reply'. Returns 'Left' on
-- aeson decode failure (with the offending bytes), 'Right Nothing' for
-- blank/prompt-only lines.
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

----------------------------------------------------------------------
-- aeson wiring.

replyParser :: A.Value -> A.Parser Reply
replyParser = A.withObject "Reply" $ \o -> do
  k <- o .: "kind"
  case (k :: Text) of
    "DisplayInfo" -> do
      info <- o .: "info"
      ReplyDisplayInfo <$> displayInfoParser info
    "GiveAction" -> do
      iid <- interactionPointId o
      gr  <- o .: "giveResult" >>= giveResultParser
      pure (ReplyGiveAction iid gr)
    "MakeCase" -> do
      iid     <- interactionPointId o
      variant <- o .:? "variant" .!= ("Function" :: Text)
      clauses <- o .:? "clauses" .!= []
      pure (ReplyMakeCase iid (makeCaseVariant variant) clauses)
    "InteractionPoints" -> do
      ips <- o .:? "interactionPoints" .!= []
      pure (ReplyInteractionPoints ips)
    other -> pure (OtherReply other)

-- | The integer interaction-point id off an @interactionPoint@ object.
interactionPointId :: A.Object -> A.Parser Int
interactionPointId o = do
  ip <- o .: "interactionPoint"
  A.withObject "interactionPoint" (.: "id") ip

giveResultParser :: A.Value -> A.Parser GiveResult
giveResultParser = A.withObject "giveResult" $ \o -> do
  mstr <- o .:? "str"
  case mstr of
    Just s  -> pure (GiveStr s)
    Nothing -> GiveParen <$> (o .:? "paren" .!= False)

makeCaseVariant :: Text -> MakeCaseVariant
makeCaseVariant = \case
  "ExtendedLambda" -> MCExtendedLambda
  _                -> MCFunction

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
    "GoalSpecific" -> do
      iid <- interactionPointId o
      gi  <- o .: "goalInfo" >>= goalInfoParser
      pure (GoalSpecific iid gi)
    "Error" -> do
      -- Nested @error.message@ string; older variants used a flat
      -- @"message"@ — accept both.
      mNested <- o .:? "error"
      msg <- case mNested of
        Just inner -> A.withObject "error" (.: "message") inner
        Nothing    -> o .:? "message" .!= ("(agda reported an error with no message)" :: Text)
      pure (ErrorReply msg)
    other -> pure (OtherDisplayInfo other)

goalInfoParser :: A.Value -> A.Parser GoalInfo
goalInfoParser = A.withObject "goalInfo" $ \o -> do
  k <- o .: "kind"
  case (k :: Text) of
    "GoalType"     -> do
      ty      <- o .:? "type" .!= ""
      entries <- o .:? "entries" .!= []
      pure (GiGoalType ty entries)
    "InferredType" -> GiInferredType <$> o .:? "expr" .!= ""
    "NormalForm"   -> GiNormalForm   <$> o .:? "expr" .!= ""
    other          -> pure (GiOther other)

-- | Errors / warnings can be strings or objects depending on the Agda
-- version. Grab the string form, else a tagged encode.
textyShow :: A.Value -> Text
textyShow = \case
  A.String t -> t
  v          -> T.pack (BLC.unpack (A.encode v))

instance A.FromJSON ContextEntry where
  parseJSON = A.withObject "ContextEntry" $ \o -> ContextEntry
    <$> (o .:? "reifiedName" >>= \case
           Just n  -> pure n
           Nothing -> o .:? "originalName" .!= "")
    <*> o .:? "binding" .!= ""
    <*> o .:? "inScope" .!= True

instance A.FromJSON InteractionPoint where
  parseJSON = A.withObject "InteractionPoint" $ \o -> InteractionPoint
    <$> o .: "id"
    <*> parseRangeArray o

instance A.FromJSON Goal where
  parseJSON = A.withObject "Goal" $ \o -> do
    k  <- o .:? "kind"  .!= ("OfType" :: Text)
    ty <- o .:? "type"  .!= ""
    mr <- parseGoalRange o
    mi <- parseGoalId o
    pure Goal
      { goalType  = ty
      , goalRange = mr
      , goalKind  = k
      , goalId    = mi
      }

-- | The interaction-point integer. In @AllGoalsWarnings@ goals it is
-- nested at @constraintObj.id@.
parseGoalId :: A.Object -> A.Parser (Maybe Int)
parseGoalId o = do
  cobj <- o .:? "constraintObj"
  case cobj of
    Just c  -> A.withObject "constraintObj" (\c' -> c' .:? "id") c
    Nothing -> o .:? "id"

-- | @AllGoalsWarnings@ nests the range at @constraintObj.range[0]@;
-- other replies put it directly at @range[0]@. Try both.
parseGoalRange :: A.Object -> A.Parser (Maybe GoalRange)
parseGoalRange o = do
  fromTop <- parseRangeArray o
  case fromTop of
    Just r  -> pure (Just r)
    Nothing -> do
      cobj <- o .:? "constraintObj"
      case cobj of
        Nothing -> pure Nothing
        Just c  -> parseRangeArray c

-- | Read the first element of a @"range"@ array, if present.
parseRangeArray :: A.Object -> A.Parser (Maybe GoalRange)
parseRangeArray o = do
  rs <- (o .:? "range") .!= []
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
