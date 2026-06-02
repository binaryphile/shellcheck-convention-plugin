{-# LANGUAGE TemplateHaskell #-}
module IfsNoglobDiscipline (check, IfsNoglobDiscipline.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import Convention
import ShellCheck.Interface

import Data.Maybe (fromMaybe)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

-- SC9010 — IFS+noglob discipline absent (#17958).
-- Fires per-occurrence at every would-be-SC9003 trigger (a quoted
-- non-tainted non-special variable expansion) in files whose
-- `fileHasIfsNoglobDiscipline` predicate returns False. SC9003 fires
-- on the same trigger family but in files that DO satisfy the
-- predicate. The two checks partition the trigger space.
--
-- See docs/design.md §SC9010 for the predicate definition and rationale.
check :: CustomCheck
check = CustomCheck {
    ccChecker = checkIfsNoglobDiscipline,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "ifs-noglob-discipline",
        cdDescription = "Suggest adopting IFS=$'\\n' + set -o noglob when the file quotes non-tainted variables",
        cdPositive = "plain=hello; echo \"$plain\"",
        cdNegative = "IFS=$'\\n'; set -o noglob; plain=hello; echo \"$plain\""
    }
}

checkIfsNoglobDiscipline :: Token -> Analysis
checkIfsNoglobDiscipline token = case getExpansionName token of
    Just name | basicWarn name -> do
        params <- ask
        let parents = parentMap params
            shell = shellType params
        when (not (usedAsCommandName parents token)
              && isInProtectiveQuotes shell parents token
              && not (fileHasIfsNoglobDiscipline parents token)) $
            style (getId token) 9010 $
                "Quoted non-tainted variable expansion in a file without "
                ++ "IFS+noglob discipline; add `IFS=$'\\n'` and `set -o noglob` "
                ++ "at file top to satisfy the discipline (then SC9003 will "
                ++ "guide quote-removal)."
    _ -> return ()
  where
    basicWarn name =
        not (hasTaintSuffix name)
        && name `notElem` specialVars
        && not (isArrayExpansion token)
        && not (isCountingReference token)

    specialVars = ["@", "*", "?", "$", "!", "#", "-", "_", "0"]
        ++ map show [1..9 :: Int]

-- | True when the token is inside a T_DoubleQuoted that serves a
-- protective purpose (i.e., removing the DQ would expose contents to
-- word splitting). Mirrors UnnecessaryQuoting's helper.
isInProtectiveQuotes :: Shell -> Map.Map Id Token -> Token -> Bool
isInProtectiveQuotes shell parents t = fromMaybe False $ do
    dq <- findDQ (NE.tail $ getPath parents t)
    return $ not (isQuoteFree shell parents dq)
  where
    findDQ [] = Nothing
    findDQ (x:xs) = case x of
        T_DoubleQuoted {} -> Just x
        T_DollarDoubleQuoted {} -> Nothing
        _ -> findDQ xs

-- Tests: should fire (would-be-SC9003 trigger in a file without discipline)
prop_sc9010_fires_no_discipline = verifyCode checkIfsNoglobDiscipline 9010 "var=hello; echo \"$var\""
prop_sc9010_fires_partial_discipline_ifs_only = verifyCode checkIfsNoglobDiscipline 9010 "IFS=$'\\n'; var=hello; echo \"$var\""
prop_sc9010_fires_partial_discipline_noglob_only = verifyCode checkIfsNoglobDiscipline 9010 "set -o noglob; var=hello; echo \"$var\""
prop_sc9010_fires_ifs_multichar = verifyCode checkIfsNoglobDiscipline 9010 "IFS=$'\\n\\t'; set -o noglob; var=hello; echo \"$var\""
prop_sc9010_fires_ifs_reassigned = verifyCode checkIfsNoglobDiscipline 9010 "IFS=$'\\n'; IFS=:; set -o noglob; var=hello; echo \"$var\""
prop_sc9010_fires_noglob_toggled_off = verifyCode checkIfsNoglobDiscipline 9010 "IFS=$'\\n'; set -o noglob; set +o noglob; var=hello; echo \"$var\""

-- Tests: should NOT fire (file has discipline, OR token isn't a candidate)
prop_sc9010_silent_with_discipline = verifyNot checkIfsNoglobDiscipline "IFS=$'\\n'\nset -o noglob\nvar=hello\necho \"$var\""
prop_sc9010_silent_noglob_re_toggled_on = verifyNot checkIfsNoglobDiscipline "IFS=$'\\n'\nset -o noglob\nset +o noglob\nset -o noglob\nvar=hello\necho \"$var\""
prop_sc9010_silent_tainted = verifyNot checkIfsNoglobDiscipline "var_=hello; echo \"$var_\""
prop_sc9010_silent_unquoted = verifyNot checkIfsNoglobDiscipline "var=hello; echo $var"
prop_sc9010_silent_special_at = verifyNot checkIfsNoglobDiscipline "echo \"$@\""

return []
runTests = $forAllProperties (quickCheckWithResult (stdArgs {maxSuccess = 1}))
