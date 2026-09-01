-- | The @## How to read this@ block appended to every human-format
-- report.
--
-- A report is a table of numbers whose column names only make sense to
-- someone holding the analysis module's header comments in their head.
-- The legend closes that gap in the artefact itself: what the analysis
-- answers, what each section is, what every column means, and which row
-- is worth acting on. It is emitted at the END of the report so a @head@
-- or a pipe still sees data first, and only for @--format=human@ — the
-- JSON payload carries its own self-describing keys.
--
-- Legends are PURE and keyed by subcommand name, so they carry no
-- parameter values: the report's own header line already prints the
-- thresholds a run used. Two variants exist for the one subcommand whose
-- columns genuinely change shape (@silhouette@ and its no-provenance
-- fallback); everything else is one entry per subcommand.
--
-- Glosses are written as single unwrapped strings and wrapped by
-- 'renderLegend' against 'legendWidth', so adding a column never means
-- re-flowing a paragraph by hand. Only 'lgWhat' is hand-wrapped, since
-- it is prose whose line breaks are a judgement call.
--
-- 'AgdaOptimization.Report.withHumanReport' is the only caller. The
-- offline suite reads the subcommand list out of the committed @--help@
-- golden (itself CI-checked against the binary) and asserts every name
-- has an entry here, so a new analysis cannot ship an unexplained table.
module AgdaOptimization.Legend
  ( legendFor
  , renderLegend
  , legendKeys
  ) where

-- | One subcommand's legend. The three parts render in order: prose
-- saying what the analysis answers, named glossary blocks (columns,
-- sections, header fields), then a single line on which row to act on.
data Legend = Legend
  { lgWhat   :: [String]
    -- ^ Prose, one entry per line, hand-wrapped to 'legendWidth'.
  , lgBlocks :: [(String, [(String, String)])]
    -- ^ @(block title, [(term, gloss)])@. Terms are column / section
    -- names exactly as the report spells them.
  , lgAct    :: String
    -- ^ What to do with the top of the ranking.
  }

-- | Every key 'legendFor' answers to: the subcommand names plus the
-- @silhouette-fallback@ variant.
legendKeys :: [String]
legendKeys = map fst legends

-- | The legend for a subcommand, or 'Nothing' for an unknown key.
legendFor :: String -> Maybe Legend
legendFor k = lookup k legends

-- | The full trailing block for a subcommand — a leading blank line, the
-- heading, and the rendered legend. Empty string for an unknown key, so
-- an unrecognised caller degrades to printing nothing rather than
-- printing a stub.
renderLegend :: String -> String
renderLegend k = case legendFor k of
  Nothing -> ""
  Just lg -> unlines $
    [ "", "## How to read this" ]
    ++ lgWhat lg
    ++ concatMap block (lgBlocks lg)
    ++ ("" : wrapHanging "Act on: " (lgAct lg))

