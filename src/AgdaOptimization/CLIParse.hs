{-# LANGUAGE BangPatterns #-}
-- | Tiny shared helpers for hand-rolled CLI parsing of the per-subcommand
-- option records. Deliberately minimal: just enough to support
-- @--flag=value@ / @--flag value@ uniformity and typed value parsing.
--
-- Each per-analysis @parseOptions@ folds over the argv strictly and
-- dispatches on the flag name; this module factors out the boring
-- bits so the dispatch tables in 'AgdaOptimization.Motif' etc. stay
-- readable.
module AgdaOptimization.CLIParse
  ( splitFlag
  , valueFor
  , readInt
  , readDbl
  ) where

-- | Split a single argv token into its flag name and (optionally) its
-- inline value. @--flag=value@ becomes @Right (\"--flag\", Just value)@;
-- @--flag@ alone becomes @Right (\"--flag\", Nothing)@; a positional
-- (no leading @--@) becomes @Left err@ naming the token.
--
-- Per-analysis parsers consume the next argv element themselves when
-- 'Nothing' is returned and the flag is known to be value-taking;
-- this keeps the "unknown flag" diagnostic accurate (we report the
-- bad flag name rather than blaming the trailing token).
splitFlag :: String -> Either String (String, Maybe String)
splitFlag !a
  | take 2 a == "--" =
      case break (== '=') a of
        (k, '=':v) -> Right (k, Just v)
        (k, _)     -> Right (k, Nothing)
  | otherwise = Left ("unexpected argument: " <> a)

-- | Resolve a flag's value: prefer the inline form (@--flag=value@),
-- otherwise consume the next argv token. Returns the value and the
-- residual argv.
valueFor :: String -> String -> Maybe String -> [String] -> Either String (String, [String])
valueFor _   _ (Just v) rest = Right (v, rest)
valueFor _   _ Nothing  (v:rest) = Right (v, rest)
valueFor sub k Nothing  []  = Left (sub <> ": " <> k <> " expects a value")

-- | Parse an integer flag value. The first two arguments are the
-- subcommand name and the flag spelling, used to build a clean error
-- message.
readInt :: String -> String -> String -> Either String Int
readInt sub k v = case reads v of
  [(n, "")] -> Right n
  _         -> Left (sub <> ": " <> k <> ": expected integer, got " <> show v)

-- | Parse a 'Double' flag value. See 'readInt' for the error format.
readDbl :: String -> String -> String -> Either String Double
readDbl sub k v = case reads v of
  [(n, "")] -> Right n
  _         -> Left (sub <> ": " <> k <> ": expected number, got " <> show v)
