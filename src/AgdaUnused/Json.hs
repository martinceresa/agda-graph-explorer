-- | Backwards-compatibility shim. The expanded-graph schema lives in
-- 'AgdaGraph.Schema'; this module re-exports just the slice the
-- unused-import analysis needs.
--
-- All new code should import 'AgdaGraph.Schema' directly.
module AgdaUnused.Json
  ( ExpandedGraph(..)
  , Definition(..)
  , Access(..)
  , ReExport(..)
  , loadExpandedGraph
  ) where

import AgdaGraph.Schema
  ( ExpandedGraph(..)
  , Definition(..)
  , Access(..)
  , ReExport(..)
  , loadExpandedGraph
  )
