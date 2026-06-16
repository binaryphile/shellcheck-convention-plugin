{-# LANGUAGE TemplateHaskell #-}
module TaintAssignment (check, TaintAssignment.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import Convention
import FragmentMode (isFragmentMode)
import ShellCheck.Interface

import Data.Char (isLower)
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkCmdSubNoUnderscore,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "taint-assignment",
        cdDescription = "Warn when command substitution is assigned to a non-_ variable",
        cdPositive = "content=$(cat file)",
        cdNegative = "content_=$(cat file)"
    }
}

checkCmdSubNoUnderscore :: Token -> Analysis
checkCmdSubNoUnderscore t@(T_Assignment id _ name _ value)
    | not (null name)
    , isLowerStart name
    , not (hasTaintSuffix name)
    , containsCommandSub value
    , not (isAllowlistedCommand value)
    = do
        params <- ask
        -- Integer-typed exception (#36870): bash coerces cmdsub output
        -- assigned to a `-i`-typed variable to an integer (failed coercion
        -- yields 0); the captured-newline hazard the taint suffix guards
        -- against cannot apply, so the SC9002 nudge is unsound here.
        -- Fragment-mode exception (#37003): the consumer asserts the
        -- snippet may not include its enclosing scope, so absent a
        -- visible `-i` decl, the decl may sit outside the fragment.
        when (not (isIntegerTyped (parentMap params) t name)
              && not isFragmentMode) $
            warn id 9002 $
                "Command substitution assigned to " ++ name
                ++ " -- use " ++ name ++ "_ if it may contain newlines."
checkCmdSubNoUnderscore _ = return ()

isLowerStart :: String -> Bool
isLowerStart (c:_) = isLower c || c == '_'
isLowerStart _ = False

containsCommandSub :: Token -> Bool
containsCommandSub t = any isCmdSub (getWordParts t)
  where
    isCmdSub (T_DollarExpansion {}) = True
    isCmdSub (T_Backticked {}) = True
    isCmdSub _ = False

isAllowlistedCommand :: Token -> Bool
isAllowlistedCommand t = any checkPart (getWordParts t)
  where
    checkPart (T_DollarExpansion _ cmds) = allowlistedPipeline cmds
    checkPart (T_Backticked _ cmds) = allowlistedPipeline cmds
    checkPart _ = False

    allowlistedPipeline (T_Pipeline _ _ (cmd:_) : _) =
        maybe False (`elem` safeCommands) (getCommandName cmd)
    allowlistedPipeline _ = False

    safeCommands =
        [ "basename", "dirname", "id", "hostname", "uname", "whoami"
        , "date", "pwd", "readlink", "realpath", "which", "type", "expr"
        ]

-- Tests: should fire
prop_sc9002_cat = verifyCode checkCmdSubNoUnderscore 9002 "content=$(cat file)"
prop_sc9002_grep = verify checkCmdSubNoUnderscore "result=$(grep foo bar)"
prop_sc9002_backtick = verify checkCmdSubNoUnderscore "result=`cat file`"
prop_sc9002_unknown = verify checkCmdSubNoUnderscore "data=$(somecommand)"

-- Tests: should NOT fire
prop_sc9002_tainted = verifyNot checkCmdSubNoUnderscore "content_=$(cat file)"
prop_sc9002_uppercase = verifyNot checkCmdSubNoUnderscore "FOO=$(cat file)"
prop_sc9002_basename = verifyNot checkCmdSubNoUnderscore "name=$(basename /foo/bar)"
prop_sc9002_dirname = verifyNot checkCmdSubNoUnderscore "dir=$(dirname /foo/bar)"
prop_sc9002_hostname = verifyNot checkCmdSubNoUnderscore "host=$(hostname)"
prop_sc9002_pwd = verifyNot checkCmdSubNoUnderscore "cwd=$(pwd)"
prop_sc9002_noSubst = verifyNot checkCmdSubNoUnderscore "x=hello"
prop_sc9002_arithmetic = verifyNot checkCmdSubNoUnderscore "x=$((1+2))"
-- Pipeline: allowlist checks first command only (heuristic — see design.md for trade-off rationale)
prop_sc9002_pipeline = verify checkCmdSubNoUnderscore "result=$(cat file | grep foo)"
prop_sc9002_simpleAllowlist = verifyNot checkCmdSubNoUnderscore "h=$(hostname)"

-- Tests: integer-typed exception (#36870). Bash `-i` coerces cmdsub
-- output to int (failed coercion → 0); the captured-newline hazard the
-- taint suffix guards against cannot apply.

-- Same-line declaration with cmdsub init: SC9002 suppressed.
prop_sc9002_intTyped_localSameLine = verifyNot checkCmdSubNoUnderscore
    "foo() { local -i count=$(nproc); echo $count; }"

-- Later plain assignment to a previously `-i` declared var.
prop_sc9002_intTyped_localLater = verifyNot checkCmdSubNoUnderscore
    "foo() { local -i n=0; n=$(nproc); echo $n; }"

-- declare -i at script scope.
prop_sc9002_intTyped_declare = verifyNot checkCmdSubNoUnderscore
    "declare -i count=$(nproc)"

-- typeset -i.
prop_sc9002_intTyped_typeset = verifyNot checkCmdSubNoUnderscore
    "foo() { typeset -i n=0; n=$(grep -c foo bar); echo $n; }"

-- Bundled flag chars (`-ir`, etc.) — any flag set containing `i`.
prop_sc9002_intTyped_bundled = verifyNot checkCmdSubNoUnderscore
    "foo() { local -ir frozen=$(nproc); echo $frozen; }"

-- readonly -i NAME.
prop_sc9002_intTyped_readonly = verifyNot checkCmdSubNoUnderscore
    "readonly -i locked=$(nproc); echo $locked"

-- Un-typed path still fires (regression guard).
prop_sc9002_unTyped_stillFires = verifyCode checkCmdSubNoUnderscore 9002
    "foo() { local n=0; n=$(nproc); echo $n; }"

-- Other flag without `i` (e.g. `-r`) does NOT suppress.
prop_sc9002_otherFlag_stillFires = verifyCode checkCmdSubNoUnderscore 9002
    "foo() { local -r n=0; n=$(nproc); echo $n; }"

-- Sibling-function isolation: `-i` in g must not protect f.
prop_sc9002_siblingFunctionIsolation = verifyCode checkCmdSubNoUnderscore 9002
    "f() { local n=0; n=$(nproc); } g() { local -i n=0; n=$(nproc); }"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
