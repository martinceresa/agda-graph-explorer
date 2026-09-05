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
  , ArgUsage(..)
  , ArgBinder(..)
  , BinderHiding(..)
  , argRemovableAlone
  , argOnSignatureLine
  , argWritten
  , argLocalEdit
  , argRemovalBlocked
  , abInserted
  , egErasureFor
  , erasureEnabledFor
  , egDescribesArgBinders
  , Definition(..)
  , ReExport(..)
  , ExternalsSummary(..)
  , Provenance(..)
  , ExpandedGraph(..)
  , loadExpandedGraph
  , explainDecodeError
  ) where

import           Control.DeepSeq      ( NFData(..) )
import           Control.Monad        ( when )
import           Control.Exception    ( IOException, try )
import           Data.Char            ( isSpace )
import           Data.List            ( isInfixOf )
import           System.IO.Error      ( isDoesNotExistError, isPermissionError
                                      , ioeGetErrorString )
import qualified Data.Aeson           as A
import           Data.Aeson           ( FromJSON(..), withObject, withText
                                      , (.:), (.:?), (.!=) )
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.IntSet          as IS
import qualified Data.Map.Strict      as M
import           Data.Text            ( Text )
import qualified Data.Text            as T
import           Data.Word            ( Word64 )
import           GHC.Generics         ( Generic )

-- The dot-component step and the shared shape tokeniser. GoalCanon imports
-- no project module, so this is not a cycle.
import           AgdaGraph.GoalCanon  ( moduleComponent )

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
-- Absent in the JSON => 'Public'.
data Access = Public | Private
  deriving (Show, Eq, Ord, Generic)

instance NFData Access

instance FromJSON Access where
  parseJSON = withText "Access" $ \t -> case t of
    "public"  -> pure Public
    "private" -> pure Private
    _         -> fail $ "unknown access: " ++ T.unpack t

-- | Per-argument usage evidence: which telescope positions a definition
-- never actually uses. The producer reads Agda's own
-- @defArgOccurrences@ \/ @defPolarity@, so the verdict is the compiler's,
-- not a heuristic — see the @agda-deps@ repo's @Prompts\/ArgUsage.md@.
--
-- Positions are 0-based telescope indices, __implicits included__,
-- ascending, over the definition's __own reduced telescope__: elaborated,
-- with the enclosing section's telescope subtracted. That is /not/ the
-- signature line — it can be __longer__, because Agda derives the
-- underlying analysis from a /reduced/ spine, so a type whose codomain
-- only becomes a function after unfolding a definition contributes
-- positions with no written binder at all. 'argOnSignatureLine' is the
-- boundary test.
--
-- Do __not__ align these against 'defSig'. That string reifies the /raw
-- elaborated/ telescope, so a section-lifted definition still shows the
-- binders it inherited while these indices do not: the producer's golden
-- has @Section.drops@ at @arity 2@ with a three-binder @type@, where index
-- 0 read off the type names the wrong binder. The disagreement runs both
-- ways — @auArity@ can also /exceed/ the binder count in 'defSig' — so
-- neither direction is a safe alignment.
-- | How a binder is passed. Rendered with Agda's own brackets, so a
-- report line reads the way the signature does.
data BinderHiding = BHExplicit | BHImplicit | BHInstance
  deriving (Show, Eq, Generic)

instance NFData BinderHiding

instance FromJSON BinderHiding where
  parseJSON = withText "hiding" $ \t -> case t of
    "explicit" -> pure BHExplicit
    "implicit" -> pure BHImplicit
    "instance" -> pure BHInstance
    _          -> fail ("unknown binder hiding: " ++ T.unpack t)

instance A.ToJSON BinderHiding where
  toJSON BHExplicit = A.String "explicit"
  toJSON BHImplicit = A.String "implicit"
  toJSON BHInstance = A.String "instance"

-- | One telescope position's binder, as the producer read it off the
-- syntactic @Pi@ spine.
data ArgBinder = ArgBinder
  { abHiding :: !BinderHiding
    -- ^ Always known — a spine position always has argument info.
  , abName   :: !(Maybe Text)
    -- ^ The binder name as Agda spells it, or 'Nothing' where the spine
    -- binds nothing to name (@Nat → Nat@). Never guessed: a position the
    -- spine does not reach has no entry in 'auBinders' at all rather
    -- than a fabricated one. A __present__ entry with no name is a binder
    -- that /is/ written, spelled @_@.
  , abType   :: !(Maybe Text)
    -- ^ The binder's domain, reified in the context of the binders before
    -- it (so it names them rather than printing de Bruijn indices).
    -- Present only when the producer ran with @--with-signatures@, the
    -- same gate as 'defSig'. Never normalised — reducing a domain would
    -- destroy the head symbol that makes it recognisable — so it is
    -- internal syntax, not source text.
    --
    -- This is what makes an /unnamed/ position reportable: two thirds of
    -- the actionable removable positions in a real proof development are
    -- unnamed explicit binders (premises written bullet-style), where the
    -- type is the only name they have.
  } deriving (Show, Eq, Generic)

