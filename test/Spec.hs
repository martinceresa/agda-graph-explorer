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
import qualified Data.Text.Encoding  as TE
import qualified Data.Yaml            as Y
import           Data.IORef
import           Data.List            ( elemIndex, intercalate, isInfixOf, sort )
import qualified Data.IntMap.Strict   as IntMap
import qualified Data.IntSet          as IntSet
import           Data.Maybe           ( listToMaybe, mapMaybe )
import           Data.Text            ( Text )
import qualified Data.Text            as T
import           System.Exit          ( ExitCode(..), exitFailure, exitSuccess )
import           System.IO            ( hPutStrLn, stderr )

import qualified Data.Set             as Set
import           AgdaGraph.Interaction.Protocol
import qualified AgdaGraph.Interaction.Iotcm as Iotcm
import           AgdaGraph.GoalCanon   ( matchTokens, nameTokens, shapeTokens
                                       , weightedCoverage, weightedCoverageIdf
                                       , headSymbol, stripQualifiers )
import           AgdaGraph.LemmaRank   ( mkRankEnv, RankOpts(..), defaultRankOpts
                                       , rankLemmaCandidates, rankLemmaCandidatesWith
                                       , computeIdf
                                       , goalCarrierSegments, moduleSegments )
import           AgdaGraph.PremiseBench ( benchRows, scoreStrategy, lookupStrategy
                                       , defaultBenchOpts, noRowReason
                                       , BenchReport(..) )
import           AgdaGraph.PremiseSelect ( CorpusRow(..), buildCorpus, featuresOf
                                        , premiseVotes, blendScores, alphaFor )
import           AgdaInteract.Guard
import           AgdaInteract.Literate
import           AgdaInteract.GoalId
import           AgdaInteract.Registry ( contentStamp, shouldKeepGoalIds )
import           AgdaInteract.Session  ( clampRemainingMicros, agdaMissingHint )
import           AgdaInteract.Edit
import           AgdaInteract.Batch    ( Step(..), wildcardCheck, allGiveSteps
                                       , checkInspectArgs, checkScratchOp
                                       , inspectOps, scratchOps )
import qualified AgdaAuto.CLI          as AA
import qualified AgdaAuto.Config       as AC
import           AgdaInteract.AutoReport ( AutoAllOutcome(..), GoalReport(..)
                                         , GoalOutcome(..), HintProv(..)
                                         , noGoalsOutcome, renderAutoAll, oosNote
                                         , annotationEdits )
import           AgdaAuto.Report       ( outcomeExit, outcomeJson, renderHumanReport
                                       , Summary(..), summarize, worstExit, ledgerLines )
import           AgdaInteract.Annotate ( Annotation(..), renderMarker, parseMarker
                                       , stripMarker, annotateHole, holeHints
                                       , sanitize, commentBalanced )
import qualified AgdaRepair.Diagnostic as RD
import qualified AgdaRepair.Edit       as RE
import qualified AgdaRepair.Strategy   as RS
import           Data.Aeson            ( Value, eitherDecode, encode, object, (.=) )
import qualified Data.Aeson.Key        as K
import qualified Data.Aeson.KeyMap     as KM
import qualified Data.Map.Strict       as Map
import           AgdaGraph.Schema      ( ExpandedGraph(..), Definition(..), ReExport(..)
                                       , State(..), Kind(..), Access(..)
                                       , loadExpandedGraph, explainDecodeError )
import           AgdaGraph.Index       ( buildIndex, lookupId, unsafeDeps, defAt
                                       , idxRealCount, moduleDependencyOrder
                                       , idxDefs, idxExternalsSummary )
import           AgdaUnused.Analysis   ( Finding(..), FindingKind(..), analyse )
import           AgdaGraph.ConfigCore  ( unknownKeys, unknownKeyError, nearestKey
                                       , checkKnownKeys, extractValueFlag )
import           AgdaOptimization.Legend ( legendKeys, renderLegend )
import           AgdaOptimization.FlagSpec ( FlagSpec, helpDefaultDrift )
import qualified AgdaOptimization.Basket        as Basket
import qualified AgdaOptimization.Chokepoint    as Chokepoint
import qualified AgdaOptimization.ConceptBundle as ConceptBundle
import qualified AgdaOptimization.Debt          as Debt
import qualified AgdaOptimization.Echo          as Echo
import qualified AgdaOptimization.Entwine       as Entwine
import qualified AgdaOptimization.Fiedler       as Fiedler
import qualified AgdaOptimization.Fingerprint   as Fingerprint
import qualified AgdaOptimization.Gravity       as Gravity
import qualified AgdaOptimization.HintBench     as HintBench
import qualified AgdaOptimization.Horizon       as Horizon
import qualified AgdaOptimization.Ledger        as Ledger
import qualified AgdaOptimization.LoadBearing   as LoadBearing
import qualified AgdaOptimization.Motif         as Motif
import qualified AgdaOptimization.Polyglot      as Polyglot
import qualified AgdaOptimization.Pyre          as Pyre
import qualified AgdaOptimization.Silhouette    as Silhouette
import qualified AgdaOptimization.Strata        as Strata
import qualified AgdaOptimization.TermCluster   as TermCluster

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
  sequence_ (map ($ fails) stampTests)
  sequence_ (map ($ fails) budgetTests)
  sequence_ (map ($ fails) batchTests)
  sequence_ (map ($ fails) editTests)
  sequence_ (map ($ fails) diagnosticTests)
  sequence_ (map ($ fails) repairEditTests)
  sequence_ (map ($ fails) goalCanonTests)
  sequence_ (map ($ fails) unusedDeadTests)
  sequence_ (map ($ fails) schemaFieldTests)
  sequence_ (map ($ fails) taintTests)
  sequence_ (map ($ fails) moduleOptionEscapeTests)
  sequence_ (map ($ fails) lemmaRankTests)
  sequence_ (map ($ fails) phase1RankTests)
  sequence_ (map ($ fails) phase2SelectTests)
  sequence_ (map ($ fails) strategyTests)
  sequence_ (map ($ fails) autoCliTests)
  sequence_ (map ($ fails) autoRenderTests)
  sequence_ (map ($ fails) autoReportTests)
  sequence_ (map ($ fails) annotateTests)
  sequence_ (map ($ fails) aggregateTests)
  sequence_ (map ($ fails) moduleTopoTests)
  sequence_ (map ($ fails) configKeyTests)
  sequence_ (map ($ fails) helpDefaultTests)
  ledgerTrustTests fails
  premiseBenchTests fails
  legendTests fails
  replayTests fails
  schemaErrorTests fails
  n <- readIORef fails
  if n == 0
    then putStrLn "all interaction-bridge tests passed" >> exitSuccess
    else hPutStrLn stderr (show n ++ " test(s) failed") >> exitFailure

----------------------------------------------------------------------
-- Report legends. Every agda-optimization subcommand must carry a
-- "## How to read this" block, since a report file is read by someone
-- who did not run it.
--
-- The subcommand list is read from the committed --help golden rather
-- than retyped here: CI already asserts that golden against the binary
-- (scripts/help-golden.sh), so adding a subcommand without a legend
-- fails HERE instead of shipping an unexplained table. Reading the
-- binary's own AgdaOptimization.CLI would instead drag all nineteen
-- analyses into this offline suite.

legendTests :: IORef Int -> IO ()
legendTests ref = do
  raw <- BL.readFile "test/help/agda-optimization.txt"
  let subs = helpSubcommands (T.unpack (TE.decodeUtf8 (BL.toStrict raw)))
  check "legend: the --help golden still parses into subcommands"
    (length subs >= 19) ref
  mapM_ (\sub -> check ("legend: " ++ sub ++ " has one")
                       (sub `elem` legendKeys) ref) subs
  -- Every key renders a complete block: heading, glossary, closing advice.
  mapM_ (\k -> do
           let out = renderLegend k
           check ("legend: " ++ k ++ " renders the heading")
             ("\n## How to read this\n" `isInfixOf` out) ref
           check ("legend: " ++ k ++ " renders an Act on: line")
             ("\nAct on: " `isInfixOf` out) ref
           check ("legend: " ++ k ++ " wraps within 80 columns")
             (all ((<= 80) . length) (lines out)) ref)
        legendKeys
  -- A stale key (a subcommand renamed out from under the table) would
  -- otherwise sit here unreachable. 'silhouette-fallback' is the one
  -- deliberate non-subcommand key: silhouette's no-provenance path.
  checkEq "legend: no key without a subcommand (bar the documented variant)"
    [] [ k | k <- legendKeys
           , k `notElem` subs, k /= "silhouette-fallback" ] ref
  -- An unrecognised caller prints nothing rather than a stub.
  checkEq "legend: an unknown key renders empty" "" (renderLegend "nope") ref

