{-
    IFS/noglob convention check plugin for ShellCheck.
    Loaded dynamically via dlopen at runtime.

    Checks:
      SC9001 - Unquoted tainted variable (always-on)
      SC9002 - Command substitution taint (optional: taint-assignment)
      SC9003 - Unnecessary quoting under IFS/noglob (optional: unnecessary-quoting)
      SC9004 - Mutually exclusive suffixes (always-on)
-}
module Plugin where

import Foreign.C.Types (CInt(..))
import Foreign.StablePtr (StablePtr, newStablePtr)

import ShellCheck.Checks.Custom.Base (CustomCheck, pluginApiVersion)

import qualified TaintSuffix
import qualified MutualExclusive
import qualified TaintAssignment
import qualified UnnecessaryQuoting

foreign export ccall plugin_api_version :: IO CInt
foreign export ccall plugin_init :: IO (StablePtr [CustomCheck])

plugin_api_version :: IO CInt
plugin_api_version = return (fromIntegral pluginApiVersion)

plugin_init :: IO (StablePtr [CustomCheck])
plugin_init = newStablePtr [
    TaintSuffix.check,         -- SC9001, always-on
    MutualExclusive.check,     -- SC9004, always-on
    TaintAssignment.check,     -- SC9002, optional
    UnnecessaryQuoting.check   -- SC9003, optional
  ]
