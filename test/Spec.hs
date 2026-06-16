{-# LANGUAGE OverloadedStrings #-}
-- | Offline test-suite for the write-side interaction bridge.
--
-- Runs with NO @agda@ binary: pure-logic tests (guard, literate, goal-id
-- reconciliation, source edits) plus fixture-replay tests that parse the
-- committed golden @--interaction-json@ transcripts in
-- @test/interaction/<version>/@. The replay tests are the protocol-skew
-- tripwire — if an Agda bump changes the wire shape, regenerating the
-- fixtures (bash test/interaction/regen.sh) makes these fail until the
-- parser is updated.
--
-- Hand-rolled harness (no tasty/hspec) to keep the dependency set minimal,
-- matching the rest of the repo.
module Main (main) where

import           Control.Monad        ( unless )
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.IORef
import           Data.Maybe           ( mapMaybe )
import           Data.Text            ( Text )
import qualified Data.Text            as T
import           System.Exit          ( exitFailure, exitSuccess )
import           System.IO            ( hPutStrLn, stderr )

import           AgdaGraph.Interaction.Protocol
import qualified AgdaGraph.Interaction.Iotcm as Iotcm
import           AgdaInteract.Guard
import           AgdaInteract.Literate
import           AgdaInteract.GoalId
import           AgdaInteract.Edit

----------------------------------------------------------------------
-- Tiny harness.

type Check = IORef Int -> IO ()

check :: String -> Bool -> Check
check name ok ref = do
  unless ok $ do
    modifyIORef' ref (+ 1)
    hPutStrLn stderr ("FAIL: " ++ name)

checkEq :: (Eq a, Show a) => String -> a -> a -> Check
checkEq name expected actual ref =
  if expected == actual
    then pure ()
    else do
      modifyIORef' ref (+ 1)
      hPutStrLn stderr ("FAIL: " ++ name ++ "\n  expected: " ++ show expected
                          ++ "\n  actual:   " ++ show actual)

main :: IO ()
main = do
  fails <- newIORef (0 :: Int)
  sequence_ (map ($ fails) guardTests)
  sequence_ (map ($ fails) fileGuardTests)
  sequence_ (map ($ fails) literateTests)
  sequence_ (map ($ fails) iotcmTests)
  sequence_ (map ($ fails) goalIdTests)
  sequence_ (map ($ fails) editTests)
  replayTests fails
  n <- readIORef fails
  if n == 0
    then putStrLn "all interaction-bridge tests passed" >> exitSuccess
    else hPutStrLn stderr (show n ++ " test(s) failed") >> exitFailure

----------------------------------------------------------------------
-- Guard.

isRejected :: GuardVerdict -> Bool
isRejected (Rejected _) = True
isRejected Allowed      = False

guardTests :: [Check]
guardTests =
  [ check "guard allows a plain term"        (not (isRejected (checkGiveInput "suc n")))
  , check "guard allows lambda + unicode"    (not (isRejected (checkGiveInput "λ x → f x")))
  , check "guard rejects postulate"          (isRejected (checkGiveInput "postulate bad : A"))
  , check "guard rejects (postulate"         (isRejected (checkGiveInput "(postulate x)"))
  , check "guard rejects TERMINATING pragma" (isRejected (checkGiveInput "{-# TERMINATING #-} f"))
  , check "guard rejects OPTIONS pragma"     (isRejected (checkGiveInput "{-# OPTIONS --type-in-type #-}"))
  , check "guard rejects primTrustMe"        (isRejected (checkGiveInput "primTrustMe"))
  , check "guard rejects unsafeCoerce"       (isRejected (checkGiveInput "unsafeCoerce x"))
  , check "guard ignores postulate in line comment"
      (not (isRejected (checkGiveInput "f -- postulate here is fine\n")))
  , check "guard ignores postulate in block comment"
      (not (isRejected (checkGiveInput "f {- postulate -}")))
  , check "guard catches postulate after a comment"
      (isRejected (checkGiveInput "{- ok -} postulate q : A"))
  , checkEq "stripComments removes block comment" "f  g" (stripComments "f {- x -} g")
  ]

-- | The whole-file guard ('checkFileInput', used by give_file / new_module
-- / promote): unlike 'checkGiveInput' it tolerates benign module pragmas
-- but still rejects the soundness-escaping ones.
fileGuardTests :: [Check]
fileGuardTests =
  [ check "file guard allows a plain module"
      (not (isRejected (checkFileInput "module M where\nfoo : Nat\nfoo = 0\n")))
  , check "file guard allows {-# OPTIONS --safe #-}"
      (not (isRejected (checkFileInput "{-# OPTIONS --safe #-}\nmodule M where\n")))
  , check "file guard allows {-# OPTIONS --without-K #-}"
      (not (isRejected (checkFileInput "{-# OPTIONS --without-K #-}\nmodule M where\n")))
  , check "file guard allows a BUILTIN pragma"
      (not (isRejected (checkFileInput "{-# BUILTIN NATURAL Nat #-}\n")))
  , check "file guard rejects postulate in a module"
      (isRejected (checkFileInput "module M where\npostulate bad : A\n"))
  , check "file guard rejects {-# TERMINATING #-}"
      (isRejected (checkFileInput "{-# TERMINATING #-}\nf = f\n"))
  , check "file guard rejects {-# OPTIONS --type-in-type #-}"
      (isRejected (checkFileInput "{-# OPTIONS --type-in-type #-}\nmodule M where\n"))
  , check "file guard rejects {-# NON_TERMINATING #-}"
      (isRejected (checkFileInput "{-# NON_TERMINATING #-}\nf = f\n"))
  , check "file guard ignores postulate in a line comment"
      (not (isRejected (checkFileInput "module M where\n-- postulate is discussed here\nfoo = 0\n")))
  , check "file guard rejects primTrustMe in a body"
      (isRejected (checkFileInput "module M where\nf = primTrustMe\n"))
  ]

----------------------------------------------------------------------
-- Literate.

literateTests :: [Check]
literateTests =
  [ check "plain .agda: whole file is code"
      (isInsideCode (codeBlocksFor "X.agda" sample) 1)
  , check "isLiterate detects .lagda.md" (isLiterate "Foo.lagda.md")
  , check "isLiterate rejects .agda"     (not (isLiterate "Foo.agda"))
  , check "literate: hole pos 379 is inside code"
      (isInsideCode lit litHolePos)
  , check "literate: prose pos 10 is NOT inside code"
      (not (isInsideCode lit 10))
  ]
  where
    sample = "module X where\nfoo = 1\n"
    -- Mirrors test/interaction/src/Lit.lagda.md: prose, then a fenced
    -- agda block whose `{!!}` hole is at char offset 379 (Agda pos).
    lit = scanCodeBlocks litFixture
    litHolePos = 379

----------------------------------------------------------------------
-- Iotcm builders.

iotcmTests :: [Check]
iotcmTests =
  [ checkEq "load with no includes"
      "IOTCM \"F.agda\" None Direct (Cmd_load \"F.agda\" [])"
      (Iotcm.iotcmLoad "F.agda" [])
  , checkEq "load preserves -iDIR single tokens (not -i DIR pairs)"
      "IOTCM \"F.agda\" None Direct (Cmd_load \"F.agda\" [\"-isrc\",\"-ilib\"])"
      (Iotcm.iotcmLoad "F.agda" ["src", "lib"])
  , checkEq "give frames WithoutForce + shown term"
      "IOTCM \"F.agda\" None Direct (Cmd_give WithoutForce 0 noRange \"suc n\")"
      (Iotcm.iotcmGive "F.agda" 0 "suc n")
  , checkEq "make_case frames vars"
      "IOTCM \"F.agda\" None Direct (Cmd_make_case 2 noRange \"n\")"
      (Iotcm.iotcmMakeCase "F.agda" 2 "n")
  , check "give shows unicode via escapes (read round-trips)"
      ("\\955" `T.isInfixOf` T.pack (Iotcm.iotcmGive "F.agda" 0 "λ x → x"))
  ]

----------------------------------------------------------------------
-- Fixture replay — the protocol-skew tripwire.

fixtureDir :: FilePath
fixtureDir = "test/interaction/2.9.0/"

parseLines :: FilePath -> IO [Reply]
parseLines fp = do
  bs <- BL.readFile fp
  pure (mapMaybe ok (BLC.lines bs))
  where
    ok l = case parseReply l of
             Right (Just r) -> Just r
             _              -> Nothing

replayTests :: IORef Int -> IO ()
replayTests ref = do
  -- load.jsonl: AllGoalsWarnings with 4 goals, ids 0..3; + InteractionPoints
  loadRs <- parseLines (fixtureDir ++ "load.jsonl")
  check "load.jsonl: 4 visible goals with ids 0..3"
    (case [g | ReplyDisplayInfo (AllGoalsWarnings g _ _) <- loadRs] of
       (gs:_) -> map goalId gs == [Just 0, Just 1, Just 2, Just 3]
                   && map goalType gs == ["Nat","Nat","Nat","A"]
       _      -> False) ref
  check "load.jsonl: InteractionPoints lists ids 0..3"
    (case [ips | ReplyInteractionPoints ips <- loadRs] of
       (ips:_) -> map ipId ips == [0,1,2,3]
       _       -> False) ref

  -- give.jsonl → GiveAction id 0, paren False
  giveRs <- parseLines (fixtureDir ++ "give.jsonl")
  check "give.jsonl: GiveParen False at id 0"
    ([0 :: Int] == [iid | ReplyGiveAction iid (GiveParen False) <- giveRs]) ref
  check "give.jsonl: exactly one GiveAction"
    (length [() | ReplyGiveAction{} <- giveRs] == 1) ref

  -- refine.jsonl → GiveAction id 0 with str "suc ?"
  refineRs <- parseLines (fixtureDir ++ "refine.jsonl")
  check "refine.jsonl: GiveStr \"suc ?\" at id 0"
    (case [s | ReplyGiveAction 0 (GiveStr s) <- refineRs] of
       (s:_) -> s == "suc ?"
       _     -> False) ref

  -- make-case.jsonl → MakeCase id 0, Function, 2 clauses
  mcRs <- parseLines (fixtureDir ++ "make-case.jsonl")
  check "make-case.jsonl: 2 Function clauses at id 0"
    (case [(v, cs) | ReplyMakeCase 0 v cs <- mcRs] of
       ((v, cs):_) -> v == MCFunction
                        && cs == ["double zero = ?", "double (suc n) = ?"]
       _           -> False) ref

  -- goal-type-context.jsonl → GoalSpecific GiGoalType "Nat" [ctx n]
  gtcRs <- parseLines (fixtureDir ++ "goal-type-context.jsonl")
  check "goal-type-context.jsonl: GoalType Nat with binder n:Nat"
    (case [ (ty, ctx) | ReplyDisplayInfo (GoalSpecific _ (GiGoalType ty ctx)) <- gtcRs ] of
       ((ty, ctx):_) -> ty == "Nat"
                          && map ceName ctx == ["n"]
                          && map ceType ctx == ["Nat"]
       _             -> False) ref

  -- infer.jsonl → InferredType "Nat"
  inferRs <- parseLines (fixtureDir ++ "infer.jsonl")
  check "infer.jsonl: InferredType Nat"
    (not (null [ () | ReplyDisplayInfo (GoalSpecific _ (GiInferredType "Nat")) <- inferRs ])) ref

  -- compute.jsonl → NormalForm "2"
  computeRs <- parseLines (fixtureDir ++ "compute.jsonl")
  check "compute.jsonl: NormalForm 2"
    (not (null [ () | ReplyDisplayInfo (GoalSpecific _ (GiNormalForm "2")) <- computeRs ])) ref

  -- give-error.jsonl → ErrorReply mentioning UnequalTypes
  errRs <- parseLines (fixtureDir ++ "give-error.jsonl")
  check "give-error.jsonl: ErrorReply carries the localized message"
    (case [m | ReplyDisplayInfo (ErrorReply m) <- errRs] of
       (m:_) -> "UnequalTypes" `T.isInfixOf` m
       _     -> False) ref

  -- session-readonly.txt: prompt-delimited burst splitting
  sess <- BL.readFile (fixtureDir ++ "session-readonly.txt")
  let bursts = splitBursts sess
  check "session-readonly.txt: 4 prompt-delimited command bursts"
    (length bursts == 4) ref
  check "session-readonly.txt: burst 1 carries AllGoalsWarnings"
    (case bursts of
       (b:_) -> not (null [ () | ReplyDisplayInfo AllGoalsWarnings{} <- b ])
       _     -> False) ref

-- | Mirror of the session reader's prompt-delimited burst splitter
-- (kept independent here so the test pins the wire behaviour, not the
-- production code's behaviour). The @JSON> @ readiness prompt is printed
-- without a trailing newline, so it is glued to the FIRST reply of the
-- next burst on the same physical line. The boundary is therefore the
-- presence of the prompt /prefix/ on a line, not an empty line. Empty
-- bursts (the trailing bare prompt) are dropped.
splitBursts :: BL.ByteString -> [[Reply]]
splitBursts raw = filter (not . null) (map (mapMaybe parse) (group (BLC.lines raw)))
  where
    hasPrompt l = BL.length (stripPromptPrefix l) < BL.length l
    group = goGrp [] []
    goGrp cur done [] = reverse (addCur cur done)
    goGrp cur done (l:ls)
      | hasPrompt l = goGrp [l] (addCur cur done) ls
      | otherwise   = goGrp (cur ++ [l]) done ls
    addCur cur done = if null cur then done else cur : done
    parse l = case parseReply l of { Right (Just r) -> Just r; _ -> Nothing }

----------------------------------------------------------------------
-- GoalId reconciliation.

mkGoal :: Int -> Int -> Text -> Goal
mkGoal iid pos ty =
  Goal { goalType = ty
       , goalRange = Just (GoalRange (RangePos 1 1 pos) (RangePos 1 5 (pos + 4)))
       , goalKind = "OfType"
       , goalId = Just iid }

goalIdTests :: [Check]
goalIdTests =
  [ check "first sight assigns g0,g1 and maps to agda ids"
      (let (gm, es) = syncGoals emptyGoalMap [mkGoal 0 81 "Nat", mkGoal 1 127 "Nat"]
       in map geStable es == [StableId 0, StableId 1]
            && toInteractionId gm (StableId 0) == Just 0
            && toInteractionId gm (StableId 1) == Just 1)
  , check "reload renumbers agda ids but keeps stable ids by offset"
      (let (gm0, _) = syncGoals emptyGoalMap [mkGoal 0 81 "Nat", mkGoal 1 127 "Nat"]
           -- after an edit, agda reissues the same holes with swapped ids
           (gm1, _) = syncGoals gm0 [mkGoal 5 127 "Nat", mkGoal 7 81 "Nat"]
       in toInteractionId gm1 (StableId 0) == Just 7   -- offset 81 kept g0
            && toInteractionId gm1 (StableId 1) == Just 5)
  , check "a brand-new hole offset gets a fresh stable id"
      (let (gm0, _) = syncGoals emptyGoalMap [mkGoal 0 81 "Nat"]
           (gm1, es) = syncGoals gm0 [mkGoal 0 81 "Nat", mkGoal 1 200 "Nat"]
       in length es == 2
            && toInteractionId gm1 (StableId 1) == Just 1
            && maximum [ s | StableId s <- map geStable es ] == 1)
  ]

----------------------------------------------------------------------
-- Source edits (splice + unified diff).

editTests :: [Check]
editTests =
  [ checkEq "spliceRange replaces the hole marker"
      "double n = suc m\n"
      (spliceRange "double n = {!!}\n" 12 16 "suc m")
  , check "renderClausesAt indents continuation clauses to the first column"
      (let out = renderClausesAt 1 ["double zero = ?", "double (suc n) = ?"]
       in out == "double zero = ?\ndouble (suc n) = ?")
  , check "unifiedDiff marks the changed line"
      (let d = unifiedDiff "A.agda" "f = {!!}\n" "f = zero\n"
       in ("-f = {!!}" `T.isInfixOf` T.pack d) && ("+f = zero" `T.isInfixOf` T.pack d))
  , checkEq "lineSpanAt finds the line containing a pos"
      (7, 15)
      (lineSpanAt "f = 1\ng = {!!}\nh = 2\n" 10)
  ]

----------------------------------------------------------------------
-- The literate fixture text (kept in-source so the test is hermetic and
-- does not depend on reading test/interaction/src/Lit.lagda.md).

litFixture :: Text
litFixture = T.unlines
  [ "# Literate interaction fixture"
  , ""
  , "This prose precedes the code block. It exists to push the code well past"
  , "byte offset zero, so a fixture can confirm whether Agda reports interaction"
  , "ranges as offsets into the **full literate file** (prose included) or into"
  , "the concatenated code blocks only."
  , ""
  , "```agda"
  , "module Lit where"
  , ""
  , "open import Agda.Builtin.Nat"
  , ""
  , "triple : Nat → Nat"
  , "triple n = {!!}"
  , "```"
  , ""
  , "More prose after the block."
  ]