----------------------------------------------------------------------
-- ledger's trust closure walks the DEPENDENCY direction.
--
-- This is the whole analysis: "what does this theorem rest on". It shipped
-- walking 'ancestors' (the theorem's dependents) and so reported, with full
-- confidence, the axioms' own dependencies as the theorems' footprints —
-- uniformly 0 on the corpus that surfaced it. The fixture pins the
-- direction rather than the numbers: 'Holes.magic' is the only postulate,
-- reached by exactly one definition, and its OWN dependency ('Nat.Nat') is
-- what the reversed walk used to name. A re-flip fails here.

ledgerTrustTests :: IORef Int -> IO ()
ledgerTrustTests ref = do
  e <- loadExpandedGraph "test/deps.json"
  case e of
    Left err ->
      check ("ledger: test/deps.json decodes (" ++ err ++ ")") False ref
    Right g -> do
      let ix               = buildIndex g
          opts             = Ledger.defaultOptions
          (foundS, axiomS) = Ledger.partitionAxioms opts
                               (idxExternalsSummary ix) (idxDefs ix)
          thmIds           = Ledger.collectPublicTheorems opts
                               (idxExternalsSummary ix) (idxDefs ix)
          trusts           = map (Ledger.computeTrust ix axiomS foundS) thmIds
          footprintOf qn   =
            [ sort [ defName (defAt ix a)
                   | a <- IntSet.toList (Ledger.ttAxioms t) ]
            | t <- trusts, defName (defAt ix (Ledger.ttId t)) == qn ]

      checkEq "ledger: the fixture's axiom set is {Holes.magic}"
        ["Holes.magic"]
        (sort [ defName (defAt ix i) | i <- IntSet.toList axiomS ]) ref

      -- The user of the axiom carries it; the axiom's own dependency does
      -- not. Reversing the walk swaps exactly these two.
      checkEq "ledger: a theorem's footprint holds the axiom it USES"
        [["Holes.magic"]] (footprintOf "Holes.useMagic") ref
      checkEq "ledger: the axiom's own dependency has an empty footprint"
        [[]] (footprintOf "Nat.Nat") ref

      checkEq "ledger: leverage counts the one user of the one axiom"
        [("Holes.magic", 1)]
        [ (defName (defAt ix i), n)
        | (i, n) <- IntMap.toList (Ledger.buildLeverage trusts) ] ref

----------------------------------------------------------------------
-- Help-text default claims. A help line reading "(default 2)" beside a
-- record field holding 5 is a lie the compiler cannot catch, and five of
-- them had accumulated. 'helpDefaultDrift' re-derives the claim: applying
-- a flag's own advertised default must leave 'defaultOptions' unchanged.
--
-- Numeric (Int/Dbl) flags only — an enum/switch default states a word, not
-- a comparable value. The 'subcommands' list is retyped here rather than
-- imported because pulling AgdaOptimization.CLI in would drag the whole
-- dispatch layer (and its IO) into this offline suite; 'legendTests'
-- already fails if a subcommand exists that nothing here knows about.

helpDefaultTests :: [Check]
helpDefaultTests =
  [ checkEq ("help defaults: " ++ sub ++ " agrees with defaultOptions")
      [] drift
  | (sub, drift) <- helpDefaultDrifts
  ]

-- | One entry per subcommand: the drift lines its flag table produces.
-- Each entry monomorphises 'helpDefaultDrift' at that subcommand's own
-- @Options@ type, which is why this is a list of results rather than a
-- list of (specs, defaults) pairs. 'drift' names the subcommand once —
-- writing it twice per row let a typo mislabel a passing test.
helpDefaultDrifts :: [(String, [String])]
helpDefaultDrifts =
  [ drift "motif" Motif.flagSpecs Motif.defaultOptions
  , drift "load-bearing" LoadBearing.flagSpecs LoadBearing.defaultOptions
  , drift "polyglot" Polyglot.flagSpecs Polyglot.defaultOptions
  , drift "fingerprint" Fingerprint.flagSpecs Fingerprint.defaultOptions
  , drift "debt" Debt.flagSpecs Debt.defaultOptions
  , drift "basket" Basket.flagSpecs Basket.defaultOptions
  , drift "ledger" Ledger.flagSpecs Ledger.defaultOptions
  , drift "echo" Echo.flagSpecs Echo.defaultOptions
  , drift "gravity" Gravity.flagSpecs Gravity.defaultOptions
  , drift "pyre" Pyre.flagSpecs Pyre.defaultOptions
  , drift "chokepoint" Chokepoint.flagSpecs Chokepoint.defaultOptions
  , drift "silhouette" Silhouette.flagSpecs Silhouette.defaultOptions
  , drift "entwine" Entwine.flagSpecs Entwine.defaultOptions
  , drift "fiedler" Fiedler.flagSpecs Fiedler.defaultOptions
  , drift "horizon" Horizon.flagSpecs Horizon.defaultOptions
  , drift "strata" Strata.flagSpecs Strata.defaultOptions
  , drift "term-cluster" TermCluster.flagSpecs TermCluster.defaultOptions
  , drift "concept-bundle" ConceptBundle.flagSpecs ConceptBundle.defaultOptions
  , drift "hint-bench" HintBench.flagSpecs HintBench.defaultOptions
  ]
  where
    drift :: Show o => String -> [FlagSpec o] -> o -> (String, [String])
    drift sub specs defs = (sub, helpDefaultDrift sub specs defs)

-- | Pull the subcommand names out of the golden's SUBCOMMANDS block: the
-- indented lines between that heading and the next unindented one.
helpSubcommands :: String -> [String]
helpSubcommands txt =
  case dropWhile (/= "SUBCOMMANDS:") (lines txt) of
    []       -> []
    (_ : ls) -> mapMaybe firstWord (takeWhile indented ls)
  where
    indented l    = take 2 l == "  "
    firstWord     = listToMaybe . words

----------------------------------------------------------------------
-- Graph-load / decode error messages (§2.1). Pins the actionable
-- diagnostics byte-for-byte so future wording changes are deliberate.

schemaErrorTests :: IORef Int -> IO ()
schemaErrorTests ref = do
  -- IO: a missing file yields the "generate one" guidance, not a raw
  -- IOException show.
  eMissing <- loadExpandedGraph "test/__definitely_absent__.json"
  check "load error: missing file is actionable"
    (isLeftWith "file does not exist. Generate one with `agda-deps" eMissing) ref
  -- IO: a non-JSON payload (an .agda source) is sniffed before aeson.
  eNotJson <- loadExpandedGraph "test/interaction/proj/Nat.agda"
  check "load error: non-JSON payload is sniffed"
    (isLeftWith "not JSON (starts with '-')" eNotJson) ref
  -- pure: a generic aeson error is wrapped with the producer pointer.
  checkEq "decode error: generic aeson error is wrapped"
    "not an expanded v2 graph.json (unexpected token). Expected the output of `agda-deps --format=json --json-mode=expanded`."
    (explainDecodeError "unexpected token") ref
  -- pure: our own diagnostics pass through verbatim (never double-framed).
  check "decode error: own schema-v diagnostic passes through"
    (let m = "Error in $: expected schema v: 2, got: 1"
     in explainDecodeError m == m) ref
  check "decode error: own packed-mode diagnostic passes through"
    (let m = "Error in $: this graph is --json-mode=packed (…)"
     in explainDecodeError m == m) ref
  -- §2.4: the shared missing-agda hint names the installer + the escape hatch.
  check "missing-agda hint names the installer + --agda-bin"
    (T.isInfixOf "agda.readthedocs.io" agdaMissingHint
       && T.isInfixOf "--agda-bin" agdaMissingHint) ref
  where
    isLeftWith :: String -> Either String a -> Bool
    isLeftWith needle (Left m)  = needle `isInfixOf` m
    isLeftWith _      (Right _) = False

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
  -- pragma tokens in inert regions are false positives; a pragma in
  -- active code (or a token blanking must not expose) still fires.
  , check "guard allows a pragma quoted in a line comment"
      (not (isRejected (checkGiveInput "f -- note: {-# TERMINATING #-}\n")))
  , check "guard allows a pragma quoted in a block comment"
      (not (isRejected (checkGiveInput "f {- {-# OPTIONS --type-in-type #-} -}")))
  , check "guard allows a string-quoted postulate"
      (not (isRejected (checkGiveInput "show \"postulate\"")))
  , check "guard: a stray quote must not hide following code"
      (isRejected (checkGiveInput "g = \"{-\"\npostulate x : A"))
  , checkEq "guardScrub removes a block comment" "f  g" (guardScrub "f {- x -} g")
  , checkEq "guardScrub preserves a pragma verbatim"
      "{-# TERMINATING #-}" (guardScrub "{-# TERMINATING #-}")
  , checkEq "guardScrub blanks string contents, keeps the quotes"
      "\"  \"" (guardScrub "\"ab\"")
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
  -- a pragma quoted in a comment or string is inert, not a refusal.
  , check "file guard allows a pragma in a line comment"
      (not (isRejected (checkFileInput "module M where\n-- {-# TERMINATING #-}\nfoo = 0\n")))
  , check "file guard allows a commented-out pragma block"
      (not (isRejected (checkFileInput "{- {-# TERMINATING #-} -}\nmodule M where\n")))
  , check "file guard allows a string-quoted pragma"
      (not (isRejected (checkFileInput "module M where\ns = \"{-# NON_TERMINATING #-}\"\n")))
  -- literate: only fenced Agda code is guarded; prose is not.
  , check "literate guard allows a pragma/postulate mentioned in prose"
      (not (isRejected (checkFileInputFor "Doc.lagda.md" litProseMention)))
  , check "literate guard rejects postulate inside a code fence"
      (isRejected (checkFileInputFor "Doc.lagda.md" litFencePostulate))
  , check "literate guard allows {-# OPTIONS --safe #-} inside a code fence"
      (not (isRejected (checkFileInputFor "Doc.lagda.md" litFenceSafe)))
  , checkEq "checkFileInputFor on a plain .agda equals checkFileInput"
      (checkFileInput plainMod) (checkFileInputFor "M.agda" plainMod)
  ]
  where
    plainMod = "module M where\nfoo : Nat\nfoo = 0\n"
    litProseMention = T.unlines
      [ "# Doc", "This mentions postulate and {-# TERMINATING #-} in prose."
      , "```agda", "module M where", "foo : Nat", "foo = 0", "```" ]
    litFencePostulate = T.unlines
      [ "# Doc", "prose", "```agda", "module M where", "postulate bad : A", "```" ]
    litFenceSafe = T.unlines
      [ "# Doc", "prose", "```agda", "{-# OPTIONS --safe #-}"
      , "module M where", "foo = 0", "```" ]

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
  , checkEq "codeSlices extracts fenced code lines, drops prose + fences"
      ["module Lit where", "open import Agda.Builtin.Nat", "triple : Nat → Nat", "triple n = {!!}"]
      (codeSlices lit litFixture)
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
-- recursive call as a caller, nor treat a mutual-recursion cycle whose
-- only callers are its own members as live, while a real *external*
-- intra-module or cross-module caller still keeps the defs off the dead list.

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
-- Schema wire fields: the producer's `unsafe` and re-export
-- `renames` decode into 'defUnsafe' / 'rxRenames', and their
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
-- Transitive soundness taint: 'unsafeDeps' reports the
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
-- Module-level OPTIONS soundness escapes (agda-deps `moduleOptionEscapes`):
-- the top-level object decodes into 'egModuleOptionEscapes', 'buildIndex'
-- folds each module's escapes into the enclosed defs' 'defUnsafe' (merged
-- with any direct escape, sorted, deduped), transitive taint ('unsafeDeps')
-- sees them, and the encoder round-trips the object (omitting it when empty).

