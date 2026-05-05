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
    ccAlwaysOn = False,
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
        when (not (usedAsCommandName parents token)
              && isInProtectiveQuotes shell parents token) $
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
-- (i.e., removing the DQ would expose contents to word splitting).
-- Skips T_DollarDoubleQuoted ($"...") which is localization, not protective quoting.
isInProtectiveQuotes :: Shell -> Map.Map Id Token -> Token -> Bool
isInProtectiveQuotes shell parents t = fromMaybe False $ do
    dq <- findDQ (NE.tail $ getPath parents t)
    return $ not (isQuoteFree shell parents dq)
  where
    findDQ [] = Nothing
    findDQ (x:xs) = case x of
        T_DoubleQuoted {} -> Just x
        T_DollarDoubleQuoted {} -> Nothing  -- skip $"..."
        _ -> findDQ xs

-- Tests: should fire (non-_ var quoted in splitting context)
prop_sc9003_echo = verifyCode checkUnnecessaryQuoting 9003 "var=hello; echo \"$var\""
prop_sc9003_arg = verify checkUnnecessaryQuoting "x=1; cmd \"$x\""

-- Tests: should NOT fire
prop_sc9003_tainted = verifyNot checkUnnecessaryQuoting "var_=x; echo \"$var_\""
prop_sc9003_unquoted = verifyNot checkUnnecessaryQuoting "var=hello; echo $var"
prop_sc9003_special_at = verifyNot checkUnnecessaryQuoting "echo \"$@\""
prop_sc9003_special_star = verifyNot checkUnnecessaryQuoting "echo \"$*\""
prop_sc9003_special_under = verifyNot checkUnnecessaryQuoting "echo \"$_\""
prop_sc9003_assignment = verifyNot checkUnnecessaryQuoting "x=1; y=\"$x\""
prop_sc9003_cmdname = verifyNot checkUnnecessaryQuoting "cmd=ls; \"$cmd\""
prop_sc9003_counting = verifyNot checkUnnecessaryQuoting "echo \"${#var}\""
prop_sc9003_array = verifyNot checkUnnecessaryQuoting "echo \"${arr[@]}\""
-- Nested: DQ inside ${} is not protective (isQuoteFree True for T_DollarBraced)
prop_sc9003_nested = verifyNot checkUnnecessaryQuoting "echo ${var:-\"$inner\"}"
-- $"..." is localization, not protective quoting (findDQ skips T_DollarDoubleQuoted)
prop_sc9003_dollarDQ = verifyNot checkUnnecessaryQuoting "echo $\"hello $var\""

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
