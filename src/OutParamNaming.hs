{-# LANGUAGE TemplateHaskell #-}
module OutParamNaming (check, OutParamNaming.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib (getBracedReference, getPath, oversimplify)
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Control.Monad (forM_)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (toList)
import Data.List (isPrefixOf)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map
import qualified Data.Set as Set

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkOutParamNaming,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "outparam-naming",
        cdDescription = "Cross-scope out-param call-site argument should be UPPER_CASE",
        cdPositive = "foo() { local -n REF=$1; REF=x; }\nfoo lower",
        cdNegative = "foo() { local -n REF=$1; REF=x; }\nfoo UPPER"
    }
}

-- | Which write mechanism established a position as an out-param.
data Mechanism = PrintfV | Eval | Nameref deriving (Eq, Ord, Show)

-- | A single top-level definition's inferred shape, prior to reconciling
-- against any other same-name top-level definition.
data DefShape = ShiftTouched | NoWrite | HasWrite (Map.Map Int (Set.Set Mechanism))

-- | Per-name resolution after reconciling all of a name's top-level
-- definitions (§"redefinition rule" in the plan).
data Resolution = Ambiguous | Positions (Map.Map Int (Set.Set Mechanism))

checkOutParamNaming :: Token -> Analysis
checkOutParamNaming t = case t of
    T_Script {} -> wholeScriptAnalysis t
    _           -> return ()