escapeGraphJson :: BL.ByteString
escapeGraphJson = BLC.pack $ unlines
  [ "{ \"v\": 2, \"mode\": \"expanded\", \"schemaVersion\": 2"
  , ", \"modules\": [\"Unsafe\", \"Proof\"]"
  , ", \"moduleFiles\": {}"
  , ", \"definitions\":"
  , "  [ { \"name\": \"Unsafe.bad\",       \"module\": \"Unsafe\", \"kind\": \"function\" }"
  , "  , { \"name\": \"Unsafe.alsoLoops\", \"module\": \"Unsafe\", \"kind\": \"function\", \"unsafe\": [\"non-terminating\"] }"
  , "  , { \"name\": \"Proof.thm\",        \"module\": \"Proof\",  \"kind\": \"function\" }"
  , "  , { \"name\": \"Proof.clean\",      \"module\": \"Proof\",  \"kind\": \"function\" }"
  , "  ]"
  , ", \"definitionEdges\": [ [\"Proof.thm\", \"Unsafe.bad\"] ]"
  , ", \"moduleOptionEscapes\": { \"Unsafe\": [\"--no-positivity-check\", \"--type-in-type\"] }"
  , "}"
  ]

moduleOptionEscapeTests :: [Check]
moduleOptionEscapeTests = case eitherDecode escapeGraphJson :: Either String ExpandedGraph of
  Left err -> [ check ("escape fixture decodes: " ++ err) False ]
  Right g ->
    let ix = buildIndex g
        -- 'defUnsafe' of a def by name, via the Index (post-fold).
        unsafeOfIx n = fmap (defUnsafe . defAt ix) (lookupId ix n)
        depNames n = fmap (\i -> map (defName . defAt ix) (unsafeDeps ix i)) (lookupId ix n)
        -- Byte containment of the encoded graph (for the omit-when-empty check).
        hasField bs = T.isInfixOf "moduleOptionEscapes"
                        (T.pack (BLC.unpack (encode (bs :: ExpandedGraph))))
    in
    [ checkEq "escape: moduleOptionEscapes decodes ascending per module"
        (Just ["--no-positivity-check", "--type-in-type"])
        (Map.lookup "Unsafe" (egModuleOptionEscapes g))
    , checkEq "escape: escape-free module is absent from the map"
        False (Map.member "Proof" (egModuleOptionEscapes g))
    , checkEq "escape: buildIndex folds module escapes into an enclosed def"
        (Just ["--no-positivity-check", "--type-in-type"]) (unsafeOfIx "Unsafe.bad")
    , checkEq "escape: fold merges with a direct escape (sorted, deduped)"
        (Just ["--no-positivity-check", "--type-in-type", "non-terminating"])
        (unsafeOfIx "Unsafe.alsoLoops")
    , checkEq "escape: a def in a clean module stays safe"
        (Just []) (unsafeOfIx "Proof.clean")
    , checkEq "escape: transitive taint reaches a def in an escaping module"
        (Just ["Unsafe.bad"]) (depNames "Proof.thm")
    , checkEq "escape: encoder round-trips the escapes object"
        (Just ["--no-positivity-check", "--type-in-type"])
        (case eitherDecode (encode g) :: Either String ExpandedGraph of
           Right g' -> Map.lookup "Unsafe" (egModuleOptionEscapes g')
           Left _   -> Nothing)
    , check "escape: encoder emits the field when non-empty" (hasField g)
    , check "escape: encoder omits the field when empty"
        (case eitherDecode taintGraphJson :: Either String ExpandedGraph of
           Right gc -> not (hasField gc)
           Left _   -> False)
    ]

----------------------------------------------------------------------
-- LemmaRank — carrier-affinity tie-break.

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
      Set.empty (goalCarrierSegments (mkRankEnv [] Map.empty) goalPlusZero [])
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
    arenaEnv = mkRankEnv
      [ mkDef "Data.Nat.Properties.+-identity\691"     "Data.Nat.Properties"     KFunction
              (Just (idr <> "0 Data.Nat._+_"))
      , mkDef "Data.Integer.Properties.+-identity\691" "Data.Integer.Properties" KFunction
              (Just (idr <> "(Data.Integer.+ 0) Data.Integer._+_"))
      , mkDef "Data.Sign.Properties.*-identity\691"    "Data.Sign.Properties"    KFunction
              (Just (idr <> "Data.Sign.+ Data.Sign._*_"))
      , mkDef "Agda.Builtin.Nat.Nat.zero"              "Agda.Builtin.Nat"        KConstructor Nothing
      ] Map.empty
    natEnv   = mkRankEnv [ mkDef "Data.Nat.Base.\8469" "Data.Nat.Base" KDatatype Nothing ] Map.empty
    aliasEnv = mkRankEnv [] (Map.singleton "Data.Nat.Base.\8469" "Agda.Builtin.Nat.Nat")

----------------------------------------------------------------------
-- Phase-1 ranking upgrades: head symbol (1b), IDF weighting (1a).

phase1RankTests :: [Check]
phase1RankTests =
  [ -- 1b. headSymbol: a relation operator heads a relational goal…
    checkEq "headSymbol: ≡ heads an equality goal"
      (Just "\8801") (headSymbol "m + n \8801 n + m")
  , checkEq "headSymbol: ≤ heads an order goal"
      (Just "\8804") (headSymbol "xs \8804 ys")
  , -- …an applied predicate is headed by its constructor…
    checkEq "headSymbol: an applied predicate is headed by its identifier"
      (Just "Even") (headSymbol "Even n")
  , -- …a bare operator application by that operator, and nothing by nothing.
    checkEq "headSymbol: a bare op application is headed by the op"
      (Just "+") (headSymbol "n + zero")
  , checkEq "headSymbol: an empty conclusion has no head"
      Nothing (headSymbol "")

    -- 1b. head-filter drops a head-mismatched candidate the baseline keeps.
    -- At minSim 0 both defs qualify; the ≤ lemma is dropped for an ≡ goal.
  , checkEq "head: baseline (no head handling) keeps both candidates"
      ["M.eqLem", "M.leLem"]
      (map (defName . snd) (rankLemmaCandidates headEnv (const True) 0 "a \8801 b" []))
  , checkEq "head-filter: drops the ≤-headed candidate for an ≡ goal"
      ["M.eqLem"]
      (map (defName . snd)
           (rankLemmaCandidatesWith defaultRankOpts { roHeadFilter = True }
                                    headEnv (const True) 0 "a \8801 b" []))

    -- 1a. weightedCoverageIdf with an empty map is exactly weightedCoverage.
  , check "idf: empty map ⇒ weightedCoverageIdf == weightedCoverage"
      (weightedCoverageIdf Map.empty gset bset == weightedCoverage gset bset)
    -- 1a. a token in one of three defs outweighs one in all three; a
    -- ubiquitous token keeps weight 1 (1 + log 1).
  , check "idf: a rare token outweighs a ubiquitous one"
      (Map.findWithDefault 0 "Rare" idfMap > Map.findWithDefault 0 "Common" idfMap)
  , check "idf: a token in every def keeps weight 1"
      (abs (Map.findWithDefault 0 "Common" idfMap - 1) < 1e-9)
  ]
  where
    headEnv = mkRankEnv
      [ mkDef "M.eqLem" "M" KFunction (Just "x \8801 y")
      , mkDef "M.leLem" "M" KFunction (Just "x \8804 y")
      ] Map.empty
    gset = Set.fromList ["\8801", "f"]
    bset = Set.fromList ["\8801", "x"]
    idfMap = computeIdf
      [ mkDef "M.f" "M" KFunction (Just "Common Rare")
      , mkDef "M.g" "M" KFunction (Just "Common Other")
      , mkDef "M.h" "M" KFunction (Just "Common Third")
      ]

----------------------------------------------------------------------
-- Phase-2 dependency-informed premise selection (k-NN).

phase2SelectTests :: [Check]
phase2SelectTests =
  [ -- featuresOf pulls the goal's operator + algebraic shape (bound vars dropped).
    check "featuresOf: a commutativity goal yields ≡ and the Commutative shape"
      (Set.member "\8801" f && Set.member "Commutative" f)

    -- premiseVotes: the premise of the most-similar neighbour out-votes a
    -- premise seen only in a less-similar one. Goal features match n1 exactly
    -- ({≡,+}), overlap n2 partially ({≡,*}) — so n1's lemA beats n2's lemC.
  , check "premiseVotes: a near neighbour's premise out-votes a far one's"
      (Map.findWithDefault 0 "lemA" votes > Map.findWithDefault 0 "lemC" votes)
  , check "premiseVotes: leave-one-out drops the excluded row's private premise"
      (Map.notMember "lemSelf" (premiseVotes 8 corpus (/= "self") goalF))

    -- blendScores: min-max normalise each side, then α·knn + (1-α)·lexical.
  , check "blendScores: α=0.5 averages the two normalised signals"
      (let b = blendScores 0.5 (Map.fromList [("a",1),("b",0)])
                                (Map.fromList [("b",1),("c",0)])
       in abs (Map.findWithDefault 0 "a" b - 0.5) < 1e-9
          && abs (Map.findWithDefault 0 "b" b - 0.5) < 1e-9
          && abs (Map.findWithDefault 0 "c" b - 0)   < 1e-9)

    -- alphaFor: pure lexical below the corpus-size floor, base α above.
  , checkEq "alphaFor: 0 below the corpus floor"  0   (alphaFor 10  0.5)
  , checkEq "alphaFor: base α above the floor"    0.5 (alphaFor 100 0.5)
  ]
  where
    f      = featuresOf Set.empty "m + n \8801 n + m"
    goalF  = featuresOf Set.empty "m + n \8801 n + m"       -- {≡, +, Commutative}
    corpus = buildCorpus Set.empty Map.empty
      [ CorpusRow "n1"   (Set.fromList ["\8801", "+"]) (Set.fromList ["lemA", "lemB"])
      , CorpusRow "n2"   (Set.fromList ["\8801", "*"]) (Set.fromList ["lemC"])
      , CorpusRow "self" (Set.fromList ["\8801", "+"]) (Set.fromList ["lemSelf"])
      ]
    votes  = premiseVotes 8 corpus (const True) goalF

