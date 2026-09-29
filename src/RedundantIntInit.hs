{-# LANGUAGE TemplateHaskell #-}
module RedundantIntInit (check, RedundantIntInit.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Control.Monad (forM_, when)
import Data.Char (isAlphaNum, isDigit)
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf, tails)
import qualified Data.Set as Set

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

-- | SC9015: `local -i NAME=0` immediately followed by an unconditional plain
-- assignment to NAME. A style heuristic that mechanizes bash-style-guide's
-- "Default to a bare local -i x" rule, not a soundness proof -- see
-- docs/design.md SC9015 for the firing condition and its named residuals.
check :: CustomCheck
check = CustomCheck {
    ccChecker = checkRedundantIntInit,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "redundant-int-init",
        cdDescription = "local -i NAME=0 immediately overwritten by a plain assignment",
        cdPositive = "f() { local -i rc=0; rc=$?; echo $rc; }",
        cdNegative = "f() { local -i i=0; while (( i < 3 )); do i+=1; done; }"
    }
}

-- | checkRedundantIntInit analyzes each function body once; script-level
-- declarations are never candidates.
checkRedundantIntInit :: Token -> Analysis
checkRedundantIntInit root = case root of
    T_Script _ _ stmts ->
        let funcNames = Set.fromList (concatMap functionNames (concatMap everything stmts))
        in forM_ (concatMap everything stmts) (checkFunction funcNames)
    _ -> return ()

-- | checkFunction walks every statement list inside one function body,
-- stopping at nested function definitions (they are visited on their own).
checkFunction :: Set.Set String -> Token -> Analysis
checkFunction funcNames (T_Function _ _ _ _ body) =
    forM_ (statementLists body) (checkList funcNames)
checkFunction _ _ = return ()

-- | checkList inspects each adjacent (declaration, next statement) pair.
checkList :: Set.Set String -> [Token] -> Analysis
checkList funcNames stmts =
    forM_ (zip stmts (drop 1 stmts)) $ \(decl, next) ->
        case candidate decl of
            Nothing -> return ()
            Just (assignId, name) ->
                when (isPlainAssignmentTo funcNames name next) $
                    style assignId 9015 (formatMessage name)

-- | candidate reports the NAME=0 assignment token of a single-variable
-- `local|declare|typeset -i` declaration statement. (C)
candidate :: Token -> Maybe (Id, String)
candidate stmt = case simpleCommandOf stmt of
    Just (T_SimpleCommand _ [] (T_NormalWord _ [T_Literal _ cmd] : args))
        | cmd `elem` ["local", "declare", "typeset"]
        , flags <- concat [ f | T_NormalWord _ [T_Literal _ ('-':f@(_:_))] <- args ]
        , 'i' `elem` flags
        , not (any (`elem` flags) "gxrnaApfF")
        , [a] <- [ t | t <- args, not (isFlag t) ]
        , T_Assignment aid Assign name [] value <- a
        , getLiteralString value == Just "0"
        -> Just (aid, name)
    _ -> Nothing
  where
    isFlag (T_NormalWord _ [T_Literal _ ('-':_)]) = True
    isFlag _ = False

-- | isPlainAssignmentTo reports whether @stmt@ is exactly `NAME=value`, with
-- no command words and no redirects, and a value that cannot obviously read
-- NAME: no mention of NAME, not a bare identifier, no literal /0 or %0, no
-- call to a same-file function, no dynamic-code command. (C)
isPlainAssignmentTo :: Set.Set String -> String -> Token -> Bool
isPlainAssignmentTo funcNames name stmt = case simpleCommandOf stmt of
    Just (T_SimpleCommand _ [T_Assignment _ Assign n [] value] []) ->
        n == name
        && not (mentions name value)
        && not (isBareIdentifier value)
        && not (hasLiteralDivZero value)
        && not (any (callsBlocked funcNames) (everything value))
    _ -> False

-- | simpleCommandOf unwraps a statement to its single simple command when it
-- has no pipe, no redirects and no annotation-free wrapper beyond those. (C)
simpleCommandOf :: Token -> Maybe Token
simpleCommandOf t = case t of
    T_Annotation _ _ inner         -> simpleCommandOf inner
    T_Pipeline _ [] [cmd]          -> simpleCommandOf cmd
    T_Redirecting _ [] cmd         -> simpleCommandOf cmd
    c@T_SimpleCommand {}           -> Just c
    _                              -> Nothing

-- | statementLists yields every statement list inside @t@, not descending
-- into nested function definitions. (C)
statementLists :: Token -> [[Token]]
statementLists t@(OuterToken _ inner) = case t of
    T_Function {} -> []
    _ -> own ++ concatMap statementLists (toList inner)
  where
    own = case t of
        T_BraceGroup _ l              -> [l]
        T_Subshell _ l                -> [l]
        T_WhileExpression _ c b       -> [c, b]
        T_UntilExpression _ c b       -> [c, b]
        T_ForIn _ _ _ b               -> [b]
        T_SelectIn _ _ _ b            -> [b]
        T_ForArithmetic _ _ _ _ b     -> [b]
        T_IfExpression _ conds elses  -> concat [ [c, b] | (c, b) <- conds ] ++ [elses]
        T_CaseExpression _ _ arms     -> [ b | (_, _, b) <- arms ]
        _                             -> []