instance NFData ArgBinder

instance FromJSON ArgBinder where
  parseJSON = withObject "argBinder" $ \o ->
    ArgBinder <$> o .: "hiding" <*> o .:? "name" <*> o .:? "type"

instance A.ToJSON ArgBinder where
  toJSON b = A.object $
    [ "hiding" A..= abHiding b ]
    ++ [ "name" A..= n | Just n <- [abName b] ]
    ++ [ "type" A..= t | Just t <- [abType b] ]

-- | True when the binder was inserted by a @variable@ generalisation
-- rather than written on the definition's signature line, so there is
-- nothing at that position to edit.
--
-- The test is the dotted name: Agda names a generalisation /dependency/
-- after its path (@P.A@), and a source binder name cannot contain a
-- @.@ — that character is the qualifier separator. It is a
-- __sufficient, not necessary__ signal: a @variable@ the signature
-- /mentions/ is inserted under its own plain name (@A@) and is
-- indistinguishable from a written binder here.
--
-- That incompleteness is harmless in practice, because
-- 'auRemovableRequires' already covers the case. An inserted binder
-- exists only because some written argument mentions it; if that
-- argument were used, the variable would be relevant in its domain and
-- the inserted binder would not be 'auRemovable' at all. So whenever an
-- inserted position is removable, the written position that mentions it
-- is removable too and sits in its closure — meaning
-- 'argRemovableAlone' always hands back a set containing something the
-- user can actually delete. The flag is for the human hunting the
-- binder on the line, not a safety gate.
abInserted :: ArgBinder -> Bool
abInserted b = maybe False (T.isInfixOf ".") (abName b)

