-- | Thin re-export of the shared @--interaction-json@ reply parser
-- ('AgdaGraph.Interaction.Protocol'), which lives in the @agda-graph@
-- library so @agda-goals@ and @agda-explore@'s write-side interaction
-- bridge share one parser.
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
