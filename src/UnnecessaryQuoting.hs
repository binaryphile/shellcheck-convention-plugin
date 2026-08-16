{-# LANGUAGE TemplateHaskell #-}
module UnnecessaryQuoting (check, UnnecessaryQuoting.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import Convention
import ShellCheck.Interface

-- ask, when re-exported from Base
import Data.Maybe (fromMaybe)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map
import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkUnnecessaryQuoting,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "unnecessary-quoting",
        cdDescription = "Suggest removing quotes from non-_ variables under IFS/noglob",
        cdPositive = "var=hello; echo \"$var\"",
        cdNegative = "var=hello; echo $var"
    }
}

checkUnnecessaryQuoting :: Token -> Analysis
checkUnnecessaryQuoting token = case getExpansionName token of
    Just name | basicWarn name -> do
        params <- ask
        let parents = parentMap params
            shell = shellType params
        -- Discipline gating (#17958): SC9003's advice is only safe in
        -- files that have IFS+noglob discipline at top-level. Files
        -- without discipline get SC9010 instead (per docs/design.md
        -- §SC9003 / §SC9010 partition rule).
        when (not (usedAsCommandName parents token)
              && isInProtectiveQuotes shell parents token
              && fileHasIfsNoglobDiscipline parents token) $
            style (getId token) 9003 $
                "Variable $" ++ name ++ " does not need quoting under IFS/noglob."
    _ -> return ()
  where
    basicWarn name =
        not (hasTaintSuffix name)
        && name `notElem` specialVars
        && not (isArrayExpansion token)
        && not (isCountingReference token)

    specialVars = ["@", "*", "?", "$", "!", "#", "-", "_", "0"]
        ++ map show [1..9 :: Int]

-- | True when the token is inside a T_DoubleQuoted that serves a protective purpose
-- (i.e., removing the DQ would expose contents to word splitting) AND the
-- expansion is the DOUBLE-QUOTED STRING'S ONLY CONTENT (#12026). When the
-- double-quoted string also carries literal text -- "label: $var" -- the
-- quotes are necessary for that literal text (spaces, punctuation), not for
-- $var; "unnecessary quoting" doesn't apply, so SC9003 must not fire there.
-- Skips T_DollarDoubleQuoted ($"...") which is localization, not protective quoting.
isInProtectiveQuotes :: Shell -> Map.Map Id Token -> Token -> Bool
isInProtectiveQuotes shell parents t = fromMaybe False $ do
    dq <- findDQ (NE.tail $ getPath parents t)
    return $ not (isQuoteFree shell parents dq) && isSoleContent dq
  where
    findDQ [] = Nothing
    findDQ (x:xs) = case x of
        T_DoubleQuoted {} -> Just x
        T_DollarDoubleQuoted {} -> Nothing  -- skip $"..."
        T_DollarExpansion {} -> Nothing     -- command-substitution boundary (#141293)
        T_Backticked {} -> Nothing          -- command-substitution boundary (#141293)
        T_ProcSub {} -> Nothing             -- process-substitution boundary (#141293)
        _ -> findDQ xs

    isSoleContent (T_DoubleQuoted _ list) = length list == 1
    isSoleContent _ = False

-- discipline prefix: every prop_ test must establish IFS+noglob
-- discipline at file top now that SC9003 is discipline-gated (#17958),
-- otherwise SC9003 stays silent and the test fixture fires SC9010 instead.
disciplineHdr :: String
disciplineHdr = "IFS=$'\\n'\nset -o noglob\n"

-- Tests: should fire (non-_ var quoted in splitting context, file has discipline)
prop_sc9003_echo = verifyCode checkUnnecessaryQuoting 9003 (disciplineHdr ++ "var=hello; echo \"$var\"")
prop_sc9003_arg = verify checkUnnecessaryQuoting (disciplineHdr ++ "x=1; cmd \"$x\"")

-- Tests: should NOT fire (file has discipline; non-trigger pattern)
-- #12026: literal text alongside the expansion makes the quotes necessary
-- for that text, not for the variable -- "unnecessary quoting" doesn't apply.
prop_sc9003_literalPrefix = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "plain=x; echo \"value: $plain\"")
prop_sc9003_literalPrefixAndSuffix = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "plain=x; echo \"prefix-$plain-suffix\"")
prop_sc9003_tainted = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "var_=x; echo \"$var_\"")
prop_sc9003_unquoted = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "var=hello; echo $var")
prop_sc9003_special_at = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "echo \"$@\"")
prop_sc9003_special_star = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "echo \"$*\"")
prop_sc9003_special_under = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "echo \"$_\"")
prop_sc9003_assignment = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "x=1; y=\"$x\"")
prop_sc9003_cmdname = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "cmd=ls; \"$cmd\"")
prop_sc9003_counting = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "echo \"${#var}\"")
prop_sc9003_array = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "echo \"${arr[@]}\"")
-- Nested: DQ inside ${} is not protective (isQuoteFree True for T_DollarBraced)
prop_sc9003_nested = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "echo ${var:-\"$inner\"}")
-- $"..." is localization, not protective quoting (findDQ skips T_DollarDoubleQuoted)
prop_sc9003_dollarDQ = verifyNot checkUnnecessaryQuoting (disciplineHdr ++ "echo $\"hello $var\"")
-- Tests: discipline-absent case (SC9003 silent regardless of trigger; #17958 gating)
prop_sc9003_silent_no_discipline = verifyNot checkUnnecessaryQuoting "var=hello; echo \"$var\""
prop_sc9003_silent_partial_discipline = verifyNot checkUnnecessaryQuoting "IFS=$'\\n'; var=hello; echo \"$var\""

-- #141293: a bare variable inside an INNER, unquoted command substitution
-- must not inherit protective-quote status from an OUTER double-quoted
-- command substitution wrapping it -- findDQ must stop at the inner
-- cmdsub boundary rather than walking past it to the outer DQ.
prop_sc9003_doublyNestedCmdsub_notFire = verifyNot checkUnnecessaryQuoting
    (disciplineHdr ++ "d9=foo; s9=$(printf '%s' \"$(realpath -m -- $d9)\" | tr '/._' '---')")
-- Single-level, unquoted, no outer DQ at all -- was never buggy, kept as
-- an explicit regression anchor matching the task's own non-reproducing shape.
prop_sc9003_singleNestedCmdsub_unquoted_notFire = verifyNot checkUnnecessaryQuoting
    (disciplineHdr ++ "d9=foo; s9=$(realpath -m -- $d9)")

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