----------------------------------------------------------------------
-- Alias-aware, carrier-ranked, import-only write-side resolvers.

strategyTests :: [Check]
strategyTests =
  [ -- Plain def: a bare `×` finds `_×_` and imports it under its mixfix name.
    check "importCandidates: bare × resolves to _×_'s module"
      ("open import Data.Product using (_\215_)"
         `elem` RS.importCandidates prodEnv Set.empty "" "\215")
  -- a name in scope only via a renaming re-export resolves to its host.
  , check "importCandidates: a renaming alias resolves to its host module"
      ("open import Reexports using (combine)"
         `elem` RS.importCandidates combineEnv Set.empty "" "combine")
  , check "importCandidates: ℕ (a renaming alias) resolves to its host, not a broken node"
      ("open import Data.Nat.Base using (\8469)"
         `elem` RS.importCandidates natAliasEnv Set.empty "" "\8469")
  , check "importCandidates: a mixfix alias _∔_ resolves under the bare ∔"
      ("open import Host using (_\8724_)"
         `elem` RS.importCandidates mixAliasEnv Set.empty "" "\8724")
  , check "importCandidates: an alias and a real def of the same name are both offered"
      (let cs = RS.importCandidates collideEnv Set.empty "" "combine"
       in "open import Reexports using (combine)" `elem` cs
            && "open import Some.Mod using (combine)" `elem` cs)
  -- a constructor resolves to its PARENT module, not the
  -- raw datatype-namespaced module (which yields a broken import).
  , checkEq "resolveImportModules: a constructor resolves to its parent module"
      (Just "Agda.Builtin.Nat")
      (listToMaybe (RS.resolveImportModules zeroEnv [] "zero"))
  -- carrier affinity picks the right module among same-named exporters.
  , checkEq "resolveImportModules: a ℕ-typed stub prefers Data.Nat.Base for +"
      (Just "Data.Nat.Base")
      (listToMaybe (RS.resolveImportModules plusEnv ["\8469 \8594 \8469"] "+"))
  , checkEq "resolveImportModules: a ℤ-typed stub flips the choice to Data.Integer.Base"
      (Just "Data.Integer.Base")
      (listToMaybe (RS.resolveImportModules plusEnv ["\8484 \8594 \8484"] "+"))
  -- candidatesFor is import-only — every candidate is a single EAddImport.
  , check "candidatesFor: DScope yields only import edits (never a rename)"
      (let cs = RS.candidatesFor combineEnv "" (RD.DScope "combine")
       in not (null cs)
            && all (\c -> case c of [RE.EAddImport _] -> True; _ -> False) cs)
  -- a typo no import fixes is only SUGGESTED, never applied.
  , check "nearMissSuggestions: a typo of an alias is suggested"
      ("combine" `elem` RS.nearMissSuggestions combineEnv "" "combin")
  ]
  where
    prodEnv     = RS.buildEnv [ mkDef "Data.Product._\215_" "Data.Product" KFunction Nothing ] Map.empty
    combineEnv  = RS.buildEnv [] (Map.singleton "Reexports.combine" "Core.Base.merge")
    natAliasEnv = RS.buildEnv [] (Map.singleton "Data.Nat.Base.\8469" "Agda.Builtin.Nat.Nat")
    mixAliasEnv = RS.buildEnv [] (Map.singleton "Host._\8724_" "X.plus")
    collideEnv  = RS.buildEnv [ mkDef "Some.Mod.combine" "Some.Mod" KFunction Nothing ]
                              (Map.singleton "Reexports.combine" "Core.Base.merge")
    zeroEnv     = RS.buildEnv [ mkDef "Agda.Builtin.Nat.Nat.zero" "Agda.Builtin.Nat.Nat" KConstructor Nothing ] Map.empty
    plusEnv     = RS.buildEnv
      [ mkDef "Data.Nat.Base._+_"     "Data.Nat.Base"     KFunction Nothing
      , mkDef "Data.Integer.Base._+_" "Data.Integer.Base" KFunction Nothing
      , mkDef "Data.Nat.Base.\8469"     "Data.Nat.Base"     KDatatype Nothing
      , mkDef "Data.Integer.Base.\8484" "Data.Integer.Base" KDatatype Nothing
      ] Map.empty

----------------------------------------------------------------------
-- hint-bench — leave-one-out premise-selection recall floor.
--
-- Reads the committed signature+provenance fixture (.agda-explore/deps.json),
-- scores the shipped `baseline` strategy, and pins any-hit@6 at or above the
-- recorded floor so a ranking "cleanup" that regresses recall fails CI. Plus
-- the two graceful-degradation contracts (no provenance / no signatures →
-- zero rows, not a crash), synthesised off the same fixture so they don't
-- depend on a second file staying signature-free.

----------------------------------------------------------------------
-- agda-auto CLI + config layer.
--
-- Pure surface only: the flag parser threads a seed 'AutoOpts', and the
-- config overlay is a no-op except where a field is set. The merge order
-- defaults < config < CLI is the contract these pin (the live ladder is
-- covered by test/auto/smoke.sh, which CI does not run).

autoCliTests :: [Check]
autoCliTests =
  [ checkEq "parseArgs [] is identity on the seed"
      (Right AA.defaultOpts) (AA.parseArgs [] AA.defaultOpts)
  , check "default annotate is on" (AA.aoAnnotate AA.defaultOpts)
  , check "--write sets aoWrite"
      (rOr False AA.aoWrite (AA.parseArgs ["--write"] AA.defaultOpts))
  , check "--no-annotate clears annotate"
      (rOr True (not . AA.aoAnnotate) (AA.parseArgs ["--no-annotate"] AA.defaultOpts))
  , checkEq "--timeout N (space form)"
      (Right 10) (AA.aoTimeout <$> AA.parseArgs ["--timeout", "10"] AA.defaultOpts)
  , checkEq "--timeout=N via preprocess"
      (Right 10) (AA.aoTimeout <$> AA.parseArgs (AA.preprocess ["--timeout=10"]) AA.defaultOpts)
  , checkEq "--hints=0 via preprocess"
      (Right 0) (AA.aoHints <$> AA.parseArgs (AA.preprocess ["--hints=0"]) AA.defaultOpts)
  , checkEq "-i repeats and appends in order"
      (Right ["a", "b"]) (AA.aoIncludes <$> AA.parseArgs ["-i", "a", "-i", "b"] AA.defaultOpts)
  , checkEq "--overlay-graph repeats"
      (Right ["g1", "g2"])
      (AA.aoOverlays <$> AA.parseArgs ["--overlay-graph", "g1", "--overlay-graph", "g2"] AA.defaultOpts)
  , checkEq "positional bare file → aoFiles"
      (Right ["Foo.agda"]) (AA.aoFiles <$> AA.parseArgs ["Foo.agda"] AA.defaultOpts)
  , checkEq "flags and files interleave, files keep order"
      (Right ["A.agda", "B.agda"])
      (AA.aoFiles <$> AA.parseArgs ["A.agda", "--write", "B.agda"] AA.defaultOpts)
  , check "--graph sets the path"
      (rOr False ((== Just "d.json") . AA.aoGraph) (AA.parseArgs ["--graph", "d.json"] AA.defaultOpts))
  -- §1.1: --format is the canonical output flag; --json is its alias.
  , check "--format json sets aoJson"
      (rOr False AA.aoJson (AA.parseArgs ["--format", "json"] AA.defaultOpts))
  , check "--format human clears aoJson"
      (rOr True (not . AA.aoJson) (AA.parseArgs ["--format", "human"] AA.defaultOpts))
  , check "--format=json via preprocess"
      (rOr False AA.aoJson (AA.parseArgs (AA.preprocess ["--format=json"]) AA.defaultOpts))
  , check "--json alias still sets aoJson"
      (rOr False AA.aoJson (AA.parseArgs ["--json"] AA.defaultOpts))
  , check "--format bogus is an error"
      (isLeft (AA.parseArgs ["--format", "bogus"] AA.defaultOpts))
  , check "config format: json decodes to aoJson"
      (case Y.decodeEither' (TE.encodeUtf8 (T.pack "format: json\n")) of
         Left _   -> False
         Right fc -> AA.aoJson (AC.applyConfig fc AA.defaultOpts))
  , check "unknown flag is an error"
      (isLeft (AA.parseArgs ["--nope"] AA.defaultOpts))
  , check "a short unknown flag is an error"
      (isLeft (AA.parseArgs ["-x"] AA.defaultOpts))
  , check "value-flag with no value is an error"
      (isLeft (AA.parseArgs ["--timeout"] AA.defaultOpts))
  -- defaults < config < CLI.
  , checkEq "config overlays a scalar onto defaults"
      5000 (AA.aoWallBudget (AC.applyConfig cfgWall AA.defaultOpts))
  , check "empty config is a no-op"
      (AC.applyConfig AC.emptyFileConfig AA.defaultOpts == AA.defaultOpts)
  , check "CLI overrides config for a scalar (write)"
      (rOr False AA.aoWrite (AA.parseArgs ["--write"] (AC.applyConfig cfgNoWrite AA.defaultOpts)))
  , checkEq "config list is the base; CLI appends after it"
      (Right ["cfgInc", "cliInc"])
      (AA.aoIncludes <$> AA.parseArgs ["-i", "cliInc"] (AC.applyConfig cfgInc AA.defaultOpts))
  -- --repair / --fixpoint / --ledger flags.
  , check "--repair sets aoRepair"
      (rOr False AA.aoRepair (AA.parseArgs ["--repair"] AA.defaultOpts))
  , check "--fixpoint sets aoFixpoint"
      (rOr False AA.aoFixpoint (AA.parseArgs ["--fixpoint"] AA.defaultOpts))
  , checkEq "--ledger sets the path"
      (Right (Just "l.jsonl")) (AA.aoLedger <$> AA.parseArgs ["--ledger", "l.jsonl"] AA.defaultOpts)
  , check "config sets a fixpoint flag; empty config leaves it"
      (AA.aoFixpoint (AC.applyConfig (AC.emptyFileConfig { AC.fcFixpoint = Just True }) AA.defaultOpts))
  -- `--show-defaults` emits valid YAML that decodes to a FileConfig and, applied
  -- to the defaults, is a no-op overlay: the dump both parses and faithfully
  -- reflects the built-in defaults (guards against key typos / value drift).
  , check "--show-defaults YAML parses and round-trips to defaultOpts"
      (case Y.decodeEither' (TE.encodeUtf8 (T.pack AA.defaultsYaml)) of
         Left _   -> False
         Right fc -> AC.applyConfig fc AA.defaultOpts == AA.defaultOpts)
  ]
  where
    rOr d f    = either (const d) f
    isLeft     = either (const True) (const False)
    cfgWall    = AC.emptyFileConfig { AC.fcWallBudget = Just 5000 }
    cfgNoWrite = AC.emptyFileConfig { AC.fcWrite = Just False }
    cfgInc     = AC.emptyFileConfig { AC.fcIncludes = Just ["cfgInc"] }

