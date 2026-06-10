{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Typed view of the expanded @agda-deps --format=json --json-mode=expanded@
-- artifact (v2 schema). This is the shared schema module used by
-- @agda-unused@ and @agda-optimization@; the producer side lives in
-- @AgdaDeps.Backend.GraphJson.buildExpandedJson@.
--
-- Conventions preserved from the producer:
--   * Missing @access@ field -> 'Public'.
--   * Missing @line@ field   -> 'Nothing'.
--   * Missing @x@ / @y@      -> 0.
--   * Missing @kind@         -> 'KOther'.
--   * Missing @reexports@    -> @[]@.
--   * Refuse @v@ /= 2 or @mode@ /= @"expanded"@.
module AgdaGraph.Schema
  ( State(..)
  , Kind(..)
  , Access(..)
  , Definition(..)
  , ReExport(..)
  , ExternalsSummary(..)
  , Provenance(..)
  , ExpandedGraph(..)
  , loadExpandedGraph
  ) where

import           Control.DeepSeq      ( NFData(..) )
import           Control.Monad        ( when )
import qualified Data.Aeson           as A
import           Data.Aeson           ( FromJSON(..), withObject, withText
                                      , (.:), (.:?), (.!=) )
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict      as M
import           Data.Text            ( Text )
import qualified Data.Text            as T
import           Data.Word            ( Word64 )
import           GHC.Generics         ( Generic )

-- | Per-definition lifecycle state. Encoded by the producer as the
-- single-letter strings @"D"@/@"P"@/@"H"@/@"F"@. See @CLAUDE.md@'s
-- "State semantics" section for the full story.
data State
  = Defined
  | Postulate
  | Hole
  | Failed
  deriving (Show, Eq, Ord, Generic)

instance NFData State

instance FromJSON State where
  parseJSON = withText "State" $ \t -> case t of
    "D" -> pure Defined
    "P" -> pure Postulate
    "H" -> pure Hole
    "F" -> pure Failed
    _   -> fail $ "unknown state: " ++ T.unpack t

-- | Structural kind of a definition. Mirrors the producer's
-- @AgdaDeps.Deps.DefKind@ via lowercase tags.
data Kind
  = KFunction
  | KProjection
  | KDatatype
  | KRecord
  | KConstructor
  | KPostulate
  | KPrimitive
  | KOther
  deriving (Show, Eq, Ord, Generic)

instance NFData Kind

instance FromJSON Kind where
  parseJSON = withText "Kind" $ \t -> case t of
    "function"    -> pure KFunction
    "projection"  -> pure KProjection
    "datatype"    -> pure KDatatype
    "record"      -> pure KRecord
    "constructor" -> pure KConstructor
    "postulate"   -> pure KPostulate
    "primitive"   -> pure KPrimitive
    "other"       -> pure KOther
    _             -> fail $ "unknown kind: " ++ T.unpack t

-- | Defining-module visibility, mirroring the producer's @access@ field.
-- Absent in the JSON => 'Public' (preserved from 'AgdaUnused.Json').
data Access = Public | Private
  deriving (Show, Eq, Ord, Generic)

instance NFData Access

instance FromJSON Access where
  parseJSON = withText "Access" $ \t -> case t of
    "public"  -> pure Public
    "private" -> pure Private
    _         -> fail $ "unknown access: " ++ T.unpack t

-- | A single definition. Strict fields throughout; this record is built
-- once per QName and held across the whole analysis.
data Definition = Definition
  { defId     :: !Int
  , defName   :: !Text
    -- ^ Fully-qualified user-visible name (matches @prettyShow@ output).
  , defModule :: !Text
  , defState  :: !State
  , defKind   :: !Kind
  , defLine   :: !(Maybe Int)
    -- ^ 1-based start-line; 'Nothing' when the producer didn't know.
  , defAccess :: !Access
    -- ^ Defaults to 'Public' when absent from the JSON.
  , defSig    :: !(Maybe Text)
    -- ^ Rendered type signature, present only when the producer ran with
    -- @--with-signatures@ (the per-def @"type"@ field). 'Nothing'
    -- otherwise. The text is the reified type collapsed to one line:
    -- shown as-written (not normalised), with Agda's default printing
    -- (no @--show-implicit@).
  , defX      :: !Double
  , defY      :: !Double
  } deriving (Show, Generic)

instance NFData Definition

instance FromJSON Definition where
  parseJSON = withObject "Definition" $ \o ->
    Definition
      <$> o .:? "id"     .!= (-1)
      <*> o .:  "name"
      <*> o .:  "module"
      <*> o .:? "state"  .!= Defined
      <*> o .:? "kind"   .!= KOther
      <*> o .:? "line"
      <*> o .:? "access" .!= Public
      <*> o .:? "type"
      <*> o .:? "x"      .!= 0.0
      <*> o .:? "y"      .!= 0.0

-- | One public-re-export row. @rxFrom@ = host module doing
-- @open import M public@; @rxTo@ = source module @M@; @rxNames@ are the
-- fully-qualified names that flow through (matching 'defName' directly).
data ReExport = ReExport
  { rxFrom  :: !Text
  , rxTo    :: !Text
  , rxNames :: ![Text]
  } deriving (Show, Generic)

instance NFData ReExport

instance FromJSON ReExport where
  parseJSON = withObject "ReExport" $ \o ->
    ReExport <$> o .: "from" <*> o .: "to" <*> o .: "names"

-- | How an edge was discovered during the producer's walk. Optional on
-- the wire: older producers omit the @definitionEdgesProvenance@ field
-- entirely, in which case 'egEdgeProvenance' is empty and downstream
-- analyses fall back to treating every edge as 'ProvUnknown'.
--
-- The provenance tags mirror the structure the producer walked through:
--
--   * 'ProvSignature' — edge sourced from @defType@ (argument or
--     result-type references).
--   * 'ProvBody'      — edge sourced from @theDef@'s clauses or record
--     fields.
--   * 'ProvWhere'     — edge sourced from a @where@-block helper that
--     ultimately points outside the helper.
--   * 'ProvWith'      — edge sourced from a @with@-generated auxiliary.
--   * 'ProvUnknown'   — producer couldn't classify (or older JSON
--     present but field-by-field tagging was indeterminate); analyses
--     should treat as body-side noise.
data Provenance
  = ProvSignature
  | ProvBody
  | ProvWhere
  | ProvWith
  | ProvUnknown
  deriving (Show, Eq, Ord, Generic)

