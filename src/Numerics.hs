{-# LANGUAGE TemplateHaskell #-}
module Numerics (check, Numerics.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkNumericInBrackets,
    ccAlwaysOn = False,
    ccDescription = newCheckDescription {
        cdName = "numerics-in-brackets",
        cdDescription = "Warn when [[ ]] / [ ] is used for numeric comparison; prefer (( ))",
        cdPositive = "[[ $rc -eq 0 ]]",
        cdNegative = "(( rc == 0 ))"
    }
}

checkNumericInBrackets :: Token -> Analysis
checkNumericInBrackets (TC_Binary id _ op _ _)
    | op `elem` ["-eq", "-ne", "-lt", "-gt", "-le", "-ge"] =
        style id 9005 $
            "Numeric comparison '" ++ op ++ "' in conditional; use (( "
            ++ arithOp op ++ " )) per bash-style-guide §7."
checkNumericInBrackets _ = return ()

arithOp :: String -> String
arithOp "-eq" = "=="
arithOp "-ne" = "!="
arithOp "-lt" = "<"
arithOp "-gt" = ">"
arithOp "-le" = "<="
arithOp "-ge" = ">="
arithOp s     = s

-- Tests: should fire (numeric flag-ops in both bracket types)
prop_sc9005_doubleEq = verifyCode checkNumericInBrackets 9005 "[[ $rc -eq 0 ]]"
prop_sc9005_doubleNe = verify checkNumericInBrackets "[[ $rc -ne 0 ]]"
prop_sc9005_doubleLt = verify checkNumericInBrackets "[[ $count -lt 5 ]]"
prop_sc9005_doubleGt = verify checkNumericInBrackets "[[ $# -gt 0 ]]"
prop_sc9005_doubleLe = verify checkNumericInBrackets "[[ $rc -le 1 ]]"
prop_sc9005_doubleGe = verify checkNumericInBrackets "[[ $rc -ge 1 ]]"
prop_sc9005_singleEq = verify checkNumericInBrackets "[ $rc -eq 0 ]"
prop_sc9005_singleGt = verify checkNumericInBrackets "[ $# -gt 0 ]"

-- Tests: should NOT fire (string emptiness, file/path predicates, string equality, (( )))
prop_sc9005_emptyZ    = verifyNot checkNumericInBrackets "[[ -z $x ]]"
prop_sc9005_emptyN    = verifyNot checkNumericInBrackets "[[ -n \"$x\" ]]"
prop_sc9005_fileF     = verifyNot checkNumericInBrackets "[[ -f /etc/hostname ]]"
prop_sc9005_fileD     = verifyNot checkNumericInBrackets "[[ -d /tmp ]]"
prop_sc9005_stringEq  = verifyNot checkNumericInBrackets "[[ $a == $b ]]"
prop_sc9005_stringEq2 = verifyNot checkNumericInBrackets "[[ $a = \"$b\" ]]"
prop_sc9005_stringNe  = verifyNot checkNumericInBrackets "[[ $a != $b ]]"
prop_sc9005_arith     = verifyNot checkNumericInBrackets "(( rc == 0 ))"
prop_sc9005_arith2    = verifyNot checkNumericInBrackets "(( count > 0 ))"

-- Tests: suppression
prop_sc9005_suppressed = verifyNot checkNumericInBrackets "# shellcheck disable=SC9005\n[[ $rc -eq 0 ]]"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