----------------------------------------------------------------------
-- renderAutoAll: the pure prose the MCP `auto_all` tool emits.
--
-- The live byte-identity of the refactor is checked against a real daemon in
-- test/auto/smoke.sh; these pins lock the pure function so a later edit can't
-- drift it, and cover the OOS-import-line and abort branches that are hard to
-- produce live. The dashes are U+2014 (—) and the ellipsis U+2026 (…), matching
-- the renderer source exactly.

autoRenderTests :: [Check]
autoRenderTests =
  [ checkEq "render: no open goals"
      "Loaded Foo.agda — no open goals; nothing for Mimer to try."
      (renderAutoAll (noGoalsOutcome "Foo.agda"))
  , checkEq "render: all solved (headline + trailing blank line)"
      "Mimer solved 1 of 1 open goal(s): g0.\n\n"
      (renderAutoAll base { aoGoalCount = 1, aoSolved = ["g0"], aoNew = Just "x" })
  , checkEq "render: solved none + survivors line"
      ( "Mimer solved none of the 2 open goal(s) in Foo.agda (per-goal budget 5s)."
          <> "\nMimer found nothing for: g0, g1 — try a `construct` refine step, "
          <> "`lemmas goal=…`, or `construct` an explicit give." )
      (renderAutoAll base { aoGoalCount = 2, aoUnsolved = ["g0", "g1"] })
  , checkEq "render: mixed — headline + survivors + OOS import line + abort"
      ( "Mimer solved 1 of 3 open goal(s): g0."
          <> "\nMimer found nothing for: g1, g2 — try a `construct` refine step, "
          <> "`lemmas goal=…`, or `construct` an explicit give."
          <> "\nNote — 1 graph-ranked hint(s) are not in the file's import scope, "
          <> "so Mimer could not try them:\n"
          <> "  - `+-suc` — add `open import Data.Nat.Properties using (+-suc)`\n"
          <> "Add the import(s) and re-run `auto_all`, or run `repair file=…` to add them for you."
          <> "\nsession died"
          <> "\n\n" )
      (renderAutoAll base
         { aoGoalCount = 3, aoSecs = 7, aoSolved = ["g0"], aoUnsolved = ["g1", "g2"]
         , aoAllCands = [("+-suc", sucDef)], aoOosNames = ["+-suc"]
         , aoAbort = Just "session died", aoNew = Just "..." })
  , checkEq "oosNote empty in → blank out" "" (oosNote "auto" [] [])
  , check "oosNote names a known def's import line"
      ("open import Data.Nat.Properties using (+-suc)"
         `T.isInfixOf` oosNote "auto" [("+-suc", sucDef)] ["+-suc"])
  , check "oosNote omits an import line for an unknown name"
      (not ("open import" `T.isInfixOf` oosNote "auto" [] ["mystery"]))
  ]
  where
    base   = (noGoalsOutcome "Foo.agda") { aoNoGoals = False, aoSecs = 5 }
    sucDef = mkDef "Data.Nat.Properties.+-suc" "Data.Nat.Properties" KFunction Nothing

----------------------------------------------------------------------
-- AgdaAuto.Report: exit-code policy + JSON contract + human table.
--
-- The JSON field names are a public contract; the golden pin below is the
-- tripwire (compared as decoded Values, so key order is irrelevant but any
-- rename/add/drop/value change trips it).

autoReportTests :: [Check]
autoReportTests =
  [ checkEq "exit: no goals → success"  ExitSuccess     (outcomeExit (noGoalsOutcome "F.agda"))
  , checkEq "exit: all solved → success" ExitSuccess    (outcomeExit (oc [solvedG] Nothing))
  , checkEq "exit: an unsolved hole → 1" (ExitFailure 1) (outcomeExit (oc [solvedG, unsolvedG] Nothing))
  , checkEq "exit: a skipped hole → 1"   (ExitFailure 1) (outcomeExit (oc [skippedG] Nothing))
  , checkEq "exit: abort → 1 even with a solve"
      (ExitFailure 1) (outcomeExit (oc [solvedG] (Just "session died")))
  , check "json matches the golden (field-name/value tripwire)"
      (case eitherDecode (BLC.pack goldenReportJson) :: Either String Value of
         Right gold -> outcomeJson True "DIFF" (oc [solvedG, unsolvedG, skippedG] Nothing) == gold
         Left  _    -> False)
  , check "json round-trips through its own encoding"
      (let v = outcomeJson True "DIFF" (oc [solvedG, unsolvedG, skippedG] Nothing)
       in (eitherDecode (encode v) :: Either String Value) == Right v)
  , checkEq "human report header"
      "F.agda: 3 hole(s) — 1 filled, 1 unsolved, 1 skipped"
      (head (T.lines (renderHumanReport (oc [solvedG, unsolvedG, skippedG] Nothing))))
  , check "human report names a solving lemma"
      ("g0 9:7  filled — via lemma `+-comm`"
         `T.isInfixOf` renderHumanReport (oc [solvedG] Nothing))
  , check "human report flags an unsolved hole with hint counts"
      ("g1 12:5  UNSOLVED — 1 hint(s) tried, 1 out of scope"
         `T.isInfixOf` renderHumanReport (oc [unsolvedG] Nothing))
  -- A solve via a hole-supplied hint is tagged "(from hole)".
  , check "human report tags a from-hole solve"
      ("via lemma `+-comm` (from hole)" `T.isInfixOf` renderHumanReport (oc [holeSolvedG] Nothing))
  , check "human report does not tag a graph solve as from-hole"
      (not ("(from hole)" `T.isInfixOf` renderHumanReport (oc [solvedG] Nothing)))

  -- annotationEdits (shared by agda-auto + MCP annotate:true).
  , check "annotationEdits: a marker edit for an unsolved hole"
      (case annotationEdits True 5 bigOrig [unsolvedG] of
         [(s, e, repl)] -> s == 60 && e == 65
                             && "agda-auto/1" `T.isInfixOf` repl
                             && "n + 0 ≡ n"  `T.isInfixOf` repl
         _              -> False)
  , checkEq "annotationEdits: off ⇒ no edits"   [] (annotationEdits False 5 bigOrig [unsolvedG])
  , checkEq "annotationEdits: solved ⇒ no edit"  [] (annotationEdits True 5 bigOrig [solvedG])
  , checkEq "annotationEdits: skipped (no range) ⇒ no edit" [] (annotationEdits True 5 bigOrig [skippedG])

  -- ledgerLines (one JSON object per goal; order-insensitive compare).
  , checkEq "ledger: a solved goal's line"
      (object [ "file" .= ("F.agda" :: Text), "goal" .= ("g0" :: Text)
              , "type" .= ("Nat" :: Text), "status" .= ("solved" :: Text)
              , "term" .= ("x" :: Text), "via" .= ("lemma:+-comm" :: Text)
              , "fromHole" .= False ])
      (head (ledgerLines "F.agda" (oc [solvedG] Nothing)))
  , checkEq "ledger: a from-hole solve is flagged"
      (object [ "file" .= ("F.agda" :: Text), "goal" .= ("g0" :: Text)
              , "type" .= ("Nat" :: Text), "status" .= ("solved" :: Text)
              , "term" .= ("x" :: Text), "via" .= ("lemma:+-comm" :: Text)
              , "fromHole" .= True ])
      (head (ledgerLines "F.agda" (oc [holeSolvedG] Nothing)))
  , checkEq "ledger: an unsolved goal's line"
      (object [ "file" .= ("F.agda" :: Text), "goal" .= ("g1" :: Text)
              , "type" .= ("n + 0 ≡ n" :: Text), "status" .= ("unsolved" :: Text)
              , "hints" .= (["h1"] :: [Text]), "holeHints" .= ([] :: [Text]) ])
      (head (ledgerLines "F.agda" (oc [unsolvedG] Nothing)))
  , checkEq "ledger: one line per goal" 3 (length (ledgerLines "F.agda" (oc [solvedG, unsolvedG, skippedG] Nothing)))
  ]
  where
    oc goals abort = (noGoalsOutcome "F.agda")
      { aoNoGoals = False, aoGoalCount = length goals, aoGoals = goals, aoAbort = abort }
    bigOrig = T.replicate 100 "x"
    gr l c s e = GoalRange (RangePos l c s) (RangePos l c e)
    sucDef = mkDef "Data.Nat.Properties.+-suc" "Data.Nat.Properties" KFunction Nothing
    h1Def  = mkDef "M.h1" "M" KFunction Nothing
    solvedG = GoalReport "g0" "Nat" (Just (gr 9 7 40 45))
                (GSolved "x" (ViaHint "+-comm")) [] [] [] []
    holeSolvedG = solvedG { grHoleHints = ["+-comm"] }
    unsolvedG = GoalReport "g1" "n + 0 ≡ n" (Just (gr 12 5 60 65))
                  (GUnsolved Nothing) [("h1", h1Def)] [("+-suc", sucDef)] [] []
    skippedG = GoalReport "g2" "?" Nothing GSkipped [] [] [] []
    goldenReportJson =
      "{\"file\":\"F.agda\",\"goals\":3,\"solved\":1,\"unsolved\":1,\"skipped\":1,\
      \\"wrote\":true,\"aborted\":null,\"diff\":\"DIFF\",\"holes\":[\
      \{\"id\":\"g0\",\"status\":\"solved\",\"line\":9,\"col\":7,\"term\":\"x\",\"via\":\"lemma:+-comm\"},\
      \{\"id\":\"g1\",\"status\":\"unsolved\",\"line\":12,\"col\":5,\"hints\":[\"h1\"],\
      \\"imports\":[\"open import Data.Nat.Properties using (+-suc)\"]},\
      \{\"id\":\"g2\",\"status\":\"skipped\"}]}"

