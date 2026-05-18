{-# LANGUAGE TemplateHaskell #-}
module ListInit (check, ListInit.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import Convention
import ShellCheck.Interface

import Data.List (isSuffixOf)
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkListMisuse,
    ccAlwaysOn = False,
    ccDescription = newCheckDescription {
        cdName = "list-array-misuse",
        cdDescription = "*List should be an IFS-serialized string (bash-style-guide §3); use plural-noun suffix for arrays",
        cdPositive = "xList=(a b c)",
        cdNegative = "xList=foo"
    }
}

checkListMisuse :: Token -> Analysis
checkListMisuse (T_Assignment id _ name _ value)
    | hasListSuffixOnBare name && isArray value =
        warn id 9008 $
            "Variable '" ++ name ++ "' uses *List suffix (= IFS-serialized "
            ++ "string per bash-style-guide §3) but is initialized as an "
            ++ "array. Use a plural-noun suffix for arrays (e.g. " ++
            pluralize name ++ "), or drop the array syntax for a serialized string."
checkListMisuse _ = return ()

isArray :: Token -> Bool
isArray (T_Array _ _) = True
isArray _             = False

-- Best-effort plural suggestion: strip 'List' (or 'List<X>') and append 's'.
-- Falls back to '<stem>s' for the simple case; leaves library-suffix forms
-- to the author's judgment with a generic suggestion.
pluralize :: String -> String
pluralize name
    | "List" `isSuffixOf` name = take (length name - 4) name ++ "s"
    | otherwise                = name ++ "s"

-- Tests: should fire (List-suffixed name, value IS an array literal)
prop_sc9008_emptyArray    = verifyCode checkListMisuse 9008 "xList=()"
prop_sc9008_arrayLiteral  = verify     checkListMisuse "xList=(a b c)"
prop_sc9008_quotedArray   = verify     checkListMisuse "xList=(\"a\" \"b\")"
prop_sc9008_libSuffix     = verify     checkListMisuse "hostListQ=(a b)"
prop_sc9008_singletonArr  = verify     checkListMisuse "xList=(only)"

-- Tests: should NOT fire (List name + string value = correct §3 form)
prop_sc9008_stringAssign  = verifyNot  checkListMisuse "xList=foo"
prop_sc9008_emptyString   = verifyNot  checkListMisuse "xList="
prop_sc9008_paramExpand   = verifyNot  checkListMisuse "xList=$other"
prop_sc9008_cmdsub        = verifyNot  checkListMisuse "xList=$(cat /etc/hosts)"
prop_sc9008_quoted        = verifyNot  checkListMisuse "xList=\"a b\""

-- Tests: should NOT fire (plural-noun suffix = correct array form)
prop_sc9008_pluralArray   = verifyNot  checkListMisuse "octopi=(inky blinky)"
prop_sc9008_widgetsArray  = verifyNot  checkListMisuse "widgets=(\"a\" \"b\")"

-- Tests: should NOT fire (not a List suffix at all)
prop_sc9008_noSuffix      = verifyNot  checkListMisuse "x=foo"
prop_sc9008_lowercaseList = verifyNot  checkListMisuse "xlist=(a b)"
prop_sc9008_listInMiddle  = verifyNot  checkListMisuse "listItems=(a b)"

-- Tests: suppression
prop_sc9008_suppressed    = verifyNot  checkListMisuse "# shellcheck disable=SC9008\nxList=(a b)"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
