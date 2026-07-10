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

import qualified Data.Set             as Set
import           AgdaGraph.Interaction.Protocol
import qualified AgdaGraph.Interaction.Iotcm as Iotcm
import           AgdaGraph.GoalCanon   ( matchTokens, nameTokens, shapeTokens
                                       , weightedCoverage, stripQualifiers )
import           AgdaGraph.LemmaRank   ( RankEnv(..), rankLemmaCandidates
                                       , goalCarrierSegments, moduleSegments )
import           AgdaInteract.Guard
import           AgdaInteract.Literate
import           AgdaInteract.GoalId
import           AgdaInteract.Edit
import qualified AgdaRepair.Diagnostic as RD
import qualified AgdaRepair.Edit       as RE
import           Data.Aeson            ( eitherDecode )
import qualified Data.Map.Strict       as Map
import           AgdaGraph.Schema      ( ExpandedGraph(..), Definition(..), ReExport(..)
                                       , State(..), Kind(..), Access(..) )
import           AgdaGraph.Index       ( buildIndex, lookupId, unsafeDeps, defAt )
import           AgdaUnused.Analysis   ( Finding(..), FindingKind(..), analyse )

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
  sequence_ (map ($ fails) diagnosticTests)
  sequence_ (map ($ fails) repairEditTests)
  sequence_ (map ($ fails) goalCanonTests)
  sequence_ (map ($ fails) unusedDeadTests)
  sequence_ (map ($ fails) schemaFieldTests)
  sequence_ (map ($ fails) taintTests)
  sequence_ (map ($ fails) lemmaRankTests)
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
-- GoalCanon: find_lemma match-oriented tokens + algebraic shape.

