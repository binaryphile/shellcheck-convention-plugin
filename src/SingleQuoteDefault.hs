{-# LANGUAGE TemplateHaskell #-}
module SingleQuoteDefault (check, SingleQuoteDefault.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib (getLiteralString)
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkSingleQuoteDefault,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "single-quote-default",
        cdDescription = "Double-quoted string literal with no expansion and no embedded single quote should be single-quoted",
        cdPositive = "echo \"hello\"",
        cdNegative = "echo 'hello'"
    }
}

-- | Fires when an entire word is a double-quoted string (bash-style-
-- guide "Single vs Double Quotes": single quotes are the default;
-- double is only warranted when the value needs parameter/command/
-- arithmetic expansion, OR contains a literal single quote that would
-- otherwise need escaping). `getLiteralString` returning `Just` on the
-- whole `T_DoubleQuoted` node is exactly "no expansion anywhere inside"
-- (it returns `Nothing` the moment any part is an expansion), so no
-- separate expansion-child-node walk is needed. Scoped to the
-- double-quoted string being the word's SOLE content (mirrors SC9003's
-- `isSoleContent` convention) -- a composite word mixing quoted and
-- expanded segments (`"prefix"$var`) isn't a clean single-quote
-- conversion candidate as a whole, so it's left alone.
checkSingleQuoteDefault :: Token -> Analysis
checkSingleQuoteDefault t = case t of
    T_NormalWord _ [dq@(T_DoubleQuoted _ _)]
        | Just lit <- getLiteralString dq
        , '\'' `notElem` lit
        -> warn (getId dq) 9012 (formatMessage lit)
    _ -> return ()

-- | `lit` is guaranteed (by checkSingleQuoteDefault's own guard) to
-- contain no single-quote character, so wrapping it in single quotes
-- for display is always safe -- unlike double quotes, which `lit`
-- itself may already contain unescaped (e.g. `say "hi"`), producing a
-- confusing nested-double-quote message.
formatMessage :: String -> String
formatMessage lit =
    "Double-quoted string '" ++ lit ++ "' has no expansion and no " ++
    "embedded single quote -- per bash-style-guide's \"Single vs Double " ++
    "Quotes\", single quotes are the default for string literals. Use '" ++
    lit ++ "' instead."

-- A. Positive -- pure literal, no expansion, no embedded single quote.
prop_sc9012_plain          = verifyCode checkSingleQuoteDefault 9012 "echo \"hello\""
prop_sc9012_assignmentRhs  = verifyCode checkSingleQuoteDefault 9012 "x=\"hello\""
prop_sc9012_spaces         = verifyCode checkSingleQuoteDefault 9012 "echo \"hello world\""
prop_sc9012_empty          = verifyCode checkSingleQuoteDefault 9012 "echo \"\""
prop_sc9012_escapedDquote  = verifyCode checkSingleQuoteDefault 9012 "echo \"say \\\"hi\\\"\""

-- B. Negative -- embedded single quote is the documented escape hatch.
prop_sc9012_embeddedSquote = verifyNot checkSingleQuoteDefault "echo \"it's\""
prop_sc9012_nestedQuoteWord = verifyNot checkSingleQuoteDefault "echo \"nested 'quote' here\""

-- C. Negative -- expansion present (parameter/command/arithmetic).
prop_sc9012_paramExpansion  = verifyNot checkSingleQuoteDefault "var=x; echo \"$var\""
prop_sc9012_cmdExpansion    = verifyNot checkSingleQuoteDefault "echo \"$(date)\""
prop_sc9012_arithExpansion  = verifyNot checkSingleQuoteDefault "echo \"$((1+1))\""
prop_sc9012_mixedLiteral    = verifyNot checkSingleQuoteDefault "var=x; echo \"value: $var\""

-- D. Negative -- already single-quoted, or unquoted.
prop_sc9012_alreadySingle   = verifyNot checkSingleQuoteDefault "echo 'hello'"
prop_sc9012_unquoted        = verifyNot checkSingleQuoteDefault "echo hello"

-- E. Negative -- localization form ($"...") is a different construct.
prop_sc9012_dollarDoubleQuoted = verifyNot checkSingleQuoteDefault "echo $\"hello\""

-- F. Negative -- composite word (quoted segment + expansion) is not
-- scoped as a whole-word single-quote candidate.
prop_sc9012_compositeWord   = verifyNot checkSingleQuoteDefault "var=x; echo \"prefix\"$var"

-- G. Suppression.
prop_sc9012_suppressed      = verifyNot checkSingleQuoteDefault "# shellcheck disable=SC9012\necho \"hello\""

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