data ArgUsage = ArgUsage
  { auRemovable :: ![Int]
    -- ^ Unused in the body /and/ variance-irrelevant: the binder and the
    -- argument at every call site can go. Deleting one changes the
    -- definition's __type__, so this is a spec change, not a refactor.
  , auRemovableRequires :: !(M.Map Int [Int])
    -- ^ Which /other/ 'auRemovable' positions must be deleted alongside a
    -- given one, transitively — a directed closure, always pointing
    -- forward (every value exceeds its key). Absent from the wire, and
    -- absent as a key, means __\"removable on its own\"__, never
    -- \"unknown\": a lone removal that strands a later binder is the
    -- failure this map exists to prevent. Empty for every single-index
    -- verdict.
  , auOccursInBody :: ![Int]
    -- ^ The subset of 'auRemovable' whose variable the __elaborated body__
    -- still mentions: the value is threaded into a callee that discards
    -- it, so the deletion is a /multi-definition/ edit (the callee's
    -- parameter and its own call sites have to go too). A removable
    -- position __absent__ from this list is a local edit — strike the
    -- binder and the arguments, nothing else changes — and an absent
    -- field means every position is local.
    --
    -- Absence is the reliable half: the producer over-reports where the
    -- clause-pattern mapping cannot answer (a position matched on, a
    -- copattern clause, a position past the clause's patterns).
    --
    -- An /instance/ position listed here is the case that breaks builds:
    -- instance search resolved a callee's constraint from that binder,
    -- which no source-text search can see.
  , auErasable  :: ![Int]
    -- ^ Unused in the body but still variance-relevant: used only in
    -- types, so an @\@0@ candidate rather than a removal.
  , auArity     :: {-# UNPACK #-} !Int
    -- ^ Telescope positions the verdict ranges over; every index above is
    -- below this. Counts the definition's own /reduced/ telescope, so it
    -- can exceed the binder count on the signature line — see
    -- 'auSyntacticArity'.
  , auSyntacticArity :: !(Maybe Int)
    -- ^ How many of the 'auArity' positions are __on the signature
    -- line__: the length of the syntactic @Pi@ spine, section prefix
    -- subtracted. The producer omits it when it equals 'auArity', so its
    -- /presence/ is itself the signal that some position has no written
    -- binder. Use 'argOnSignatureLine' rather than reading it directly.
  , auPartiallyApplied :: !Bool
    -- ^ The definition is referenced somewhere in the graph with fewer
    -- arguments than it takes, so its arity is part of its interface and
    -- __no position is removable__ however dead it is: a value used as
    -- @f x@ where a unary function is wanted cannot lose a binder.
    --
    -- Corpus-scoped (only as complete as the modules compiled) and
    -- @Def@-heads only, so it is a filter, not a proof. Absent from the
    -- wire means \"not observed unsaturated\".
  , auBinders   :: !(M.Map Int ArgBinder)
    -- ^ Binder hiding + name (+ type under @--with-signatures@) for the
    -- reported positions, sparse and keyed like 'auRemovableRequires'.
    -- Keys are always below 'auSyntacticArity' — an invariant the
    -- producer asserts — so a __missing__ entry means the position is
    -- past the signature line, not that the binder is unremarkable.
    -- Render the bare index there, and say why.
  } deriving (Show, Eq, Generic)

instance NFData ArgUsage

instance FromJSON ArgUsage where
  parseJSON = withObject "argUsage" $ \o ->
    ArgUsage
      <$> o .:? "removable" .!= []
      -- Wire keys are decimal strings ("0", "1"); aeson's 'FromJSONKey'
      -- for 'Int' parses them.
      <*> o .:? "removableRequires" .!= M.empty
      <*> o .:? "occursInBody" .!= []
      <*> o .:? "erasable"  .!= []
      <*> o .:? "arity"     .!= 0
      <*> o .:? "syntacticArity"
      <*> o .:? "partiallyApplied" .!= False
      <*> o .:? "binders"   .!= M.empty

instance A.ToJSON ArgUsage where
  toJSON au = A.object $
    [ "removable" A..= auRemovable au
    , "erasable"  A..= auErasable au
    , "arity"     A..= auArity au
    ]
    -- Every optional field is omitted at its producer default, so a
    -- decode/encode round-trip is byte-stable.
    ++ [ "removableRequires" A..= auRemovableRequires au
       | not (M.null (auRemovableRequires au)) ]
    ++ [ "occursInBody" A..= auOccursInBody au
       | not (null (auOccursInBody au)) ]
    ++ [ "syntacticArity" A..= k | Just k <- [auSyntacticArity au] ]
    ++ [ "partiallyApplied" A..= True | auPartiallyApplied au ]
    ++ [ "binders" A..= auBinders au | not (M.null (auBinders au)) ]

-- | The positions that must be deleted together with @i@, @i@ included and
-- ascending. A position with no requirement yields @[i]@, so a caller can
-- treat every finding uniformly as \"delete this set\".
--
-- Returns @[]@ for a position that is not removable at all, so a caller
-- cannot accidentally propose a deletion the producer never sanctioned.
argRemovableAlone :: ArgUsage -> Int -> [Int]
argRemovableAlone au i
  | i `notElem` auRemovable au = []
  | otherwise = IS.toAscList
      (IS.insert i (IS.fromList (M.findWithDefault [] i (auRemovableRequires au))))

-- | Is position @i@ a binder the reader can find __on the signature
-- line__, as opposed to one that exists only after a type in the
-- signature unfolds?
--
-- The distinction is not cosmetic: for an unwritten position the verdict
-- is still true and often interesting (\"the proof never inspects this
-- hypothesis\", so the statement could be strengthened), but the edit
-- target is the /unfolded definition/, not this signature. Reporting it
-- as \"delete argument 2\" sends the reader hunting for a binder nobody
-- wrote.
--
-- Prefers 'auSyntacticArity' (exact, and the producer asserts every
-- 'auBinders' key is below it) and falls back to the binder-entry
-- membership that implies, for a graph from a producer that predates the
-- field. On a graph so old it carries no binder data __at all__ the
-- fallback has nothing to read, so callers should gate on
-- 'egDescribesArgBinders' — 'argWritten' is that gate applied.
argOnSignatureLine :: ArgUsage -> Int -> Bool
argOnSignatureLine au i = case auSyntacticArity au of
  Just k  -> i < k
  Nothing -> M.member i (auBinders au)

-- | 'argOnSignatureLine', but answering \"unknown\" as \"written\".
--
-- @described@ is 'egDescribesArgBinders' for the graph the 'ArgUsage' came
-- from: 'False' means the producer emits no binder data anywhere, and there
-- an absent entry is not evidence of an unwritten binder. THE one gate both
-- a report line and a machine payload must ask, so the two cannot disagree
-- about which positions are on the signature line.
argWritten :: Bool -> ArgUsage -> Int -> Bool
argWritten described au i = not described || argOnSignatureLine au i

-- | Does an unsaturated reference to this definition __block__ removing
-- these positions?
--
-- A partial application pins the order of the __explicit__ arguments, so
-- deleting one shifts every call site's list. A hidden position is never
-- written at a call site and Agda re-solves it at each use, so removing it
-- is invisible to a partial application — and gating on that distinction is
-- the difference between reporting and burying a genuine finding on a
-- definition that happens to be passed to a combinator.
--
-- A position with no binder entry has no hiding to read and counts as
-- explicit: conservative, and such a position is not on the signature line
-- anyway.
argRemovalBlocked :: ArgUsage -> [Int] -> Bool
argRemovalBlocked au ixs = auPartiallyApplied au && any explicitAt ixs
  where
    explicitAt i = case M.lookup i (auBinders au) of
      Just b  -> abHiding b == BHExplicit
      Nothing -> True

-- | Is deleting position @i@ a __local__ edit — the binder and its call-site
-- arguments and nothing else?
--
-- 'False' means the elaborated body still threads the value into a callee,
-- so the callee's parameter (and /its/ call sites) must go too. Only
-- meaningful for a position in 'auRemovable'; an 'auErasable' position
-- makes no deletion claim at all.
argLocalEdit :: ArgUsage -> Int -> Bool
argLocalEdit au i = i `notElem` auOccursInBody au

-- | A single definition. Strict fields throughout; this record is built
-- once per QName and held across the whole analysis.
data Definition = Definition
  { defId     :: {-# UNPACK #-} !Int
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
  , defUnsafe :: ![Text]
    -- ^ Soundness escapes the def uses /directly/: @"non-terminating"@ (a
    -- @NON_TERMINATING@ pragma on the def) and/or @"trustme"@ (its body
    -- references @primTrustMe@). Empty — and absent on the wire — for a
    -- safe def. Orthogonal to 'defState' (the 4-state kind). The producer
    -- tags only direct use; transitive taint is a reachability query the
    -- consumer layers on the dep graph. File-level @--no-positivity-check@ /
    -- @--type-in-type@ escapes arrive separately in 'egModuleOptionEscapes'
    -- (a top-level object); 'AgdaGraph.Index.buildIndex' folds them into this
    -- list for every def in the escaping module, so as decoded from the wire
    -- this holds only the declaration-level escapes, while an 'Index' def's
    -- 'defUnsafe' also carries its module's option escapes.
  , defUnsolvedMetas :: {-# UNPACK #-} !Int
    -- ^ How many __silent__ unsolved metavariables this def mentions directly
    -- (the optional per-def @"unsolvedMetas"@; @0@ — and absent on the wire —
    -- when there are none, so older JSON decodes to @0@).
    --
    -- Silent means /not/ an interaction point: a missing record field, a failed
    -- instance search, an un-inferable @_@. An honest @?@ hole is __not__
    -- counted — it only sets 'defState' to 'Hole'. So the pair discriminates
    -- what 'defState' alone cannot: @Hole@ with @0@ here is an open goal
    -- someone is working on, while @Hole@ with a nonzero count is missing
    -- evidence nobody asked for — an unnamed axiom. Only reachable at all when
    -- the producer ran with @--allow-unsolved-metas@ \/ @--lenient-imports@
    -- (otherwise such a module fails and lands in 'egFailedModules').
  , defArgUsage :: !(Maybe ArgUsage)
    -- ^ Per-argument usage evidence (the optional per-def @"argUsage"@
    -- object). 'Nothing' when the definition has nothing to report — and
    -- on any graph from a producer that predates the field, so every
    -- consumer path gated on presence yields zero findings there.
  , defX      :: {-# UNPACK #-} !Double
  , defY      :: {-# UNPACK #-} !Double
  , defOrigin :: !(Maybe Text)
    -- ^ Consumer-internal source tag, NOT on the wire (always decodes to
    -- 'Nothing'): 'Nothing' for the project graph, @Just label@ for a def
    -- from a federated overlay. Set at overlay-decode time; rendered as an
    -- @[external: label]@ suffix.
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
      <*> o .:? "unsafe" .!= []
      <*> o .:? "unsolvedMetas" .!= 0
      <*> o .:? "argUsage"
      <*> o .:? "x"      .!= 0.0
      <*> o .:? "y"      .!= 0.0
      <*> pure Nothing

-- | One public-re-export row. @rxFrom@ = host module doing
-- @open import M public@; @rxTo@ = source module @M@; @rxNames@ are the
-- fully-qualified names that flow through (matching 'defName' directly).
data ReExport = ReExport
  { rxFrom  :: !Text
  , rxTo    :: !Text
  , rxNames :: ![Text]
  , rxRenames :: !(M.Map Text Text)
    -- ^ For a @renaming (orig to alias)@ clause on the re-export: the
    -- in-scope alias short-name mapped to its canonical node-key (a member
    -- of 'rxNames'), e.g. @combine ↦ Core.Base.merge@. Empty — and absent
    -- on the wire — for a plain @open import M public@ with no @renaming@,
    -- so a graph from an older producer decodes to 'mempty'.
  } deriving (Show, Generic)

instance NFData ReExport

instance FromJSON ReExport where
  parseJSON = withObject "ReExport" $ \o ->
    ReExport <$> o .: "from" <*> o .: "to" <*> o .: "names"
             <*> o .:? "renames" .!= mempty

-- | Decode-only wrapper for one @unsolvedModules@ value
-- (@{metas: […], constraints: […]}@) — see 'egUnsolvedModules', which holds
-- the unwrapped pair.
newtype UnsolvedModule = UnsolvedModule { unUnsolvedModule :: ([Int], [Int]) }

instance FromJSON UnsolvedModule where
  parseJSON = withObject "UnsolvedModule" $ \o -> do
    ms <- o .:? "metas"       .!= []
    cs <- o .:? "constraints" .!= []
    pure (UnsolvedModule (ms, cs))

-- | How an edge was discovered during the producer's walk. Optional on
-- the wire: older producers omit the @definitionEdgesProvenance@ field
-- entirely, in which case 'egEdgeProvenance' is empty and downstream
-- analyses fall back to treating every edge as 'ProvUnknown'.
--
-- The provenance tags mirror the structure the producer walked through:
--
--   * 'ProvSignature'   — edge sourced from @defType@ (argument or
--     result-type references).
--   * 'ProvBody'        — edge sourced from @theDef@'s clauses or record
--     fields.
--   * 'ProvModuleLocal' — target is an anonymous-module-local helper (a
--     @where@-block helper or a @module _ (…) where@ parameterised-section
--     member; Agda represents both identically). Describes the /target/,
--     not a source-ownership relation. Wire tag @module-local@ as of
--     producer @nodeKeyVersion@ 3.
--   * 'ProvWhere'       — legacy alias for 'ProvModuleLocal' under the
--     pre-v3 wire tag @where@. Retained so v2 fixtures / on-disk caches
--     still decode; analyses treat it identically to 'ProvModuleLocal'.
--   * 'ProvWith'        — edge sourced from a @with@-generated auxiliary.
--   * 'ProvUnknown'     — producer couldn't classify (or older JSON
--     present but field-by-field tagging was indeterminate); analyses
--     should treat as body-side noise.
data Provenance
  = ProvSignature
  | ProvBody
  | ProvModuleLocal
  | ProvWhere
  | ProvWith
  | ProvUnknown
  deriving (Show, Eq, Ord, Generic)

instance NFData Provenance

instance FromJSON Provenance where
  parseJSON = withText "Provenance" $ \t -> case t of
    "signature"    -> pure ProvSignature
    "body"         -> pure ProvBody
    "module-local" -> pure ProvModuleLocal
    "where"        -> pure ProvWhere       -- legacy (pre-v3) tag
    "with"         -> pure ProvWith
    "unknown"      -> pure ProvUnknown
    _              -> fail $ "unknown provenance: " ++ T.unpack t

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
  , egModuleOptionEscapes :: !(M.Map Text [Text])
    -- ^ Per module, the file-level @{-\# OPTIONS ⋯ \#-}@ soundness escapes
    -- the producer kept (its @safetyRelevantOptionFlags@ ∩ the module's own
    -- pragma tokens): @--type-in-type@, @--no-positivity-check@,
    -- @--rewriting@, … Each value is ascending; only modules with at least
    -- one escape appear. Absent — and 'M.empty' — for an escape-free corpus
    -- (the producer omits the @moduleOptionEscapes@ object then, so older
    -- JSON decodes to 'mempty'). Orthogonal to the per-def 'defUnsafe' (which
    -- carries only the /declaration/-level @NON_TERMINATING@ / @primTrustMe@
    -- escapes): 'AgdaGraph.Index.buildIndex' folds these module-wide escapes
    -- into every enclosed def's 'defUnsafe', so the @agda-explore@ soundness
    -- audit (@search@ / @roots@ @unsafe=@) and transitive taint see them.
  , egModuleEffectiveOptions :: !(M.Map Text [Text])
    -- ^ Per top-level module, the actionability-relevant Agda options
    -- actually __in force__ — currently @--erasure@ alone. Read from the
    -- interface's /effective/ options, which is deliberately the opposite
    -- source to 'egModuleOptionEscapes' (the module's own @OPTIONS@
    -- tokens): a flag like @--erasure@ normally lives in the
    -- @.agda-lib@'s @flags:@ line or on the command line, where a pragma
    -- scan cannot see it.
    --
    -- Only modules enabling one appear, so 'M.empty' — from an older
    -- producer /or/ from a project that enables none — is the answer
    -- \"nowhere\". Gate advice on it via 'egErasureFor': without
    -- @--erasure@, @\@0@ is a syntax error
    -- (@[AttributeKindNotEnabled]@), so every 'auErasable' verdict in
    -- that module is un-appliable as configured however true it is.
  , egUnsolvedModules  :: !(M.Map Text ([Int], [Int]))
    -- ^ Per top-level module, @(silent unsolved-meta lines, unsolved-constraint
    -- lines)@ — the optional @unsolvedModules@ object, @{module → {metas: […],
    -- constraints: […]}}@; only modules with at least one entry appear, so an
    -- older producer (or a clean corpus) decodes to 'mempty'.
    --
    -- The rollup of 'defUnsolvedMetas', and the reason
    -- @egFailedModules == []@ must not be read as "compiles": under
    -- @--allow-unsolved-metas@ these modules /succeeded/ with un-produced
    -- evidence, so the producer's @--keep-going@ failure catch never fired for
    -- them. Meta lines are exact (from the meta store); constraint lines are
    -- best-effort (from highlighting spans, so two constraints on one line
    -- collapse) — count metas, treat constraints as locations.
  , egEdgeProvenance   :: ![Provenance]
    -- ^ Parallel to 'egDefinitionEdges' — index @i@ in this list
    -- tags the @i@-th edge. Empty when the producer didn't emit the
    -- @definitionEdgesProvenance@ field (older JSON); when non-empty,
    -- the parser enforces @length egEdgeProvenance == length
    -- egDefinitionEdges@.
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
        -- The expanded form always emits @"mode":"expanded"@; the packed
        -- form emits no @mode@ key at all (so it defaults to "packed"
        -- here). Refuse packed with an ACTIONABLE message: it is the
        -- HTML-viewer wire form and drops the per-definition fields the
        -- analyses need (kind, source line, access, type signature, and
        -- subterm hashes), so it cannot back these tools — see
        -- test/packed/README.md.
        mode <- o .:? "mode" .!= ("packed" :: Text)
        if mode /= "expanded"
          then fail $
            "this graph is --json-mode=" ++ T.unpack mode ++ " (the HTML-viewer \
            \form). The analysis tools need the expanded form: packed omits \
            \per-definition kind, source line, access, type signature, and \
            \subterm hashes. Re-generate with `agda-deps --json-mode=expanded` \
            \(the agda-explore daemon does this by default). See \
            \test/packed/README.md for the packed layout and the gap."
          else do
            defs   <- o .:  "definitions"
            -- Edges arrive as 2-element JSON arrays; aeson's tuple instance
            -- decodes each straight to a @(Text,Text)@ (a malformed array is a
            -- clean decode error, not a Haskell 'error'). Field type pins it.
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
            mesc   <- o .:? "moduleOptionEscapes" .!= M.empty
            meff   <- o .:? "moduleEffectiveOptions" .!= M.empty
            unsol  <- fmap (fmap unUnsolvedModule) (o .:? "unsolvedModules" .!= M.empty)
            prov   <- o .:? "definitionEdgesProvenance" .!= []
            sths   <- o .:? "definitionSubtermHashes"   .!= []
            stds   <- o .:? "definitionSubtermDepths"   .!= []
            -- Lengths only feed the parallel-array checks below; keep them
            -- lazy so the O(defs)/O(edges) spine walks fire only when the
            -- corresponding optional array is actually present.
            let nE = length edges
                nP = length prov
                nD = length defs
                nS = length sths
                nT = length stds
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
                , egDefinitionEdges  = edges
                , egModules          = mods
                , egEntryModule      = entry
                , egExternalModules  = exts
                , egFailedModules    = failed
                , egModuleFiles      = mfiles
                , egProducer         = prod
                , egNodeKeyVersion   = nkv
                , egReExports        = rxs
                , egExternalsSummary = extSum
                , egModuleOptionEscapes = mesc
                , egModuleEffectiveOptions = meff
                , egUnsolvedModules  = unsol
                , egEdgeProvenance   = prov
                , egSubtermHashes    = sths
                , egSubtermDepths    = stds
                }

-- ---------------------------------------------------------------------
-- ToJSON — the faithful inverse of the FromJSON instances above.
--
-- The @agda-explore@ daemon's multi-entry path unions several graphs
-- in-process and must materialise the result back to @cfgGraphPath@ so
-- out-of-process consumers (the @unused@ tool shells out to
-- @agda-unused --json=cfgGraphPath@) read the SAME graph the in-memory
-- 'AgdaGraph.Index.Index' was built from. These instances round-trip
-- through the 'FromJSON' instances above.
-- ---------------------------------------------------------------------

instance A.ToJSON State where
  toJSON s = A.toJSON (st :: Text)
    where st = case s of
            Defined   -> "D"; Postulate -> "P"; Hole -> "H"; Failed -> "F"

instance A.ToJSON Kind where
  toJSON k = A.toJSON (kt :: Text)
    where kt = case k of
            KFunction -> "function"; KProjection -> "projection"
            KDatatype -> "datatype"; KRecord -> "record"
            KConstructor -> "constructor"; KPostulate -> "postulate"
            KPrimitive -> "primitive"; KOther -> "other"

instance A.ToJSON Access where
  toJSON Public  = A.toJSON ("public" :: Text)
  toJSON Private = A.toJSON ("private" :: Text)

instance A.ToJSON Provenance where
  toJSON p = A.toJSON (pt :: Text)
    where pt = case p of
            ProvSignature -> "signature"; ProvBody -> "body"
            ProvModuleLocal -> "module-local"; ProvWhere -> "where"
            ProvWith -> "with"; ProvUnknown -> "unknown"

instance A.ToJSON Definition where
  toJSON d = A.object $
    [ "id"     A..= defId d
    , "name"   A..= defName d
    , "module" A..= defModule d
    , "state"  A..= defState d
    , "kind"   A..= defKind d
    , "line"   A..= defLine d
    , "access" A..= defAccess d
    , "type"   A..= defSig d
    , "x"      A..= defX d
    , "y"      A..= defY d
    ]
    -- Omitted when empty/zero, matching the producer (keeps clean defs terse).
    ++ [ "unsafe" A..= defUnsafe d | not (null (defUnsafe d)) ]
    ++ [ "unsolvedMetas" A..= defUnsolvedMetas d | defUnsolvedMetas d > 0 ]
    ++ [ "argUsage" A..= au | Just au <- [defArgUsage d] ]

instance A.ToJSON ReExport where
  toJSON r = A.object $
    [ "from" A..= rxFrom r, "to" A..= rxTo r, "names" A..= rxNames r ]
    ++ [ "renames" A..= rxRenames r | not (M.null (rxRenames r)) ]

instance A.ToJSON ExternalsSummary where
  toJSON e = A.object
    [ "modules"              A..= esModules e
    , "postulates_by_module" A..= esPostulatesByModule e
    ]

instance A.ToJSON ExpandedGraph where
  toJSON g = A.object $
    [ "v"                         A..= (2 :: Int)
    , "schemaVersion"             A..= (2 :: Int)
    , "mode"                      A..= ("expanded" :: Text)
    , "definitions"               A..= egDefinitions g
      -- Edges go back out as 2-element arrays, matching 'toPair' on read.
    , "definitionEdges"           A..= map (\(a, b) -> [a, b]) (egDefinitionEdges g)
    , "modules"                   A..= egModules g
    , "entryModule"               A..= egEntryModule g
    , "externalModules"           A..= egExternalModules g
    , "failedModules"             A..= egFailedModules g
    , "moduleFiles"               A..= egModuleFiles g
    , "producer"                  A..= egProducer g
    , "nodeKeyVersion"            A..= egNodeKeyVersion g
    , "reexports"                 A..= egReExports g
    , "externals_summary"         A..= egExternalsSummary g
    , "definitionEdgesProvenance" A..= egEdgeProvenance g
    , "definitionSubtermHashes"   A..= egSubtermHashes g
    , "definitionSubtermDepths"   A..= egSubtermDepths g
    ]
    -- Optional object, omitted when empty to match the producer (escape-free
    -- corpora stay byte-identical, and the round-tripped union graph the
    -- daemon materialises to @cfgGraphPath@ mirrors the producer exactly).
    ++ [ "moduleOptionEscapes" A..= egModuleOptionEscapes g
       | not (M.null (egModuleOptionEscapes g)) ]
    ++ [ "moduleEffectiveOptions" A..= egModuleEffectiveOptions g
       | not (M.null (egModuleEffectiveOptions g)) ]
    ++ [ "unsolvedModules" A..= M.map unsolvedModuleJson (egUnsolvedModules g)
       | not (M.null (egUnsolvedModules g)) ]

-- | Is @--erasure@ in force for module @m@ (so an 'auErasable' verdict
-- there is actually appliable)?
--
-- 'egModuleEffectiveOptions' is keyed by __top-level__ module, because the
-- flag is a file/library-level fact, so a submodule inherits its file's
-- answer: @Foo.Bar.Baz@ is answered by the longest dot-prefix present in
-- the map. An older producer emits no map at all, which reads as
-- \"nowhere\" — the same answer as a project that enables it nowhere, and
-- the conservative one for advice that would otherwise be a syntax error.
egErasureFor :: ExpandedGraph -> Text -> Bool
egErasureFor = erasureEnabledFor . egModuleEffectiveOptions

-- | 'egErasureFor' over the map alone.
--
-- The map is the whole input, so a consumer that answers this question
-- repeatedly holds __only the map__ rather than a closure over the graph:
-- a partially-applied 'egErasureFor' stored in a long-lived record keeps
-- every definition, edge and subterm array of a decoded graph reachable
-- for as long as that record lives.
erasureEnabledFor :: M.Map Text [Text] -> Text -> Bool
erasureEnabledFor opts m
  | M.null opts = False
  | otherwise   = any enabled (m : ancestors m)
  where
    enabled k = "--erasure" `elem` M.findWithDefault [] k opts
    -- "A.B.C" -> ["A.B", "A"]: the enclosing modules, innermost first.
    -- 'moduleComponent' is the shared spelling of that step and yields
    -- @""@ once there is no dot left, which ends the walk.
    ancestors = takeWhile (not . T.null) . drop 1 . iterate moduleComponent

-- | Does this graph's producer describe argument binders at all — any
-- 'auSyntacticArity', or any 'auBinders' entry?
--
-- A graph capability, not a per-definition fact, and the distinction is
-- load-bearing: the FIRST producer to emit @argUsage@ emitted
-- @{removable, removableRequires, erasable, arity}@ and nothing else, and
-- on such a graph a missing binder entry carries no information. Per
-- definition the two cases are indistinguishable — and a definition whose
-- every reported position is unwritten is exactly the case worth
-- labelling — so the question has to be asked of the whole graph.
-- 'argWritten' is the gate that consumes it.
egDescribesArgBinders :: ExpandedGraph -> Bool
egDescribesArgBinders g =
  any described [ au | d <- egDefinitions g, Just au <- [defArgUsage d] ]
  where
    described au =
      maybe False (const True) (auSyntacticArity au)
        || not (M.null (auBinders au))

-- | One 'egUnsolvedModules' value back in the producer's object shape.
unsolvedModuleJson :: ([Int], [Int]) -> A.Value
unsolvedModuleJson (ms, cs) = A.object [ "metas" A..= ms, "constraints" A..= cs ]

-- | True iff @subtermHashes@ and @subtermDepths@ have a per-def length
-- mismatch somewhere. Used purely as a sanity check on the producer's
-- parallel-array invariant.
lengthMismatch :: [[a]] -> [[b]] -> Bool
lengthMismatch xs ys =
  length xs /= length ys
    || or (zipWith (\a b -> length a /= length b) xs ys)

-- | Read an expanded-mode @graph.json@ from disk. The error case carries
-- a human-readable, ACTIONABLE message (no Haskell exception trace) for a
-- failed read (missing / unreadable file), a non-JSON payload, and a
-- failed decode, so every consumer gets a clean diagnostic instead of an
-- uncaught 'IOException' or a bare aeson token error. The message never
-- includes the path — callers prefix @"<tool>: failed to read <path>: "@.
--
-- The parser's own actionable diagnostics (wrong schema @v@, packed mode,
-- a parallel-array length mismatch) are recognised and passed through
-- verbatim rather than re-wrapped, so a good message is never double-framed.
loadExpandedGraph :: FilePath -> IO (Either String ExpandedGraph)
loadExpandedGraph p = do
  r <- try (BS.readFile p) :: IO (Either IOException BS.ByteString)
  pure $ case r of
    Left e   -> Left (readErr e)
    Right bs
      -- Sniff the first non-whitespace byte: anything but '{' isn't the
      -- JSON object we expect (catches "--graph pointed at an .agda file").
      | Just c <- firstNonWs bs, c /= '{' ->
          Left ("not JSON (starts with " ++ show c ++ "). Expected the expanded \
                \v2 graph.json from `agda-deps --format=json --json-mode=expanded`.")
      | otherwise -> case A.eitherDecodeStrict' bs of
          Right g   -> Right g
          Left err  -> Left (explainDecodeError err)
  where
    readErr :: IOException -> String
    readErr e
      | isDoesNotExistError e =
          "file does not exist. Generate one with `agda-deps --format=json \
          \--json-mode=expanded -i <src> -o <out> <Entry.agda>` (see README \
          \'Producing the input graph'), or point --graph at an existing \
          \expanded deps.json."
      | isPermissionError e = "permission denied (" ++ ioeGetErrorString e ++ ")."
      | otherwise           = "cannot read graph file (" ++ ioeGetErrorString e ++ ")."

    firstNonWs :: BS.ByteString -> Maybe Char
    firstNonWs = fmap fst . BSC.uncons . BSC.dropWhile isSpace

-- | Turn a raw aeson decode error into the user-facing message. The
-- parser's own @fail@ diagnostics (wrong schema @v@, packed mode, a
-- parallel-array length mismatch) are already actionable, so they pass
-- through verbatim; anything else is wrapped with a pointer to the
-- producer command so a bare token error can't strand a new user.
-- Pure + exported so the offline suite can pin both branches byte-for-byte.
explainDecodeError :: String -> String
explainDecodeError err
  | isOwnDiagnostic err = err
  | otherwise =
      "not an expanded v2 graph.json (" ++ err ++ "). Expected the output of \
      \`agda-deps --format=json --json-mode=expanded`."
  where
    -- Stable substrings of our own @fail@ messages (aeson prefixes them
    -- with "Error in $: ").
    isOwnDiagnostic :: String -> Bool
    isOwnDiagnostic s = any (`isInfixOf` s)
      [ "expected schema v:", "--json-mode=", "length (", "inner-array lengths" ]
