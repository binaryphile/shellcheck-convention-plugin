{-# LANGUAGE TemplateHaskell #-}
module ListInit (check, ListInit.runTests) where

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
    ccChecker = checkListInit,
    ccAlwaysOn = False,
    ccDescription = newCheckDescription {
        cdName = "list-init-shape",
        cdDescription = "List-suffixed variables should be initialized as arrays",
        cdPositive = "xList=foo",
        cdNegative = "xList=()"
    }
}

checkListInit :: Token -> Analysis
checkListInit (T_Assignment id _ name _ value)
    | hasListSuffixOnBare name && not (isArray value) =
        warn id 9008 $
            "List-suffixed variable '" ++ name ++
            "' should be initialized as an array (e.g. " ++
            name ++ "=() or " ++ name ++ "=(\"a\" \"b\"))."
checkListInit _ = return ()

isArray :: Token -> Bool
isArray (T_Array _ _) = True
isArray _             = False

-- Tests: should fire (List-suffixed name, value is not an array literal)
prop_sc9008_stringAssign  = verifyCode checkListInit 9008 "xList=foo"
prop_sc9008_emptyString   = verify     checkListInit "xList="
prop_sc9008_paramExpand   = verify     checkListInit "xList=$other"
prop_sc9008_cmdsub        = verify     checkListInit "xList=$(cat /etc/hosts)"
prop_sc9008_quoted        = verify     checkListInit "xList=\"a b\""
prop_sc9008_libSuffix     = verify     checkListInit "hostListQ=foo"

-- Tests: should NOT fire (initialized as array)
prop_sc9008_emptyArray    = verifyNot  checkListInit "xList=()"
prop_sc9008_arrayLiteral  = verifyNot  checkListInit "xList=(\"a\" \"b\")"
prop_sc9008_singletonArr  = verifyNot  checkListInit "xList=(\"only\")"

-- Tests: should NOT fire (name doesn't end in List / List<X>)
prop_sc9008_noSuffix      = verifyNot  checkListInit "x=foo"
prop_sc9008_lowercaseList = verifyNot  checkListInit "xlist=foo"
prop_sc9008_listInMiddle  = verifyNot  checkListInit "listItems=foo"

-- Tests: suppression
prop_sc9008_suppressed    = verifyNot  checkListInit "# shellcheck disable=SC9008\nxList=foo"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