----------------------------------------------------------------------
-- AgdaInteract.Annotate: the in-hole marker grammar.
--
-- All pure. The live end-to-end (marker loads in agda, second run is a zero
-- diff) is in test/auto/smoke.sh; these lock the algebra: round-trip,
-- idempotence, user-content preservation, comment-safety, the ?-rewrite.

annotateTests :: [Check]
annotateTests =
  -- Round-trip on normalised annotations (render is lossy — collapses ws +
  -- truncates — so only normalised values round-trip; that is the contract).
  [ checkEq "round-trip: full annotation"   (Just a1) (parseMarker (renderMarker a1))
  , checkEq "round-trip: empty try + import" (Just a2) (parseMarker (renderMarker a2))
  , check "parseMarker: no marker → Nothing"
      (parseMarker "just some hole text" == Nothing)
  , check "parseMarker: finds a marker embedded after user content"
      (parseMarker (annotateHole "{! myTerm !}" a1) == Just a1)

  -- Idempotence: annotate∘annotate = annotate, for every hole shape.
  , check "idempotent: bare ?"        (idem "?")
  , check "idempotent: empty {!!}"    (idem "{!!}")
  , check "idempotent: spaced {!  !}" (idem "{!   !}")
  , check "idempotent: {! userExpr !}" (idem "{! foo x !}")
  , check "idempotent: multi-line hole" (idem "{! foo\n  bar !}")
  , check "idempotent: a hole already carrying a marker"
      (idem (annotateHole "{! keep !}" a2))

  -- User content survives annotate → strip verbatim.
  , checkEq "preserves user content" "myTerm"
      (stripMarker (holeInnerOf (annotateHole "{! myTerm !}" a1)))
  , checkEq "strip of a marker-only hole is empty" ""
      (stripMarker (holeInnerOf (annotateHole "{!!}" a1)))

  -- Comment-safety: nasty goal types cannot unbalance the nesting lexer, and
  -- cannot close the hole early.
  , check "sanitize kills an opener"  (not ("{-" `T.isInfixOf` sanitize "a {- b"))
  , check "sanitize kills a closer"   (not ("-}" `T.isInfixOf` sanitize "a -} b"))
  , check "sanitize kills a hole-closer" (not ("!}" `T.isInfixOf` sanitize "a !} b"))
  , check "sanitize output stays balanced on nested tokens"
      (commentBalanced (sanitize "{- {- -} -}"))
  , check "rendered marker is comment-balanced (nasty goal)"
      (commentBalanced (renderMarker nasty))
  , check "annotated hole is comment-balanced (nasty goal)"
      (commentBalanced (annotateHole "{! foo !}" nasty))
  , check "annotated hole has exactly one hole-closer"
      (T.count "!}" (annotateHole "{! foo !}" nasty) == 1)

  -- ?-rewrite is one-way (documented): ? becomes a braced hole.
  , check "annotateHole ? yields a braced hole"
      ("{!" `T.isPrefixOf` annotateHole "?" a2)
  , check "annotated ? is no longer a bare ?"
      (annotateHole "?" a2 /= "?")

  -- Truncation: an over-long goal type is cut with an ellipsis.
  , check "long goal type is truncated with …"
      ("…" `T.isInfixOf` renderMarker (a1 { annGoalType = T.replicate 300 "x" }))

  -- holeHints extracts candidate names from a hole's text.
  , checkEq "holeHints: bare identifier"      ["+-comm"] (holeHints "{! +-comm !}")
  , checkEq "holeHints: several, in order"    ["trans", "foo", "x", "bar"]
      (holeHints "{! trans (foo x) bar !}")
  , checkEq "holeHints: qualified → base"     ["lemma"]  (holeHints "{! M.N.lemma !}")
  , checkEq "holeHints: mixfix operator kept" ["_+_"]    (holeHints "{! _+_ !}")
  , checkEq "holeHints: dedup"                ["foo"]    (holeHints "{! foo foo !}")
  , checkEq "holeHints: empty hole"           []         (holeHints "{!!}")
  , checkEq "holeHints: bare ?"               []         (holeHints "?")
  , check   "holeHints: drops ? and _"        (holeHints "{! ? _ !}" == [])
  , checkEq "holeHints: marker-only hole → its try: list"
      ["+-identityʳ", "+-comm"] (holeHints (annotateHole "{!!}" a1))
  , checkEq "holeHints: user content FIRST, then marker try:, deduped"
      ["myLemma", "+-identityʳ", "+-comm"] (holeHints (annotateHole "{! myLemma !}" a1))
  , check "holeHints: garbage is lenient (no crash)"
      (holeHints "{! ((( ; , @ !}" `seq` True)
  ]
  where
    a1 = Annotation "n + 0 ≡ n" "plain 5s + 4 hints"
                    ["+-identityʳ", "+-comm"]
                    ["open import Data.Nat.Properties using (+-suc)"]
    a2 = Annotation "Nat" "plain 1s + 0 hints" [] []
    nasty = Annotation "a {- b -} c {-{- x -}-} !} d" "x" [] []
    idem h = annotateHole (annotateHole h a1) a1 == annotateHole h a1
    -- Mirror AgdaInteract.Annotate.holeInner (unexported) for the tests.
    holeInnerOf raw =
      let h = T.strip raw
      in if h == "?" then ""
         else if "{!" `T.isPrefixOf` h && "!}" `T.isSuffixOf` h
                then T.strip (T.dropEnd 2 (T.drop 2 h))
                else h

----------------------------------------------------------------------
-- Project-mode aggregation + topological file ordering.

aggregateTests :: [Check]
aggregateTests =
  [ checkEq "summarize: sums per-file counts + counts files"
      (Summary 3 10 7 2 3)
      (summarize [(4, 3, 1, 1), (5, 4, 0, 1), (1, 0, 1, 1)])
  , checkEq "summarize: empty sweep" (Summary 0 0 0 0 0) (summarize [])
  , checkEq "worstExit: all success → success" ExitSuccess (worstExit [ExitSuccess, ExitSuccess])
  , checkEq "worstExit: worst (largest) failure wins"
      (ExitFailure 2) (worstExit [ExitSuccess, ExitFailure 1, ExitFailure 2, ExitFailure 1])
  , checkEq "worstExit: empty → success" ExitSuccess (worstExit [])
  ]

-- | 'moduleDependencyOrder' on controlled synthetic graphs: a chain A→B→C (A
-- uses B uses C) must order dependencies first (C, B, A); a module cycle P↔Q
-- must still yield a total, complete order (the DFS breaks the cycle, never
-- loops or drops a module). Real graphs can have cross-module cycles, so a
-- "zero back-edges" assertion on the fixture would be wrong — this pins the
-- ordering contract without that fragility.
moduleTopoTests :: [Check]
moduleTopoTests =
  [ checkEq "moduleDependencyOrder: dependencies first (C, B, A)"
      ["C", "B", "A"] (moduleDependencyOrder dagIx)
  , check "moduleDependencyOrder: a module cycle stays total + complete"
      (Set.fromList (moduleDependencyOrder cycIx) == Set.fromList ["P", "Q"]
         && length (moduleDependencyOrder cycIx) == 2)
  ]
  where
    dagIx = buildIndex (decodeG dagJson)
    cycIx = buildIndex (decodeG cycJson)
    decodeG bs = either (error . ("moduleTopo fixture: " ++)) id (eitherDecode bs)
    gJson mods defs edges = BLC.pack $ unlines
      [ "{ \"v\": 2, \"mode\": \"expanded\", \"schemaVersion\": 2"
      , ", \"modules\": [" ++ intercalate ", " [ "\"" ++ m ++ "\"" | m <- mods ] ++ "]"
      , ", \"moduleFiles\": {}"
      , ", \"definitions\": [" ++ intercalate ", "
          [ "{ \"name\": \"" ++ n ++ "\", \"module\": \"" ++ m ++ "\", \"kind\": \"function\" }"
          | (n, m) <- defs ] ++ "]"
      , ", \"definitionEdges\": [" ++ intercalate ", "
          [ "[\"" ++ s ++ "\", \"" ++ t ++ "\"]" | (s, t) <- edges ] ++ "]"
      , "}"
      ]
    -- A.f uses B.g uses C.h  ⇒  A depends on B depends on C.
    dagJson = gJson ["A", "B", "C"]
                    [("A.f", "A"), ("B.g", "B"), ("C.h", "C")]
                    [("A.f", "B.g"), ("B.g", "C.h")]
    -- P.x ↔ Q.y (mutually referential across modules).
    cycJson = gJson ["P", "Q"]
                    [("P.x", "P"), ("Q.y", "Q")]
                    [("P.x", "Q.y"), ("Q.y", "P.x")]

