-- | Thin re-export of the shared @--interaction-json@ reply parser.
--
-- The implementation was promoted into the @agda-graph@ library
-- ('AgdaGraph.Interaction.Protocol') so it can be shared with
-- @agda-explore@'s write-side interaction bridge. This module keeps the
-- historical @AgdaGoals.Protocol@ name (mirroring 'AgdaGoals.Canon').
module AgdaGoals.Protocol
  ( -- * Parsed wire shapes
    Reply(..)
  , DisplayInfo(..)
  , Goal(..)
  , GoalRange(..)
  , RangePos(..)

    -- * Parsing
  , parseReply
  , parseReplyLines
  , stripPromptPrefix
  ) where

import AgdaGraph.Interaction.Protocol
  ( Reply(..)
  , DisplayInfo(..)
  , Goal(..)
  , GoalRange(..)
  , RangePos(..)
  , parseReply
  , parseReplyLines
  , stripPromptPrefix
  )
