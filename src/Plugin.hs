{-
    IFS/noglob convention check plugin for ShellCheck.
    Loaded dynamically via dlopen at runtime.

    All checks are always-on: installing the plugin opts the user into
    the full convention vocabulary. Suppress individual codes per-line
    via `# shellcheck disable=SC9xxx` or globally via `disable=SC9xxx`
    in .shellcheckrc.

    Checks:
      SC9001 - Unquoted tainted variable
      SC9002 - Command substitution taint (taint-assignment)
      SC9003 - Unnecessary quoting under IFS/noglob (unnecessary-quoting)
      SC9004 - Mutually exclusive suffixes
      SC9005 - Numeric comparison in [[ ]] / [ ] (numerics-in-brackets)
      SC9006 - Legacy whitelist/blacklist in identifier or comment (inclusive-language)
      SC9007 - Docstring should begin with function name (docstring-shape)
      SC9008 - *List should be IFS-serialized string, not array (list-array-misuse)
      SC9009 - Uninitialized-then-appended variable (nil-avoidance)
      SC9010 - IFS+noglob discipline absent (ifs-noglob-discipline)
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
import qualified NilAvoidance
import qualified IfsNoglobDiscipline

foreign export ccall plugin_api_version :: IO CInt
foreign export ccall plugin_init :: IO (StablePtr [CustomCheck])

plugin_api_version :: IO CInt
plugin_api_version = return (fromIntegral pluginApiVersion)

plugin_init :: IO (StablePtr [CustomCheck])
plugin_init = newStablePtr [
    TaintSuffix.check,         -- SC9001
    MutualExclusive.check,     -- SC9004
    TaintAssignment.check,     -- SC9002
    UnnecessaryQuoting.check,  -- SC9003
    Numerics.check,            -- SC9005
    Inclusive.check,           -- SC9006
    Docstring.check,           -- SC9007
    ListInit.check,            -- SC9008
    NilAvoidance.check,        -- SC9009
    IfsNoglobDiscipline.check  -- SC9010
  ]
