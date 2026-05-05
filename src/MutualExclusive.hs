{-# LANGUAGE TemplateHaskell #-}
module MutualExclusive (check, MutualExclusive.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import Convention
import ShellCheck.Interface

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkMutuallyExclusive,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "mutually-exclusive-suffixes",
        cdDescription = "Warn when _ and List suffixes are both present on a variable",
        cdPositive = "hostList_=foo",
        cdNegative = "hostList=foo"
    }
}

checkMutuallyExclusive :: Token -> Analysis
checkMutuallyExclusive (T_Assignment id _ name _ _)
    | hasTaintSuffix name && hasListSuffix name =
        err id 9004 $ "Suffixes _ and List are mutually exclusive on " ++ name ++ "."
checkMutuallyExclusive token = case getExpansionName token of
    Just name | hasTaintSuffix name && hasListSuffix name ->
        err (getId token) 9004 $ "Suffixes _ and List are mutually exclusive on " ++ name ++ "."
    _ -> return ()

-- Tests

prop_sc9004_assignHostList = verifyCode checkMutuallyExclusive 9004 "hostList_=foo"
prop_sc9004_assignHostListQ = verify checkMutuallyExclusive "hostListQ_=foo"
prop_sc9004_assignGroupList = verify checkMutuallyExclusive "groupList_=foo"
prop_sc9004_expandHostList = verify checkMutuallyExclusive "echo $hostList_"

prop_sc9004_noTaint = verifyNot checkMutuallyExclusive "hostList=foo"
prop_sc9004_noList = verifyNot checkMutuallyExclusive "host_=foo"
prop_sc9004_lowercaseList = verifyNot checkMutuallyExclusive "hostlist_=foo"
prop_sc9004_listInMiddle = verifyNot checkMutuallyExclusive "listItems_=foo"
prop_sc9004_listItemsEnd = verifyNot checkMutuallyExclusive "itemListItems_=foo"
prop_sc9004_plainVar = verifyNot checkMutuallyExclusive "foo=bar"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
