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
  , ConstraintEntry(..)
  , InstanceCandidate(..)

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
      { agwVisibleGoals   :: ![Goal]
      , agwInvisibleGoals :: ![Goal]
      , agwErrors         :: ![Text]
      , agwWarnings       :: ![Text]
      }
    -- ^ Fired after @Cmd_load@ (and after a successful @Cmd_give@) —
    -- enumerates every visible goal in the loaded module.
    --
    -- @agwInvisibleGoals@ are the unsolved metas that are __not__
    -- interaction points: a missing record field, an un-inferable implicit,
    -- a stuck instance argument. Batch @agda@ promotes these to
    -- @[UnsolvedMetaVariables]@ errors at the end of a module; the
    -- interaction mode (built for editors, where a hole-carrying file must
    -- stay loadable) reports them here with @errors@ and @warnings@ both
    -- empty — so a consumer that reads only @agwErrors@ and
    -- @agwVisibleGoals@ sees a clean load over un-produced evidence.
    -- Note they are routine and benign for a file that still has holes (an
    -- implicit blocked on a hole's eventual content is one), which is why
    -- the verdict rule keys on @agwVisibleGoals@ being empty — see
    -- @AgdaInteract.Tools.checkAcceptable@.
  | GoalSpecific !Int !GoalInfo
    -- ^ @info.kind == "GoalSpecific"@. The 'Int' is
    -- @interactionPoint.id@; the 'GoalInfo' is the @goalInfo@ payload.
    -- Produced by @Cmd_goal_type_context@ / @Cmd_infer@ / @Cmd_compute@.
  | ErrorReply !Text
    -- ^ @info.kind == "Error"@. The rendered message off
    -- @info.error.message@ — for a rejected @give@/@refine@ this is the
    -- localized type error (it embeds the source location). Surfaced to
    -- the user verbatim.
  | ConstraintsReply ![ConstraintEntry]
    -- ^ @info.kind == "Constraints"@ — the reply to @Cmd_constraints@:
    -- the constraints Agda could not solve. Empty for a clean load /and/
    -- for a plain unsolved meta (which carries no constraint); non-empty
    -- for a stuck instance search, where it is the actionable form (it
    -- carries the candidate list).
  | OtherDisplayInfo !Text
    -- ^ The display-info @kind@ string; payload discarded.
  deriving (Show)

-- | One entry of a 'ConstraintsReply'. Deliberately shallow: Agda's
-- constraint vocabulary is large and unversioned, so only the fields that
-- generalise across kinds are destructured and 'cnRaw' keeps the compact
-- JSON as the fallback rendering for a shape we don't recognise.
data ConstraintEntry = ConstraintEntry
  { cnKind       :: !Text
    -- ^ @constraint.kind@ (e.g. @FindInstanceOF@); @""@ when absent.
  , cnMeta       :: !(Maybe Text)
    -- ^ The blocked meta's name off @constraint.constraintObj@ (a bare
    -- string here, unlike the goal object in an 'AllGoalsWarnings').
  , cnType       :: !(Maybe Text)
    -- ^ @constraint.type@, for the kinds that carry one.
  , cnCandidates :: ![InstanceCandidate]
    -- ^ @constraint.candidates@ — what an instance search had to choose
    -- between. Echoing these is what makes a stuck-instance report
    -- actionable.
  , cnRange      :: !(Maybe GoalRange)
  , cnRaw        :: !Text
    -- ^ Compact JSON of the whole entry; rendered when 'cnKind' is empty.
  } deriving (Show)

-- | One @{value, type}@ candidate of an instance-resolution constraint.
data InstanceCandidate = InstanceCandidate
  { icValue :: !Text
  , icType  :: !Text
  } deriving (Show)

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
  , goalName  :: !(Maybe Text)
    -- ^ @constraintObj.name@ — the meta's internal name (@_bad_12@). Set
    -- for an /invisible/ goal, which has a name but no interaction id
    -- (the reverse of a visible one); the only handle for reporting it.
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
      gs    <- o .:? "visibleGoals"   .!= []
      igs   <- o .:? "invisibleGoals" .!= []
      errs  <- o .:? "errors"         .!= []
      warns <- o .:? "warnings"       .!= []
      pure AllGoalsWarnings
        { agwVisibleGoals   = gs
        , agwInvisibleGoals = igs
        , agwErrors         = map textyShow errs
        , agwWarnings       = map textyShow warns
        }
    "Constraints" -> do
      cs <- o .:? "constraints" .!= []
      pure (ConstraintsReply cs)
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
-- version. Grab the string form, the object's rendered @message@ when it
-- has one (2.8 wraps each entry as @{"message": …}@ — the raw encode of
-- that is unreadable in a report), else a tagged encode.
textyShow :: A.Value -> Text
textyShow = \case
  A.String t -> t
  v          -> case A.parseMaybe (A.withObject "msg" (.: "message")) v of
    Just t  -> t
    Nothing -> T.pack (BLC.unpack (A.encode v))

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
    mn <- parseGoalName o
    pure Goal
      { goalType  = ty
      , goalRange = mr
      , goalKind  = k
      , goalId    = mi
      , goalName  = mn
      }

-- | The meta's internal name, nested at @constraintObj.name@ (invisible
-- goals) or flat (defensive).
parseGoalName :: A.Object -> A.Parser (Maybe Text)
parseGoalName o = do
  cobj <- o .:? "constraintObj"
  case cobj of
    Just c  -> A.withObject "constraintObj" (\c' -> c' .:? "name") c
    Nothing -> o .:? "name"

instance A.FromJSON ConstraintEntry where
  parseJSON v = flip (A.withObject "ConstraintEntry") v $ \o -> do
    inner <- o .:? "constraint"
    rng   <- parseRangeArray o
    let raw = T.pack (BLC.unpack (A.encode v))
    case inner of
      Nothing -> pure (ConstraintEntry "" Nothing Nothing [] rng raw)
      Just c  -> flip (A.withObject "constraint") c $ \c' -> do
        k     <- c' .:? "kind" .!= ""
        ty    <- c' .:? "type"
        cands <- c' .:? "candidates" .!= []
        -- A bare string here, unlike the object form in an AllGoalsWarnings
        -- goal; accept either so one shape change doesn't fail the decode.
        mMeta <- c' .:? "constraintObj" >>= \case
          Just (A.String s) -> pure (Just s)
          Just obj@A.Object{} -> A.withObject "constraintObj" (\m -> m .:? "name") obj
          _                 -> pure Nothing
        pure (ConstraintEntry k mMeta ty cands rng raw)

instance A.FromJSON InstanceCandidate where
  parseJSON = A.withObject "InstanceCandidate" $ \o -> InstanceCandidate
    <$> o .:? "value" .!= ""
    <*> o .:? "type"  .!= ""

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
