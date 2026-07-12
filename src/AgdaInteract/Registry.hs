{-# LANGUAGE OverloadedStrings #-}
-- | A live interaction session as registered in the @agda-explore@
-- daemon: the session itself plus its per-load stable-goal map, a dirty
-- flag the file-watcher flips when sources change on disk (serve-stale
-- parity — reload lazily on next use), and a content stamp of the on-disk
-- source the current load reflects (so a mutator can refuse to
-- splice against a file that changed under it). Held in the
-- 'AgdaMcp.State.ServerState' registry.
--
-- Kept separate from "AgdaInteract.Session" so that module stays a clean
-- transport primitive with no goal-id dependency — letting @agda-goals@
-- reuse the session driver without pulling in the bridge's goal-id layer.
module AgdaInteract.Registry
  ( SessionEntry(..)
  , contentStamp
  , shouldKeepGoalIds
  ) where

import Data.IORef          (IORef)
import Data.Text           (Text)
import qualified Data.Text as T
import Data.Time.Clock     (UTCTime)
import Data.Word           (Word64)

import AgdaGraph.GoalCanon (hashString)
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
  , seLoadHash :: !(Maybe Word64)
    -- ^ 'contentStamp' of the on-disk source the current load reflects.
    -- 'Nothing' = unknown (the file was unreadable at load, or it changed
    -- while the load was in flight) — mutators refuse until a clean reload
    -- restamps it. A mutator that reads different content than this refuses
    -- rather than splicing a stale offset.
  }

-- | Content identity stamp: the vendored Murmur64 over the decoded text
-- (see the @hashString@ gotcha in CLAUDE.md — no new hash dependency, and
-- hashing the char 'Text' keeps it consistent with the 1-based char-offset
-- world the bridge lives in).
contentStamp :: Text -> Word64
contentStamp = hashString . T.unpack

-- | Whether a (re)load may keep the prior stable goal-id map, given the
-- expected hash of a bridge-initiated write (if any), the previous load's
-- stamp, and the newly-observed on-disk stamp:
--
--   * a bridge write keeps ids iff disk still holds exactly what we wrote
--     (offset-keyed reuse is safe — we know the new layout);
--   * a plain reload keeps ids iff the content is byte-identical to the
--     prior load (an unsaved-file watcher reload, or a @give@ that didn't
--     move the other holes);
--   * an unknown new stamp (unreadable / changed-mid-load) or a first load
--     resets, so a client's cached id can never silently retarget a
--     different hole.
shouldKeepGoalIds
  :: Maybe Word64   -- ^ expected hash of a bridge-initiated write, if any
  -> Maybe Word64   -- ^ previous 'seLoadHash'
  -> Maybe Word64   -- ^ newly-observed stamp
  -> Bool
shouldKeepGoalIds mExpect mPrev mNew = case (mNew, mExpect, mPrev) of
  (Just h, Just w, _)       -> h == w
  (Just h, Nothing, Just p) -> h == p
  _                         -> False
