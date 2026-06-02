{-# LANGUAGE TemplateHaskell #-}
module NilAvoidance (check, NilAvoidance.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Control.Monad (forM_)
import Data.Foldable (toList)
import Data.List (isPrefixOf)
import qualified Data.Map as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker = checkNilAvoidance,
    ccAlwaysOn = True,
    ccDescription = newCheckDescription {
        cdName = "nil-avoidance",
        cdDescription = "Variable declared without init, then first-materialized via +=",
        cdPositive = "foo() { local items; items+=(a); echo \"${items[@]}\"; }",
        cdNegative = "foo() { local items=(); items+=(a); echo \"${items[@]}\"; }"
    }
}

data WriteKind = AlwaysInit | AppendOrRisky deriving (Eq, Show)

checkNilAvoidance :: Token -> Analysis
checkNilAvoidance t = case t of
    T_Function _ _ _ _ body -> analyzeScope [body]
    T_Script _ _ stmts      -> analyzeScope stmts
    _                       -> return ()

-- | Per-scope analysis. Pre-indexes reads and writes by name, then for
-- each bare-name declaration candidate checks the §6 operative case.
analyzeScope :: [Token] -> Analysis
analyzeScope stmts = do
    params <- ask
    let positions    = tokenPositions params
        scopeToks    = concatMap collectScope stmts
        candidates   = concatMap extractBareDecls scopeToks
        arithLhsSet  = Set.fromList (concatMap arithLhsIds scopeToks)
        readIdx      = buildReadIndex positions arithLhsSet scopeToks
        writeIdx     = buildWriteIndex positions scopeToks
    forM_ candidates $ \(declId, name) ->
        case Map.lookup declId positions of
            Nothing -> return ()
            Just (declStart, _) -> do
                let readsAfter = filter (> declStart)
                                     (Map.findWithDefault [] name readIdx)
                case readsAfter of
                    [] -> return ()
                    _  ->
                        let firstReadPos = minimum readsAfter
                            betweenWrites =
                                [ kind
                                | (p, kind) <- Map.findWithDefault [] name writeIdx
                                , p > declStart, p < firstReadPos
                                ]
                        in case betweenWrites of
                            [] -> return ()
                            _ | all (== AppendOrRisky) betweenWrites ->
                                warn declId 9009 (formatMessage name)
                              | otherwise -> return ()

-- | Flatten subtree to a list of tokens, stopping at scope-creating nodes.
-- T_BraceGroup is NOT a scope boundary (shares parent variable scope).
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

-- | Extract (declId, name) pairs from T_SimpleCommand with cmd in
-- {local, declare, typeset} and bare-name args.
--
-- Skip when args contain:
--   * `-n` flag (nameref exception per §6 — out-param namerefs have
--     no useful init).
--   * `-p`, `-f`, `-F` flag (query forms — `declare -p x` prints
--     x's declaration but does not declare/initialize x; classifying
--     it as a candidate would false-positive when x is later
--     appended to elsewhere in scope).
extractBareDecls :: Token -> [(Id, String)]
extractBareDecls (T_SimpleCommand _ _
        (T_NormalWord _ (T_Literal _ cmd : _) : args))
    | cmd `elem` ["local", "declare", "typeset"]
    , not (hasFlagChar 'n' args)
    , not (hasAnyFlagChar "pfF" args)
    = [ (getId a, n)
      | a@(T_NormalWord _ [T_Literal _ n]) <- args
      , not ("-" `isPrefixOf` n)
      ]
extractBareDecls _ = []

-- | True if any arg is a bundled flag-token (starts with `-`, length ≥ 2)
-- containing the given character among its flag chars.
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

-- | Reads of variables: T_DollarBraced, TC_Unary with -v/-n/-z, TA_Variable.
extractReads :: Token -> [(Id, String)]
extractReads (T_DollarBraced tid _ inner) =
    let ref = getBracedReference (concat (oversimplify inner))
    in if null ref then [] else [(tid, ref)]
extractReads (TC_Unary tid _ op (T_NormalWord _ [T_Literal _ n]))
    | op `elem` ["-v", "-n", "-z"] = [(tid, n)]
extractReads (TA_Variable tid name _) = [(tid, name)]
extractReads _ = []

-- | Writes: classified into AlwaysInit (Assign, mapfile, readarray,
-- printf -v, arithmetic =) or AppendOrRisky (Append, bare read).
-- Unrecognized writers are invisible (false-negative shape, documented).
extractWrites :: Token -> [(Id, String, WriteKind)]
extractWrites (T_Assignment aid Assign name _ _) = [(aid, name, AlwaysInit)]
extractWrites (T_Assignment aid Append name _ _) = [(aid, name, AppendOrRisky)]
extractWrites (T_SimpleCommand _ _
        (T_NormalWord _ (T_Literal _ cmd : _) : args))
    | cmd `elem` ["mapfile", "readarray"] =
        [ (mid, mname, AlwaysInit) | (mid, mname) <- extractMapfileTargets args ]
    | cmd == "read" =
        [ (rid, rname, AppendOrRisky) | (rid, rname) <- extractReadTargets args ]
    | cmd == "printf" =
        case findPrintfV args of
            Just (aid, n) -> [(aid, n, AlwaysInit)]
            Nothing       -> []
extractWrites (T_Arithmetic _ inner)       = arithAssignsOf inner
extractWrites (T_DollarArithmetic _ inner) = arithAssignsOf inner
extractWrites _ = []

findPrintfV :: [Token] -> Maybe (Id, String)
findPrintfV (T_NormalWord _ [T_Literal _ "-v"] : v : _)
    | T_NormalWord _ [T_Literal _ n] <- v = Just (getId v, n)
findPrintfV (_ : rest) = findPrintfV rest
findPrintfV []         = Nothing

-- | Generic flag-aware positional extractor. Skips known single-char
-- value-flags `-X` AND their next positional (the flag's value).
-- Other dash-prefixed tokens are treated as opaque flags and skipped
-- without consuming the next positional. Bare positionals (no `-`
-- prefix, single T_Literal) are returned as write targets.
extractFlagAwareTargets :: String -> [Token] -> [(Id, String)]
extractFlagAwareTargets valueFlagChars = go
  where
    go [] = []
    go (T_NormalWord _ [T_Literal _ ('-':[f])] : rest)
        | f `elem` valueFlagChars = case rest of
            (_ : more) -> go more
            []         -> []
    go (T_NormalWord _ [T_Literal _ ('-':_)] : rest) = go rest
    go (a@(T_NormalWord _ [T_Literal _ n]) : rest)
        | not ("-" `isPrefixOf` n) = (getId a, n) : go rest
    go (_ : rest) = go rest

-- | Write-target variable names from `read` command args.
-- Bash `read` value-flags: -d, -i, -n, -N, -p, -t, -u.
-- `-a NAME` writes to array NAME (NAME is the target, not just a
-- value-arg). Other flags (-r, -s, -e) take no value-arg.
extractReadTargets :: [Token] -> [(Id, String)]
extractReadTargets = go
  where
    valueFlags = "dinNptu"
    go [] = []
    go (T_NormalWord _ [T_Literal _ ('-':[f])] : rest)
        | f `elem` valueFlags = case rest of
            (_ : more) -> go more
            []         -> []
        | f == 'a' = case rest of
            (T_NormalWord _ [T_Literal _ n] : more)
                | not ("-" `isPrefixOf` n)
                -> (getId (head rest), n) : go more
            _ -> go rest
    go (T_NormalWord _ [T_Literal _ ('-':_)] : rest) = go rest
    go (a@(T_NormalWord _ [T_Literal _ n]) : rest)
        | not ("-" `isPrefixOf` n) = (getId a, n) : go rest
    go (_ : rest) = go rest

-- | Write-target variable names from `mapfile`/`readarray` args.
-- Bash mapfile value-flags: -c, -C, -d, -n, -O, -s, -u.
-- No special name-flag (unlike `read -a`).
extractMapfileTargets :: [Token] -> [(Id, String)]
extractMapfileTargets = extractFlagAwareTargets "cCdnOsu"

-- | Walk an arithmetic subtree collecting TA_Assignment writes to
-- TA_Variable LHS. Any operator counts (including +=, -=, etc. inside
-- arithmetic — these fully assign the new value, no nilable-then-mutate
-- pattern applies). Recurses INTO matched TA_Assignment nodes so chained
-- assignments like `(( x = y = 1 ))` register every write, not just the
-- outermost. Without recursion, `local y; y+=foo; (( x = y = 1 )); echo $y`
-- would miss the y-write and false-positive (lexically only += visible).
arithAssignsOf :: Token -> [(Id, String, WriteKind)]
arithAssignsOf t@(OuterToken _ inner) = case t of
    TA_Assignment aid _ (TA_Variable _ name _) _ ->
        (aid, name, AlwaysInit) : concatMap arithAssignsOf (toList inner)
    _ -> concatMap arithAssignsOf (toList inner)

-- | Collect Ids of TA_Variable nodes that appear as the LHS of a
-- TA_Assignment. These should NOT be classified as reads — they are
-- write-target sites in arithmetic context, and treating them as
-- reads would shift "first read" earlier and exclude legitimate
-- AlwaysInit writes from the "writes between" set
-- (false-positive shape on `local x; x+=a; (( x = 1 )); echo "$x"`).
arithLhsIds :: Token -> [Id]
arithLhsIds t = case t of
    T_Arithmetic _ inner       -> walkLhs inner
    T_DollarArithmetic _ inner -> walkLhs inner
    _ -> []
  where
    walkLhs :: Token -> [Id]
    walkLhs w@(OuterToken _ inner) = case w of
        TA_Assignment _ _ lhs _ ->
            getId lhs : concatMap walkLhs (toList inner)
        _ -> concatMap walkLhs (toList inner)

buildReadIndex :: Map.Map Id (Position, Position) -> Set.Set Id
               -> [Token] -> Map.Map String [Position]
buildReadIndex positions arithLhs tokens =
    Map.fromListWith (++)
        [ (name, [start])
        | t <- tokens
        , (rid, name) <- extractReads t
        , not (Set.member rid arithLhs)
        , Just (start, _) <- [Map.lookup rid positions]
        ]

buildWriteIndex :: Map.Map Id (Position, Position) -> [Token]
                -> Map.Map String [(Position, WriteKind)]
buildWriteIndex positions tokens =
    Map.fromListWith (++)
        [ (name, [(start, kind)])
        | t <- tokens
        , (wid, name, kind) <- extractWrites t
        , Just (start, _) <- [Map.lookup wid positions]
        ]

formatMessage :: String -> String
formatMessage name =
    "Variable '" ++ name ++ "' declared without an initializer but " ++
    "first materialized via += (or risky write) before its first read. " ++
    "Initialize at declaration per bash-style-guide §6 " ++
    "(e.g. " ++ name ++ "=() for an array, " ++ name ++ "=\"\" for a string)."

-- A. Positive — every write before first read is AppendOrRisky.
prop_sc9009_arrayAppend         = verifyCode checkNilAvoidance 9009 "foo() { local items; items+=(a); echo \"${items[@]}\"; }"
prop_sc9009_stringAppend        = verify     checkNilAvoidance "foo() { local s; s+=hello; echo \"$s\"; }"
prop_sc9009_conditionalAppend   = verify     checkNilAvoidance "foo() { local arr; [[ $1 ]] && arr+=(x); echo \"${arr[@]}\"; }"
prop_sc9009_readWithoutInit     = verify     checkNilAvoidance "foo() { local line; read -r line < file; echo \"$line\"; }"
prop_sc9009_declare             = verify     checkNilAvoidance "foo() { declare arr; arr+=(a); echo \"${arr[@]}\"; }"
prop_sc9009_topLevel            = verify     checkNilAvoidance "declare arr; arr+=(a); echo \"${arr[@]}\""
prop_sc9009_LEXICAL_OVERFIRE_silentBranch
                                = verify     checkNilAvoidance "foo() { local x; if true; then x+=a; else :; fi; echo \"$x\"; }"

-- B. Negative — AlwaysInit write present.
prop_sc9009_plainAssign         = verifyNot  checkNilAvoidance "foo() { local x; x=foo; echo \"$x\"; }"
prop_sc9009_mapfile             = verifyNot  checkNilAvoidance "foo() { local arr; mapfile -t arr < <(echo a); echo \"${arr[@]}\"; }"
prop_sc9009_readarray           = verifyNot  checkNilAvoidance "foo() { local arr; readarray -t arr <file; echo \"${arr[@]}\"; }"
prop_sc9009_printfV             = verifyNot  checkNilAvoidance "foo() { local x; printf -v x '%s' \"$1\"; echo \"$x\"; }"
prop_sc9009_arithAssign         = verifyNot  checkNilAvoidance "foo() { local x; (( x = $1 + 1 )); echo \"$x\"; }"
prop_sc9009_overridePath        = verifyNot  checkNilAvoidance "foo() { local x; x+=foo; x=bar; echo \"$x\"; }"
prop_sc9009_mixedBranches       = verifyNot  checkNilAvoidance "foo() { local x; [[ $1 ]] && x=a || x+=b; echo \"$x\"; }"

-- C. Negative — no candidate (init at declaration).
prop_sc9009_initAtDeclArray     = verifyNot  checkNilAvoidance "foo() { local items=(); items+=(a); echo \"${items[@]}\"; }"
prop_sc9009_initAtDeclString    = verifyNot  checkNilAvoidance "foo() { local s=\"\"; s+=hello; echo \"$s\"; }"
prop_sc9009_emptyInitThenRead   = verifyNot  checkNilAvoidance "foo() { local line=\"\"; read -r line < f; echo \"$line\"; }"
prop_sc9009_cmdsubInit          = verifyNot  checkNilAvoidance "foo() { local result=$(echo a); echo \"$result\"; }"
prop_sc9009_namerefException    = verifyNot  checkNilAvoidance "foo() { local -n REF=$1; REF=value; }"

-- D. Negative — no read or no write.
prop_sc9009_unused              = verifyNot  checkNilAvoidance "foo() { local x; }"
prop_sc9009_uninitRead          = verifyNot  checkNilAvoidance "foo() { local x; echo \"$x\"; }"

-- E. Negative — sentinel pattern detected by extended read coverage.
prop_sc9009_sentinelV           = verifyNot  checkNilAvoidance "foo() { local x; [[ -v x ]] && echo present; }"
prop_sc9009_sentinelN           = verifyNot  checkNilAvoidance "foo() { local x; [[ -n $x ]] || x=default; echo \"$x\"; }"

-- F. Negative — subshell isolation (scope walker stops at subshell-like nodes).
prop_sc9009_subshellAppend      = verifyNot  checkNilAvoidance "foo() { local x; ( x+=a ); echo \"$x\"; }"
prop_sc9009_cmdsubAppend        = verifyNot  checkNilAvoidance "foo() { local x; y=$(x+=a; echo done); echo \"$x\"; }"

-- G. Scope isolation: separate dispatch per function.
prop_sc9009_scopeIsolation_f    = verifyCode checkNilAvoidance 9009 "f() { local x; x+=a; echo \"$x\"; } g() { local x=\"\"; x+=b; echo \"$x\"; }"
-- Note: f fires SC9009; g is silent. verifyCode asserts 9009 fires
-- somewhere, satisfying the fact that f warns. (verifyNot on the same
-- input would fail because f warns.)

-- H. Suppression.
prop_sc9009_suppressed          = verifyNot  checkNilAvoidance "# shellcheck disable=SC9009\nfoo() { local x; x+=a; echo \"$x\"; }"

-- I. Read-detection coverage (sanity check for arithmetic reads).
prop_sc9009_arithRead           = verifyNot  checkNilAvoidance "foo() { local x; (( x + 1 )); }"

-- J. `read` option-bearing forms — option-value args must NOT be classified as writes.
prop_sc9009_readDashPValueOnly  = verifyNot  checkNilAvoidance "foo() { local prompt=\"\"; local line=\"\"; read -p \"$prompt\" line; echo \"$line\"; }"
prop_sc9009_readDashUFdOperand  = verifyNot  checkNilAvoidance "foo() { local x=\"\"; read -u 3 x; echo \"$x\"; }"
prop_sc9009_readDashTTimeoutVal = verifyNot  checkNilAvoidance "foo() { local x=\"\"; read -t 10 x; echo \"$x\"; }"
prop_sc9009_readDashAArrayTarget = verify    checkNilAvoidance "foo() { local arr; read -a arr; echo \"${arr[@]}\"; }"
  -- -a's name-arg IS the target; this is correctly classified as a risky write
  -- (`read -a` without prior init is the antipattern shape).

-- K. Arithmetic +=/-= must classify as AlwaysInit (no warning).
prop_sc9009_arithPlusEq         = verifyNot  checkNilAvoidance "foo() { local x; (( x += 1 )); echo \"$x\"; }"
prop_sc9009_arithMinusEq        = verifyNot  checkNilAvoidance "foo() { local x; (( x -= 1 )); echo \"$x\"; }"

-- L. Nested-function single-emit: only the inner function's local emits SC9009.
-- verifyCode asserts emitted codes equal exactly [9009] — a single warning.
prop_sc9009_nestedFunction_singleEmit = verifyCode checkNilAvoidance 9009
    "outer() { inner() { local x; x+=a; echo \"$x\"; }; inner; }"

-- M. mapfile/readarray flag-aware target extraction — value-args must NOT
-- be classified as write targets (symmetric with read's flag handling).
prop_sc9009_mapfileWithFdFlag    = verifyNot checkNilAvoidance "foo() { local arr; mapfile -u 3 -t arr; echo \"${arr[@]}\"; }"
prop_sc9009_mapfileWithCallback  = verifyNot checkNilAvoidance "foo() { local arr; mapfile -C cb -c 5 -t arr; echo \"${arr[@]}\"; }"
prop_sc9009_mapfileWithDelim     = verifyNot checkNilAvoidance "foo() { local arr; mapfile -d '' -t arr; echo \"${arr[@]}\"; }"
prop_sc9009_readarrayWithOrigin  = verifyNot checkNilAvoidance "foo() { local arr; readarray -O 10 -t arr; echo \"${arr[@]}\"; }"

-- N. Query-form exclusion — `declare -p/-f/-F NAME` queries x, doesn't
-- declare it. Must NOT be classified as a candidate (would false-positive
-- when x is later appended elsewhere in scope).
prop_sc9009_declareDashP_query   = verifyNot checkNilAvoidance "foo() { local x=\"default\"; declare -p x; x+=suffix; echo \"$x\"; }"
prop_sc9009_declareDashF_query   = verifyNot checkNilAvoidance "foo() { local fn=\"\"; declare -F fn; fn+=stuff; echo \"$fn\"; }"
prop_sc9009_declareLowerF_query  = verifyNot checkNilAvoidance "foo() { local fn=\"\"; declare -f fn; fn+=stuff; echo \"$fn\"; }"

-- O. TA_Variable LHS of TA_Assignment is a write-site, not a read —
-- excluding it from the read index prevents a false-positive where
-- a later arith-init follows a prior append (the mixed-writes shape
-- is silent per §6 strict, and SC9009 should agree).
prop_sc9009_appendThenArithInit  = verifyNot checkNilAvoidance "foo() { local x; x+=foo; (( x = 1 )); echo \"$x\"; }"

-- P. Chained arithmetic assignment — `(( x = y = 1 ))` writes BOTH x and y.
-- arithAssignsOf must recurse into matched TA_Assignment nodes so the
-- inner write is captured, otherwise a prior += would lexically dominate
-- and false-positive.
prop_sc9009_chainedArithAssign   = verifyNot checkNilAvoidance "foo() { local y; y+=foo; (( x = y = 1 )); echo \"$y\"; }"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
