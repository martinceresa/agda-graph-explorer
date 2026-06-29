{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
-- | Declarative per-flag specifications for the @agda-optimization@
-- subcommands.
--
-- Each subcommand declares one list of 'FlagSpec' values; three
-- interpreters derive the argv fold, the YAML overlay, and the help block
-- from that single list, so a flag is described in exactly one place:
--
--   * 'parseFlags'      — the argv fold (@--flag=val@ / @--flag val@,
--     switch handling, enum validation, error wording; reuses
--     "AgdaOptimization.CLIParse").
--   * 'applyFlagConfig' — the YAML overlay (reuses
--     "AgdaOptimization.Config" lookups, honouring the nested
--     per-subcommand section).
--   * 'renderFlagHelp'  — the help lines for 'AgdaOptimization.CLI.subFlags'.
--
-- The 'FlagSpec' type is parameterised over a subcommand's @Options@
-- record @o@: each value-taking constructor carries a SETTER that folds
-- the parsed value into @o@.
module AgdaOptimization.FlagSpec
  ( -- * Spec type
    FlagSpec(..)
  , EnumErr(..)
  , SwitchVal(..)
    -- * Spec accessors
  , flagName
  , flagHelp
    -- * Interpreters
  , parseFlags
  , applyFlagConfig
  , renderFlagHelp
  ) where

import           Data.Text                 ( Text )
import qualified Data.Text                 as T
import qualified Data.Aeson                as A

import           AgdaOptimization.CLIParse ( splitFlag, valueFor, readInt, readDbl )
import           AgdaOptimization.Config   ( lookupKey, lookupKeyEnum
                                           , lookupKeyTextList )

----------------------------------------------------------------------
-- Spec type
----------------------------------------------------------------------

-- | How a value-taking enum flag wraps a rejected token on the /argv/
-- side. (The YAML-overlay side is uniform — see 'applyFlagConfig'.)
--
--   * 'EnumVerbatim' — the parser's @Left@ is returned untouched
--     (the @enumK@ used by load-bearing\/gravity\/chokepoint\/
--     fingerprint\/horizon). The parser itself bakes in whatever
--     prefix it wants (fingerprint's @readDirection@ embeds
--     @"fingerprint: --direction: …"@; the others emit a bare
--     @"expected one of …"@).
--   * 'EnumWrapped' — the parser's @Left@ @e@ becomes
--     @sub <> ": " <> flag <> ": " <> e@ (ledger's @--axiom-source@
--     and term-cluster's @--sort@).
data EnumErr = EnumVerbatim | EnumWrapped
  deriving (Eq, Show)

-- | How a bare (no-value) switch treats an attached @=value@ on the
-- argv side. The three spellings mirror the three behaviours found
-- across the analyses; YAML overlay is uniform regardless.
--
--   * 'SwitchPreGuard' — matched by an exact-string guard BEFORE
--     'splitFlag', so @--flag=x@ never matches and falls through to the
--     normal unknown-flag path (motif @--per-module@, debt's toggles,
--     ledger @--no-foundational@, entwine @--transitive@, horizon
--     @--no-module-hist@).
--   * 'SwitchIgnoreValue' — matched after 'splitFlag' with the value
--     slot ignored, so @--flag=x@ still sets the switch (basket\/
--     concept-bundle @--forced-suppress@\/@--no-forced-suppress@, pyre
--     @--calibrate@\/@--levers@).
--   * 'SwitchRejectValue' — matched after 'splitFlag'; an attached
--     value is a hard error @sub <> ": " <> flag <> " does not take a value"@
--     (echo @--delta-only@).
data SwitchVal = SwitchPreGuard | SwitchIgnoreValue | SwitchRejectValue
  deriving (Eq, Show)

-- | A single flag specification for a subcommand whose options record
-- is @o@.
--
-- In every constructor the first 'String' is the flag name WITHOUT the
-- leading @--@ (e.g. @"min-support"@) and the second is the VERBATIM
-- help line as it appears in 'AgdaOptimization.CLI.subFlags' (already
-- stripped of its leading two-space indent, which @subUsage@ re-adds).
--
-- The flag name doubles as the YAML key for the config overlay (matching
-- the kebab-case-minus-dashes convention), except where a constructor
-- carries an explicit key (see 'SwitchFlag').
data FlagSpec o
  = -- | A bare boolean switch. Fields:
    --
    --   * flag name (no dashes),
    --   * help line,
    --   * 'SwitchVal' — attached-value handling on argv,
    --   * argv setter @o -> o@ (the switch's effect when seen),
    --   * YAML key (no dashes) for the overlay, or 'Nothing' to take no
    --     part in config (used for the secondary spelling of a toggle
    --     pair, so the shared key is applied exactly once),
    --   * YAML setter @Bool -> o -> o@.
    SwitchFlag   String String SwitchVal (o -> o)
                 (Maybe Text) (Bool -> o -> o)
  | -- | An @Int@-valued flag: name, help, setter.
    IntFlag      String String (Int -> o -> o)
  | -- | A @Double@-valued flag: name, help, setter.
    DblFlag      String String (Double -> o -> o)
  | -- | A 'Text'-valued flag (value is @T.pack@-ed): name, help, setter.
    TextFlag     String String (Text -> o -> o)
  | -- | A 'String'/'FilePath'-valued flag (value passed raw): name,
    -- help, setter. YAML decodes the key as a 'FilePath'.
    StrFlag      String String (String -> o -> o)
  | -- | A repeatable 'Text' flag. The two list semantics differ between
    -- the two sides, so the spec carries both setters:
    --
    --   * the ARGV setter @Text -> o -> o@ runs once per occurrence and
    --     APPENDS to the list field (matching ledger's
    --     @optTheoremPrefixes o' ++ [tv]@);
    --   * the CONFIG setter @[Text] -> o -> o@ runs once with the whole
    --     list read via 'lookupKeyTextList' and REPLACES the field
    --     (matching ledger's @optTheoremPrefixes = v@; since config runs
    --     on @defaultOptions@ the field is empty so replace == append).
    --
    -- Fields: name, help, argv-append setter, config-replace setter.
    TextListFlag String String (Text -> o -> o) ([Text] -> o -> o)
  | -- | A validated enum flag. Fields: name, help, the existing parser
    -- closure @String -> Either String a@, the 'EnumErr' argv-wrapping
    -- mode, and the setter @a -> o -> o@.
    forall a. EnumFlag String String (String -> Either String a)
                       EnumErr (a -> o -> o)

----------------------------------------------------------------------
-- Accessors
----------------------------------------------------------------------

-- | The flag's name without the leading @--@.
flagName :: FlagSpec o -> String
flagName (SwitchFlag n _ _ _ _ _) = n
flagName (IntFlag      n _ _)     = n
flagName (DblFlag      n _ _)     = n
flagName (TextFlag     n _ _)     = n
flagName (StrFlag      n _ _)     = n
flagName (TextListFlag n _ _ _)   = n
flagName (EnumFlag     n _ _ _ _) = n

-- | The flag's verbatim help line (no leading indent).
flagHelp :: FlagSpec o -> String
flagHelp (SwitchFlag _ h _ _ _ _) = h
flagHelp (IntFlag      _ h _)     = h
flagHelp (DblFlag      _ h _)     = h
flagHelp (TextFlag     _ h _)     = h
flagHelp (StrFlag      _ h _)     = h
flagHelp (TextListFlag _ h _ _)   = h
flagHelp (EnumFlag     _ h _ _ _) = h

----------------------------------------------------------------------
-- argv interpreter
----------------------------------------------------------------------

-- | Fold the argv over a spec list, reproducing the hand-rolled
-- per-module 'parseOptions' exactly.
--
-- @sub@ is the subcommand name (used in error wording, matching the
-- @sub = "motif"@ etc. constants). The fold is strict in the
-- accumulator, mirroring @go !o@.
--
-- Dispatch order mirrors the modules: 'SwitchPreGuard' switches are
-- matched against the raw token /before/ 'splitFlag', everything else
-- after. The @"--"@ name shape is @"--" <> flagName@.
parseFlags :: forall o. String -> [FlagSpec o] -> o -> [String] -> Either String o
parseFlags sub specs = go
  where
    -- Pre-guard switches: { rawToken -> setter }.
    preGuards =
      [ ("--" <> n, set)
      | SwitchFlag n _ SwitchPreGuard set _ _ <- specs ]

    go :: o -> [String] -> Either String o
    go !o []     = Right o
    go !o (a:as)
      | Just set <- lookup a preGuards = go (set o) as
      | otherwise = case splitFlag a of
          Left err   -> Left (sub <> ": " <> err)
          Right (k, mv) -> dispatch o k mv as

    dispatch o k mv as =
      case lookup k named of
        Just step -> step o mv as
        Nothing   -> Left (sub <> ": unknown flag: " <> k)

    -- All flags addressable after 'splitFlag', keyed by their @--name@.
    -- Pre-guard switches are NOT included here, so e.g. @--per-module=x@
    -- correctly falls through to the unknown-flag arm (its only entry is
    -- the raw exact-string guard above).
    named = concatMap entry specs

    entry :: FlagSpec o -> [(String, o -> Maybe String -> [String] -> Either String o)]
    entry (SwitchFlag _ _ SwitchPreGuard _ _ _) = []
    entry (SwitchFlag n _ SwitchIgnoreValue set _ _) =
      [ ("--" <> n, \o _mv as -> go (set o) as) ]
    entry (SwitchFlag n _ SwitchRejectValue set _ _) =
      let flag = "--" <> n
      in [ (flag, \o mv as -> case mv of
              Nothing -> go (set o) as
              Just _  -> Left (sub <> ": " <> flag <> " does not take a value")) ]
    entry (IntFlag n _ set) =
      let flag = "--" <> n
      in [ (flag, \o mv as -> do
              (v, rest) <- valueFor sub flag mv as
              x <- readInt sub flag v
              go (set x o) rest) ]
    entry (DblFlag n _ set) =
      let flag = "--" <> n
      in [ (flag, \o mv as -> do
              (v, rest) <- valueFor sub flag mv as
              x <- readDbl sub flag v
              go (set x o) rest) ]
    entry (TextFlag n _ set) =
      let flag = "--" <> n
      in [ (flag, \o mv as -> do
              (v, rest) <- valueFor sub flag mv as
              go (set (T.pack v) o) rest) ]
    entry (StrFlag n _ set) =
      let flag = "--" <> n
      in [ (flag, \o mv as -> do
              (v, rest) <- valueFor sub flag mv as
              go (set v o) rest) ]
    entry (TextListFlag n _ appendSet _) =
      let flag = "--" <> n
      in [ (flag, \o mv as -> do
              (v, rest) <- valueFor sub flag mv as
              go (appendSet (T.pack v) o) rest) ]
    entry (EnumFlag n _ parseEnum eerr set) =
      let flag = "--" <> n
      in [ (flag, \o mv as -> do
              (v, rest) <- valueFor sub flag mv as
              r <- case parseEnum v of
                     Right a -> Right a
                     Left e  -> case eerr of
                       EnumVerbatim -> Left e
                       EnumWrapped  -> Left (sub <> ": " <> flag <> ": " <> e)
              go (set r o) rest) ]

----------------------------------------------------------------------
-- YAML overlay interpreter
----------------------------------------------------------------------

-- | Overlay a YAML section over a seed @o@, reproducing each module's
-- hand-rolled 'applyConfig' exactly. @section@ is the kebab-case
-- subcommand name (matching the @section = "motif"@ etc. constants).
--
-- Specs are applied left-to-right (the same order the modules thread
-- @o0 -> o1 -> …@). Each value-typed flag uses the matching
-- "AgdaOptimization.Config" lookup so JSON-type errors carry the
-- identical @section.key: …@ wording. Enum keys go through
-- 'lookupKeyEnum'. A 'SwitchFlag' whose config-key field is 'Nothing'
-- contributes nothing here.
applyFlagConfig :: forall o. String -> [FlagSpec o] -> A.Object -> o -> Either String o
applyFlagConfig section specs obj = go specs
  where
    go []     o = Right o
    go (s:ss) o = step s o >>= go ss

    step :: FlagSpec o -> o -> Either String o
    step (SwitchFlag _ _ _ _ Nothing _) o = Right o
    step (SwitchFlag _ _ _ _ (Just key) set) o = do
      mv <- lookupKey section obj key :: Either String (Maybe Bool)
      pure $ maybe o (`set` o) mv
    step (IntFlag n _ set) o = do
      mv <- lookupKey section obj (T.pack n) :: Either String (Maybe Int)
      pure $ maybe o (`set` o) mv
    step (DblFlag n _ set) o = do
      mv <- lookupKey section obj (T.pack n) :: Either String (Maybe Double)
      pure $ maybe o (`set` o) mv
    step (TextFlag n _ set) o = do
      mv <- lookupKey section obj (T.pack n) :: Either String (Maybe Text)
      pure $ maybe o (`set` o) mv
    step (StrFlag n _ set) o = do
      mv <- lookupKey section obj (T.pack n) :: Either String (Maybe FilePath)
      pure $ maybe o (`set` o) mv
    step (TextListFlag n _ _ replaceSet) o = do
      mv <- lookupKeyTextList section obj (T.pack n)
      pure $ maybe o (`replaceSet` o) mv
    step (EnumFlag n _ parseEnum _ set) o = do
      mv <- lookupKeyEnum section obj (T.pack n) parseEnum
      pure $ maybe o (`set` o) mv

----------------------------------------------------------------------
-- Help rendering
----------------------------------------------------------------------

-- | The verbatim help lines for a spec list, in declaration order — the
-- exact strings 'AgdaOptimization.CLI.subFlags' currently returns for
-- the subcommand. ('subUsage' re-adds the two-space indent.)
renderFlagHelp :: [FlagSpec o] -> [String]
renderFlagHelp = map flagHelp
