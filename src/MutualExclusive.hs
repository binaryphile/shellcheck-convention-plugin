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
        cdDescription = "Warn when _ and List/Lists suffixes are both present on a variable",
        cdPositive = "hostList_=foo",
        cdNegative = "hostList=foo"
    }
}

checkMutuallyExclusive :: Token -> Analysis
checkMutuallyExclusive (T_Assignment id _ name _ _)
    | hasTaintSuffix name && hasListSuffix name =
        err id 9004 $ "Suffixes _ and List are mutually exclusive on " ++ name ++ "."
    | hasTaintSuffix name && hasListsSuffix name =
        err id 9004 $ "Suffixes _ and Lists are mutually exclusive on " ++ name ++ "."
checkMutuallyExclusive token = case getExpansionName token of
    Just name | hasTaintSuffix name && hasListSuffix name ->
        err (getId token) 9004 $ "Suffixes _ and List are mutually exclusive on " ++ name ++ "."
    Just name | hasTaintSuffix name && hasListsSuffix name ->
        err (getId token) 9004 $ "Suffixes _ and Lists are mutually exclusive on " ++ name ++ "."
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

prop_sc9004_assignHostLists = verifyCode checkMutuallyExclusive 9004 "hostLists_=(a b)"
prop_sc9004_assignHostListsQ = verify checkMutuallyExclusive "hostListsQ_=(a b)"
prop_sc9004_expandHostLists = verify checkMutuallyExclusive "echo $hostLists_"

prop_sc9004_noTaintLists = verifyNot checkMutuallyExclusive "hostLists=(a b)"
prop_sc9004_noLists = verifyNot checkMutuallyExclusive "host_=(a b)"
prop_sc9004_lowercaseLists = verifyNot checkMutuallyExclusive "hostlists_=(a b)"
prop_sc9004_listsInMiddle = verifyNot checkMutuallyExclusive "listsItems_=foo"
prop_sc9004_listItemsEndLists = verifyNot checkMutuallyExclusive "itemListsItems_=foo"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
