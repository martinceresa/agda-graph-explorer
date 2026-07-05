-- | Pure builders for the @IOTCM@ command strings consumed by
-- @agda --interaction-json@ on stdin, one per line.
--
-- The frame is @IOTCM <file> None Direct (<command>)@, where @<file>@
-- and any payload strings are rendered with Haskell 'show' — Agda
-- parses the command with @read@, and 'show'\/@read@ round-trip Unicode
-- via @\\NNN@ decimal escapes, so a goal term containing @λ@ \/ @→@
-- survives intact.
--
-- The constructor names \/ argument shapes here are pinned by the
-- golden fixtures in @test\/interaction\/\<version\>\/@ (see that
-- README). @--interaction-json@ is not officially versioned.
module AgdaGraph.Interaction.Iotcm
  ( Rewrite(..)
  , ComputeMode(..)
  , renderRewrite
  , renderComputeMode
  , iotcmLoad
  , iotcmGoalTypeContext
  , iotcmInfer
  , iotcmCompute
  , iotcmMakeCase
  , iotcmGive
  , iotcmRefineOrIntro
  , iotcmAutoOne
  ) where

import Data.List (intercalate)

-- | How much to normalise a rendered goal\/type. @Simplified@ matches
-- agda-mode's default for goal display.
data Rewrite = AsIs | Instantiated | HeadNormal | Simplified | Normalised
  deriving (Show, Eq)

-- | Compute (normalise) mode for @Cmd_compute@.
data ComputeMode = DefaultCompute | IgnoreAbstract | UseShowInstance
  deriving (Show, Eq)

renderRewrite :: Rewrite -> String
renderRewrite = show

renderComputeMode :: ComputeMode -> String
renderComputeMode = show

-- | Wrap a command body in the IOTCM frame for the given module file.
frame :: FilePath -> String -> String
frame modPath body =
  "IOTCM " ++ show modPath ++ " None Direct (" ++ body ++ ")"

-- | @Cmd_load@. The second argument is a list of bare command-line
-- option tokens — @["-iDIR"]@, a single token per include dir, __not__
-- @["-i","DIR"]@ pairs (the latter yields a quietly-degenerate session
-- that type-checks but emits no @AllGoalsWarnings@).
iotcmLoad :: FilePath -> [FilePath] -> String
iotcmLoad modPath includes =
  frame modPath $
    "Cmd_load " ++ show modPath ++ " " ++ showStringList (map ("-i" ++) includes)

-- | @Cmd_goal_type_context@ — goal type + in-scope context at a hole.
iotcmGoalTypeContext :: FilePath -> Rewrite -> Int -> String
iotcmGoalTypeContext modPath rw iid =
  frame modPath $
    "Cmd_goal_type_context " ++ renderRewrite rw ++ " " ++ show iid ++ " noRange " ++ show ""

-- | @Cmd_infer@ — infer the type of an expression in a hole's context.
iotcmInfer :: FilePath -> Rewrite -> Int -> String -> String
iotcmInfer modPath rw iid expr =
  frame modPath $
    "Cmd_infer " ++ renderRewrite rw ++ " " ++ show iid ++ " noRange " ++ show expr

-- | @Cmd_compute@ — normalise an expression in a hole's context.
iotcmCompute :: FilePath -> ComputeMode -> Int -> String -> String
iotcmCompute modPath cm iid expr =
  frame modPath $
    "Cmd_compute " ++ renderComputeMode cm ++ " " ++ show iid ++ " noRange " ++ show expr

-- | @Cmd_make_case@ — case-split the given (space-separated) variables.
iotcmMakeCase :: FilePath -> Int -> String -> String
iotcmMakeCase modPath iid vars =
  frame modPath $
    "Cmd_make_case " ++ show iid ++ " noRange " ++ show vars

-- | @Cmd_give@ — fill a hole with a term (no force).
iotcmGive :: FilePath -> Int -> String -> String
iotcmGive modPath iid term =
  frame modPath $
    "Cmd_give WithoutForce " ++ show iid ++ " noRange " ++ show term

-- | @Cmd_refine_or_intro@ — refine a hole by a head symbol (or intro
-- when the hint is empty). The 'Bool' is agda's @pmac@ flag (whether to
-- allow pattern-matching lambdas); 'False' matches agda-mode's refine.
iotcmRefineOrIntro :: FilePath -> Int -> String -> String
iotcmRefineOrIntro modPath iid hint =
  frame modPath $
    "Cmd_refine_or_intro False " ++ show iid ++ " noRange " ++ show hint

-- | @Cmd_autoOne@ — Mimer proof search at a goal. Agda 2.9's signature is
-- @Cmd_autoOne Rewrite InteractionId Range String@; the leading 'Rewrite'
-- is required (Agda cannot parse the command without it). The trailing
-- string carries Mimer options (empty = defaults). On success Agda replies
-- with a @GiveAction@ carrying the found term.
iotcmAutoOne :: FilePath -> Rewrite -> Int -> String -> String
iotcmAutoOne modPath rw iid opts =
  frame modPath $
    "Cmd_autoOne " ++ renderRewrite rw ++ " " ++ show iid ++ " noRange " ++ show opts

showStringList :: [String] -> String
showStringList ss = "[" ++ intercalate "," (map show ss) ++ "]"