instance NFData Provenance

instance FromJSON Provenance where
  parseJSON = withText "Provenance" $ \t -> case t of
    "signature" -> pure ProvSignature
    "body"      -> pure ProvBody
    "where"     -> pure ProvWhere
    "with"      -> pure ProvWith
    "unknown"   -> pure ProvUnknown
    _           -> fail $ "unknown provenance: " ++ T.unpack t

-- | Diagnostic summary of the externals that @agda-deps --no-externals@
-- stripped from the graph. Producer-side definition lives in
-- @AgdaDeps.Backend.GraphJson.ExternalsSummary@ and is emitted by hand
-- to keep the agda-deps executable aeson-free; this mirror exists so
-- @agda-optimization@ et al. can parse the field with a typed
-- 'FromJSON' instance.
--
-- Wire shape (matches what the producer emits):
--
-- @
--   { "modules": ["Agda.Builtin.Bool", ...],
--     "postulates_by_module": {
--       "Agda.Builtin.Bool": ["true", "false"], ... } }
-- @
--
-- 'esModules' holds the dropped module names; 'esPostulatesByModule'
-- maps each dropped module to the *unqualified* postulate names (last
-- dot-component) that lived in it before the drop.
data ExternalsSummary = ExternalsSummary
  { esModules            :: ![Text]
    -- ^ Every module classified external and dropped. Wire order:
    -- ascending; consumers should not rely on it.
  , esPostulatesByModule :: !(M.Map Text [Text])
    -- ^ Per module, the unqualified postulate names sorted ascending.
  } deriving (Show)

instance NFData ExternalsSummary where
  rnf (ExternalsSummary ms pm) = rnf ms `seq` rnf pm

instance FromJSON ExternalsSummary where
  parseJSON = withObject "ExternalsSummary" $ \o -> do
    !ms <- o .:? "modules"              .!= []
    !pm <- o .:? "postulates_by_module" .!= M.empty
    pure ExternalsSummary
      { esModules            = ms
      , esPostulatesByModule = pm
      }

-- | The expanded graph as carried over the wire. Field names match the
-- producer one-for-one where possible.
data ExpandedGraph = ExpandedGraph
  { egDefinitions      :: ![Definition]
  , egDefinitionEdges  :: ![(Text, Text)]
  , egModules          :: ![Text]
  , egEntryModule      :: !(Maybe Text)
  , egExternalModules  :: ![Text]
  , egFailedModules    :: ![Text]
  , egModuleFiles      :: !(M.Map Text FilePath)
  , egProducer         :: !(Maybe Text)
    -- ^ The build fingerprint of the @agda-deps@ that produced this
    -- graph (@"producer"@ field). 'Nothing' for older JSON. Surfaced by
    -- @agda-explore status@ so a graph\/binary mismatch is visible.
  , egNodeKeyVersion   :: !Int
    -- ^ The node-key convention version the producer used
    -- (@"nodeKeyVersion"@). Defaults to @1@ when absent (older JSON that
    -- collapsed same-named helpers). A consumer compares this to the
    -- version /it/ expects to detect a stale-format cache.
  , egReExports        :: ![ReExport]
  , egExternalsSummary :: !(Maybe ExternalsSummary)
    -- ^ 'Just' when the producer was run with @--no-externals@;
    -- 'Nothing' otherwise (older JSON, or default mode where the
    -- externals are still part of the main graph).
  , egEdgeProvenance   :: ![Provenance]
    -- ^ Parallel to 'egDefinitionEdges' — index @i@ in this list
    -- tags the @i@-th edge. Empty when the producer didn't emit the
    -- @definitionEdgesProvenance@ field (older JSON); when non-empty,
    -- the parser enforces @length egEdgeProvenance == length
    -- egDefinitionEdges@. The strict spine + 'NFData Provenance' mean
    -- this is safe to keep around for the whole analysis lifetime.
  , egSubtermHashes    :: ![[Word64]]
    -- ^ Parallel to 'egDefinitions' — index @i@ in this list is the
    -- array of canonical-form hashes for the @i@-th definition's
    -- walked subterms. Empty list when the producer didn't emit
    -- @definitionSubtermHashes@ (i.e. wasn't run with
    -- @--with-term-hashes@); when non-empty, the parser enforces
    -- @length egSubtermHashes == length egDefinitions@. Consumed by
    -- @agda-optimization term-cluster@.
  , egSubtermDepths    :: ![[Int]]
    -- ^ Parallel to 'egSubtermHashes' — AST depth of each emitted
    -- subterm. Same emptiness contract. Older JSON with hashes but no
    -- depths is still accepted (the consumer falls back to size-only
    -- ranking).
  } deriving (Show, Generic)

