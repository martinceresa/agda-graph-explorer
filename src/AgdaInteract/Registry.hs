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

import AgdaInteract.GoalId  (GoalMap)
import AgdaInteract.Session (Session)

data SessionEntry = SessionEntry
  { seSession :: !Session
  , seGoalMap :: !GoalMap
  , seDirty   :: !Bool
  }
