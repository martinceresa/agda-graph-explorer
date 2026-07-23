module Main where

-- Lib is opened twice from the same file: the second is a duplicate.
open import Lib using (foo)
open import Lib using (bar)

run : Set₁
run = foo
