# Literate interaction fixture

This prose precedes the code block. It exists to push the code well past
byte offset zero, so a fixture can confirm whether Agda reports interaction
ranges as offsets into the **full literate file** (prose included) or into
the concatenated code blocks only.

```agda
module Lit where

open import Agda.Builtin.Nat

triple : Nat → Nat
triple n = {!!}
```

More prose after the block.
