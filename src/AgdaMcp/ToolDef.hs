{-# LANGUAGE OverloadedStrings #-}
-- | The shared tool-definition vocabulary for the @agda-explore@ MCP
-- surface: the 'Tool' record, the 'ToolRunner' type, the JSON-schema
-- builders, and the argument accessors. Extracted from 'AgdaMcp.Tools' so
-- the write-side interaction tools ('AgdaInteract.Tools') can contribute
-- catalogue entries without a module cycle.
module AgdaMcp.ToolDef
  ( ToolRunner
  , Tool(..)
    -- * Schema builders
  , objSchema
  , sp, ip, bp, np, ep
    -- * Argument accessors
  , argLookup
  , argText
  , argInt
  , argBool
  , argDouble
  , needName
  ) where

import           Data.Aeson        (Value (..), object, parseJSON, (.=))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import           Data.Aeson.Types  (parseMaybe)
import           Data.Maybe        (fromMaybe)
import           Data.Text         (Text)

import           AgdaMcp.State     (ServerState)

-- | A tool runner: the server state and the decoded @arguments@ object in,
-- a @Right@ text result or a @Left@ error message out.
type ToolRunner = ServerState -> Value -> IO (Either Text Text)

data Tool = Tool
  { tName   :: !Text
  , tDesc   :: !Text
  , tSchema :: !Value
  , tRun    :: !ToolRunner
  }

-- ---------------------------------------------------------------------
-- JSON-schema builders
-- ---------------------------------------------------------------------

objSchema :: [(Text, Value)] -> [Text] -> Value
objSchema props req = object
  [ "type"                 .= ("object" :: Text)
  , "properties"           .= object [ Key.fromText k .= v | (k, v) <- props ]
  , "required"             .= req
  , "additionalProperties" .= False
  ]

sp, ip, bp, np :: Text -> Value
sp d = object ["type" .= ("string" :: Text),  "description" .= d]
ip d = object ["type" .= ("integer" :: Text), "description" .= d]
bp d = object ["type" .= ("boolean" :: Text), "description" .= d]
np d = object ["type" .= ("number" :: Text),  "description" .= d]

-- | A string property constrained to an @enum@ (e.g. @format@: text|json).
ep :: Text -> [Text] -> Value
ep d vals = object ["type" .= ("string" :: Text), "enum" .= vals, "description" .= d]

-- ---------------------------------------------------------------------
-- Argument accessors
-- ---------------------------------------------------------------------

argLookup :: Value -> Text -> Maybe Value
argLookup (Object o) k = KM.lookup (Key.fromText k) o
argLookup _          _ = Nothing

argText :: Value -> Text -> Maybe Text
argText v k = argLookup v k >>= parseMaybe parseJSON

argInt :: Value -> Text -> Int -> Int
argInt v k d = fromMaybe d (argLookup v k >>= parseMaybe parseJSON)

argBool :: Value -> Text -> Bool -> Bool
argBool v k d = fromMaybe d (argLookup v k >>= parseMaybe parseJSON)

argDouble :: Value -> Text -> Double -> Double
argDouble v k d = fromMaybe d (argLookup v k >>= parseMaybe parseJSON)

needName :: Value -> (Text -> IO (Either Text Text)) -> IO (Either Text Text)
needName a go = case argText a "name" of
  Nothing -> pure (Left "missing required argument: name")
  Just n  -> go n
