{-# LANGUAGE TemplateHaskell #-}
module ListsInit (check, ListsInit.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Data.Char (isAsciiUpper)
import Data.List (isSuffixOf)
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkListsMisuse,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "lists-scalar-misuse",
        cdDescription = "*Lists should be a true bash array (bash-style-guide §3); use *List (singular) for a serialized string",
        cdPositive = "xLists=foo",
        cdNegative = "xLists=(a b c)"
    }
}

-- | Fires when a *Lists-suffixed variable is assigned something that
-- isn't a true array literal. Restricted to bare (Assign mode, no
-- index) assignments -- see note below.
checkListsMisuse :: Token -> Analysis
checkListsMisuse (T_Assignment id Assign name [] value)
    | hasListsSuffixOnBare name && not (isArray value) =
        warn id 9013 $
            "Variable '" ++ name ++ "' uses *Lists suffix (= true bash "
            ++ "array per bash-style-guide §3) but is initialized as a "
            ++ "scalar. Use array syntax (e.g. " ++ name ++ "=(...)), or "
            ++ "drop the plural-Lists suffix for a serialized string "
            ++ "(e.g. " ++ singularize name ++ ")."
checkListsMisuse _ = return ()

-- Restricting the match to Assign mode with an empty indices list
-- narrows the rule to "bare shape-establishing assignment": a
-- non-array RHS is NOT proof of scalar misuse for `xLists[0]=foo`
-- (indexed element-assignment -- already correctly array-shaped) or
-- `xLists+=foo` (append mode presupposes prior declaration state this
-- check can't see). SC9008's own pattern gets away with ignoring both
-- fields because an array-literal RHS can only appear on a bare
-- Assign-mode, unindexed LHS in valid bash; the inverted direction has
-- no such structural guarantee.

isArray :: Token -> Bool
isArray (T_Array _ _) = True
isArray _             = False

-- | True if the bare name ends in 'Lists' or 'Lists<X>' where X is a
-- single uppercase ASCII library suffix letter. Mirrors
-- Convention.hasListSuffixOnBare's two-branch shape.
-- Examples: commandLists (yes), hostListsQ (yes), listsItems (no).
hasListsSuffixOnBare :: String -> Bool
hasListsSuffixOnBare name =
    "Lists" `isSuffixOf` name
    || (length name >= 6
        && isAsciiUpper (last name)
        && "Lists" `isSuffixOf` init name)

-- Best-effort *List rename suggestion, handling both branches of
-- hasListsSuffixOnBare precisely (the library-suffix case needs the
-- letter re-appended after the stem, not dropped).
singularize :: String -> String
singularize name
    | "Lists" `isSuffixOf` name = take (length name - 5) name ++ "List"
    | otherwise =   -- library-suffix branch; guard already established by the caller
        take (length (init name) - 5) (init name) ++ "List" ++ [last name]

-- Tests: should fire (Lists-suffixed name, value is NOT an array)

prop_sc9013_stringAssign = verifyCode checkListsMisuse 9013 "xLists=foo"
prop_sc9013_emptyString  = verify     checkListsMisuse "xLists="
prop_sc9013_paramExpand  = verify     checkListsMisuse "xLists=$other"
prop_sc9013_cmdsub       = verify     checkListsMisuse "xLists=$(cat /etc/hosts)"
prop_sc9013_quoted       = verify     checkListsMisuse "xLists=\"a b\""
prop_sc9013_libSuffix    = verify     checkListsMisuse "hostListsQ=foo"

-- Tests: should NOT fire (Lists name + array value = correct §3 form)

prop_sc9013_emptyArray    = verifyNot checkListsMisuse "xLists=()"
prop_sc9013_arrayLiteral  = verifyNot checkListsMisuse "xLists=(a b c)"
prop_sc9013_quotedArray   = verifyNot checkListsMisuse "xLists=(\"a\" \"b\")"
prop_sc9013_libSuffixArr  = verifyNot checkListsMisuse "hostListsQ=(a b)"
prop_sc9013_singletonArr  = verifyNot checkListsMisuse "xLists=(only)"

-- Tests: should NOT fire (no suffix match / crosses into SC9008's domain)

prop_sc9013_noSuffix      = verifyNot checkListsMisuse "x=foo"
prop_sc9013_lowercase     = verifyNot checkListsMisuse "xlists=foo"
prop_sc9013_listsInMiddle = verifyNot checkListsMisuse "listsItems=foo"
prop_sc9013_singularList  = verifyNot checkListsMisuse "xList=foo"

-- Tests: should NOT fire (indexed / append -- not shape-establishing)

prop_sc9013_indexed = verifyNot checkListsMisuse "xLists[0]=foo"
prop_sc9013_append   = verifyNot checkListsMisuse "xLists+=foo"

-- Tests: suppression

prop_sc9013_suppressed = verifyNot checkListsMisuse "# shellcheck disable=SC9013\nxLists=foo"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
