{-# LANGUAGE TemplateHaskell #-}
module Inclusive (check, Inclusive.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Data.Char (toLower)
import Data.List (isInfixOf)
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkInclusiveLanguage,
    ccAlwaysOn = False,
    ccDescription = newCheckDescription {
        cdName = "inclusive-language",
        cdDescription = "Suggest allowlist/denylist over legacy terms in identifier names",
        cdPositive = "whitelist=foo",
        cdNegative = "allowlist=foo"
    }
}

checkInclusiveLanguage :: Token -> Analysis
checkInclusiveLanguage (T_Assignment id _ name _ _) = checkName id name
checkInclusiveLanguage (T_Function id _ _ name _)   = checkName id name
checkInclusiveLanguage _                            = return ()

checkName :: Id -> String -> Analysis
checkName id name
    | "whitelist" `isInfixOf` lc =
        warn id 9006 $
            "Identifier '" ++ name ++ "' contains 'whitelist'; prefer 'allowlist'."
    | "blacklist" `isInfixOf` lc =
        warn id 9006 $
            "Identifier '" ++ name ++ "' contains 'blacklist'; prefer 'denylist'."
    | otherwise = return ()
  where
    lc = map toLower name

-- Tests: should fire (legacy term in assignment or function name)
prop_sc9006_assignWhite  = verifyCode checkInclusiveLanguage 9006 "whitelist=foo"
prop_sc9006_assignBlack  = verify checkInclusiveLanguage "blacklist=()"
prop_sc9006_caseInsens   = verify checkInclusiveLanguage "BLACKLIST=()"
prop_sc9006_mixedCase    = verify checkInclusiveLanguage "userWhitelistDir=foo"
prop_sc9006_funcName     = verify checkInclusiveLanguage "blacklistFn() { :; }"
prop_sc9006_funcKeyword  = verify checkInclusiveLanguage "function whitelistInit { :; }"

-- Tests: should NOT fire (inclusive forms, unrelated names, expansion sites)
prop_sc9006_allowlist    = verifyNot checkInclusiveLanguage "allowlist=foo"
prop_sc9006_denylist     = verifyNot checkInclusiveLanguage "denylist=foo"
prop_sc9006_plain        = verifyNot checkInclusiveLanguage "plain=hello"
prop_sc9006_helperFn     = verifyNot checkInclusiveLanguage "helperFn() { :; }"
prop_sc9006_expansion    = verifyNot checkInclusiveLanguage "echo $whitelist"
prop_sc9006_forIn        = verifyNot checkInclusiveLanguage "for whitelistVar in a b; do :; done"

-- Tests: suppression
prop_sc9006_suppressed   = verifyNot checkInclusiveLanguage "# shellcheck disable=SC9006\nwhitelist=foo"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
