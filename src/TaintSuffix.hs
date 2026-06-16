{-# LANGUAGE TemplateHaskell #-}
module TaintSuffix (check, TaintSuffix.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import Convention
import ShellCheck.Interface

-- ask, when re-exported from Base
import qualified Data.Map as Map
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkUnquotedUnderscore,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "taint-suffix",
        cdDescription = "Warn when _-suffixed variable is used unquoted in a splitting context",
        cdPositive = "var_=x; echo $var_",
        cdNegative = "var_=x; echo \"$var_\""
    }
}

checkUnquotedUnderscore :: Token -> Analysis
checkUnquotedUnderscore token = case getExpansionName token of
    Just name | hasTaintSuffix name -> do
        params <- ask
        let parents = parentMap params
            shell = shellType params
        -- Integer-typed exception (#36870): bash coerces every assignment
        -- to a `-i`-typed variable to an integer; the IFS-splitting hazard
        -- doesn't apply.
        when (needsQuoting shell parents token
              && not (isIntegerTyped parents token name)) $
            err (getId token) 9001 $
                "Variable $" ++ name ++ " contains IFS characters and must be quoted."
    _ -> return ()

needsQuoting :: Shell -> Map.Map Id Token -> Token -> Bool
needsQuoting shell parents token =
    not (isArrayExpansion token)
    && not (isCountingReference token)
    && not (isQuoteFree shell parents token)
    && not (isQuotedAlternativeReference token)
    && not (usedAsCommandName parents token)
    && not (isInRedirectContext parents token)

-- Tests: splitting contexts (first test asserts specific SC code)
prop_sc9001_echo = verifyCode checkUnquotedUnderscore 9001 "var_=x; echo $var_"
prop_sc9001_arg = verify checkUnquotedUnderscore "var_=x; cmd $var_"
prop_sc9001_modifier = verify checkUnquotedUnderscore "echo ${var_/a/b}"
prop_sc9001_indirect = verify checkUnquotedUnderscore "echo ${!var_}"
prop_sc9001_default = verify checkUnquotedUnderscore "echo ${var_:-x}"
prop_sc9001_lowercase = verify checkUnquotedUnderscore "echo ${var_,,}"
prop_sc9001_uppercase = verify checkUnquotedUnderscore "echo ${var_^^}"
prop_sc9001_quoting_op = verify checkUnquotedUnderscore "echo ${var_@Q}"

-- Tests: quote-free contexts (should NOT fire)
prop_sc9001_quoted = verifyNot checkUnquotedUnderscore "var_=x; echo \"$var_\""
prop_sc9001_assignment = verifyNot checkUnquotedUnderscore "var_=x; y=$var_"
prop_sc9001_doublebrack = verifyNot checkUnquotedUnderscore "var_=x; [[ $var_ ]]"
prop_sc9001_arithmetic = verifyNot checkUnquotedUnderscore "(( var_ + 1 ))"
prop_sc9001_heredoc = verifyNot checkUnquotedUnderscore "cat <<EOF\n$var_\nEOF"
prop_sc9001_case = verifyNot checkUnquotedUnderscore "case $var_ in x) ;; esac"
prop_sc9001_forin = verifyNot checkUnquotedUnderscore "for f in $var_; do :; done"

-- Tests: special exclusions
prop_sc9001_special = verifyNot checkUnquotedUnderscore "echo $_"
prop_sc9001_counting = verifyNot checkUnquotedUnderscore "echo ${#var_}"
prop_sc9001_array = verifyNot checkUnquotedUnderscore "echo ${var_[@]}"
prop_sc9001_quotedalt = verifyNot checkUnquotedUnderscore "echo ${var_:+\"x\"}"

-- Tests: unbracedforms (ShellCheck parses $foo_ as T_DollarBraced)
prop_sc9001_unbraced = verify checkUnquotedUnderscore "echo $content_"
prop_sc9001_braced = verify checkUnquotedUnderscore "echo ${content_}"

-- Tests: suffix removal modifiers (getBracedReference stops at % correctly)
prop_sc9001_suffix_rm = verify checkUnquotedUnderscore "echo ${var_%pattern}"
prop_sc9001_suffix_rm2 = verify checkUnquotedUnderscore "echo ${var_%%pattern}"

-- Tests: redirect context (no word splitting in redirections)
prop_sc9001_redirect = verifyNot checkUnquotedUnderscore "echo x > $var_"
prop_sc9001_redirect_append = verifyNot checkUnquotedUnderscore "echo x >> $var_"

-- Tests: non-tainted vars (should NOT fire)
prop_sc9001_nontaint = verifyNot checkUnquotedUnderscore "echo $var"
prop_sc9001_nontaint2 = verifyNot checkUnquotedUnderscore "echo $varname"

-- Tests: suppression
prop_sc9001_suppressed = verifyNot checkUnquotedUnderscore "# shellcheck disable=SC9001\necho $var_"

-- Tests: integer-typed exception (#36870). Bash `-i` coerces every
-- assignment to integer, so the IFS-splitting hazard cannot apply.

-- Same scope: `local -i` decl suppresses SC9001 at the read site.
prop_sc9001_intTyped_local = verifyNot checkUnquotedUnderscore
    "foo() { local -i rc_=0; rc_=$?; echo $rc_; }"

-- declare -i at script scope likewise suppresses.
prop_sc9001_intTyped_declare = verifyNot checkUnquotedUnderscore
    "declare -i n_=0; echo $n_"

-- typeset -i is equivalent to declare -i.
prop_sc9001_intTyped_typeset = verifyNot checkUnquotedUnderscore
    "foo() { typeset -i x_=0; echo $x_; }"

-- Bundled flag chars (`-ir`, `-iA`, etc.) — any flag set containing `i`.
prop_sc9001_intTyped_bundled = verifyNot checkUnquotedUnderscore
    "foo() { local -ir frozen_=0; echo $frozen_; }"

-- readonly -i NAME also confers the integer attribute.
prop_sc9001_intTyped_readonly = verifyNot checkUnquotedUnderscore
    "readonly -i locked_=0; echo $locked_"

-- Un-typed path still fires (no -i; regression guard).
prop_sc9001_unTyped_stillFires = verifyCode checkUnquotedUnderscore 9001
    "foo() { local rc_=0; rc_=$?; echo $rc_; }"

-- Other flag (no `i`) does NOT suppress.
prop_sc9001_otherFlag_stillFires = verifyCode checkUnquotedUnderscore 9001
    "foo() { local -r rc_=0; echo $rc_; }"

-- Sibling-function isolation: `-i` declared in g must not protect f.
prop_sc9001_siblingFunctionIsolation = verifyCode checkUnquotedUnderscore 9001
    "f() { local rc_=0; echo $rc_; } g() { local -i rc_=0; echo $rc_; }"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
