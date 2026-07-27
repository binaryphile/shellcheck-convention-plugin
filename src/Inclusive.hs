{-# LANGUAGE TemplateHaskell #-}
module Inclusive (check, Inclusive.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Data.Char (isLower, isUpper, toLower, toUpper)
import Data.List (isInfixOf)
import qualified Data.Map as Map
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkInclusiveLanguage,
    ccAlwaysOn = True,
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
checkInclusiveLanguage (T_Comment id str)           = checkText id str
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

-- | Comment-scope SC9006 (#75070 autofix pilot). Rewrites BOTH terms in
-- one pass when the comment is autofix-eligible (R1 absorption item 4);
-- otherwise falls back to the plain `warn` (no Fix attached), matching
-- Formatter/Diff.hs's own "detected but not auto-fixable" fallback. See
-- `rewriteTerms` for the eligibility rule.
checkText :: Id -> String -> Analysis
checkText id str = case termMsg of
    Nothing -> return ()
    Just msg -> do
        params <- ask
        case (rewriteTerms str, Map.lookup id (tokenPositions params)) of
            (Just rewritten, Just (startPos, endPos)) ->
                warnWithFix id 9006 msg (newFix { fixReplacements = [
                    newReplacement {
                        repStartPos = startPos,
                        repEndPos = endPos,
                        repString = rewritten
                    }
                ]})
            _ -> warn id 9006 msg
  where
    lc = map toLower str
    hasWhite = "whitelist" `isInfixOf` lc
    hasBlack = "blacklist" `isInfixOf` lc
    termMsg
        | hasWhite && hasBlack =
            Just "Comment contains 'whitelist'/'blacklist'; prefer 'allowlist'/'denylist'."
        | hasWhite  = Just "Comment contains 'whitelist'; prefer 'allowlist'."
        | hasBlack  = Just "Comment contains 'blacklist'; prefer 'denylist'."
        | otherwise = Nothing

-- | Case-preserving substring replacer for comment text (R1 absorption
-- items 4/5/6, R2 item 12). Scans case-insensitively for every occurrence
-- of "whitelist"/"blacklist" and rewrites ALL of them in one pass (item
-- 4 -- a comment mentioning both terms must get both fixed, not just
-- whichever guard fired first). Returns Nothing (no Fix; falls back to
-- plain warn) when:
--
--   * the comment has no whitelist/blacklist occurrence at all, OR
--   * ANY occurrence's case doesn't fall into one of the 3 supported
--     classes -- ALLCAPS, Capitalized, lowercase (item 5 -- silently
--     normalizing an unsupported casing like "WhiteList" or "wHiTeLiSt"
--     would be a silent content change, not a safe rewrite), OR
--   * the comment contains the case-insensitive substring "shellcheck"
--     anywhere (R2 item 12, broadened from the original space-suffixed
--     "shellcheck " guard -- catches tab-separated or punctuation-adjacent
--     directive-looking text too; maximally conservative).
rewriteTerms :: String -> Maybe String
rewriteTerms str
    | "shellcheck" `isInfixOf` map toLower str = Nothing
    | not hasTerm = Nothing
    | otherwise = go str
  where
    lc = map toLower str
    hasTerm = "whitelist" `isInfixOf` lc || "blacklist" `isInfixOf` lc

    go [] = Just ""
    go s@(c:cs) =
        case tryMatch "whitelist" s of
            Just (matched, rest) -> rewriteOne matched "allowlist" rest
            Nothing -> case tryMatch "blacklist" s of
                Just (matched, rest) -> rewriteOne matched "denylist" rest
                Nothing -> (c:) <$> go cs
      where
        rewriteOne matched repl rest = do
            tc <- classifyCase matched
            restRewritten <- go rest
            return (applyCase tc repl ++ restRewritten)

    -- Matches term (already lowercase) case-insensitively at the head of
    -- s; returns the matched (as-written) substring and the remainder.
    tryMatch term s
        | length candidate == n && map toLower candidate == term = Just (candidate, drop n s)
        | otherwise = Nothing
      where
        n = length term
        candidate = take n s

data TermCase = AllCaps | Capitalized | LowerCase

-- | Classifies a matched term's as-written casing into one of the 3
-- supported classes, or Nothing if it doesn't cleanly fit any of them.
classifyCase :: String -> Maybe TermCase
classifyCase s
    | all isUpper s = Just AllCaps
    | (x:xs) <- s, isUpper x && all isLower xs = Just Capitalized
    | all isLower s = Just LowerCase
    | otherwise = Nothing

applyCase :: TermCase -> String -> String
applyCase AllCaps s = map toUpper s
applyCase Capitalized (c:cs) = toUpper c : cs
applyCase Capitalized []     = []
applyCase LowerCase s = map toLower s

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

-- Tests: comment-text scope (SC9006-comments, #7739)
prop_sc9006_commentWhite = verifyCode checkInclusiveLanguage 9006 "# avoid whitelist\necho ok"
prop_sc9006_commentBlack = verify     checkInclusiveLanguage "# the blacklist must go\necho ok"
prop_sc9006_commentCase  = verify     checkInclusiveLanguage "# WHITELIST is bad\necho ok"
prop_sc9006_commentClean = verifyNot  checkInclusiveLanguage "# use allowlist not the old term\necho ok"
prop_sc9006_directiveOK  = verifyNot  checkInclusiveLanguage "# shellcheck disable=SC9999\necho ok"

-- Tests: suppression
prop_sc9006_suppressed   = verifyNot checkInclusiveLanguage "# shellcheck disable=SC9006\nwhitelist=foo"
prop_sc9006_suppCmnt     = verifyNot checkInclusiveLanguage "# shellcheck disable=SC9006\n# whitelist warning here\necho ok"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
