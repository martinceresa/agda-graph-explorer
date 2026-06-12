# Literate convergence fixture

Prose before the code block, so the hole sits well past byte offset zero and
the edit must land inside the fenced block (never in this prose).

```agda
module Doc where

open import Agda.Builtin.Nat

six : Nat
six = {!!}            -- give: 6
```

More prose after the block.
