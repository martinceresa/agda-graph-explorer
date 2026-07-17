{-# LANGUAGE OverloadedStrings #-}
-- | Client-facing goal ids (@g0@, @g1@, …) over Agda's interaction holes.
--
-- Agda reissues interaction-point integers (@?0@, @?1@, …) on every
-- @Cmd_load@. This layer assigns each hole a monotonic 'StableId' the
-- first time it is seen, keyed by the hole's start __character offset__
-- (Agda @pos@), and re-derives the offset→stable mapping on every reload.
--
-- __Scope of stability.__ An id is preserved across a reload only while
-- the hole's offset is unchanged — e.g. a watcher-triggered reload of an
-- unsaved file, or the other goals after a @give@ that doesn't move them.
-- An edit that shifts a hole's offset (most edits shift everything below
-- the edit point) gives that hole a /fresh/ id. So this does not provide
-- identity that survives arbitrary edits; clients should re-read the goal
-- list after applying an edit (selecting by @(line:col)@) rather than
-- caching an id across one. The win over raw Agda ids is the within-load
-- and unchanged-hole-across-reload cases. And when a reload observes that
-- the file changed on disk since the last load, the map is reset
-- ('dropEntriesKeepNext') — the counter is kept so a stale cached id fails
-- loudly rather than retargeting a different hole.
--
-- A 'GoalMap' lives per session ('AgdaInteract.Session'): interaction
-- ids are per-load, so the map is rebuilt each time 'syncGoals' runs
-- against a fresh @AllGoalsWarnings@.
module AgdaInteract.GoalId
  ( StableId(..)
  , GoalEntry(..)
  , GoalMap
  , emptyGoalMap
  , dropEntriesKeepNext
  , syncGoals
  , toInteractionId
  , lookupStable
  , renderStableId
  , parseStableId
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import           Data.Text  ( Text )
import qualified Data.Text  as T
import           Text.Read  ( readMaybe )

import           AgdaGraph.Interaction.Protocol
                   ( Goal(..), GoalRange(..), RangePos(..) )

-- | The stable handle the MCP client sees (rendered @g0@, @g1@, …).
newtype StableId = StableId Int
  deriving (Eq, Ord, Show)

-- | One goal as currently known: its stable id, Agda's current
-- interaction id, source range, and rendered type.
data GoalEntry = GoalEntry
  { geStable :: !StableId
  , geIid    :: !(Maybe Int)
  , geRange  :: !(Maybe GoalRange)
  , geType   :: !Text
  } deriving (Show)

-- | The per-session stable-id state.
data GoalMap = GoalMap
  { gmNext     :: !Int                       -- ^ next fresh stable id
  , gmByStable :: !(M.Map StableId GoalEntry) -- ^ current goals only
  } deriving (Show)

emptyGoalMap :: GoalMap
emptyGoalMap = GoalMap { gmNext = 0, gmByStable = M.empty }

-- | Drop every current entry but __keep__ the id counter (unlike
-- 'emptyGoalMap', which resets it to 0). Used when a reload observes an
-- external on-disk change: a client's cached @g0@ must resolve to
-- "not an open goal" (loud) rather than silently retargeting the new first
-- hole — which is exactly what reusing @g0@ would do. See the "Scope of
-- stability" note above.
dropEntriesKeepNext :: GoalMap -> GoalMap
dropEntriesKeepNext gm = gm { gmByStable = M.empty }

-- | The start character offset that identifies a hole across reloads.
goalStartPos :: Goal -> Maybe Int
goalStartPos g = (rpPos . grStart) <$> goalRange g

entryStartPos :: GoalEntry -> Maybe Int
entryStartPos e = (rpPos . grStart) <$> geRange e

-- | Reconcile a fresh set of goals (from an @AllGoalsWarnings@ after a
-- (re)load) against the prior map. A hole whose start offset matches a
-- prior entry keeps its 'StableId' (and adopts the new interaction id);
-- a hole at a new offset gets a fresh 'StableId'. Holes absent from the
-- new set are dropped (they were solved or removed). The returned
-- 'GoalEntry' list is in the order the goals were given.
syncGoals :: GoalMap -> [Goal] -> (GoalMap, [GoalEntry])
syncGoals gm goals =
  let prev = M.elems (gmByStable gm)
      -- Prior entries indexed by start offset. @prev@ is ascending by
      -- 'StableId' and 'fromListWith' keeps the first-seen value, so when
      -- two prior entries share a start offset the smallest StableId wins
      -- (first-match tie-break).
      offMap = IM.fromListWith (\_new old -> old)
                 [ (off, geStable e) | e <- prev, Just off <- [entryStartPos e] ]
      step (m, next, esRev) g =
        let moff = goalStartPos g
            reused = moff >>= \off -> IM.lookup off offMap
            (sid, next') = case reused of
              Just s  -> (s, next)
              Nothing -> (StableId next, next + 1)
            entry = GoalEntry
              { geStable = sid
              , geIid    = goalId g
              , geRange  = goalRange g
              , geType   = goalType g
              }
        in (M.insert sid entry m, next', entry : esRev)
      (m', next'', esRev') = foldl step (M.empty, gmNext gm, []) goals
  in (gm { gmNext = next'', gmByStable = m' }, reverse esRev')

-- | Agda's current interaction id for a stable id, if the goal is still open.
toInteractionId :: GoalMap -> StableId -> Maybe Int
toInteractionId gm sid = M.lookup sid (gmByStable gm) >>= geIid

-- | The full entry (range, type, current interaction id) for a stable id.
lookupStable :: GoalMap -> StableId -> Maybe GoalEntry
lookupStable gm sid = M.lookup sid (gmByStable gm)

renderStableId :: StableId -> Text
renderStableId (StableId n) = "g" <> T.pack (show n)

-- | Parse a client-supplied goal handle: @g3@ → 'StableId' 3. Also
-- accepts a bare integer for convenience.
parseStableId :: Text -> Maybe StableId
parseStableId t0 =
  let t = T.strip t0
  in case T.stripPrefix "g" t of
       Just rest -> StableId <$> readMaybe (T.unpack rest)
       Nothing   -> StableId <$> readMaybe (T.unpack t)