-- | The recorded any-hit@6 floor for `baseline` on .agda-explore/deps.json.
-- Equal to the current value, so any downward move trips the test — raise or
-- lower it only deliberately, alongside a fixture or ranker change.
premiseBenchFloor :: Double
premiseBenchFloor = 0.2

premiseBenchTests :: IORef Int -> IO ()
premiseBenchTests ref = do
  e <- loadExpandedGraph ".agda-explore/deps.json"
  case e of
    Left err ->
      check ("hint-bench: .agda-explore/deps.json decodes (" ++ err ++ ")") False ref
    Right g -> do
      let ix    = buildIndex g
          env   = mkRankEnv [ defAt ix i | i <- [0 .. idxRealCount ix - 1] ] Map.empty
          opts  = defaultBenchOpts
          rows  = benchRows ix opts
      check "hint-bench: fixture yields a non-empty corpus" (not (null rows)) ref
      case lookupStrategy "baseline" rows env opts of
        Nothing    -> check "hint-bench: baseline strategy is registered" False ref
        Just strat -> do
          let rep = scoreStrategy opts strat rows
              a6  = maybe 0 id (lookup 6 (brpAnyHitAt rep))
          check ("hint-bench: baseline any-hit@6 (" ++ show a6
                   ++ ") >= floor " ++ show premiseBenchFloor)
            (a6 >= premiseBenchFloor - 1e-9) ref
      -- Graceful degradation: no per-edge provenance → no premise ground
      -- truth → zero rows (the classifier names provenance).
      let ixNoProv   = buildIndex g { egEdgeProvenance = [] }
          rowsNoProv = benchRows ixNoProv opts
      check "hint-bench: no edge provenance yields zero rows" (null rowsNoProv) ref
      check "hint-bench: no-provenance reason mentions provenance"
        (maybe False ("provenance" `T.isInfixOf`) (noRowReason ixNoProv rowsNoProv)) ref
      -- Graceful degradation: no signatures → no goal text → zero rows.
      let ixNoSig   = buildIndex g { egDefinitions = map (\d -> d { defSig = Nothing })
                                                         (egDefinitions g) }
          rowsNoSig = benchRows ixNoSig opts
      check "hint-bench: no signatures yields zero rows" (null rowsNoSig) ref
      check "hint-bench: no-signature reason mentions signatures"
        (maybe False ("signatures" `T.isInfixOf`) (noRowReason ixNoSig rowsNoSig)) ref

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

  -- auto-batch.jsonl (Phase-3a) → a multi-hint Cmd_autoOne batch returns the
  -- COMBINED term `trans' eq1 eq2`, which no single hint reaches. Pins the
  -- batch semantics verified on this agda (2.8.0 dir); a future agda that
  -- aborts the batch instead would drop the GiveAction and fail this.
  batchRs <- parseLines "test/interaction/2.8.0/auto-batch.jsonl"
  check "auto-batch.jsonl: batch combines two hints into `trans' eq1 eq2`"
    (case [s | ReplyGiveAction 0 (GiveStr s) <- batchRs] of
       (s:_) -> s == "trans' eq1 eq2"
       _     -> False) ref

  -- auto-hole-content.jsonl → plain Cmd_autoOne on a hole whose body
  -- names an in-scope lemma returns NO GiveAction (the goal stays open): Mimer
  -- does not read hole contents as a hint on this agda, so agda-auto seeds them
  -- explicitly. A future agda that consumed hole bodies would add a GiveAction
  -- and fail the first check — the signal to simplify the seeding.
  holeRs <- parseLines "test/interaction/2.8.0/auto-hole-content.jsonl"
  check "auto-hole-content.jsonl: hole body is NOT a native Mimer hint (no give)"
    (null [() | ReplyGiveAction{} <- holeRs]) ref
  check "auto-hole-content.jsonl: the goal stayed open after the probe"
    (any ((== "n + 0 ≡ n") . goalType)
         (concat [gs | ReplyDisplayInfo (AllGoalsWarnings gs _ _) <- holeRs])) ref

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
-- Content stamps + external-change goal-id reset.

stampTests :: [Check]
stampTests =
  [ check "contentStamp: identical text hashes equal"
      (contentStamp "module M where\nfoo = 0\n" == contentStamp "module M where\nfoo = 0\n")
  , check "contentStamp: a one-char change differs"
      (contentStamp "foo = 0\n" /= contentStamp "foo = 1\n")
  , check "contentStamp: unicode is distinguished from its ascii spelling"
      (contentStamp "n → n" /= contentStamp "n -> n")
  -- shouldKeepGoalIds (expected-write) (prev-stamp) (new-stamp)
  , check "keep: a bridge write whose disk matches what we wrote"
      (shouldKeepGoalIds (Just 7) (Just 3) (Just 7))
  , check "reset: a bridge write whose disk no longer matches"
      (not (shouldKeepGoalIds (Just 7) (Just 3) (Just 9)))
  , check "keep: a plain reload of unchanged content"
      (shouldKeepGoalIds Nothing (Just 3) (Just 3))
  , check "reset: a plain reload of changed content"
      (not (shouldKeepGoalIds Nothing (Just 3) (Just 9)))
  , check "reset: an unknown new stamp (unreadable / changed mid-load)"
      (not (shouldKeepGoalIds Nothing (Just 3) Nothing))
  , check "reset: a first load (no prior stamp, no expectation)"
      (not (shouldKeepGoalIds Nothing Nothing (Just 3)))
  -- dropEntriesKeepNext: a stale id fails, and new holes get FRESH ids.
  , check "external change: dropEntriesKeepNext + re-sync mints fresh ids, old id gone"
      (let (gm0, _)  = syncGoals emptyGoalMap [mkGoal 0 81 "Nat", mkGoal 1 127 "Nat"]
           gmReset   = dropEntriesKeepNext gm0
           (gm1, es) = syncGoals gmReset [mkGoal 0 81 "Nat", mkGoal 1 127 "Nat"]
       in map geStable es == [StableId 2, StableId 3]     -- counter preserved
            && toInteractionId gm1 (StableId 0) == Nothing  -- stale g0 fails loudly
            && toInteractionId gm1 (StableId 2) == Just 0)
  ]

----------------------------------------------------------------------
-- Wall-clock budget clamp (the underflow guard that keeps `timeout`
-- from ever being handed a negative "wait forever" argument).

budgetTests :: [Check]
budgetTests =
  [ checkEq "clamp: 5ms remaining on a 10ms deadline is 5000µs"
      5000 (clampRemainingMicros 10000000 5000000)
  , checkEq "clamp: exactly at the deadline is 0µs"
      0 (clampRemainingMicros 5000000 5000000)
  , checkEq "clamp: past the deadline is 0µs (no Word64 underflow)"
      0 (clampRemainingMicros 5000000 9000000)
  ]

----------------------------------------------------------------------
-- Batcher dispatch logic: construct `Step` parsing + wildcard / all-give
-- discriminators, and the inspect / scratch `op` validators. Pure — the
-- IO runners in AgdaInteract.Tools route on exactly these decisions, so a
-- byte-identical-to-auto_all / -to-give_many diff is a live-agda-only check.

isLeft' :: Either a b -> Bool
isLeft' (Left _) = True
isLeft' _        = False

decodeStep :: BL.ByteString -> Either String Step
decodeStep = eitherDecode

stepTriple :: Step -> (Text, Text, Maybe Text)
stepTriple (Step op g marg) = (op, g, marg)

