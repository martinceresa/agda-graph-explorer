-- | A live interaction session as registered in the @agda-explore@
-- daemon: the session itself plus its per-load stable-goal map and a
-- dirty flag the file-watcher flips when sources change on disk
-- (serve-stale parity — reload lazily on next use). Held in the
-- 'AgdaMcp.State.ServerState' registry.
--
-- Kept separate from "AgdaInteract.Session" so that module stays a clean
-- transport primitive with no goal-id dependency — letting @agda-goals@
-- reuse the session driver without pulling in the bridge's goal-id layer.
module AgdaInteract.Registry
  ( SessionEntry(..)
  ) where

import Data.IORef          (IORef)
import Data.Time.Clock     (UTCTime)

import AgdaInteract.GoalId  (GoalMap)
import AgdaInteract.Session (Session)

data SessionEntry = SessionEntry
  { seSession  :: !Session
  , seGoalMap  :: !GoalMap
  , seDirty    :: !Bool
  , seLastUsed :: !(IORef UTCTime)
    -- ^ Last time this session was loaded or used to serve a goal command.
    -- Read by the idle-session reaper ('AgdaInteract.Tools.reapIdleSessions');
    -- an 'IORef' so reuse can refresh it cheaply without rebuilding the entry.
  }
