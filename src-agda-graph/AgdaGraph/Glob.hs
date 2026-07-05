-- | A tiny hand-rolled glob matcher shared by the graph consumers:
-- @agda-unused@'s @--exclude@ globs ('MainUnused') and @agda-explore@'s
-- @coverage-ignore@ globs ('AgdaMcp.State'). Supports @**@ (spans @/@),
-- @*@ (stops at @/@), @?@ (one non-@/@ char), and literals — no character
-- classes or braces. Matches the whole string (anchored both ends).
module AgdaGraph.Glob
  ( globMatch
  ) where

data GTok = GStarStar | GStar | GQuest | GLit !Char

globTokens :: String -> [GTok]
globTokens []           = []
globTokens ('*':'*':cs) = GStarStar : globTokens cs
globTokens ('*':cs)     = GStar     : globTokens cs
globTokens ('?':cs)     = GQuest    : globTokens cs
globTokens (c:cs)       = GLit c    : globTokens cs

-- | @globMatch pat s@ — does the glob @pat@ match the whole string @s@?
globMatch :: String -> String -> Bool
globMatch pat = match (globTokens pat)
  where
    match []                s  = null s
    match (GStarStar : ts)  s  =
      match ts s || case s of { (_:cs) -> match (GStarStar : ts) cs; [] -> False }
    match (GStar : ts)      s  =
      match ts s || case s of { (c:cs) | c /= '/' -> match (GStar : ts) cs; _ -> False }
    match (GQuest : ts) (c:cs) | c /= '/' = match ts cs
    match (GQuest : _)  _      = False
    match (GLit p : ts) (c:cs) | p == c   = match ts cs
    match (GLit _ : _)  _      = False
