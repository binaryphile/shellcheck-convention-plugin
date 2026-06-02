{-# LANGUAGE TemplateHaskell #-}
module Docstring (check, Docstring.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Data.Maybe (listToMaybe)
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkDocstring,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "docstring-shape",
        cdDescription = "Docstring above a function should begin with the function name",
        cdPositive = "# Helper that frobs\nfoo() { :; }",
        cdNegative = "# foo frobs the input\nfoo() { :; }"
    }
}

checkDocstring :: Token -> Analysis
checkDocstring t@(T_Function id _ _ name _) = do
    params <- ask
    case firstWordOfDocs (getDocCommentsBefore params t) of
        Just w | w /= name ->
            style id 9007 $
                "Docstring should begin with the function name '" ++
                name ++ "', not '" ++ w ++ "'."
        _ -> return ()
checkDocstring _ = return ()

-- | First whitespace-separated word found after stripping leading '#' and
--   inline whitespace, scanning lines in source order until a non-empty
--   line yields a word. Empty doc-comment block → Nothing.
firstWordOfDocs :: [String] -> Maybe String
firstWordOfDocs = listToMaybe . concatMap (take 1 . words . strip)
  where
    strip = dropWhile (\c -> c == '#' || c == ' ' || c == '\t')

-- Tests: should fire (first word mismatches function name)
prop_sc9007_helperPrefix    = verifyCode checkDocstring 9007 "# Helper that frobs\nfoo() { :; }"
prop_sc9007_returnsPrefix   = verify     checkDocstring "# Returns the count\ncount() { echo 1; }"
prop_sc9007_articleLead     = verify     checkDocstring "# The widget that ...\nwidget() { :; }"
prop_sc9007_multiLineBad    = verify     checkDocstring "# Misnamed\n# Actually does foo\nfoo() { :; }"

-- Tests: should NOT fire
prop_sc9007_nameMatch       = verifyNot  checkDocstring "# foo frobs the input\nfoo() { :; }"
prop_sc9007_multiLineGood   = verifyNot  checkDocstring "# foo does this\n# and that\nfoo() { :; }"
prop_sc9007_noDocstring     = verifyNot  checkDocstring "foo() { :; }"
prop_sc9007_blankFirstLine  = verifyNot  checkDocstring "#\n# foo does the thing\nfoo() { :; }"
prop_sc9007_underscoreName  = verifyNot  checkDocstring "# _helper frobs\n_helper() { :; }"
prop_sc9007_blankGapBreaks  = verifyNot  checkDocstring "# Helper\n\n# foo does it\nfoo() { :; }"
prop_sc9007_functionKw      = verifyNot  checkDocstring "# myFunc does X\nfunction myFunc { :; }"

-- Tests: suppression via shellcheck disable= still works
prop_sc9007_suppressed      = verifyNot  checkDocstring "# shellcheck disable=SC9007\n# Helper\nfoo() { :; }"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
