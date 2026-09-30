{-# LANGUAGE TemplateHaskell #-}
module BlankSubstitution (check, BlankSubstitution.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Control.Monad (forM_)
import Data.Char (isAlpha, isAlphaNum)
import Data.Foldable (toList)

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

-- | SC9016: `[[ -z/-n ${NAME//[CLASS]/} ]]` tests "all CLASS characters" by
-- deleting them; a glob says it directly. See docs/design.md SC9016 for the
-- firing condition and why negated classes and `[ ]` tests are excluded.
check :: CustomCheck
check = CustomCheck {
    ccChecker = checkBlankSubstitution,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "blank-substitution",
        cdDescription = "blank test via ${var//[class]/}; use a glob instead",
        cdPositive = "[[ -z ${s//[[:space:]]/} ]]",
        cdNegative = "[[ $s != *[![:space:]]* ]]"
    }
}

-- | checkBlankSubstitution visits every `[[ ]]` unary test in the script.
checkBlankSubstitution :: Token -> Analysis
checkBlankSubstitution root = forM_ (everything root) $ \t -> case t of
    TC_Unary tid DoubleBracket op word
        | op `elem` ["-z", "-n"]
        , Just inner <- soleBraced word
        , Just (name, cls) <- parseBlankSub inner
        -> style tid 9016 (formatMessage op name cls)
    _ -> return ()

-- | soleBraced yields the text of a word that is exactly one `${...}`,
-- optionally inside one pair of double quotes. (C)
soleBraced :: Token -> Maybe String
soleBraced w = case w of
    T_NormalWord _ [T_DollarBraced _ True inner]                  -> Just (text inner)
    T_NormalWord _ [T_DoubleQuoted _ [T_DollarBraced _ True inner]] -> Just (text inner)
    _                                                            -> Nothing
  where text = concat . oversimplify

-- | parseBlankSub splits `NAME//[CLASS]/` or `NAME//[CLASS]` into NAME and
-- CLASS (the bracket's contents), refusing negated classes. (C)
parseBlankSub :: String -> Maybe (String, String)
parseBlankSub s = do
    let (name, rest) = span (\c -> isAlphaNum c || c == '_') s
    (c:_) <- Just name
    if isAlpha c || c == '_' then Just () else Nothing
    ('/':'/':'[':body) <- Just rest
    (first:_) <- Just body
    if first `elem` "!^" then Nothing else Just ()
    (cls, after) <- bracketBody body
    if after `elem` ["", "/"] && not (any (`elem` "\"'\\$`") cls)
        then Just (name, cls) else Nothing

-- | bracketBody consumes a bracket expression's contents up to its closing
-- `]`: a leading `]` is literal and `[:class:]` is consumed whole. (C)
bracketBody :: String -> Maybe (String, String)
bracketBody body = case body of
    (']':more) -> prepend ']' (go more)
    _          -> go body
  where
    go str = case str of
        (']':after)       -> Just ("", after)
        ('[':':':more)    -> do
            (cls, after) <- posixClass more
            prependAll ("[:" ++ cls ++ ":]") (go after)
        (c:more)          -> prepend c (go more)
        []                -> Nothing
    posixClass str = case break (== ':') str of
        (cls, ':':']':after) | all isAlpha cls -> Just (cls, after)
        _                                     -> Nothing
    prepend c = fmap (\(a, b) -> (c : a, b))
    prependAll p = fmap (\(a, b) -> (p ++ a, b))

-- | everything flattens @t@ and all its descendants. (C)
everything :: Token -> [Token]
everything t@(OuterToken _ inner) = t : concatMap everything (toList inner)

formatMessage :: String -> String -> String -> String
formatMessage op name cls =
    "Test the characters directly: [[ $" ++ name ++ glob ++ " ]] is equivalent " ++
    "and does not copy the string (bash-style-guide Risks item 10)."
  where glob = (if op == "-z" then " != " else " == ") ++ "*[!" ++ cls ++ "]*"

-- Documentation mirrors of the executed fixture cases (the flake does not run
-- props; test/positive and test/negative under bin/verify are the coverage).
prop_sc9016_z          = verifyCode checkBlankSubstitution 9016 "[[ -z ${s//[[:space:]]/} ]]"
prop_sc9016_nQuoted    = verifyCode checkBlankSubstitution 9016 "[[ -n \"${s//[[:blank:]]}\" ]]"
prop_sc9016_negated    = verifyNot  checkBlankSubstitution "[[ -z ${s//[!a]/} ]]"
prop_sc9016_single     = verifyNot  checkBlankSubstitution "[ -n \"${s//[[:space:]]/}\" ]"
prop_sc9016_replace    = verifyNot  checkBlankSubstitution "[[ -z ${s//[[:space:]]/_} ]]"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