-- | Render one glossary block: a blank line, the title, then one entry
-- per term with its gloss wrapped into the remaining width.
--
-- The term column is capped at 'maxTermCol' so a single long section
-- name (@## Algebraic-connectivity hotspots@) can't squeeze every gloss
-- in the block into a sliver; a term wider than the cap takes a line of
-- its own and its gloss follows at the normal gloss indent.
block :: (String, [(String, String)]) -> [String]
block (title, entries) =
  "" : (title ++ ":") : concatMap entryLines entries
  where
    w      = min maxTermCol (maximum (1 : map (length . fst) entries))
    indent = 2 + w + 2
    body   = wrapTo (legendWidth - indent)
    hang   = map (replicate indent ' ' ++)
    entryLines (term, gloss)
      | length term > w = ("  " ++ term) : hang (body gloss)
      | otherwise       = case body gloss of
          []       -> ["  " ++ term]
          (l : ls) -> ("  " ++ pad term ++ "  " ++ l) : hang ls
    pad s = s ++ replicate (w - length s) ' '

-- | Word-wrap @body@ to 'legendWidth', prefixing the first line with
-- @lead@ and indenting continuations to line up under it.
wrapHanging :: String -> String -> [String]
wrapHanging lead body = case wrapTo (legendWidth - length lead) body of
  []       -> [lead]
  (l : ls) -> (lead ++ l) : map (replicate (length lead) ' ' ++) ls

-- | Greedy word wrap to @w@ columns. Always takes at least one word per
-- line, so a word longer than @w@ overflows rather than looping.
wrapTo :: Int -> String -> [String]
wrapTo w = go . words
  where
    go [] = []
    go ws = let (line, rest) = fill "" ws in line : go rest
    fill acc []       = (acc, [])
    fill acc (x : xs)
      | null acc                       = fill x xs
      | length acc + 1 + length x <= w = fill (acc ++ " " ++ x) xs
      | otherwise                      = (acc, x : xs)

-- | Target width for wrapped text: inside an 80-column terminal with a
-- little slack, matching the hand-wrapped 'lgWhat' prose.
legendWidth :: Int
legendWidth = 76

-- | Widest term that still shares the aligned gloss column.
maxTermCol :: Int
maxTermCol = 22

-- | Shared gloss for the one-letter definition-state column, which most
-- of the ranked-table analyses print under the name @State@.
stateCol :: (String, String)
stateCol =
  ( "State"
  , "D defined, P postulate, H open hole, F failed to typecheck." )

------------------------------------------------------------------------
-- The legends
------------------------------------------------------------------------

legends :: [(String, Legend)]
legends =
  [ ("motif", Legend
      { lgWhat =
          [ "Each row is a recurring SHAPE, not a definition: a connected subgraph"
          , "whose node labels (Kind:State) and edge directions repeat elsewhere in"
          , "the project. Definition identity is not part of the label, so a single"
          , "row can stand for dozens of unrelated sites that are structurally the"
          , "same. A shape that recurs often and is larger than a single edge is an"
          , "idiom the project open-codes by hand."
          ]
      , lgBlocks =
          [ ("Columns",
              [ ("Rank", "position by Score, descending.")
              , ("Score", "Support x (Size - 2). A two-node shape scores 0, so \
                          \recurrence alone never wins — the shape must also be big \
                          \enough to be worth naming.")
              , ("Support", "MNI support: for each motif node, how many distinct \
                            \definitions it maps to, minimised over the nodes. \
                            \Anti-monotone, so a shape never has more support than a \
                            \shape contained in it.")
              , ("Size", "definitions in the shape.")
              , ("Labels", "the node-label multiset, Kind:State xN. State letters as \
                           \below.")
              , ("ExampleSite", "one definition from one occurrence — the handle for \
                                \grepping the rest of them.")
              , stateCol
              ])
          , ("Trailer line",
              [ ("considered", "distinct shapes enumerated.")
              , ("kept", "those surviving the filters: support, size, at least two \
                         \host modules, label diversity, and uniform-path suppression.")
              , ("hosts", "distinct modules the kept shapes touch.")
              , ("hub-excluded", "nodes dropped up front by --exclude-hub-pct.")
              ])
          ]
      , lgAct = "the highest Support at Size >= 3. Open ExampleSite and judge whether \
                \the repetition deserves a combinator or a generic lemma."
      })

  , ("load-bearing", Legend
      { lgWhat =
          [ "How much of the project's proof structure runs through each definition."
          , "Edges point user -> usee, so the results named in the header (exported,"
          , "tagged, or terminal) sit at the top and critical paths walk down from"
          , "them to primitive leaves. This is a FLOW measure — how many"
          , "result-to-leaf witnesses touch a node. Compare horizon, which measures"
          , "distance, and chokepoint, which measures whether a parallel path exists."
          ]
      , lgBlocks =
          [ ("Header line",
              [ ("|V|", "definitions in the graph.")
              , ("|S|", "seed results the critical paths start from.")
              , ("|SCC|", "strongly-connected components. Cycles (a datatype and its \
                          \constructors, mutual recursion) are condensed first, so \
                          \every member of one SCC carries that SCC's scores.")
              , ("D", "the longest result-to-leaf chain in the project.")
              ])
          , ("Columns",
              [ ("dr", "depth rank — how deep beneath a result this node sits. Higher \
                       \means it carries a longer chain of users above it.")
              , ("spanBet", "span betweenness — the fraction of per-result \
                            \critical-path witnesses that pass through this node. \
                            \1.000 = every result's critical path goes through it.")
              , ("\916", "perturbation — how much the project's longest chain would \
                         \shrink if this node were deleted. 0 means a parallel path \
                         \already carries that depth; `-` means the row fell outside \
                         \the perturbation cap and was not re-run.")
              , stateCol
              ])
          , ("Sections",
              [ ("## Advice", "one sentence per top candidate naming why it ranked \
                              \and what the structural consequence of touching it \
                              \would be.")
              ])
          ]
      , lgAct = "high spanBet with \916 > 0 — both widely relied on and irreplaceable. \
                \High spanBet with \916 = 0 is popular but has a parallel route, so \
                \changing it is cheaper than the rank suggests."
      })

  , ("polyglot", Legend
      { lgWhat =
          [ "Definitions used across MANY unrelated parts of the project, as opposed"
          , "to definitions merely used a lot. Consumers are clustered by a Louvain"
          , "run on the undirected projection of the graph; a definition scores well"
          , "when its consumers spread evenly across those clusters rather than"
          , "concentrating in one. Broad spread is the empirical case for generalising"
          , "a lemma — it already serves audiences with nothing else in common."
          ]
      , lgBlocks =
          [ ("Header block",
              [ ("nodes considered", "definitions examined — every node in the graph.")
              , ("dropped (min-uses)", "definitions with too few consumers to judge.")
              , ("dropped (threshold)", "definitions judged, but with diversity D \
                                        \below --threshold.")
              , ("communities found", "clusters Louvain settled on.")
              , ("modularity Q", "how cleanly the graph splits into them. Below ~0.3 \
                                 \the clustering is weak and the D column is worth \
                                 \less.")
              ])
          , ("Columns",
              [ ("Tag", "\9733 = >= 30 consumers and D >= 0.8, a genuine cross-cutting \
                        \utility; \9670 = >= 10 consumers and D >= 0.6; \183 = widely \
                        \used but concentrated (D < 0.3), popular inside one community \
                        \rather than polyglot. [god?] marks a definition with no \
                        \line/size signal to rule out its being a god-object rather \
                        \than a clean abstraction.")
              , ("|cons|", "consumers (ancestors in the dependency graph).")
              , ("|clu|", "distinct consumer communities.")
              , ("D", "diversity — Shannon entropy of the consumer-to-community \
                      \distribution, normalised to [0, 1]. A consumer in a \
                      \re-exporting module counts half, one hop only.")
              , ("topClusters", "consumer counts in the largest few communities, \
                                \biggest first.")
              ])
          ]
      , lgAct = "\9733-tagged rows: high |cons| AND high D. A high |cons| with low D is \
                \a local workhorse — generalising it buys nothing."
      })

  , ("fingerprint", Legend
      { lgWhat =
          [ "Near-duplicate definitions found structurally, not textually. Each"
          , "definition's rooted dependency subtree is refined by Weisfeiler-Lehman"
          , "colouring and summarised as a colour histogram; definitions whose"
          , "histograms are close (weighted Jaccard above the header's threshold) join"
          , "one cluster. The default direction is incoming, which groups definitions"
          , "that ANSWER the same callers; --direction=outgoing groups by callees."
          ]
      , lgBlocks =
          [ ("Header block",
              [ ("candidates considered", "definitions eligible as cluster seeds. \
                                          \Synthetic and unknown-shape nodes are \
                                          \skipped as seeds, though they still appear \
                                          \inside other candidates' subtrees.")
              , ("pairs evaluated", "similarity comparisons actually made.")
              , ("pairs above threshold", "those that became cluster edges.")
              , ("pairs skipped (same owner)", "pairs from one parent definition. A \
                                               \datatype and its own constructors are \
                                               \trivially similar and say nothing.")
              ])
          , ("Per cluster",
              [ ("avg sim", "mean pairwise similarity inside the cluster. 1.000 means \
                            \the fingerprints are identical, not that the source text \
                            \is.")
              , ("size", "nodes in that member's subtree — how much structure the \
                         \match is asserting over. A cluster of size=2 subtrees is \
                         \weak evidence; size=20 subtrees is strong.")
              , ("[D] / [P] / [H]", "the definition's state, as in the State column \
                                    \elsewhere.")
              ])
          ]
      , lgAct = "large clusters of large subtrees first. WL is a heuristic and false \
                \positives are expected — read two members before unifying anything."
      })

  , ("debt", Legend
      { lgWhat =
          [ "What the project's open holes and stub postulates cost, and the order in"
          , "which to pay them off. Every exported definition that reaches a hole is"
          , "conditional on that hole, so each hole 'covers' a set of exports. The"
          , "schedule is the standard submodular greedy for maximum coverage: each"
          , "step picks the hole unlocking the most exports NOT already unlocked by an"
          , "earlier step."
          ]
      , lgBlocks =
          [ ("Header block",
              [ ("Exp size", "the exported set coverage is measured against.")
              , ("Open holes", "definitions in the Hole state.")
              , ("Stub postulates", "postulates counted as debt, when included.")
              , ("Currently fully provable", "exports reaching no debt at all — the \
                                             \part of the project that is \
                                             \unconditional today.")
              ])
          , ("Columns (## Greedy schedule)",
              [ ("Step", "position in the payoff order, not a ranking of size.")
              , ("cov", "exports this hole covers in total.")
              , ("\916", "MARGINAL gain: exports it unlocks that no earlier step \
                         \already did. This is what the greedy sorts by, and why a \
                         \big-cov hole can appear late with a small \916.")
              , ("cum %", "cumulative share of Exp unlocked through this step.")
              , stateCol
              ])
          , ("Sections",
              [ ("Gain bar", "one cell per scheduled hole, scaled to the largest \916. \
                             \A long flat tail means the remaining debt is diffuse.")
              , ("## Hole-prereq edges", "holes depending on other holes. The \
                                         \prerequisite must be filled first regardless \
                                         \of what the schedule says.")
              , ("## Failed modules", "modules that did not typecheck. Their debt is \
                                      \UNKNOWN and is folded into no number above.")
              ])
          ]
      , lgAct = "step 1 downwards, but read ## Hole-prereq edges first — a \
                \prerequisite hole outranks the schedule. A non-empty ## Failed \
                \modules means every percentage here is optimistic."
      })

  , ("basket", Legend
      { lgWhat =
          [ "Association rules over co-used definitions. Each definition is a"
          , "transaction and its DIRECT dependencies are the basket (no transitive"
          , "closure — universal primitives would drown the signal); Apriori mines"
          , "itemsets up to size 3 and turns them into rules LHS => RHS. A surviving"
          , "rule says: when a proof uses the LHS it nearly always uses the RHS too,"
          , "so the two want to travel together as one abstraction."
          ]
      , lgBlocks =
          [ ("Trailer of the header",
              [ ("tx", "transactions (definitions with a non-empty basket).")
              , ("qualifying", "baskets of size >= 2, the only ones that can carry a \
                               \rule.")
              , ("L1/L2/L3", "frequent itemsets found at size 1, 2 and 3.")
              , ("rules-considered", "candidate rules — the Bonferroni denominator.")
              , ("passed / kept", "rules surviving the statistical and threshold \
                                  \gates.")
              ])
          , ("Columns",
              [ ("Support", "fraction of all transactions containing the whole bundle.")
              , ("Conf", "P(RHS | LHS) — how reliably the LHS drags the RHS along.")
              , ("Lift", "Conf divided by the RHS's own base rate. 1.0 means the rule \
                         \merely describes a popular definition; > 1 is real \
                         \association.")
              , ("Spec", "specificity = Support x Lift, the sort key. Rewards rules \
                         \that are both frequent and non-obvious.")
              , ("p_corr", "Bonferroni-corrected upper bound on the Fisher p-value, \
                           \over rules-considered. Rules above 0.01 were already \
                           \rejected, so a printed row has survived multiple-testing \
                           \control.")
              ])
          , ("Sections",
              [ ("## Near-miss bundles", "definitions using k-1 of a k-item bundle. \
                                         \These are the actionable outliers: either a \
                                         \genuine exception, or a site that forgot the \
                                         \missing piece.")
              ])
          ]
      , lgAct = "high Lift before high Support — a lift near 1.0 tells you nothing \
                \however frequent it is. Then read ## Near-miss bundles for the sites \
                \that break the pattern."
      })

  , ("ledger", Legend
      { lgWhat =
          [ "What each public theorem actually rests on. For every theorem the"
          , "transitive postulate set is split into a FOUNDATIONAL part"
          , "(Agda.Builtin.* / Agda.Primitive.*, which you are trusting anyway) and a"
          , "PAPER-LEVEL part — every other postulate, i.e. the assumptions this"
          , "project introduced itself. The paper-level set is the theorem's real"
          , "trust budget, and the thing a reviewer asks about."
          ]
      , lgBlocks =
          [ ("Columns (## Per-theorem trust footprint)",
              [ ("axioms", "paper-level axioms the theorem depends on. 0 is the goal.")
              , ("found", "foundational postulates, counted separately because they \
                          \are not project-specific debt.")
              , ("axiom names", "the first three paper-level axioms, then `...`.")
              ])
          , ("Sections",
              [ ("## Axiom leverage", "per axiom, how many public theorems rest on it. \
                                      \The top row is the single assumption whose \
                                      \discharge buys the most.")
              , ("## Cohorts", "theorems sharing an EXACT axiom set — a \
                               \provable-together group. Discharge the set once and \
                               \the whole cohort becomes unconditional at the same \
                               \moment.")
              , ("## Foundational postulates", "the trusted base surviving \
                                               \--no-externals, by module.")
              ])
          ]
      , lgAct = "the top of ## Axiom leverage rather than the top of the theorem table \
                \— one high-leverage axiom usually clears many theorems at once. Pass \
                \--axiom-source=record-field if this project encodes its assumptions \
                \as record fields rather than postulates."
      })

  , ("echo", Legend
      { lgWhat =
          [ "The dual of fingerprint. The same Weisfeiler-Lehman machinery runs over"
          , "the REVERSE edges, so two definitions cluster when they answer the same"
          , "callers. On its own that mostly re-derives the forward clustering; the"
          , "signal here is the DELTA. A reverse cluster whose members come from many"
          , "different forward clusters is the interesting case: definitions that look"
          , "unrelated by what they call, yet converge on the same audience."
          ]
      , lgBlocks =
          [ ("Header block",
              [ ("candidates considered", "definitions eligible as cluster seeds.")
              , ("forward / reverse clusters", "cluster counts in each direction.")
              , ("reverse-cluster pairs", "similarity comparisons that became reverse \
                                          \cluster edges.")
              , ("delta-actionable clusters", "reverse clusters whose members span \
                                              \several forward clusters — the rows \
                                              \worth reading.")
              , ("rejected by --max-cluster-spread", "reverse clusters that collapsed \
                                                     \to one or two forward clusters \
                                                     \and were dropped as redundant.")
              ])
          , ("Per cluster",
              [ ("reverse-Jaccard", "caller-set similarity floor holding the cluster \
                                    \together.")
              , ("forward-cluster-spread", "distinct forward clusters its members come \
                                           \from. 1 means fingerprint already told you \
                                           \this; high means it did not.")
              , ("(fwd-cluster N)", "which forward cluster each member belongs to.")
              ])
          ]
      , lgAct = "clusters with the highest forward-cluster-spread. A spread of 1 is \
                \noise here — read it in fingerprint instead."
      })

  , ("gravity", Legend
      { lgWhat =
          [ "Random-walk centrality: the silent connective tissue that critical-path"
          , "counting misses. Three signals combine — reverse PageRank (how much"
          , "demand flows into a definition from everywhere), one personalised"
          , "PageRank per theorem (so each definition has a row across theorems), and"
          , "HITS authority/hub. The rank multiplies mass by spread, so a definition"
          , "needs BOTH heavy structural load and a broad audience to reach the top."
          ]
      , lgBlocks =
          [ ("Header line",
              [ ("revPR iters / delta", "power-iteration sweeps used and the final L1 \
                                        \change. A delta near the tolerance means it \
                                        \converged; hitting the iteration cap with a \
                                        \large delta means the ranking is not settled.")
              ])
          , ("Columns",
              [ ("Gravity", "Mass x H(theorems), the sort key.")
              , ("Mass", "reverse PageRank — total demand flowing into this node.")
              , ("H(theorems)", "Shannon entropy in bits of its PPR mass across \
                                \theorems. High = many theorems reach it; near 0 = one \
                                \theorem's private helper, however heavy.")
              , ("nzTh", "theorems with non-zero PPR mass here, out of those seeded.")
              , ("Auth", "HITS authority — pointed at by many hubs. Authorities skew \
                         \toward primitive sinks.")
              , ("Hub", "HITS hub — points at many authorities. Hubs skew toward \
                        \orchestration lemmas.")
              , ("Role", "whichever of Auth / Hub is larger; ties go to authority.")
              , stateCol
              ])
          ]
      , lgAct = "high Gravity with high H — load-bearing for the whole project rather \
                \than for one theorem. If the header warns that H collapsed, the \
                \ranking fell back to mass x theorem count and the spread signal is \
                \not available."
      })

  , ("pyre", Legend
      { lgWhat =
          [ "Where the typechecker's time is predicted to go, from the graph alone —"
          , "no agda run. Cost is modelled as a weighted sum of four structural"
          , "features of the SCC condensation: how much a definition reaches, how"
          , "tangled that reachable set is, what construct kinds it contains, and how"
          , "deep it sits. The score is a RELATIVE ranking, not a time estimate; the"
          , "weights that produced it are printed in the header."
          ]
      , lgBlocks =
          [ ("Header line",
              [ ("|SCC|", "components after condensation. Each counts once in reach, \
                          \however many definitions it contains.")
              , ("D", "maximum depth rank.")
              , ("weights", "w1 reach, w2 fan-in x fan-out, w3 construct kinds, w4 \
                            \depth.")
              ])
          , ("Columns",
              [ ("score", "the modelled cost C(d). Compare rows; do not read seconds.")
              , ("reach", "components in the forward transitive closure.")
              , ("recDeps", "summed per-construct unfolding weight over that closure — \
                            \records and datatypes heavy, postulates and primitives \
                            \zero.")
              , ("depth", "position in the longest-path ranking.")
              , stateCol
              ])
          , ("Sections",
              [ ("## Calibration", "only with --profile. Spearman \961 says whether \
                                   \the proxy tracks observed cost at all; the fitted \
                                   \weights are what would track it better. Copy them \
                                   \into the pyre: section of the config to keep them, \
                                   \or pass --calibrate to apply them to this run.")
              , ("## Levers", "the DUAL question: not what is expensive to check, but \
                              \which definition, made cheaper, would cut the most \
                              \aggregate cost. lever = reachers x selfCost. It is an \
                              \attribution, not a counterfactual — it assumes only \
                              \that node leaves the reach sets, not whatever it was \
                              \the sole path to.")
              ])
          ]
      , lgAct = "the ## Levers table over the main table when your goal is build time \
                \— the top of the main table is usually a deep result you cannot make \
                \cheaper. Without --profile, treat the ordering as a hypothesis."
      })

  , ("chokepoint", Legend
      { lgWhat =
          [ "Non-redundancy, not popularity. A node-capacitated min-cut runs from the"
          , "exported theorems down to the axiom/leaf set, which finds the definitions"
          , "sitting on a funnel of width 1 — the sole connector between the top of"
          , "the project and its foundations. Such a node may lie on very few critical"
          , "paths and so rank low in load-bearing, yet nothing can be proved through"
          , "it if it breaks. Betweenness misses this; min-cut does not."
          ]
      , lgBlocks =
          [ ("Header line",
              [ ("|S| / |T|", "source (exported) and sink (axiom/leaf) components.")
              , ("max-flow", "the cut's total capacity. Capacity is 1/(line+1) per \
                             \node: a unitless bias toward shallow, cheap-to-change \
                             \nodes, NOT a line count. A small max-flow means a \
                             \genuinely thin funnel.")
              , ("|cut| / |art|", "components in the min-cut and the articulation set.")
              ])
          , ("Columns",
              [ ("Role", "cut = on the min-cut; art = an articulation point of the \
                         \symmetrised graph; cut+art = both, the strongest signal, and \
                         \the only one carrying the 1.5x score bonus.")
              , ("Score", "cut multiplicity x |ancestors| x |descendants| — how much \
                          \sits on each side of the funnel.")
              , ("up(S)", "definitions upstream, toward the theorems.")
              , ("down(T)", "definitions downstream, toward the axioms.")
              , stateCol
              ])
          ]
      , lgAct = "cut+art rows with large up(S) and down(T) — that node is the whole \
                \bridge. If it is a postulate, it is the single assumption the project \
                \funnels through."
      })

  , ("silhouette", Legend
      { lgWhat =
          [ "Statement shape versus proof shape. With edge provenance available, a"
          , "definition's out-edges split into a SIGNATURE subgraph (edges coming from"
          , "its type) and a BODY subgraph (everything else). Weisfeiler-Lehman runs"
          , "on each independently, which separates two questions that usually get"
          , "conflated: do these two lemmas STATE the same thing, and do they PROVE"
          , "it the same way?"
          ]
      , lgBlocks =
          [ ("Header block",
              [ ("candidates considered", "definitions eligible as cluster seeds.")
              , ("signature / body edges", "how the provenance split fell out. A small \
                                           \signature count means the producer tagged \
                                           \little, and the clusters below rest on \
                                           \thin evidence.")
              , ("combinator / copy-paste / mixed", "how the structural-twin clusters \
                                                    \were classified. Counts are over \
                                                    \the WHOLE population, not the \
                                                    \rows below; a line under the \
                                                    \table names any class --top-n \
                                                    \cut entirely.")
              ])
          , ("Per cluster",
              [ ("body overlap", "weighted Jaccard of the members' body fingerprints.")
              , ("[combinator]", "same statement, nearly the same proof (overlap above \
                                 \--high-overlap). Factor the shared proof out.")
              , ("[copy-paste]", "same statement, disjoint proofs (below \
                                 \--low-overlap). The lemma was re-proved rather than \
                                 \reused — unify the statements.")
              , ("[mixed]", "in between; read it before acting.")
              , ("sig-size", "nodes in the member's signature subgraph — how much \
                             \shape the twin claim is actually asserting over.")
              ])
          ]
      , lgAct = "[copy-paste] clusters first: they are duplicated work, whereas \
                \[combinator] clusters are merely an abstraction you have not named \
                \yet."
      })

  , ("silhouette-fallback", Legend
      { lgWhat =
          [ "This run had NO edge provenance in the graph, so the signature/body split"
          , "was unavailable and Weisfeiler-Lehman ran over all out-edges at once. The"
          , "clusters below are therefore plain structural twins — the same thing"
          , "fingerprint reports — and none of the statement-versus-proof reading"
          , "applies. Regenerate the graph with a producer that emits"
          , "definitionEdgesProvenance to get the real analysis."
          ]
      , lgBlocks =
          [ ("Per cluster",
              [ ("body overlap", "weighted Jaccard over ALL edges, not body edges.")
              , ("sig-size", "nodes in the member's subgraph.")
              ])
          ]
      , lgAct = "nothing here that fingerprint does not already tell you. Fix the \
                \provenance first."
      })

  , ("entwine", Legend
      { lgWhat =
          [ "Pairs of definitions that travel together, measured by mutual information"
          , "over caller baskets rather than by frequency. This is what basket cannot"
          , "see: a pair used by only three callers but used by them with perfect"
          , "determinism is exactly the bundle worth folding into a combinator, and"
          , "support thresholds throw it away. The same test catches the inverse —"
          , "pairs systematically kept apart."
          ]
      , lgBlocks =
          [ ("Trailer of the header",
              [ ("callers", "definitions with a non-empty basket.")
              , ("avg-basket", "mean basket size. Large baskets make spurious pairs \
                               \more likely.")
              , ("excluded", "definitions dropped by --exclude-name-regex.")
              , ("pairs-counted / kept / emitted", "candidates, survivors of the \
                                                   \gates, and rows printed.")
              ])
          , ("Columns",
              [ ("n_xy", "callers using both.")
              , ("n_x / n_y", "callers using each.")
              , ("I", "mutual information in bits. Scale-dependent — read IQR instead.")
              , ("IQR", "I normalised by joint entropy: 1.000 = perfectly mutual, \
                        \0 = independent. This is the sort key and the real signal.")
              , ("G", "log-likelihood-ratio statistic, asymptotically \967\178 with 1 \
                      \dof. The default gate 6.635 is p < 0.01, so a printed row is \
                      \significant however small n_xy looks.")
              , ("anti", "yes = ANTI-coreference. The pair is more either-or than \
                         \both: callers systematically choose one. Often a sign of two \
                         \competing idioms rather than one bundle.")
              ])
          ]
      , lgAct = "IQR near 1.000 with anti=no, even at small n_xy — that is a \
                \deterministic bundle. anti=yes rows are worth reading for the \
                \opposite reason: they usually mark a split the codebase never \
                \resolved."
      })

  , ("fiedler", Legend
      { lgWhat =
          [ "Spectral structure of the whole project. The smallest non-trivial"
          , "eigenpairs of the normalised Laplacian are computed (via SciPy in"
          , "scripts/fiedler_helper.py), which is a global view no local metric gives:"
          , "where the graph nearly falls into two pieces, which modules are stringy"
          , "chains rather than cohesive units, and which groups of definitions"
          , "vibrate together across declared module boundaries."
          ]
      , lgBlocks =
          [ ("Stats line",
              [ ("nodes / component", "nodes in the graph, and in the largest \
                                      \component the spectrum was taken over. A big \
                                      \gap between them means the rest of the project \
                                      \is disconnected from what is analysed here.")
              , ("\955\8322", "global algebraic connectivity. Near 0 = the graph is \
                              \already nearly two pieces.")
              , ("eigvals", "the computed spectrum, ascending. The first is always ~0; \
                            \a large jump after \955\8322 means the bisection is a \
                            \genuine split rather than one of many equally good cuts.")
              ])
          , ("Sections",
              [ ("## Bridge edges", "edges spanning the spectral bisection, ranked by \
                                    \the gap in the Fiedler vector across them. A \
                                    \large Gap means the two sides are nearly separate \
                                    \components joined by this one edge — a thin cut, \
                                    \and a candidate seam for splitting the \
                                    \development.")
              , ("## Algebraic-connectivity hotspots", "modules ranked ASCENDING by \
                                                       \\955\8322 of their own \
                                                       \subgraph. Low \955\8322 means \
                                                       \stringy: a linear chain of \
                                                       \definitions rather than a \
                                                       \connected unit. Compare each \
                                                       \against the global \955\8322 \
                                                       \printed beneath the heading.")
              , ("## Resonant clusters", "definitions sharing a sign pattern across \
                                         \v\8322..v_k, kept only when they span at \
                                         \least two DECLARED modules. These are groups \
                                         \the graph treats as one unit while your \
                                         \module tree does not — the declared boundary \
                                         \disagrees with the real one.")
              ])
          , ("Columns",
              [ ("Gap", "|v\8322(U) - v\8322(V)| across the edge; the bridge sort key.")
              , ("\955\8322", "algebraic connectivity of the module's largest \
                              \component.")
              , ("Signature", "the cluster's sign pattern, one character per \
                              \eigenvector.")
              , ("#Mods", "declared modules the cluster spans.")
              ])
          ]
      , lgAct = "the top bridge edge and the lowest-\955\8322 module. Both name a place \
                \where the project's real structure and its file structure have come \
                \apart. This subcommand needs SciPy: with no helper or no SciPy it \
                \exits cleanly (2 / 3) and says why on stderr."
      })

  , ("horizon", Legend
      { lgWhat =
          [ "Proof geometry: how FAR things are, where load-bearing measures how much"
          , "flows. Forward eccentricity is the longest distance down to an"
          , "axiom/leaf, backward eccentricity the longest distance from a root"
          , "theorem. A lemma can be high-flow yet shallow, or peripheral yet"
          , "load-bearing — the two analyses disagree by design, and the disagreement"
          , "is usually the informative part."
          ]
      , lgBlocks =
          [ ("Header line",
              [ ("diameter", "the longest axiom-to-result chain: the depth of the \
                             \deepest thing the project proves.")
              , ("radius", "the shallowest such chain over the root theorems.")
              , ("periphery / center", "how many nodes sit at the diameter and at the \
                                       \radius.")
              ])
          , ("Columns",
              [ ("\949\8314", "forward eccentricity — distance down to the furthest \
                              \leaf.")
              , ("\949\8315", "backward eccentricity — distance from the furthest \
                              \root.")
              , ("\949\8314+\949\8315", "the sort key: deepest balanced results first.")
              , ("tag", "periphery = at the diameter; center = at the radius (both \
                        \when the node hits each); root = it IS one of the roots named \
                        \in the header (\949\8315 = 0); leaf = it IS one of the leaves \
                        \(\949\8314 = 0).")
              , ("-", "unreachable in that direction (reaches no leaf, or no root \
                      \reaches it). These sort to the bottom. A whole column of them \
                      \cannot happen: horizon falls back (or refuses) when too few \
                      \roots reach a leaf for the ranking to mean anything.")
              , stateCol
              ])
          , ("Sections",
              [ ("## Per-module \949\8314 histogram", "every definition's forward \
                                                     \eccentricity, bucketed by \
                                                     \module. A sharp peak means the \
                                                     \module is a natural seam — \
                                                     \everything in it sits at one \
                                                     \depth. Buckets that fan out mean \
                                                     \the module mixes abstraction \
                                                     \levels and is a candidate for \
                                                     \splitting.")
              ])
          ]
      , lgAct = "the periphery rows — they are the project's deepest results and the \
                \most expensive to re-prove. Then the fanned-out modules in the \
                \histogram."
      })

  , ("strata", Legend
      { lgWhat =
          [ "Whether the module tree you DECLARED matches the dependencies you"
          , "actually have. Each module's out-edges are classified as internal (same"
          , "module), parent-internal (an ancestor in the dotted tree — ordinary"
          , "hierarchy traffic, neither rewarded nor punished) or external. From that"
          , "come Henderson-Sellers LCOM' and Martin's instability and abstractness,"
          , "folded into one incoherence score."
          ]
      , lgBlocks =
          [ ("Columns",
              [ ("|m|", "definitions in the module.")
              , ("LCOM'", "1 - internal/(internal + external). 0 = self-contained; \
                          \1 = every dependency leaves the module.")
              , ("spread", "distinct sibling-disjoint module prefixes the externals \
                           \reach. High spread with high LCOM' means the module is not \
                           \just outward-facing but scattered.")
              , ("I", "instability, Ce/(Ca+Ce) over distinct external modules. 1 = it \
                      \depends on others and nothing depends on it; 0 = the reverse.")
              , ("A", "abstractness — the share of records, datatypes, postulates and \
                      \holes. Agda has no interface concept, so datatypes proxy for \
                      \the structural-shape role.")
              , ("D", "|A + I - 1|, distance from Martin's main sequence. Near 0 is \
                      \healthy: abstract-and-stable, or concrete-and-unstable. Near 1 \
                      \is either a rigid abstraction nobody can change or a concrete \
                      \module everything depends on.")
              , ("inc", "incoherence = LCOM' x log(1 + spread) x |D - (1 - I)|, the \
                        \sort key.")
              ])
          , ("Sections",
              [ ("## Top out-of-place external", "the modal sibling subtree each \
                                                 \module leaks into — a child of its \
                                                 \parent that is not its own subtree. \
                                                 \That is the concrete move: those \
                                                 \definitions probably belong there, \
                                                 \or that module belongs here.")
              ])
          ]
      , lgAct = "the top inc rows, then their ## Top out-of-place external line — it \
                \names where the definitions want to move. Modules below --min-size \
                \are skipped, so a small messy module will not appear at all."
      })

  , ("term-cluster", Legend
      { lgWhat =
          [ "Repeated syntax, below the level of any dependency edge. This reads the"
          , "per-definition subterm hashes that agda-deps --with-term-hashes emits, so"
          , "it sees the same canonical-form AST fragment recurring in unrelated"
          , "proofs — common-subexpression candidates a graph-only analysis cannot"
          , "reach. Without those hashes in the graph the subcommand has nothing to"
          , "read, and says so instead of reporting an empty result."
          , ""
          , "Two sections. `Exact duplicates` leads and takes no thresholds:"
          , "definitions whose whole subterm-hash MULTISET is identical, and whose"
          , "signature also matches when the producer ran with --with-signatures."
          , "`Recurring subterms` is the ranked cluster list under it, where a shared"
          , "fragment is enough to group."
          , ""
          , "A duplicate group is evidence, not proof: a multiset has no shape, so two"
          , "definitions assembling the same parts differently land in one group. The"
          , "signature match is what rules most of those out — on a graph built"
          , "without signatures the header says the tier is running on hashes alone."
          ]
      , lgBlocks =
          [ ("Exact duplicates",
              [ ("Group", "rank within the duplicate listing; capped at --top-n.")
              , ("|defs|", "how many definitions share the bag — always at least 2.")
              , ("Terms", "size of the shared multiset. 1 means a single fragment \
                          \matched, which is weak on its own; a large bag matching \
                          \exactly is not a coincidence.")
              , ("Members", "the definitions in the group, capped at --max-defs.")
              ])
          , ("Columns",
              [ ("Hash", "opaque 16-hex fingerprint of the canonical subterm. The \
                         \source term does not cross the JSON boundary, so this is the \
                         \only handle you get — it is stable enough to grep across \
                         \runs.")
              , ("Size", "total occurrences project-wide.")
              , ("|defs| / |mods|", "distinct definitions and modules it occurs in.")
              , ("MeanD", "mean AST depth of the occurrences. Deep fragments are real \
                          \structure; shallow ones are usually a variable or a \
                          \constructor. 1.00 means the producer emitted no depths.")
              , ("Div", "diversity — normalised entropy of the per-module \
                        \distribution. 0 = confined to one module; 1 = spread evenly \
                        \across many.")
              , ("Score", "Size x MeanD x (1 + Div). Ranking by Size alone is dominated \
                          \by trivial shapes, which is what the other two factors \
                          \correct. Use --sort=log-score when shallow high-count noise \
                          \still wins.")
              , ("TopDefs", "the definitions carrying the most occurrences, with \
                            \counts.")
              ])
          ]
      , lgAct = "an exact-duplicate group before any cluster — it is the one finding \
                \here that needed no threshold to survive. Then high MeanD and high \
                \Div before high Size: a deep fragment repeated across several \
                \modules is the abstraction worth extracting. A huge Size at \
                \MeanD ~1 is noise."
      })

  , ("concept-bundle", Legend
      { lgWhat =
          [ "Vocabulary that recurs in type SIGNATURES. Where basket mines all"
          , "out-edges, this restricts to signature-provenance edges, so it finds"
          , "lemmas whose STATEMENTS converge on the same set of helper names even"
          , "when their proofs have nothing in common. That is the case both"
          , "fingerprint and term-cluster miss by construction: the bundle exists in"
          , "the types, never as a body clone, and it usually wants to be a record."
          ]
      , lgBlocks =
          [ ("Trailer of the header",
              [ ("tx", "definitions with a non-empty signature basket.")
              , ("qualifying", "baskets large enough to contribute a bundle.")
              , ("L1..L4", "frequent itemsets per size. L4 only under --k-max=4.")
              , ("top-freq-excluded", "ubiquitous items dropped before mining.")
              ])
          , ("Columns",
              [ ("Items", "the bundle — names that keep appearing in signatures \
                          \together.")
              , ("Sup", "definitions whose signature contains the whole bundle. An \
                        \absolute count, not a fraction: proof corpora are small.")
              , ("Lift", "how much more often they co-occur than independence predicts.")
              , ("Span", "distinct modules contributing. This is the gate that matters \
                         \— below ~3 the bundle is one module's private idiom, not a \
                         \cross-cutting concept.")
              , ("Spec", "Sup x Lift x log(Span), the sort key.")
              ])
          ]
      , lgAct = "high Span first, then Lift. An empty table usually means the graph \
                \carries no signature provenance rather than that no bundles exist — \
                \check the header's tx and L2 counts before concluding anything."
      })

  , ("hint-bench", Legend
      { lgWhat =
          [ "Not a graph analysis: an offline eval of the lemma ranker that feeds"
          , "agda-explore's auto hints. Every proved theorem is a self-labelled"
          , "retrieval query — its signature is the goal, its body-provenance"
          , "dependencies are the ground-truth premises. Hiding it and ranking the rest"
          , "of the library against its statement measures how often the real premises"
          , "land inside the hint budget, with no live agda run."
          ]
      , lgBlocks =
          [ ("Header block",
              [ ("corpus rows", "scorable theorems. 0 means the graph has no \
                                \signatures or no edge provenance — the note line says \
                                \which, and it is a producer-flag problem rather than \
                                \a result.")
              , ("premise set", "whether constructors and records count as premises.")
              ])
          , ("Columns",
              [ ("Strategy", "the ranking variant. baseline is what ships; the others \
                             \are the Phase-1/2 experiments, selectable with \
                             \--strategy.")
              , ("R@k", "mean recall@k — the share of a row's real premises appearing \
                        \in the top k candidates.")
              , ("A@k", "any-hit@k — the share of rows with AT LEAST ONE real premise \
                        \in the top k. This is the number that predicts whether \
                        \seeding k hints lets Mimer close the goal, because one good \
                        \hint often suffices; R@k is the stricter, less operational \
                        \measure.")
              , ("MRR", "mean reciprocal rank of the first real premise.")
              , ("|cand|", "mean candidate-pool size per row. A ranking that improves \
                           \while this grows has not necessarily got better.")
              ])
          ]
      , lgAct = "A@k at the k you actually seed as hints (--auto-hints-lemmas). \
                \Compare strategies against baseline within one run: absolute numbers \
                \are corpus-dependent and not comparable across projects. No ranking \
                \change should land without moving these."
      })
  ]