batchTests :: [Check]
batchTests =
  -- Step FromJSON: the single op-arg slot collapses term/expr/var, and the
  -- `*` wildcard goal round-trips.
  [ checkEq "Step give parses term into the arg slot"
      (Right ("give", "g0", Just "suc n"))
      (stepTriple <$> decodeStep "{\"op\":\"give\",\"goal\":\"g0\",\"term\":\"suc n\"}")
  , checkEq "Step refine parses expr into the arg slot"
      (Right ("refine", "g1", Just "f"))
      (stepTriple <$> decodeStep "{\"op\":\"refine\",\"goal\":\"g1\",\"expr\":\"f\"}")
  , checkEq "Step case_split parses var into the arg slot"
      (Right ("case_split", "g2", Just "xs ys"))
      (stepTriple <$> decodeStep "{\"op\":\"case_split\",\"goal\":\"g2\",\"var\":\"xs ys\"}")
  , checkEq "Step auto wildcard goal parses as \"*\" with no arg"
      (Right ("auto", "*", Nothing))
      (stepTriple <$> decodeStep "{\"op\":\"auto\",\"goal\":\"*\"}")

  -- wildcardCheck: a lone {auto,*} is the auto_all shorthand; `*` on any other
  -- op, or mixed with further steps, is rejected; no `*` ⇒ ordinary path.
  , checkEq "wildcardCheck: lone {auto,*} is the auto_all shorthand"
      (Right True)  (wildcardCheck [Step "auto" "*" Nothing])
  , checkEq "wildcardCheck: no wildcard ⇒ ordinary construct path"
      (Right False) (wildcardCheck [Step "give" "g0" (Just "x"), Step "auto" "g1" Nothing])
  , check "wildcardCheck rejects `*` on give"
      (isLeft' (wildcardCheck [Step "give" "*" (Just "x")]))
  , check "wildcardCheck rejects `*` on refine"
      (isLeft' (wildcardCheck [Step "refine" "*" (Just "f")]))
  , check "wildcardCheck rejects `*` on case_split"
      (isLeft' (wildcardCheck [Step "case_split" "*" (Just "n")]))
  , check "wildcardCheck rejects wildcard auto mixed with another step"
      (isLeft' (wildcardCheck [Step "auto" "*" Nothing, Step "give" "g0" (Just "x")]))

  -- allGiveSteps: the single-load atomic fast-path discriminator.
  , check "allGiveSteps true for an all-give batch"
      (allGiveSteps [Step "give" "g0" (Just "x"), Step "give" "g1" (Just "y")])
  , check "allGiveSteps false when any non-give step is present"
      (not (allGiveSteps [Step "give" "g0" (Just "x"), Step "auto" "g1" Nothing]))

  -- inspect: op parsing + expr requirement (infer/normalize need expr).
  , checkEq "inspect op=type needs no expr"       (Right "type")    (checkInspectArgs (Just "type") Nothing)
  , checkEq "inspect op=context needs no expr"    (Right "context") (checkInspectArgs (Just "context") Nothing)
  , checkEq "inspect op=infer with expr is valid" (Right "infer")   (checkInspectArgs (Just "infer") (Just "n + 0"))
  , check "inspect op=infer without expr is rejected"     (isLeft' (checkInspectArgs (Just "infer") Nothing))
  , check "inspect op=normalize without expr is rejected" (isLeft' (checkInspectArgs (Just "normalize") Nothing))
  , check "inspect rejects an unknown op"                 (isLeft' (checkInspectArgs (Just "bogus") Nothing))
  , check "inspect requires an op"                        (isLeft' (checkInspectArgs Nothing (Just "x")))
  , checkEq "inspectOps enumerates the four read ops"
      ["type", "context", "infer", "normalize"] inspectOps

  -- scratch: op parsing (per-op required fields are enforced by the runners).
  , checkEq "scratch op=open is valid"    (Right "open")    (checkScratchOp (Just "open"))
  , checkEq "scratch op=promote is valid" (Right "promote") (checkScratchOp (Just "promote"))
  , checkEq "scratch op=discard is valid" (Right "discard") (checkScratchOp (Just "discard"))
  , check "scratch rejects an unknown op" (isLeft' (checkScratchOp (Just "open-file")))
  , check "scratch requires an op"        (isLeft' (checkScratchOp Nothing))
  , checkEq "scratchOps enumerates the three lifecycle ops"
      ["open", "promote", "discard"] scratchOps
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

-- Real Agda 2.9 [NoParseForLHS] renderings (captured).
-- A missing constructor in a pattern surfaces as an alphabetic token in the
-- "Problematic expression" (not a symbolic one), and a missing _,_ as a bare
-- comma.
parseLhsCtorMsg :: Text
parseLhsCtorMsg = T.intercalate "\n"
  [ "/tmp/x/CtorParse.agda:6.1-11: error: [NoParseForLHS]"
  , "Could not parse the left-hand side f (just x)"
  , "Problematic expression: (just x)"
  , "Operators used in the grammar:"
  , "  None"
  , "when scope checking the left-hand side f (just x) in the definition"
  , "of f" ]

parseLhsCommaMsg :: Text
parseLhsCommaMsg = T.intercalate "\n"
  [ "/tmp/x/CommaPat.agda:9.1-10: error: [NoParseForLHS]"
  , "Could not parse the left-hand side f (a , b)"
  , "Problematic expression: ((a ,) b)"
  , "Operators used in the grammar:"
  , "  None"
  , "when scope checking the left-hand side f (a , b) in the definition"
  , "of f" ]

diagnosticTests :: [Check]
diagnosticTests =
  [ checkEq "notInScopeNames extracts the reported operator/name"
      ["\8484"] (RD.notInScopeNames notInScopeMsg)
  , check "notInScopeNames drops the stopword in 'when scope checking the declaration'"
      ("the" `notElem` RD.notInScopeNames missingSigMsg)
  , check "parseErrorNames pulls the dropped operator out of a NoParseForApplication"
      ("_\8804_" `elem` RD.parseErrorNames parseAppMsg)
  , check "parseErrorNames subtracts an in-grammar (in-scope) operator (× is listed)"
      ("\215" `notElem` RD.parseErrorNames parseAppMsg)
  -- alphabetic tokens ARE now collected (a bare constructor name), but
  -- ordered AFTER the symbolic ones and bounded by classify's cap + the Env
  -- hit filter — so a `just`/`AllPairs` is a candidate, not silently dropped.
  , check "parseErrorNames now collects alphabetic tokens too, ordered after symbolic ones"
      (let ns = RD.parseErrorNames parseAppMsg
       in "AllPairs" `elem` ns
            && case (elemIndex "_\8804_" ns, elemIndex "AllPairs" ns) of
                 (Just i, Just j) -> i < j
                 _                -> False)
  -- a missing constructor is an alphabetic Problematic token.
  , check "parseErrorNames extracts a missing constructor (just) from a NoParseForLHS"
      ("just" `elem` RD.parseErrorNames parseLhsCtorMsg)
  , check "parseErrorNames drops the 1-char pattern var (x)"
      ("x" `notElem` RD.parseErrorNames parseLhsCtorMsg)
  -- a missing _,_ is a bare comma the old delimiter set discarded.
  , check "parseErrorNames keeps a bare comma (a missing _,_)"
      ("," `elem` RD.parseErrorNames parseLhsCommaMsg)
  , check "nameKeys maps a bare comma onto its mixfix _,_"
      ("_,_" `elem` RD.nameKeys ",")
  , checkEq "grammarOperators reads the in-scope operators list"
      ["\215"] (RD.grammarOperators parseAppMsg)
  , check "grammarOperators is empty when the section says None"
      (null (RD.grammarOperators parseLhsCtorMsg))
  , checkEq "classify caps the DParse frontier at 6"
      6 (length [ () | RD.DParse _ <- RD.classify [parseAppMsg] ])
  , check "stillMissingNames unions scope + parse names, minus grammar operators"
      (let ns = RD.stillMissingNames parseAppMsg
       in "_\8804_" `elem` ns && "\215" `notElem` ns)
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
  -- hintOutOfScope: a Mimer hint the file hasn't imported must be
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
  [ check "insertImport places the line after the last import"
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

----------------------------------------------------------------------
-- Config-file key vocabulary (AgdaGraph.ConfigCore).
--
-- A YAML key no reader looks up is a typo or a stale name; either way the
-- value silently does nothing, which is the one failure mode a config file
-- cannot show you. These pin the rejection + the suggestion heuristic, plus
-- the `extractValueFlag` lifting that makes `--config` position-independent
-- (see AgdaOptimization.CLI.run — the scanner reserves the post-subcommand
-- slot for the graph path and never peels it).

configKeyTests :: [Check]
configKeyTests =
  [ checkEq "unknownKeys: reports only the strays, ascending"
      ["aa", "zz"] (unknownKeys ["a", "b"] (keyObj ["b", "zz", "aa"]))
  , check "unknownKeyError: a fully-known object is accepted"
      (unknownKeyError "cfg" ["a", "b"] (keyObj ["a"]) == Nothing)
  , checkEq "unknownKeyError: one stray, with a near-miss suggestion"
      (Just "cfg: unknown key: min-suport (did you mean min-support?)")
      (unknownKeyError "cfg" ["min-support", "top-n"] (keyObj ["min-suport"]))
  , checkEq "unknownKeyError: several strays are pluralised and joined"
      (Just "cfg: unknown keys: min-suport (did you mean min-support?), \
            \topn (did you mean top-n?)")
      (unknownKeyError "cfg" ["min-support", "top-n"] (keyObj ["topn", "min-suport"]))
  , checkEq "unknownKeyError: an unrelated key gets no misleading suggestion"
      (Just "cfg: unknown key: zzzzzzzzzz")
      (unknownKeyError "cfg" ["min-support", "top-n"] (keyObj ["zzzzzzzzzz"]))
  , check "checkKnownKeys: Right on a clean object, Left otherwise"
      (checkKnownKeys "cfg" ["a"] (keyObj ["a"]) == Right ()
        && isLeftE (checkKnownKeys "cfg" ["a"] (keyObj ["b"])))
  -- Suggestions: a toggle pair puts the CLI flag (`--no-include-postulates`)
  -- three edits from the key it reads, so containment is tried first.
  , checkEq "nearestKey: a negated flag spelling finds its positive key"
      (Just "include-postulates")
      (nearestKey "no-include-postulates" ["include-postulates", "foundational-inventory"])
  , checkEq "nearestKey: a one-character typo"
      (Just "graph") (nearestKey "grap" ["graph", "format", "out"])
  , checkEq "nearestKey: containment needs to dominate both keys"
      Nothing (nearestKey "timeout" ["out"])
  , checkEq "nearestKey: nothing close enough stays silent"
      Nothing (nearestKey "wholly-different" ["graph", "format"])
  , checkEq "nearestKey: a short key gets a tighter budget"
      Nothing (nearestKey "abcd" ["wxyz"])
  -- The agda-auto instance, as a live example of the FromJSON-side check.
  , check "agda-auto config: an unknown key fails the decode"
      (isLeftY (decodeAuto "timeuot: 5\n"))
  , check "agda-auto config: the same key spelled right decodes"
      (either (const False) ((== Just 5) . AC.fcTimeout) (decodeAuto "timeout: 5\n"))
  -- `--config` is lifted out of argv exactly like `--graph`, so both
  -- spellings work in every position — including the slot right after the
  -- subcommand, which the positional scanner takes verbatim as the path.
  , checkEq "extractValueFlag: --config F peeled from the post-subcommand slot"
      (Just "f.yml", ["motif", "g.json"])
      (extractValueFlag "--config" ["motif", "--config", "f.yml", "g.json"])
  , checkEq "extractValueFlag: --config=F peeled from the same slot"
      (Just "f.yml", ["motif", "g.json"])
      (extractValueFlag "--config" ["motif", "--config=f.yml", "g.json"])
  , checkEq "extractValueFlag: a trailing bare --config yields no value"
      (Nothing, ["motif", "g.json"])
      (extractValueFlag "--config" ["motif", "g.json", "--config"])
  ]
  where
    keyObj ks  = KM.fromList [ (K.fromText k, Y.Null) | k <- ks ]
    isLeftE    = either (const True) (const False)
    isLeftY    = either (const True) (const False)
    decodeAuto :: Text -> Either Y.ParseException AC.FileConfig
    decodeAuto = Y.decodeEither' . TE.encodeUtf8