instance NFData ExpandedGraph

instance FromJSON ExpandedGraph where
  parseJSON = withObject "ExpandedGraph" $ \o -> do
    v    <- o .:? "v" .!= (0 :: Int)
    if v /= 2
      then fail $ "expected schema v: 2, got: " ++ show v
      else do
        mode <- o .:? "mode" .!= ("packed" :: Text)
        if mode /= "expanded"
          then fail $ "expected --json-mode=expanded, got: " ++ T.unpack mode
          else do
            defs   <- o .:  "definitions"
            edges  <- o .:  "definitionEdges"
            mfiles <- o .:  "moduleFiles"
            mods   <- o .:  "modules"
            prod   <- o .:? "producer"
            nkv    <- o .:? "nodeKeyVersion" .!= 1
            entry  <- o .:? "entryModule"
            exts   <- o .:? "externalModules"  .!= []
            failed <- o .:? "failedModules"    .!= []
            rxs    <- o .:? "reexports"        .!= []
            extSum <- o .:? "externals_summary"
            prov   <- o .:? "definitionEdgesProvenance" .!= []
            sths   <- o .:? "definitionSubtermHashes"   .!= []
            stds   <- o .:? "definitionSubtermDepths"   .!= []
            let !pairs = map toPair edges
                !nE    = length pairs
                !nP    = length prov
                !nD    = length defs
                !nS    = length sths
                !nT    = length stds
            -- Optional fields, but if present the producer MUST emit
            -- the parallel-array invariant. Mismatch is a producer bug;
            -- surface it with a clear decode error rather than silently
            -- dropping.
            when (not (null prov) && nP /= nE) $
              fail $ "definitionEdgesProvenance length ("
                       ++ show nP
                       ++ ") does not match definitionEdges ("
                       ++ show nE ++ ")"
            when (not (null sths) && nS /= nD) $
              fail $ "definitionSubtermHashes length ("
                       ++ show nS
                       ++ ") does not match definitions ("
                       ++ show nD ++ ")"
            when (not (null stds) && nT /= nD) $
              fail $ "definitionSubtermDepths length ("
                       ++ show nT
                       ++ ") does not match definitions ("
                       ++ show nD ++ ")"
            when (not (null stds) && not (null sths) && lengthMismatch sths stds) $
              fail "definitionSubtermDepths inner-array lengths \
                   \do not match definitionSubtermHashes \
                   \(producer bug)"
            pure ExpandedGraph
                { egDefinitions      = defs
                , egDefinitionEdges  = pairs
                , egModules          = mods
                , egEntryModule      = entry
                , egExternalModules  = exts
                , egFailedModules    = failed
                , egModuleFiles      = mfiles
                , egProducer         = prod
                , egNodeKeyVersion   = nkv
                , egReExports        = rxs
                , egExternalsSummary = extSum
                , egEdgeProvenance   = prov
                , egSubtermHashes    = sths
                , egSubtermDepths    = stds
                }

-- | Edges arrive as @[a, b]@ JSON arrays of length 2. Anything else is a
-- producer bug; surface it as a decode error rather than a Haskell crash.
toPair :: [Text] -> (Text, Text)
toPair [a, b] = (a, b)
toPair xs     = error $ "expected pair, got list of length " ++ show (length xs)

-- | True iff @subtermHashes@ and @subtermDepths@ have a per-def length
-- mismatch somewhere. Used purely as a sanity check on the producer's
-- parallel-array invariant.
lengthMismatch :: [[a]] -> [[b]] -> Bool
lengthMismatch xs ys =
  length xs /= length ys
    || or (zipWith (\a b -> length a /= length b) xs ys)

-- | Read an expanded-mode @graph.json@ from disk. The error case carries
-- a human-readable message (no Haskell exception trace).
loadExpandedGraph :: FilePath -> IO (Either String ExpandedGraph)
loadExpandedGraph p = do
  !bytes <- BL.readFile p
  pure (A.eitherDecode bytes)
