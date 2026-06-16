{-
    Fragment-mode toggle (#37003).

    When the SC_PLUGIN_FRAGMENT environment variable is set to "1" at
    plugin load, the convention checks treat the input as a fragment
    that may not include the enclosing scope. Concretely, SC9001 and
    SC9002 (the scope-aware checks from #36870) suppress when no `-i`
    declaration is visible — the consumer's fragment-mode signal asserts
    that the declaration could lie outside the snippet, so the nudge is
    unsound.

    Read once via a NOINLINE CAF: shellcheck dlopens the plugin per
    invocation, so the value is stable for the run.
-}
module FragmentMode (isFragmentMode) where

import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE isFragmentMode #-}
isFragmentMode :: Bool
isFragmentMode = unsafePerformIO $ do
    v <- lookupEnv "SC_PLUGIN_FRAGMENT"
    return (v == Just "1")