-- | everything flattens @t@ and all its descendants. (C)
everything :: Token -> [Token]
everything t@(OuterToken _ inner) = t : concatMap everything (toList inner)

-- | functionNames yields the name of a function definition token. (C)
functionNames :: Token -> [String]
functionNames (T_Function _ _ _ name _) = [name]
functionNames _ = []

-- | mentions reports whether any read, indirection or literal inside @t@
-- names @name@ as a whole word. (C)
mentions :: String -> Token -> Bool
mentions name t = any hit (everything t)
  where
    hit (T_DollarBraced _ _ inner) =
        let s = concat (oversimplify inner)
        in getBracedReference s == name || "!" `isPrefixOf` s
    hit (TA_Variable _ n _) = n == name
    hit (T_Literal _ s) = wholeWord name s
    hit (T_SingleQuoted _ s) = wholeWord name s
    hit _ = False

-- | wholeWord reports whether @w@ occurs in @s@ bounded by non-identifier
-- characters. (C)
wholeWord :: String -> String -> Bool
wholeWord w s = any bounded (zip (Nothing : map Just s) (tails s))
  where
    identChar c = isAlphaNum c || c == '_'
    bounded (before, rest) =
        w `isPrefixOf` rest
        && maybe True (not . identChar) before
        && case drop (length w) rest of
               (c:_) -> not (identChar c)
               []    -> True

-- | isBareIdentifier reports whether the value is a lone identifier word,
-- which an integer assignment would evaluate as a variable reference. (C)
isBareIdentifier :: Token -> Bool
isBareIdentifier v = case getLiteralString v of
    Just s@(c:_) -> not (isDigit c) && all (\ch -> isAlphaNum ch || ch == '_') s
    _            -> False

-- | hasLiteralDivZero reports a literal `/0` or `%0` in the value. (C)
hasLiteralDivZero :: Token -> Bool
hasLiteralDivZero v = any hit (everything v)
  where
    hit (T_Literal _ s)       = any (`isInfixOf` s) ["/0", "%0"]
    hit (TA_Binary _ op _ r)  = op `elem` ["/", "%"] && getLiteralString r == Just "0"
    hit _                     = False

-- | callsBlocked reports a simple command whose name is a same-file function
-- or a dynamic-code builtin that can read the caller's locals. (C)
callsBlocked :: Set.Set String -> Token -> Bool
callsBlocked funcNames (T_SimpleCommand _ _ (w : _)) = case getLiteralString w of
    Just c  -> c `Set.member` funcNames
               || c `elem` ["eval", "source", ".", "trap", "declare", "typeset", "local", "export"]
    Nothing -> True
callsBlocked _ _ = False

formatMessage :: String -> String
formatMessage name =
    "'" ++ name ++ "' is assigned by the very next statement, so the =0 is redundant " ++
    "if nothing reads " ++ name ++ " in between (bash-style-guide: default to a bare " ++
    "local -i " ++ name ++ "; keep =0 only when the variable is read first, e.g. a loop counter)."

-- Documentation mirrors of the executed fixture cases (the flake does not run
-- props; test/positive and test/negative under bin/verify are the coverage).
prop_sc9015_rcAfter        = verifyCode checkRedundantIntInit 9015 "f() { local -i rc=0; rc=$?; echo $rc; }"
prop_sc9015_cmdsub         = verify     checkRedundantIntInit "f() { local -i n=0; n=$(wc -l </dev/null); echo $n; }"
prop_sc9015_readFirst      = verifyNot  checkRedundantIntInit "f() { local -i i=0; while (( i < 3 )); do i+=1; done; }"
prop_sc9015_conditional    = verifyNot  checkRedundantIntInit "f() { local -i n=0; [[ $1 ]] && n=5; echo $n; }"
prop_sc9015_callBetween    = verifyNot  checkRedundantIntInit "g() { echo $x; }; f() { local -i x=0; g; x=1; }"
prop_sc9015_selfRef        = verifyNot  checkRedundantIntInit "f() { local -i c=0; c=$(( c + 1 )); echo $c; }"
prop_sc9015_nonZero        = verifyNot  checkRedundantIntInit "f() { local -i x=1; x=2; echo $x; }"
prop_sc9015_scriptLevel    = verifyNot  checkRedundantIntInit "declare -i x=0; x=5; echo $x"
prop_sc9015_multiVar       = verifyNot  checkRedundantIntInit "f() { local -i x=0 y=x; x=5; echo $x $y; }"
prop_sc9015_evalValue      = verifyNot  checkRedundantIntInit "f() { local -i x=0; x=$(eval \"$c\"); echo $x; }"
prop_sc9015_suppressed     = verifyNot  checkRedundantIntInit "f() {\n# shellcheck disable=SC9015\nlocal -i rc=0; rc=$?; echo $rc; }"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
