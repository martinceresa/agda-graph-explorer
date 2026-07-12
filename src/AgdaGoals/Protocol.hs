-- | Thin re-export of the shared @--interaction-json@ wire shapes
-- ('AgdaGraph.Interaction.Protocol'), which live in the @agda-graph@
-- library so @agda-goals@ and @agda-explore@'s write-side interaction
-- bridge share one parser.
module AgdaGoals.Protocol
  ( -- * Parsed wire shapes
    Reply(..)
  , DisplayInfo(..)
  , Goal(..)
  , GoalRange(..)
  , RangePos(..)
  ) where

import AgdaGraph.Interaction.Protocol
  ( Reply(..)
  , DisplayInfo(..)
  , Goal(..)
  , GoalRange(..)
  , RangePos(..)
  )
