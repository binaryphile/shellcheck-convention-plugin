{-# LANGUAGE TemplateHaskell #-}
module SentinelLiteral (check, SentinelLiteral.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib (getLiteralString)
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Control.Monad (forM_)
import Data.Foldable (toList)
import Data.List (isSuffixOf)
import qualified Data.Map as Map

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkSentinelLiteral,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "sentinel-literal",
        cdDescription = "_-suffixed local whose value is provably never empty or IFS-bearing",
        cdPositive = "foo() { local x_=\"no\"; x_=\"yes\"; echo \"$x_\"; }",
        cdNegative = "foo() { local x_; x_=\"no\"; echo \"$x_\"; }"
    }
}

checkSentinelLiteral :: Token -> Analysis
checkSentinelLiteral t = case t of
    T_Function _ _ _ _ body -> analyzeScope [body]
    T_Script _ _ stmts      -> analyzeScope stmts
    _                       -> return ()

-- | A write site's AST shape, prior to judging safety (safety judgment
-- depends on whether the candidate is integer- or string-typed, so shape
-- extraction and safety judgment are kept separate).
data WriteShape = LiteralAssign Token | ArithAssign | AppendWrite

-- | Per-scope analysis. Unlike NilAvoidance/SC9009 (existential: "is the
-- write between decl and first read risky"), this is a universal claim
-- ("are ALL writes across the whole scope provably-safe literals") -- see
-- design.md for the full rationale and the /grade trail that shaped it.
analyzeScope :: [Token] -> Analysis
analyzeScope stmts = do
    params <- ask
    let positions   = tokenPositions params
        scopeToks   = concatMap collectScope stmts
        candidates  = concatMap extractDeclCandidates scopeToks
        dynamicEval = any isEvalSourceOrDot scopeToks
    forM_ candidates $ \(declId, name, initWord, isInteger) ->
        case Map.lookup declId positions of
            Nothing -> return ()
            Just (declStart, _) -> do
                let initSafe = isSafeFor isInteger (LiteralAssign initWord)
                if not initSafe || dynamicEval
                then return ()
                else do
                    let laterShapes = writeShapesAfter positions declStart name scopeToks
                        escaped     = any (bareNameEscape name) scopeToks
                        allSafe     = all (isSafeFor isInteger) laterShapes
                    if escaped || not allSafe
                    then return ()
                    else warn declId 9011 (formatMessage name)

-- | Safety judgment for a write shape, parameterized on whether the
-- candidate is `-i`-typed. Integer candidates are safe unconditionally
-- (R2 finding: `-i` coerces every successful assignment to a non-empty
-- numeric string regardless of the RHS's own shape -- empirically
-- verified). String candidates require the value to resolve to a
-- non-empty, IFS-free literal (via getLiteralString); a bare arithmetic-
-- command assignment (`(( x = ... ))`) is always safe by construction;
-- `+=` is never safe.
isSafeFor :: Bool -> WriteShape -> Bool
isSafeFor True  _                    = True
isSafeFor False (LiteralAssign val)  = isSafeLiteralWord val
isSafeFor False ArithAssign          = True
isSafeFor False AppendWrite          = False

-- | Flatten subtree to a list of tokens, stopping at scope-creating nodes.
-- Identical to NilAvoidance.collectScope (duplicated rather than exported
-- from NilAvoidance.hs -- a shared-module refactor is out of scope for
-- this cycle; see design.md).
collectScope :: Token -> [Token]
collectScope t@(OuterToken _ inner) = case t of
    T_Function {}        -> [t]
    T_Subshell {}        -> [t]
    T_DollarExpansion {} -> [t]
    T_ProcSub {}         -> [t]
    T_Backticked {}      -> [t]
    T_CoProc {}          -> [t]
    T_CoProcBody {}      -> [t]
    _                    -> t : concatMap collectScope (toList inner)

-- | Extract (assignId, name, initializerWord, isInteger) candidates: a
-- `local`/`declare`/`typeset` argument that is an ASSIGNMENT (not a bare
-- name -- R1 finding: a bare-name-only filter misses every initialized
-- declaration, including the task's own anchor `local taskSeen_="no"`),
-- whose name ends in `_`, excluding nameref/query-form/array flags.
-- `-i` (integer) declarations are a separate sub-rule: same initializer
-- requirement (R2 finding: bare `-i` is NOT guaranteed non-empty --
-- empirically verified), but no literal-shape check on the value.
extractDeclCandidates :: Token -> [(Id, String, Token, Bool)]
extractDeclCandidates (T_SimpleCommand _ _
        (T_NormalWord _ (T_Literal _ cmd : _) : args))
    | cmd `elem` ["local", "declare", "typeset"]
    , not (hasFlagChar 'n' args)
    , not (hasAnyFlagChar "pfFaA" args)
    = [ (aid, name, val, hasFlagChar 'i' args)
      | T_Assignment aid Assign name _ val <- args
      , "_" `isSuffixOf` name
      ]
extractDeclCandidates _ = []

-- | True if any arg is a bundled flag-token containing the given char.
hasFlagChar :: Char -> [Token] -> Bool
hasFlagChar c = any go
  where
    go (T_NormalWord _ [T_Literal _ ('-':rest@(_:_))]) = c `elem` rest
    go _ = False

hasAnyFlagChar :: String -> [Token] -> Bool
hasAnyFlagChar chars = any go
  where
    go (T_NormalWord _ [T_Literal _ ('-':rest@(_:_))]) =
        any (`elem` rest) chars
    go _ = False

-- | A word is a safe literal iff it resolves to a non-empty string
-- containing no default-IFS characters (space, tab, newline). Uses
-- ShellCheck.ASTLib's getLiteralString, which uniformly handles
-- single-quoted, double-quoted-without-expansion, and unquoted literal
-- forms and returns Nothing the moment any part is an expansion (R1
-- finding: a hand-rolled `T_NormalWord _ [T_Literal _ s]` pattern misses
-- quote-wrapper AST shapes that getLiteralString already resolves).
isSafeLiteralWord :: Token -> Bool
isSafeLiteralWord w = case getLiteralString w of
    Just s | not (null s), not (any isIFSChar s) -> True
    _ -> False
  where
    isIFSChar c = c `elem` " \t\n"

-- | Every write to `name` strictly after `declStart` (R1 finding: writes
-- must be bounded to after the candidate's own declaration position, not
-- collected scope-wide, or an unrelated same-named write elsewhere
-- contaminates the judgment). A bare arithmetic-command assignment
-- (`(( name = ... ))`, NOT `name=$(( ... ))` -- R1 finding: these are
-- different AST shapes and must not be conflated; the latter is an
-- ordinary `T_Assignment` whose value contains an expansion) is its own
-- shape.
writeShapesAfter :: Map.Map Id (Position, Position) -> Position -> String -> [Token] -> [WriteShape]
writeShapesAfter positions declStart name = concatMap go
  where
    go tok = case tok of
        T_Assignment aid Assign n _ val | n == name, after aid -> [LiteralAssign val]
        T_Assignment aid Append n _ _   | n == name, after aid -> [AppendWrite]
        T_Arithmetic _ inner             -> arithHitsFor inner
        T_DollarArithmetic _ inner       -> arithHitsFor inner
        _ -> []
    after tid = case Map.lookup tid positions of
        Just (start, _) -> start > declStart
        Nothing         -> False
    arithHitsFor inner =
        [ ArithAssign | (aid, n) <- arithAssignNames inner, n == name, after aid ]

-- | Walk an arithmetic subtree collecting TA_Assignment writes to
-- TA_Variable LHS, recursing into matched nodes for chained assignments
-- (`(( x = y = 1 ))`) -- same recursion NilAvoidance's arithAssignsOf uses.
arithAssignNames :: Token -> [(Id, String)]
arithAssignNames t@(OuterToken _ inner) = case t of
    TA_Assignment aid _ (TA_Variable _ name _) _ ->
        (aid, name) : concatMap arithAssignNames (toList inner)
    _ -> concatMap arithAssignNames (toList inner)

-- | Escape/unknown-mutator disqualifier (R2 finding): a bare literal-word
-- occurrence of `name` as a command argument -- anywhere in scope, not
-- position-bounded -- conservatively disqualifies. This is deliberately
-- blunt (an incidental bare-word collision unrelated to the variable also
-- disqualifies; accepted cost, see design.md) but it closes the
-- false-positive path an invisible custom mutator (`mycustomsetter x_
-- ...`) would otherwise leave open, AND -- as a side effect -- already
-- covers `read`/`printf -v`/`mapfile` targets, which are exactly this
-- same AST shape (a bare-word command argument), so no separate
-- modeled-writer classification is needed for those three forms.
bareNameEscape :: String -> Token -> Bool
bareNameEscape name (T_SimpleCommand _ _ (_ : args)) = any isBareName args
  where
    isBareName (T_NormalWord _ [T_Literal _ n]) = n == name
    isBareName _ = False
bareNameEscape _ _ = False

-- | True when `tok` is a T_SimpleCommand whose *effective* command name
-- (after recursively resolving a literal `command`/`builtin` wrapper
-- prefix, including execution-mode options and `--` -- R3/R4 findings: a
-- single-level strip misses chained forms like `command builtin eval
-- ...`, and `command -v`/`-V` introspects rather than executes, so must
-- NOT disqualify) is `eval`, `source`, or `.`.
isEvalSourceOrDot :: Token -> Bool
isEvalSourceOrDot (T_SimpleCommand _ _ words_) =
    case resolveEffectiveCommand words_ of
        Just name -> name `elem` ["eval", "source", "."]
        Nothing   -> False
isEvalSourceOrDot _ = False

-- | Resolve the literal command actually executed, recursively stripping
-- `command`/`builtin` wrappers. Returns Nothing when the head is
-- dynamically constructed (can't be resolved statically -- a documented
-- residual limitation, not a defect) OR when a `command` invocation is in
-- introspection mode (`-v`/`-V` anywhere among its combined short flags --
-- queries the command rather than executing it).
resolveEffectiveCommand :: [Token] -> Maybe String
resolveEffectiveCommand [] = Nothing
resolveEffectiveCommand (w:rest) = case getLiteralString w of
    Just "command" -> goCommand rest
    Just "builtin"  -> goPlainWrapper rest
    Just lit        -> Just lit
    Nothing         -> Nothing
  where
    goCommand (w':rest')
        | Just "--" <- getLiteralString w' = resolveEffectiveCommand rest'
        | Just lit@('-':flags) <- getLiteralString w'
        , not (null flags)
        = if any (`elem` "vV") flags
          then Nothing                    -- introspection: -v/-V present
          else goCommand rest'             -- transparent flag (e.g. -p)
    goCommand toks = resolveEffectiveCommand toks

    goPlainWrapper (w':rest')
        | Just "--" <- getLiteralString w' = resolveEffectiveCommand rest'
    goPlainWrapper toks = resolveEffectiveCommand toks

formatMessage :: String -> String
formatMessage name =
    "Variable '" ++ name ++ "' is only ever assigned non-empty, IFS-free " ++
    "literals -- the '_' suffix is unwarranted per bash-style-guide's " ++
    "two-state-literal-sentinel rule. Drop the suffix (e.g. rename '" ++
    name ++ "' to '" ++ init name ++ "')."

-- A. Positive -- initialized decl + safe reassignment (era#80703 anchor).
prop_sc9011_anchorShape        = verifyCode checkSentinelLiteral 9011 "foo() { local taskSeen_=\"no\"; taskSeen_=\"yes\"; echo \"$taskSeen_\"; }"
prop_sc9011_singleQuote        = verifyCode checkSentinelLiteral 9011 "foo() { local x_='no'; x_='yes'; echo \"$x_\"; }"
prop_sc9011_unquoted           = verifyCode checkSentinelLiteral 9011 "foo() { local x_=no; x_=yes; echo \"$x_\"; }"
prop_sc9011_declare            = verifyCode checkSentinelLiteral 9011 "declare x_=\"no\"; x_=\"yes\"; echo \"$x_\""
prop_sc9011_singleAssignOnly   = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; echo \"$x_\"; }"
prop_sc9011_arithCommandForm   = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; (( x_ = 1 )); echo \"$x_\"; }"
prop_sc9011_integerDeclEq0     = verifyCode checkSentinelLiteral 9011 "foo() { local -i count_=0; count_=5; echo \"$count_\"; }"
prop_sc9011_integerAnyRhs      = verifyCode checkSentinelLiteral 9011 "foo() { local -i count_=$1; echo \"$count_\"; }"

-- B. Negative -- bare declaration (R1/R2 findings: must NOT fire, even
-- with only-later-safe-writes; emptiness is reachable at declaration).
prop_sc9011_bareStringDecl      = verifyNot checkSentinelLiteral "foo() { local x_; x_=\"no\"; echo \"$x_\"; }"
prop_sc9011_bareStringIfElse    = verifyNot checkSentinelLiteral "foo() { local mode_; if [[ $1 ]]; then mode_=\"a\"; else mode_=\"b\"; fi; echo \"$mode_\"; }"
prop_sc9011_bareIntegerDecl     = verifyNot checkSentinelLiteral "foo() { local -i count_; count_=5; echo \"$count_\"; }"

-- C. Negative -- unsafe initializer or unsafe reassignment.
prop_sc9011_cmdsubInit          = verifyNot checkSentinelLiteral "foo() { local x_=$(echo no); echo \"$x_\"; }"
prop_sc9011_dollarArithInit     = verifyNot checkSentinelLiteral "foo() { local x_=$((1+1)); echo \"$x_\"; }"
prop_sc9011_emptyInit           = verifyNot checkSentinelLiteral "foo() { local x_=\"\"; echo \"$x_\"; }"
prop_sc9011_ifsCharInit         = verifyNot checkSentinelLiteral "foo() { local x_=\"a b\"; echo \"$x_\"; }"
prop_sc9011_appendAfterSafe     = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; x_+=\"more\"; echo \"$x_\"; }"
prop_sc9011_cmdsubReassign      = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; x_=$(echo yes); echo \"$x_\"; }"

-- D. Negative -- escape/unknown-mutator disqualifier (also covers
-- read/printf -v/mapfile targets, which share the same bare-word shape).
prop_sc9011_customSetterEscape  = verifyNot checkSentinelLiteral "foo() { local x_=\"yes\"; mycustomsetter x_ \"\"; echo \"$x_\"; }"
prop_sc9011_readTarget          = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_; echo \"$x_\"; }"
prop_sc9011_printfVTarget       = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ '%s' \"$1\"; echo \"$x_\"; }"
prop_sc9011_mapfileTarget       = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; mapfile -t x_ <file; echo \"${x_[@]}\"; }"

-- E. Negative -- eval/source/. scope-wide disqualifier, including
-- recursive builtin/command wrapper forms (R2/R3/R4 findings).
prop_sc9011_evalPresent         = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; eval 'x_=yes'; echo \"$x_\"; }"
prop_sc9011_sourcePresent       = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; source ./conf.sh; echo \"$x_\"; }"
prop_sc9011_dotPresent          = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; . ./conf.sh; echo \"$x_\"; }"
prop_sc9011_builtinEvalWrapped  = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; builtin eval 'x_=yes'; echo \"$x_\"; }"
prop_sc9011_commandSourceWrapped = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; command source ./conf.sh; echo \"$x_\"; }"
prop_sc9011_chainedWrapper      = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; command builtin eval 'x_=yes'; echo \"$x_\"; }"

-- F. Positive -- eval/source introspection forms must NOT disqualify.
prop_sc9011_commandDashVIntrospect = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; command -v eval; x_=\"yes\"; echo \"$x_\"; }"
prop_sc9011_commandDashVCapIntrospect = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; command -V eval; x_=\"yes\"; echo \"$x_\"; }"

-- G. Negative -- array/assoc/nameref/query-form declares, unused candidates.
prop_sc9011_arrayDeclExcluded   = verifyNot checkSentinelLiteral "foo() { local -a arr_=(a b); echo \"${arr_[@]}\"; }"
prop_sc9011_namerefExcluded     = verifyNot checkSentinelLiteral "foo() { local -n REF_=$1; echo \"$REF_\"; }"
prop_sc9011_declareDashPQuery   = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; declare -p x_; echo \"$x_\"; }"

-- Initializer alone is sufficient evidence -- a literal-init candidate
-- with no further writes and no read still fires: the suffix is
-- unwarranted regardless of whether the value is ever consumed.
prop_sc9011_initOnlyStillFires  = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; }"

-- H. Suppression.
prop_sc9011_suppressed          = verifyNot checkSentinelLiteral "# shellcheck disable=SC9011\nfoo() { local x_=\"no\"; x_=\"yes\"; echo \"$x_\"; }"

-- I. Scope isolation: separate dispatch per function.
prop_sc9011_scopeIsolation_f    = verifyCode checkSentinelLiteral 9011 "f() { local x_=\"no\"; x_=\"yes\"; echo \"$x_\"; } g() { local x_; x_=\"no\"; echo \"$x_\"; }"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