-- | Boundary tokens: a write or definition reachable ONLY through one of
-- these does not persist into the enclosing/caller scope. Extends
-- NilAvoidance.collectScope's boundary set with a REAL (length > 1)
-- T_Pipeline (`lastpipe` makes even the last element's persistence a
-- runtime `shopt` setting, not statically knowable) and T_Backgrounded.
--
-- Empirically verified (bash -c parse dump, task #26606 3a): ShellCheck's
-- parser wraps EVERY statement in a T_Pipeline node, even a lone command
-- with no actual pipe (`Inner_T_Pipeline [] [cmd]` -- empty separator
-- list, singleton command list). Treating ANY T_Pipeline as a boundary
-- (the R2/R3-absorbed design's original wording) would make every
-- statement in the script pipeline-excluded, including a function's own
-- top-level body statements and the function definition itself -- this
-- would have been a near-total false-negative regression. Only a T_Pipeline
-- with 2+ commands is a REAL pipe chain and counts as a boundary.
isBoundaryToken :: Token -> Bool
isBoundaryToken t = case t of
    T_Function {}        -> True
    T_Subshell {}        -> True
    T_DollarExpansion {} -> True
    T_ProcSub {}         -> True
    T_Backticked {}      -> True
    T_CoProc {}          -> True
    T_CoProcBody {}      -> True
    T_Pipeline _ _ cmds  -> length cmds > 1
    T_Backgrounded {}    -> True
    _                    -> False

-- | Flatten a subtree to a list of tokens, stopping (not descending past)
-- any boundary token. Mirrors NilAvoidance.collectScope's shape.
collectScope :: Token -> [Token]
collectScope t@(OuterToken _ inner)
    | isBoundaryToken t = [t]
    | otherwise         = t : concatMap collectScope (toList inner)

-- | Every T_Function anywhere in the tree, regardless of nesting --
-- candidates for the top-level-eligibility filter below.
collectAllFunctions :: Token -> [Token]
collectAllFunctions t@(OuterToken _ inner) = case t of
    T_Function {} -> t : rest
    _             -> rest
  where
    rest = concatMap collectAllFunctions (toList inner)

-- | Every T_SimpleCommand anywhere in the tree (call sites can occur in
-- any context -- reading a caller's literal argument carries no
-- persistence concern, unlike the write/definition side above).
collectAllCommands :: Token -> [Token]
collectAllCommands t@(OuterToken _ inner) = case t of
    T_SimpleCommand {} -> t : rest
    _                  -> rest
  where
    rest = concatMap collectAllCommands (toList inner)

-- | A T_Function is index-eligible only if none of its STRICT ancestors
-- (excluding itself) up to T_Script is a boundary token.
isTopLevelEligible :: Map.Map Id Token -> Token -> Bool
isTopLevelEligible tree f = not (any isBoundaryToken (NE.tail (getPath tree f)))

functionName :: Token -> String
functionName (T_Function _ _ _ name _) = name
functionName _                         = ""

functionBody :: Token -> Token
functionBody (T_Function _ _ _ _ body) = body
functionBody t                         = t

-- | Positional-reference extraction: bare `$N`/`${N}`, or a single level
-- of double-quote wrapping one (`"$1"`). Returns Nothing for a named
-- variable or anything else.
positionalRefOf :: Token -> Maybe Int
positionalRefOf (T_DollarBraced _ _ inner) =
    case reads (getBracedReference (concat (oversimplify inner))) of
        [(n, "")] -> Just n
        _         -> Nothing
positionalRefOf (T_DoubleQuoted _ [inner]) = positionalRefOf inner
positionalRefOf _ = Nothing

-- | Literal text of a token restricted to pure literal shapes (no
-- expansions) -- used for the `=...` remainder after eval's positional
-- reference, across bare/single/double-quoted word-parts.
literalTextOf :: Token -> Maybe String
literalTextOf (T_Literal _ s)      = Just s
literalTextOf (T_SingleQuoted _ s) = Just s
literalTextOf (T_DoubleQuoted _ ps) = concat <$> mapM literalTextOf ps
literalTextOf _                    = Nothing

literalTextOfParts :: [Token] -> Maybe String
literalTextOfParts = fmap concat . mapM literalTextOf

-- | `printf -v "$N"` (or `printf -v NAME` where NAME is itself a
-- positional reference token, not a literal name -- the literal-name
-- case is SC9009's concern, not this check's).
findPrintfVPositional :: [Token] -> Maybe Int
findPrintfVPositional (T_NormalWord _ [T_Literal _ "-v"] : v : _) = positionalRefOfWord v
findPrintfVPositional (_ : rest)                                  = findPrintfVPositional rest
findPrintfVPositional []                                          = Nothing

positionalRefOfWord :: Token -> Maybe Int
positionalRefOfWord (T_NormalWord _ [w]) = positionalRefOf w
positionalRefOfWord _                    = Nothing

-- | `eval`'s single argument: the first word-part (possibly the sole
-- member of an outer double-quote wrapping the whole argument) must be a
-- positional reference, immediately followed by a literal segment
-- beginning with `=`, with no intervening expansion.
evalOutParamPosition :: [Token] -> Maybe Int
evalOutParamPosition [T_NormalWord _ [T_DoubleQuoted _ innerParts]] =
    evalParts innerParts
evalOutParamPosition [T_NormalWord _ parts] = evalParts parts
evalOutParamPosition _ = Nothing

evalParts :: [Token] -> Maybe Int
evalParts (first : rest) = do
    n <- positionalRefOf first
    remainder <- literalTextOfParts rest
    if "=" `isPrefixOf` remainder then Just n else Nothing
evalParts [] = Nothing

-- | `local`/`declare`/`typeset -n NAME=$N` -- NAME=$N parses as a
-- T_Assignment directly in the arg list (Convention.hs/SentinelLiteral.hs
-- precedent); the RHS positional ref is what we want, NAME's own
-- (callee-chosen) case is a different, already-handled concern.
findNamerefPositional :: [Token] -> Maybe Int
findNamerefPositional (T_Assignment _ Assign _ _ value : _) = positionalRefOfWord value
findNamerefPositional (_ : rest)                             = findNamerefPositional rest
findNamerefPositional []                                     = Nothing

hasFlagChar :: Char -> [Token] -> Bool
hasFlagChar c = any go
  where
    go (T_NormalWord _ [T_Literal _ ('-':cs@(_:_))]) = c `elem` cs
    go _ = False

hasLiteralShift :: [Token] -> Bool
hasLiteralShift scopeToks = any isShift scopeToks
  where
    isShift (T_SimpleCommand _ _ (T_NormalWord _ [T_Literal _ "shift"] : _)) = True
    isShift _ = False

-- | Infer a single top-level function definition's shape from its
-- scope-respecting body tokens.
defShapeOf :: [Token] -> DefShape
defShapeOf scopeToks
    | hasLiteralShift scopeToks = ShiftTouched
    | Map.null merged           = NoWrite
    | otherwise                 = HasWrite merged
  where
    merged = Map.unionsWith Set.union (concatMap oneCmd scopeToks)
    oneCmd :: Token -> [Map.Map Int (Set.Set Mechanism)]
    oneCmd (T_SimpleCommand _ _ (T_NormalWord _ (T_Literal _ cmd : _) : args))
        | cmd == "printf"
        , Just n <- findPrintfVPositional args
        = [Map.singleton n (Set.singleton PrintfV)]
        | cmd == "eval"
        , Just n <- evalOutParamPosition args
        = [Map.singleton n (Set.singleton Eval)]
        | cmd `elem` ["local", "declare", "typeset"]
        , hasFlagChar 'n' args
        , Just n <- findNamerefPositional args
        = [Map.singleton n (Set.singleton Nameref)]
    oneCmd _ = []

-- | Reconcile a name's list of top-level definition shapes per the
-- redefinition rule: any shift-touched definition makes the whole name
-- Ambiguous; otherwise all definitions must agree on the exact set of
-- out-param POSITIONS (mechanisms may differ per position across
-- definitions -- that's fine, not a collision -- R3 `/grade` fix).
resolveName :: [DefShape] -> Resolution
resolveName shapes
    | any isShiftTouched shapes = Ambiguous
    | allSameKeySet              = Positions (Map.unionsWith Set.union [ m | HasWrite m <- shapes ])
    | otherwise                  = Ambiguous
  where
    isShiftTouched ShiftTouched = True
    isShiftTouched _            = False
    keySetOf NoWrite       = Set.empty
    keySetOf (HasWrite m)  = Map.keysSet m
    keySetOf ShiftTouched  = Set.empty
    keySets = map keySetOf shapes
    allSameKeySet = case keySets of
        []     -> True
        (k:ks) -> all (== k) ks

-- | Accept a checkable literal identifier at a call-site argument: bare
-- `T_Literal`, or a double-quoted literal with no expansion (R1 finding
-- #3 -- SC9012/SentinelLiteral already recognize this shape).
literalIdentifierArg :: Token -> Maybe (Id, String)
literalIdentifierArg w@(T_NormalWord _ [T_Literal _ n])                    = Just (getId w, n)
literalIdentifierArg w@(T_NormalWord _ [T_DoubleQuoted _ [T_Literal _ n]]) = Just (getId w, n)
literalIdentifierArg _                                                    = Nothing

isBashIdentifier :: String -> Bool
isBashIdentifier (c:cs) = (isAsciiUpper c || isAsciiLower c || c == '_')
                       && all (\x -> isAsciiUpper x || isAsciiLower x || isDigit x || x == '_') cs
isBashIdentifier []     = False

hasLowerAsciiLetter :: String -> Bool
hasLowerAsciiLetter = any isAsciiLower

wholeScriptAnalysis :: Token -> Analysis
wholeScriptAnalysis script = do
    params <- ask
    let tree     = parentMap params
        allFns   = collectAllFunctions script
        eligible = filter (isTopLevelEligible tree) allFns
        shapesByName = Map.fromListWith (++)
            [ (functionName f, [defShapeOf (collectScope (functionBody f))])
            | f <- eligible, not (null (functionName f))
            ]
        resolved = Map.map resolveName shapesByName
        cmds = collectAllCommands script
    forM_ cmds $ \cmd -> case cmd of
        T_SimpleCommand _ _ (T_NormalWord _ [T_Literal _ cmdName] : args) ->
            case Map.lookup cmdName resolved of
                Just (Positions posMap) ->
                    forM_ (Map.keys posMap) $ \n ->
                        case drop (n - 1) args of
                            (argTok : _) -> case literalIdentifierArg argTok of
                                Just (tid, name)
                                    | isBashIdentifier name, hasLowerAsciiLetter name ->
                                        warn tid 9014 (formatMessage cmdName name)
                                _ -> return ()
                            [] -> return ()
                _ -> return ()
        _ -> return ()

formatMessage :: String -> String -> String
formatMessage cmdName name =
    "Cross-scope out-param argument '" ++ name ++ "' passed to '" ++ cmdName ++
    "' should be UPPER_CASE (bash-style-guide: cross-scope return variables)."

-- A. Positive -- printf -v out-param call-site arg is lowercase.
prop_sc9014_printfVLowercase = verifyCode checkOutParamNaming 9014
    "foo() { printf -v \"$1\" '%s' x; }\nfoo lower"

-- B. Positive -- eval out-param call-site arg is lowercase.
prop_sc9014_evalLowercase = verifyCode checkOutParamNaming 9014
    "foo() { eval \"$1=x\"; }\nfoo lower"

-- B2. Positive -- eval with braced positional reference.
prop_sc9014_evalBraced = verifyCode checkOutParamNaming 9014
    "foo() { eval \"${1}=x\"; }\nfoo lower"

-- B3. Positive -- eval with split-quote form.
prop_sc9014_evalSplitQuote = verifyCode checkOutParamNaming 9014
    "foo() { eval \"$1\"'=x'; }\nfoo lower"

-- B4. Positive -- eval with escaped-double-quote form.
prop_sc9014_evalEscapedQuote = verifyCode checkOutParamNaming 9014
    "foo() { eval \"$1=\\\"x\\\"\"; }\nfoo lower"

-- C. Positive -- local -n out-param call-site arg is lowercase.
prop_sc9014_namerefLowercase = verifyCode checkOutParamNaming 9014
    "foo() { local -n REF=$1; REF=x; }\nfoo lower"

-- D. Positive -- double-quoted static call-site arg is lowercase.
prop_sc9014_quotedStaticArg = verifyCode checkOutParamNaming 9014
    "foo() { local -n REF=$1; REF=x; }\nfoo \"lower\""

-- E. Negative -- UPPER_CASE call-site arg is silent.
prop_sc9014_upperSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo UPPER"

-- F. Negative -- non-literal call-site arg is silent.
prop_sc9014_nonLiteralSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo \"$var\""

-- G. Negative -- function with no out-param write shape is silent.
prop_sc9014_noWriteSilent = verifyNot checkOutParamNaming
    "foo() { echo \"$1\"; }\nfoo lower"

-- H. Positive -- forward-reference call site (call precedes definition).
prop_sc9014_forwardReference = verifyCode checkOutParamNaming 9014
    "foo lower\nfoo() { local -n REF=$1; REF=x; }"

-- I. Positive -- recursive self-call with lowercase arg.
prop_sc9014_recursiveSelfCall = verifyCode checkOutParamNaming 9014
    "foo() { local -n REF=$1; foo lower; }"

-- J. Negative -- function containing shift anywhere is silent regardless of naming.
prop_sc9014_shiftTouchedSilent = verifyNot checkOutParamNaming
    "foo() { shift; local -n REF=$1; REF=x; }\nfoo lower"

-- K. Negative -- shift nested inside an if branch is still caught.
prop_sc9014_shiftNestedInIfSilent = verifyNot checkOutParamNaming
    "foo() { if true; then shift; fi; local -n REF=$1; REF=x; }\nfoo lower"

-- L. Negative -- ambiguous redefinition (differing positions) is silent.
prop_sc9014_ambiguousRedefinitionSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo() { local -n REF=$2; REF=x; }\nfoo lower lower"

-- M. Negative -- write inside a subshell does not register the function.
prop_sc9014_subshellWriteSilent = verifyNot checkOutParamNaming
    "foo() { ( local -n REF=$1; REF=x; ); }\nfoo lower"

-- N. Negative -- non-identifier literal reaching the case-check is silent.
prop_sc9014_nonIdentifierSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo -x"

-- O. Negative -- no-write definition alongside a write definition of the
-- same name is silent (the R2 "no-write definition" comparison bug).
prop_sc9014_noWriteVsWriteSilent = verifyNot checkOutParamNaming
    "foo() { echo hi; }\nfoo() { local -n REF=$1; REF=x; }\nfoo lower"

-- P. Negative -- a write inside a nested function definition does not
-- register the OUTER function as having an out-param.
prop_sc9014_nestedFunctionWriteSilent = verifyNot checkOutParamNaming
    "foo() { bar() { local -n REF=$1; REF=x; }; bar UPPER; }\nfoo lower"

-- Q. Negative -- the out-param-establishing write itself inside a real
-- (2+ command) pipeline does not register the function.
prop_sc9014_pipelineWriteSilent = verifyNot checkOutParamNaming
    "foo() { printf -v \"$1\" x | cat; }\nfoo lower"

-- R. Negative -- the out-param-establishing write itself inside a
-- backgrounded command does not register the function.
prop_sc9014_backgroundedWriteSilent = verifyNot checkOutParamNaming
    "foo() { printf -v \"$1\" x & }\nfoo lower"

-- S. Negative -- a function definition reachable only through a subshell
-- is never index-eligible (definition-side, not just write-side).
prop_sc9014_definitionInSubshellSilent = verifyNot checkOutParamNaming
    "( foo() { local -n REF=$1; REF=x; }; foo lower; )"

-- T. Positive, single warning -- the same position established via two
-- different mechanisms across two top-level definitions still resolves,
-- and fires exactly once (verifyCode itself asserts codes == [9014] --
-- i.e. exactly one occurrence, not two).
prop_sc9014_multiMechanismSinglePosition = verifyCode checkOutParamNaming 9014
    "if true; then foo() { local -n REF=$1; REF=x; }; else foo() { printf -v \"$1\" x; }; fi\nfoo lower"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