goalCanonTests :: [Check]
goalCanonTests =
  -- matchTokens: qualifier-strip to last component; keep a lowercase head
  -- symbol only when the vocab predicate accepts it; drop bound vars.
  [ checkEq "matchTokens keeps in-vocab head symbols, drops bound vars + qualifiers"
      (Set.fromList ["length", "map", "≡"])
      (matchTokens (`elem` (["map", "length"] :: [Text]))
        "Data.List.length (Data.List.map f xs) \
        \Relation.Binary.PropositionalEquality.≡ Data.List.length xs")
  , checkEq "matchTokens reduces combinator sig to {combinator, ≡, +}"
      (Set.fromList ["RightIdentity", "≡", "+"])
      (matchTokens (const False)
        "Algebra.Definitions.RightIdentity \
        \Relation.Binary.PropositionalEquality._≡_ 0 Data.Nat._+_")

  -- nameTokens: split the base name on the stdlib '-' separator.
  , checkEq "nameTokens +-comm"    (Set.fromList ["+", "comm"])
      (nameTokens "Data.Nat.Properties.+-comm")
  , checkEq "nameTokens length-map" (Set.fromList ["length", "map"])
      (nameTokens "Data.List.Properties.length-map")

  -- shapeTokens: recognise the algebraic property named by the goal shape.
  , checkEq "shape: a+b ≡ b+a is Commutative" (Set.fromList ["Commutative"])
      (shapeTokens "m + n ≡ n + m")
  , checkEq "shape: (a+b)+c ≡ a+(b+c) is Associative" (Set.fromList ["Associative"])
      (shapeTokens "(m + n) + p ≡ m + (n + p)")
  , checkEq "shape: x+0 ≡ x is an Identity" (Set.fromList ["Identity", "RightIdentity", "LeftIdentity"])
      (shapeTokens "n + 0 ≡ n")
  , checkEq "shape: xs++[] ≡ xs is an Identity (empty-list literal)"
      (Set.fromList ["Identity", "RightIdentity", "LeftIdentity"])
      (shapeTokens "xs ++ [] ≡ xs")
  , checkEq "shape: f (f x) ≡ x is Involutive" (Set.fromList ["Involutive"])
      (shapeTokens "reverse (reverse xs) ≡ xs")
  , checkEq "shape: R x x is Reflexive" (Set.fromList ["Reflexive"])
      (shapeTokens "n ≤ n")
  , checkEq "shape: no shape for a concrete congruence (length-++)" Set.empty
      (shapeTokens "length (xs ++ ys) ≡ length xs + length ys")
  , checkEq "shape: no shape for a concrete congruence (map-++)" Set.empty
      (shapeTokens "map f (xs ++ ys) ≡ map f xs ++ map f ys")

  -- stripQualifiers: display-only module-qualifier stripping.
  , checkEq "stripQualifiers: combinator + qualified operators"
      "RightIdentity _≡_ (+ 0) _+_"
      (stripQualifiers "Algebra.Definitions.RightIdentity \
                        \Relation.Binary.PropositionalEquality._≡_ \
                        \(Data.Integer.+ 0) Data.Integer._+_")
  , checkEq "stripQualifiers: unqualified passes through" "n + zero ≡ n"
      (stripQualifiers "n + zero ≡ n")

  -- weightedCoverage: fraction of goal tokens covered, operators doubled.
  , checkEq "coverage: full cover = 1.0" (1.0 :: Double)
      (weightedCoverage (Set.fromList ["+", "≡"]) (Set.fromList ["+", "≡", "RightIdentity"]))
  , checkEq "coverage: one of two operators = 0.5" (0.5 :: Double)
      (weightedCoverage (Set.fromList ["+", "≡"]) (Set.fromList ["+"]))
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
-- agda-unused: the dead-definition check must not count a def's own
-- recursive call as a caller (I5 self-recursion), nor treat a
-- mutual-recursion cycle whose only callers are its own members as
-- live (I5 dead-cycle half), while a real *external* intra-module or
-- cross-module caller still keeps the defs off the dead list.

unusedGraphJson :: BL.ByteString
unusedGraphJson = BLC.pack $ unlines
  [ "{ \"v\": 2, \"mode\": \"expanded\", \"schemaVersion\": 2"
  , ", \"modules\": [\"Deadwood\"]"
  , ", \"moduleFiles\": { \"Deadwood\": \"/t/Deadwood.agda\" }"
  , ", \"definitions\":"
  , "  [ { \"name\": \"Deadwood.deadA\",  \"module\": \"Deadwood\", \"kind\": \"function\", \"state\": \"D\" }"
  , "  , { \"name\": \"Deadwood.deadC\",  \"module\": \"Deadwood\", \"kind\": \"function\", \"state\": \"D\" }"
  , "  , { \"name\": \"Deadwood.helper\", \"module\": \"Deadwood\", \"kind\": \"function\", \"state\": \"D\" }"
  , "  , { \"name\": \"Deadwood.busy\",   \"module\": \"Deadwood\", \"kind\": \"function\", \"state\": \"D\" }"
  , "  , { \"name\": \"Deadwood.caller\", \"module\": \"Deadwood\", \"kind\": \"function\", \"state\": \"D\" }"
  , "  ]"
  , ", \"definitionEdges\":"
  , "  [ [\"Deadwood.deadC\",  \"Deadwood.deadC\"]"
  , "  , [\"Deadwood.busy\",   \"Deadwood.busy\"]"
  , "  , [\"Deadwood.caller\", \"Deadwood.helper\"]"
  , "  , [\"Deadwood.caller\", \"Deadwood.busy\"]"
  , "  ]"
  , "}"
  ]

unusedSrc :: Text
unusedSrc = T.unlines
  [ "module Deadwood where"
  , ""
  , "deadA : Nat"
  , "deadA = zero"
  , ""
  , "deadC : Nat -> Nat"
  , "deadC zero = zero"
  , "deadC (suc n) = deadC n"
  , ""
  , "helper : Nat"
  , "helper = zero"
  , ""
  , "busy : Nat -> Nat"
  , "busy zero = zero"
  , "busy (suc n) = busy n"
  , ""
  , "caller : Nat"
  , "caller = helper + busy zero"
  ]

-- | A ↔ B mutual recursion with NO external entry: both are dead as a
-- unit, but each is the other's intra-module caller — the case the
-- self-recursion fix does not cover.
cycleDeadJson :: BL.ByteString
cycleDeadJson = BLC.pack $ unlines
  [ "{ \"v\": 2, \"mode\": \"expanded\", \"schemaVersion\": 2"
  , ", \"modules\": [\"Cyc\"]"
  , ", \"moduleFiles\": { \"Cyc\": \"/t/Cyc.agda\" }"
  , ", \"definitions\":"
  , "  [ { \"name\": \"Cyc.cycA\", \"module\": \"Cyc\", \"kind\": \"function\", \"state\": \"D\" }"
  , "  , { \"name\": \"Cyc.cycB\", \"module\": \"Cyc\", \"kind\": \"function\", \"state\": \"D\" }"
  , "  ]"
  , ", \"definitionEdges\":"
  , "  [ [\"Cyc.cycA\", \"Cyc.cycB\"]"
  , "  , [\"Cyc.cycB\", \"Cyc.cycA\"]"
  , "  ]"
  , "}"
  ]

cycleSrc :: Text
cycleSrc = T.unlines
  [ "module Cyc where"
  , ""
  , "cycA : Nat -> Nat"
  , "cycA zero = zero"
  , "cycA (suc n) = cycB n"
  , ""
  , "cycB : Nat -> Nat"
  , "cycB zero = zero"
  , "cycB (suc n) = cycA n"
  ]

-- | The same A ↔ B cycle PLUS a cross-module caller of A. Now the cycle
-- is reachable from outside, so neither member is dead: A has a real
-- user, B stays internal-only (reachable only via A).
cycleLiveJson :: BL.ByteString
cycleLiveJson = BLC.pack $ unlines
  [ "{ \"v\": 2, \"mode\": \"expanded\", \"schemaVersion\": 2"
  , ", \"modules\": [\"Cyc\", \"Client\"]"
  , ", \"moduleFiles\": { \"Cyc\": \"/t/Cyc.agda\", \"Client\": \"/t/Client.agda\" }"
  , ", \"definitions\":"
  , "  [ { \"name\": \"Cyc.cycA\",     \"module\": \"Cyc\",    \"kind\": \"function\", \"state\": \"D\" }"
  , "  , { \"name\": \"Cyc.cycB\",     \"module\": \"Cyc\",    \"kind\": \"function\", \"state\": \"D\" }"
  , "  , { \"name\": \"Client.use\",   \"module\": \"Client\", \"kind\": \"function\", \"state\": \"D\" }"
  , "  ]"
  , ", \"definitionEdges\":"
  , "  [ [\"Cyc.cycA\",   \"Cyc.cycB\"]"
  , "  , [\"Cyc.cycB\",   \"Cyc.cycA\"]"
  , "  , [\"Client.use\", \"Cyc.cycA\"]"
  , "  ]"
  , "}"
  ]

cycleClientSrc :: Text
cycleClientSrc = T.unlines
  [ "module Client where"
  , ""
  , "open import Cyc"
  , ""
  , "use : Nat -> Nat"
  , "use n = cycA n"
  ]

-- | Decode a fixture graph and hand the resulting findings to the
-- assertion builder; a decode failure surfaces as a single failing
-- check.
fixtureChecks
  :: BL.ByteString -> [(FilePath, Text)] -> ([Finding] -> [Check]) -> [Check]
fixtureChecks json files asserts =
  case eitherDecode json :: Either String ExpandedGraph of
    Left err -> [ check ("unused fixture graph decodes: " ++ err) False ]
    Right g  -> asserts (analyse g files)

unusedDeadTests :: [Check]
unusedDeadTests = concat
  [ fixtureChecks unusedGraphJson [("/t/Deadwood.agda", unusedSrc)] $ \findings ->
      let kindOf sh = [ kindFinding f | f <- findings, symbolFinding f == Just sh ]
          noteOf sh = [ n | f <- findings, symbolFinding f == Just sh
                          , Just n <- [noteFinding f] ]
      in
      [ checkEq "self-recursive def with no other callers is dead"
          [DefinedDead] (kindOf "deadC")
      , check "dead recursive note says so"
          (any ("recursive" `T.isInfixOf`) (noteOf "deadC"))
      , checkEq "plain dead def still dead" [DefinedDead] (kindOf "deadA")
      , checkEq "self-recursion plus a real intra caller stays internal-only"
          [DefinedInternalOnly] (kindOf "busy")
      , checkEq "intra-module-called def stays internal-only"
          [DefinedInternalOnly] (kindOf "helper")
      ]

  , fixtureChecks cycleDeadJson [("/t/Cyc.agda", cycleSrc)] $ \findings ->
      let kindOf sh = [ kindFinding f | f <- findings, symbolFinding f == Just sh ]
          noteOf sh = [ n | f <- findings, symbolFinding f == Just sh
                          , Just n <- [noteFinding f] ]
      in
      [ checkEq "dead mutual cycle: cycA is dead" [DefinedDead] (kindOf "cycA")
      , checkEq "dead mutual cycle: cycB is dead" [DefinedDead] (kindOf "cycB")
      , check "dead-cycle note says so and names the peer"
          (any (\n -> "dead cycle" `T.isInfixOf` n && "cycB" `T.isInfixOf` n)
               (noteOf "cycA"))
      , check "dead-cycle note names the peer for cycB too"
          (any ("cycA" `T.isInfixOf`) (noteOf "cycB"))
      ]

  , fixtureChecks cycleLiveJson
      [("/t/Cyc.agda", cycleSrc), ("/t/Client.agda", cycleClientSrc)] $ \findings ->
      let kindOf sh = [ kindFinding f | f <- findings, symbolFinding f == Just sh ]
      in
      [ check "reachable cycle: cycA is NOT dead"
          (DefinedDead `notElem` kindOf "cycA")
      , check "reachable cycle: cycB is NOT dead"
          (DefinedDead `notElem` kindOf "cycB")
      , checkEq "reachable cycle: cycB stays internal-only (via cycA)"
          [DefinedInternalOnly] (kindOf "cycB")
      ]
  ]

----------------------------------------------------------------------
-- Schema wire fields: the producer's `unsafe` (R12) and re-export
-- `renames` (R14) decode into 'defUnsafe' / 'rxRenames', and their
-- absence in an older graph degrades to empty (backward compatibility).

schemaGraphJson :: BL.ByteString
schemaGraphJson = BLC.pack $ unlines
  [ "{ \"v\": 2, \"mode\": \"expanded\", \"schemaVersion\": 2"
  , ", \"modules\": [\"Danger\", \"Reexports\", \"Core.Base\"]"
  , ", \"moduleFiles\": { \"Danger\": \"/t/Danger.agda\" }"
  , ", \"definitions\":"
  , "  [ { \"name\": \"Danger.loops\", \"module\": \"Danger\", \"kind\": \"function\", \"unsafe\": [\"non-terminating\"] }"
  , "  , { \"name\": \"Danger.cheat\", \"module\": \"Danger\", \"kind\": \"function\", \"unsafe\": [\"trustme\"] }"
  , "  , { \"name\": \"Danger.safe\",  \"module\": \"Danger\", \"kind\": \"function\" }"
  , "  ]"
  , ", \"definitionEdges\": []"
  , ", \"reexports\":"
  , "  [ { \"from\": \"Reexports\", \"to\": \"Core.Base\", \"names\": [\"Core.Base.merge\"]"
  , "    , \"renames\": { \"combine\": \"Core.Base.merge\" } }"
  , "  , { \"from\": \"Reexports\", \"to\": \"Core.Base\", \"names\": [\"Core.Base.plain\"] }"
  , "  ]"
  , "}"
  ]

schemaFieldTests :: [Check]
schemaFieldTests = case eitherDecode schemaGraphJson :: Either String ExpandedGraph of
  Left err -> [ check ("schema fixture decodes: " ++ err) False ]
  Right g ->
    let unsafeOf n = concat [ defUnsafe d | d <- egDefinitions g, defName d == n ]
        renamesOf src = [ rxRenames r | r <- egReExports g, head (rxNames r) == src ]
    in
    [ checkEq "R12: unsafe non-terminating decodes" ["non-terminating"] (unsafeOf "Danger.loops")
    , checkEq "R12: unsafe trustme decodes"         ["trustme"]         (unsafeOf "Danger.cheat")
    , checkEq "R12: absent unsafe → empty"          []                  (unsafeOf "Danger.safe")
    , checkEq "R14: renames decodes to alias→canonical"
        [Map.fromList [("combine", "Core.Base.merge")]]
        (renamesOf "Core.Base.merge")
    , checkEq "R14: absent renames → empty map"
        [Map.empty] (renamesOf "Core.Base.plain")
    ]

----------------------------------------------------------------------
-- Transitive soundness taint (R12 follow-on): 'unsafeDeps' reports the
-- directly-`unsafe` defs in a node's forward (dependency) closure — the
-- escapes a theorem transitively rests on. Chain: thm → step → loops
-- (non-terminating); `cheat` (trustme) is present but unreachable from
-- thm; `clean` depends on nothing.

taintGraphJson :: BL.ByteString
taintGraphJson = BLC.pack $ unlines
  [ "{ \"v\": 2, \"mode\": \"expanded\", \"schemaVersion\": 2"
  , ", \"modules\": [\"Proof\", \"Danger\"]"
  , ", \"moduleFiles\": {}"
  , ", \"definitions\":"
  , "  [ { \"name\": \"Proof.thm\",    \"module\": \"Proof\",  \"kind\": \"function\" }"
  , "  , { \"name\": \"Proof.step\",   \"module\": \"Proof\",  \"kind\": \"function\" }"
  , "  , { \"name\": \"Proof.clean\",  \"module\": \"Proof\",  \"kind\": \"function\" }"
  , "  , { \"name\": \"Danger.loops\", \"module\": \"Danger\", \"kind\": \"function\", \"unsafe\": [\"non-terminating\"] }"
  , "  , { \"name\": \"Danger.cheat\", \"module\": \"Danger\", \"kind\": \"function\", \"unsafe\": [\"trustme\"] }"
  , "  ]"
  , ", \"definitionEdges\": [ [\"Proof.thm\", \"Proof.step\"], [\"Proof.step\", \"Danger.loops\"] ]"
  , "}"
  ]

taintTests :: [Check]
taintTests = case eitherDecode taintGraphJson :: Either String ExpandedGraph of
  Left err -> [ check ("taint fixture decodes: " ++ err) False ]
  Right g ->
    let ix = buildIndex g
        -- unsafe dependency names for a node, or Nothing if the name is absent.
        depNames n = fmap (\i -> map (defName . defAt ix) (unsafeDeps ix i)) (lookupId ix n)
    in
    [ checkEq "taint: thm transitively rests on loops (via step)"
        (Just ["Danger.loops"]) (depNames "Proof.thm")
    , checkEq "taint: step directly rests on loops"
        (Just ["Danger.loops"]) (depNames "Proof.step")
    , checkEq "taint: clean cone has no escapes"
        (Just []) (depNames "Proof.clean")
    , checkEq "taint: subject's own escape is excluded (not a self-dependency)"
        (Just []) (depNames "Danger.loops")
    , checkEq "taint: unreachable escape (cheat) does not taint thm"
        False (fmap (elem "Danger.cheat") (depNames "Proof.thm") == Just True)
    ]

----------------------------------------------------------------------
-- LemmaRank — carrier-affinity tie-break (arena R20).

-- | Build a 'Definition' fixture; only the fields the ranker reads matter.
mkDef :: Text -> Text -> Kind -> Maybe Text -> Definition
mkDef nm md kind sig = Definition
  { defId = -1, defName = nm, defModule = md, defState = Defined
  , defKind = kind, defLine = Nothing, defAccess = Public
  , defSig = sig, defUnsafe = [], defX = 0, defY = 0, defOrigin = Nothing }

lemmaRankTests :: [Check]
lemmaRankTests =
  [ -- Arena repro: for `n + zero ≡ n` the ℕ instance must outrank the
    -- byte-identical ℤ one, and the Sign variant sits below on Jaccard.
    checkEq "rank: Data.Nat.+-identityʳ outranks the ℤ then Sign variants"
      [ "Data.Nat.Properties.+-identity\691"
      , "Data.Integer.Properties.+-identity\691"
      , "Data.Sign.Properties.*-identity\691" ]
      (map (defName . snd) (rankLemmaCandidates arenaEnv (const True) 0.3 goalPlusZero []))
  , check "rank: coverage stays 0.625 for the whole identity family (G1 tripwire)"
      (all (\((c,_,_,_),_) -> abs (c - 0.625) < 1e-9)
           (rankLemmaCandidates arenaEnv (const True) 0.3 goalPlusZero []))
  , check "rank: ℕ instance has affinity 1, ℤ instance affinity 0"
      (case rankLemmaCandidates arenaEnv (const True) 0.3 goalPlusZero [] of
         (((_,_,aNat,_),_) : ((_,_,aInt,_),_) : _) -> aNat == 1 && aInt == 0
         _                                         -> False)
  , check "carrier: goal `zero` token resolves to the Nat segment"
      (Set.member "Nat" (goalCarrierSegments arenaEnv goalPlusZero []))
  , check "carrier: generic namespace segments never match"
      (Set.null (Set.intersection
                   (Set.fromList ["Data","Agda","Builtin","Properties","Base"])
                   (goalCarrierSegments arenaEnv goalPlusZero [])))
  , checkEq "carrier: a Commutative goal has no value carrier"
      Set.empty (goalCarrierSegments arenaEnv "m + n \8801 n + m" [])
  , check "carrier: context type ℕ contributes the Nat segment"
      (Set.member "Nat" (goalCarrierSegments natEnv "foo" ["\8469"]))
  , checkEq "carrier: the same goal with no context yields no carrier"
      Set.empty (goalCarrierSegments natEnv "foo" [])
  , check "carrier: a renaming alias's host module supplies the segment"
      (Set.member "Nat" (goalCarrierSegments aliasEnv "\8469" []))
  , checkEq "carrier: empty env → empty segments (no-renames determinism pin)"
      Set.empty (goalCarrierSegments (RankEnv [] Map.empty) goalPlusZero [])
  , checkEq "rank: with no carrier signal, order is the pre-R20 alphabetical tie-break"
      [ "Data.Integer.Properties.+-identity\691"
      , "Data.Nat.Properties.+-identity\691"
      , "Data.Sign.Properties.*-identity\691" ]
      (map (defName . snd) (rankLemmaCandidates arenaEnv (const True) 0.3 "m + n \8801 n + m" []))
  , checkEq "moduleSegments strips generic components" (Set.fromList ["Nat"])
      (moduleSegments "Data.Nat.Properties")
  ]
  where
    goalPlusZero = "n + zero \8801 n"                     -- n + zero ≡ n
    idr = "Algebra.RightIdentity Relation.Binary.PropositionalEquality._\8801_ "
    arenaEnv = RankEnv
      [ mkDef "Data.Nat.Properties.+-identity\691"     "Data.Nat.Properties"     KFunction
              (Just (idr <> "0 Data.Nat._+_"))
      , mkDef "Data.Integer.Properties.+-identity\691" "Data.Integer.Properties" KFunction
              (Just (idr <> "(Data.Integer.+ 0) Data.Integer._+_"))
      , mkDef "Data.Sign.Properties.*-identity\691"    "Data.Sign.Properties"    KFunction
              (Just (idr <> "Data.Sign.+ Data.Sign._*_"))
      , mkDef "Agda.Builtin.Nat.Nat.zero"              "Agda.Builtin.Nat"        KConstructor Nothing
      ] Map.empty
    natEnv   = RankEnv [ mkDef "Data.Nat.Base.\8469" "Data.Nat.Base" KDatatype Nothing ] Map.empty
    aliasEnv = RankEnv [] (Map.singleton "Data.Nat.Base.\8469" "Agda.Builtin.Nat.Nat")

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
-- AgdaRepair.Diagnostic: classifier goldens. Messages are real
-- --interaction-json Error text (byte-identical to agda's CLI rendering),
-- so these pin the parsing against an Agda upgrade.

notInScopeMsg :: Text
notInScopeMsg = T.intercalate "\n"
  [ "/tmp/x/Live.agda:4.7-8: error: [NotInScope]"
  , "Not in scope:"
  , "  \8484"                                     -- ℤ
  , "  at /tmp/x/Live.agda:4.7-8"
  , "when scope checking \8484" ]

parseAppMsg :: Text
parseAppMsg = T.intercalate "\n"
  [ "error: [NoParseForApplication]"
  , "Could not parse the application"
  , "(result \8621 deduplicate _\8799_ arr) \215 AllPairs _\8804_ result"  -- ↭ ≟ × ≤
  , "Operators used in the grammar:"
  , "  \215 (infixr operator, level 2)" ]

unequalMsg :: Text
unequalMsg = T.intercalate "\n"
  [ "/tmp/x/Bad.agda:5.8-12: error: [UnequalTypes]"
  , "The type Bool is not a subtype of Nat" ]

missingSigMsg :: Text
missingSigMsg = T.intercalate "\n"
  [ "/tmp/x/T.agda:32.1-17: error: [MissingTypeSignature]"
  , "Missing type signature for left hand side fin nums []"
  , "when scope checking the declaration"
  , "  fin nums [] = 0" ]

diagnosticTests :: [Check]
diagnosticTests =
  [ checkEq "notInScopeNames extracts the reported operator/name"
      ["\8484"] (RD.notInScopeNames notInScopeMsg)
  , check "notInScopeNames drops the stopword in 'when scope checking the declaration'"
      ("the" `notElem` RD.notInScopeNames missingSigMsg)
  , check "parseErrorNames pulls the dropped operator out of a NoParseForApplication"
      ("_\8804_" `elem` RD.parseErrorNames parseAppMsg
         && "\215" `elem` RD.parseErrorNames parseAppMsg)
  , check "parseErrorNames excludes the alphabetic non-operator tokens"
      ("AllPairs" `notElem` RD.parseErrorNames parseAppMsg
         && "result"  `notElem` RD.parseErrorNames parseAppMsg)
  , checkEq "errorTags reads the bracketed class"
      ["NotInScope"] (RD.errorTags notInScopeMsg)
  , checkEq "classify routes a not-in-scope error to DScope"
      [RD.DScope "\8484"] (RD.classify [notInScopeMsg])
  , check "classify refuses a semantic (UnequalTypes) error"
      (case RD.classify [unequalMsg] of
         [RD.DRefuse tag _] -> tag == "UnequalTypes"
         _                  -> False)
  , checkEq "nameKeys maps a bare operator onto its mixfix form"
      True ("_\215_" `elem` RD.nameKeys "\215")            -- × ↦ _×_
  , check "isRefusableTag flags termination but not scope"
      (RD.isRefusableTag "TerminationIssue" && not (RD.isRefusableTag "NotInScope"))
  -- hintOutOfScope (R19): a Mimer hint the file hasn't imported must be
  -- recognised from the NotInScope reply; a genuine search miss must not.
  , check "hintOutOfScope: true when the hint is the not-in-scope name"
      (RD.hintOutOfScope "\8484" notInScopeMsg)                 -- ℤ, named in notInScopeMsg
  , check "hintOutOfScope: false for an unrelated hint on a scope error"
      (not (RD.hintOutOfScope "+-identity\691" notInScopeMsg))  -- +-identityʳ, not named
  , check "hintOutOfScope: false on a non-scope (UnequalTypes) error"
      (not (RD.hintOutOfScope "\8484" unequalMsg))
  ]

----------------------------------------------------------------------
-- AgdaRepair.Edit: the spec-preserving, comment/string-safe edits.

repairEditTests :: [Check]
repairEditTests =
  [ checkEq "renameInBody rewrites a body reference"
      "g : Nat\ng = refl\n"
      (RE.renameInBody "g : Nat\ng = ref\n" "ref" "refl")
  , checkEq "renameInBody never touches a signature line"
      "ref : Nat\nx = refl\n"
      (RE.renameInBody "ref : Nat\nx = ref\n" "ref" "refl")
  , checkEq "renameInBody leaves a line comment alone"
      "x = refl  -- ref here\n"
      (RE.renameInBody "x = ref  -- ref here\n" "ref" "refl")
  , checkEq "renameInBody leaves a string literal alone"
      "x = g \"ref\"\n"
      (RE.renameInBody "x = g \"ref\"\n" "ref" "refl")
  , checkEq "renameInBody matches whole tokens only"
      "y = prefix\n"
      (RE.renameInBody "y = prefix\n" "ref" "refl")
  , check "insertImport places the line after the last import"
      ("open import A\nopen import B" `T.isInfixOf`
         RE.insertImport "module M where\nopen import A\nf = x\n" "open import B")
  , checkEq "insertImport is a no-op when the import is already present"
      "open import A\nf = x\n"
      (RE.insertImport "open import A\nf = x\n" "open import A")
  , checkEq "applyEdits returns Nothing for a net no-op"
      Nothing
      (RE.applyEdits "open import A\nf = x\n" [RE.EAddImport "open import A"])
  , check "isSigLine recognises a top-level signature but not a clause/indent"
      (RE.isSigLine "foo : Nat"
         && not (RE.isSigLine "foo x = y")
         && not (RE.isSigLine "  nested : T"))
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
