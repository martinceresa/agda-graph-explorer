-- | Shell-completion script generation from plain flag/subcommand data.
--
-- Decoupled from any particular CLI parser (it takes strings, not a
-- 'FlagSpec'), so each executable can feed it whatever it derives from its
-- own flag table — @agda-optimization@ builds a 'CompletionSpec' straight
-- from its @flagSpecs@ + subcommand list, so the completion can't drift from
-- the parser. Bash is the primary target; the zsh variant reuses the bash
-- function via @bashcompinit@ (portable, no hand-written @_arguments@).
module AgdaGraph.Completion
  ( CompletionSpec(..)
  , renderCompletion
  ) where

-- | What a program offers for completion. @csSubcommands@ empty ⇒ a flat tool
-- (only @csGlobals@ complete); non-empty ⇒ the first non-flag word completes to
-- a subcommand, after which that subcommand's flags plus the globals complete.
data CompletionSpec = CompletionSpec
  { csProg        :: String                 -- ^ program name (e.g. @"agda-optimization"@).
  , csGlobals     :: [String]               -- ^ global flags, with leading @--@.
  , csSubcommands :: [(String, [String])]   -- ^ @(subcommand, its flags with @--@)@.
  }

-- | Render a completion script for the given shell (@"bash"@ or @"zsh"@).
-- An unrecognised shell falls back to bash. The zsh output is the bash script
-- prefixed with an @autoload bashcompinit@ shim.
renderCompletion :: String -> CompletionSpec -> String
renderCompletion shell spec = case shell of
  "zsh" -> zshPreamble ++ bashScript spec
  _     -> bashScript spec

zshPreamble :: String
zshPreamble = unlines
  [ "# zsh: reuse the bash completion via bashcompinit."
  , "autoload -Uz +X compinit && compinit"
  , "autoload -Uz +X bashcompinit && bashcompinit"
  , ""
  ]

bashScript :: CompletionSpec -> String
bashScript (CompletionSpec prog globals subs) = unlines $
  [ "# bash completion for " ++ prog ++ ". Source it, or install into a"
  , "# completions dir:  " ++ prog ++ " --completion-script=bash > \\"
  , "#   \"${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/" ++ prog ++ "\""
  , fn ++ "() {"
  , "  local cur subs globals sub i"
  , "  cur=\"${COMP_WORDS[COMP_CWORD]}\""
  , "  subs=\"" ++ unwords (map fst subs) ++ "\""
  , "  globals=\"" ++ unwords globals ++ "\""
  ]
  ++ (if null subs
        then [ "  COMPREPLY=( $(compgen -W \"$globals\" -- \"$cur\") )" ]
        else
          [ "  # find the chosen subcommand: the first non-flag word before the cursor."
          , "  sub=\"\""
          , "  for (( i=1; i < COMP_CWORD; i++ )); do"
          , "    case \"${COMP_WORDS[i]}\" in"
          , "      -*) ;;"
          , "      *) sub=\"${COMP_WORDS[i]}\"; break ;;"
          , "    esac"
          , "  done"
          , "  if [ -z \"$sub\" ]; then"
          , "    COMPREPLY=( $(compgen -W \"$subs $globals\" -- \"$cur\") )"
          , "    return"
          , "  fi"
          , "  case \"$sub\" in"
          ]
          ++ concatMap subCase subs
          ++
          [ "    *) COMPREPLY=( $(compgen -W \"$globals\" -- \"$cur\") ) ;;"
          , "  esac"
          ])
  ++
  [ "}"
  , "complete -F " ++ fn ++ " " ++ prog
  ]
  where
    fn = "_" ++ map sanitize prog
    sanitize c = if c == '-' || c == '.' then '_' else c
    subCase (name, flags) =
      [ "    " ++ name ++ ")"
      , "      COMPREPLY=( $(compgen -W \"" ++ unwords flags ++ " $globals\" -- \"$cur\") ) ;;"
      ]
