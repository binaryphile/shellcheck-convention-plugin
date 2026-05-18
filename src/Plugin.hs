{-
    IFS/noglob convention check plugin for ShellCheck.
    Loaded dynamically via dlopen at runtime.

    Checks:
      SC9001 - Unquoted tainted variable (always-on)
      SC9002 - Command substitution taint (optional: taint-assignment)
      SC9003 - Unnecessary quoting under IFS/noglob (optional: unnecessary-quoting)
      SC9004 - Mutually exclusive suffixes (always-on)
      SC9005 - Numeric comparison in [[ ]] / [ ] (optional: numerics-in-brackets)
      SC9006 - Legacy whitelist/blacklist in identifier or comment (optional: inclusive-language)
      SC9007 - Docstring should begin with function name (optional: docstring-shape)
      SC9008 - *List should be IFS-serialized string, not array (optional: list-array-misuse)
-}
module Plugin where

import Foreign.C.Types (CInt(..))
import Foreign.StablePtr (StablePtr, newStablePtr)

import ShellCheck.Checks.Custom.Base (CustomCheck, pluginApiVersion)

import qualified TaintSuffix
import qualified MutualExclusive
import qualified TaintAssignment
import qualified UnnecessaryQuoting
import qualified Numerics
import qualified Inclusive
import qualified Docstring
import qualified ListInit

foreign export ccall plugin_api_version :: IO CInt
foreign export ccall plugin_init :: IO (StablePtr [CustomCheck])

plugin_api_version :: IO CInt
plugin_api_version = return (fromIntegral pluginApiVersion)

plugin_init :: IO (StablePtr [CustomCheck])
plugin_init = newStablePtr [
    TaintSuffix.check,         -- SC9001, always-on
    MutualExclusive.check,     -- SC9004, always-on
    TaintAssignment.check,     -- SC9002, optional
    UnnecessaryQuoting.check,  -- SC9003, optional
    Numerics.check,            -- SC9005, optional
    Inclusive.check,           -- SC9006, optional
    Docstring.check,           -- SC9007, optional
    ListInit.check             -- SC9008, optional
  ]
