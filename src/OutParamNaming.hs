{-# LANGUAGE TemplateHaskell #-}
module OutParamNaming (check, OutParamNaming.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib (getBracedReference, getPath, oversimplify)
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Control.Applicative ((<|>))
import Control.Monad (forM_)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (toList)
import Data.List (foldl', isPrefixOf)
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
        cdDescription = "Cross-scope out-param call-site argument collides with the callee's own local",
        cdPositive = "foo() { local -n REF=$1; REF=x; }\nfoo REF",
        cdNegative = "foo() { local -n REF=$1; REF=x; }\nfoo repo"
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

-- | Named (non-positional) variable-reference extraction: bare `$x`/
-- `${x}`, or a single level of double-quote wrapping one (`"$x"`).
-- #126163: sibling to `positionalRefOf`, but deliberately does NOT use
-- `getBracedReference` -- empirically confirmed (AST probe, task #126163
-- R1) that `getBracedReference` STRIPS modifiers (`${x:-fallback}` and
-- even the indirect-expansion form `${!x}` both come back as bare "x"),
-- which would make `local -n Y=${x:-fallback}` (or worse, `${!x}`, a
-- semantically different indirect-expansion form) silently misresolve
-- as a faithful `$x` reference. This same latent bug exists in the
-- EXISTING `positionalRefOf` for the direct-positional case
-- (`${1:-fallback}` misresolves as `$1`) -- pre-existing, out of this
-- cycle's scope, tracked separately (#126222). Uses the RAW pre-strip
-- text (`concat (oversimplify inner)`, same extraction `positionalRefOf`
-- performs before handing it to `getBracedReference`) validated via
-- `isBashIdentifier`, which correctly rejects both modifier forms since
-- their raw text ("x:-fallback", "!x") is not a plain identifier.
namedVarRefOf :: Token -> Maybe String
namedVarRefOf (T_DollarBraced _ _ inner) =
    case concat (oversimplify inner) of
        s | isBashIdentifier s -> Just s
        _                      -> Nothing
namedVarRefOf (T_DoubleQuoted _ [inner]) = namedVarRefOf inner
namedVarRefOf _ = Nothing

namedVarRefOfWord :: Token -> Maybe String
namedVarRefOfWord (T_NormalWord _ [w]) = namedVarRefOf w
namedVarRefOfWord _                    = Nothing

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

-- | A named intermediate local's resolved donor position, tracked
-- SEQUENTIALLY in scope-token order (#126163 R1 findings 1+2 -- unlike
-- direct-positional resolution, indirect resolution needs cross-
-- statement state, and getting the order wrong is a real soundness bug:
-- a later `local x=$2` cannot retroactively establish an EARLIER
-- `local -n Y=$x`). `Just n` = as of this point in the scope, the name
-- unambiguously holds position n's caller-supplied value. `Nothing` =
-- the name was declared/reassigned to something that isn't a direct
-- positional reference (including a CONFLICTING positional -- e.g.
-- `local x=$2` followed later by `local x=$3`), permanently
-- disqualifying it as a donor from that point on -- never silently
-- picks one of two conflicting positions.
type Donors = Map.Map String (Maybe Int)

-- | `local`/`declare`/`typeset -n NAME=$N` (direct) or
-- `local`/`declare`/`typeset -n NAME=$x` where `x` resolves via the
-- CURRENT `donors` state (indirect, #126163) -- NAME's own
-- (callee-chosen) case is a different, already-handled concern.
findNamerefPositional :: Donors -> [Token] -> Maybe Int
findNamerefPositional donors (T_Assignment _ Assign _ _ value : _) =
    positionalRefOfWord value <|> (namedVarRefOfWord value >>= \n -> Map.lookup n donors >>= id)
findNamerefPositional donors (_ : rest) = findNamerefPositional donors rest
findNamerefPositional _ [] = Nothing

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

-- | Update the donor map from one `local`/`declare`/`typeset` command's
-- assignments (#126163). Excludes `-g` (not function-scoped, matching
-- #126151's global-exclusion precedent). Every assignment updates (or
-- disqualifies) its own name; a positional RHS records the position,
-- anything else (including a conflicting positional) disqualifies the
-- name as a future donor.
updateDonors :: Token -> Donors -> Donors
updateDonors (T_SimpleCommand _ _ (T_NormalWord _ (T_Literal _ cmd : _) : args)) donors
    | cmd `elem` ["local", "declare", "typeset"]
    , not (hasFlagChar 'g' args)
    = foldl' oneAssign donors args
  where
    oneAssign :: Donors -> Token -> Donors
    oneAssign d (T_Assignment _ Assign name _ value) = case positionalRefOfWord value of
        Just n -> case Map.lookup name d of
            Just (Just m) | m /= n -> Map.insert name Nothing d
            _                      -> Map.insert name (Just n) d
        Nothing -> Map.insert name Nothing d
    oneAssign d _ = d
updateDonors _ donors = donors

-- | Infer a single top-level function definition's shape from its
-- scope-respecting body tokens. Sequential left-to-right fold
-- (#126163) so indirect nameref-binding resolution sees only
-- ALREADY-ESTABLISHED donors, never later ones.
defShapeOf :: [Token] -> DefShape
defShapeOf scopeToks
    | hasLiteralShift scopeToks = ShiftTouched
    | Map.null merged           = NoWrite
    | otherwise                 = HasWrite merged
  where
    (_, merged) = foldl' step (Map.empty, Map.empty) scopeToks

    step :: (Donors, Map.Map Int (Set.Set Mechanism))
         -> Token
         -> (Donors, Map.Map Int (Set.Set Mechanism))
    step (donors, found) t@(T_SimpleCommand _ _ (T_NormalWord _ (T_Literal _ cmd : _) : args)) =
        case cmd of
            "printf" | Just n <- findPrintfVPositional args ->
                (donors, addFound n PrintfV found)
            "eval" | Just n <- evalOutParamPosition args ->
                (donors, addFound n Eval found)
            _ | cmd `elem` ["local", "declare", "typeset"] ->
                let donors' = updateDonors t donors
                    found'
                        | hasFlagChar 'n' args
                        , Just n <- findNamerefPositional donors' args
                        = addFound n Nameref found
                        | otherwise = found
                in (donors', found')
            _ -> (donors, found)
    step st _ = st

    addFound n mech = Map.insertWith Set.union n (Set.singleton mech)

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

-- | Every name a `local`/`declare`/`typeset` command in this function body
-- introduces into the FUNCTION'S OWN scope -- the collision set a caller's
-- out-param argument must not match (#126151: the real 2018 invariant --
-- see bash-style-guide "Cross-scope return variables" -- is that the
-- CALLEE namespaces its own locals so no caller-chosen name can collide,
-- not that the caller must adopt special casing).
--
-- Excludes `-g`/`-global` declarations (not function-scoped despite the
-- keyword) and `-p`/`-f` (inspection forms -- `declare -p x` reads an
-- existing binding, it does not introduce one). Handles multi-name forms
-- (`local -n a=$2 b=$3`), bare uninitialized names (`local x`), and
-- array/subscript assignments (`arr[0]=x`) -- ShellCheck's own
-- T_Assignment already carries the base name separately from any
-- subscript, so no extra normalization is needed for the array case.
localNamesOf :: [Token] -> Set.Set String
localNamesOf scopeToks = Set.unions (map oneCmd scopeToks)
  where
    oneCmd :: Token -> Set.Set String
    oneCmd (T_SimpleCommand _ _ (T_NormalWord _ (T_Literal _ cmd : _) : args))
        | cmd `elem` ["local", "declare", "typeset"]
        , not (hasFlagChar 'g' args)
        , not (hasFlagChar 'p' args)
        , not (hasFlagChar 'f' args)
        = Set.fromList (concatMap namesOfArg args)
    oneCmd _ = Set.empty

    namesOfArg :: Token -> [String]
    namesOfArg (T_Assignment _ Assign name _ _) = [name]
    namesOfArg (T_NormalWord _ [T_Literal _ n])
        | isBashIdentifier n = [n]
    namesOfArg _ = []

wholeScriptAnalysis :: Token -> Analysis
wholeScriptAnalysis script = do
    params <- ask
    let tree     = parentMap params
        allFns   = collectAllFunctions script
        eligible = filter (isTopLevelEligible tree) allFns
        namedEligible = [ f | f <- eligible, not (null (functionName f)) ]
        shapesByName = Map.fromListWith (++)
            [ (functionName f, [defShapeOf (collectScope (functionBody f))])
            | f <- namedEligible
            ]
        resolved = Map.map resolveName shapesByName
        -- Locals-set collection is independent of out-param-position
        -- resolution (#126151 R1 finding 2): a shift-touched/ambiguous
        -- name's POSITIONS are unknowable, but its declared LOCALS are
        -- not affected by that -- shift renumbers which position writes
        -- where, it doesn't change what names a function declares. Union
        -- unconditionally across every same-named top-level definition.
        localsByName = Map.fromListWith Set.union
            [ (functionName f, localNamesOf (collectScope (functionBody f)))
            | f <- namedEligible
            ]
        cmds = collectAllCommands script
    forM_ cmds $ \cmd -> case cmd of
        T_SimpleCommand _ _ (T_NormalWord _ [T_Literal _ cmdName] : args) ->
            case Map.lookup cmdName resolved of
                Just (Positions posMap) ->
                    let locals = Map.findWithDefault Set.empty cmdName localsByName
                    in forM_ (Map.keys posMap) $ \n ->
                        case drop (n - 1) args of
                            (argTok : _) -> case literalIdentifierArg argTok of
                                Just (tid, name)
                                    | isBashIdentifier name, name `Set.member` locals ->
                                        warn tid 9014 (formatMessage cmdName name)
                                _ -> return ()
                            [] -> return ()
                _ -> return ()
        _ -> return ()

formatMessage :: String -> String -> String
formatMessage cmdName name =
    "Cross-scope out-param argument '" ++ name ++ "' passed to '" ++ cmdName ++
    "' may collide with '" ++ cmdName ++ "'s own local '" ++ name ++
    "' -- a static namespace collision that can silently redirect the write " ++
    "to the callee's local instead of your variable (bash-style-guide: " ++
    "cross-scope return variables)."

-- A. Positive -- printf -v out-param call-site arg collides with a
-- sibling local the callee itself declares.
prop_sc9014_printfVColliding = verifyCode checkOutParamNaming 9014
    "foo() { local tmp; printf -v \"$1\" '%s' x; }\nfoo tmp"

-- A2. Negative (#126151 R1 finding 4/5 -- the false-positive fix, printf-v
-- mechanism): a lowercase, non-colliding argument with no other callee
-- locals is silent -- this exact shape is `safe()`'s real call site.
prop_sc9014_printfVNonCollidingSilent = verifyNot checkOutParamNaming
    "foo() { printf -v \"$1\" '%s' x; }\nfoo repo"

-- B. Positive -- eval out-param call-site arg collides with a sibling local.
prop_sc9014_evalColliding = verifyCode checkOutParamNaming 9014
    "foo() { local tmp; eval \"$1=x\"; }\nfoo tmp"

-- B2. Positive -- eval with braced positional reference, colliding.
prop_sc9014_evalBraced = verifyCode checkOutParamNaming 9014
    "foo() { local tmp; eval \"${1}=x\"; }\nfoo tmp"

-- B3. Positive -- eval with split-quote form, colliding.
prop_sc9014_evalSplitQuote = verifyCode checkOutParamNaming 9014
    "foo() { local tmp; eval \"$1\"'=x'; }\nfoo tmp"

-- B4. Positive -- eval with escaped-double-quote form, colliding.
prop_sc9014_evalEscapedQuote = verifyCode checkOutParamNaming 9014
    "foo() { local tmp; eval \"$1=\\\"x\\\"\"; }\nfoo tmp"

-- B5. Negative -- eval mechanism, non-colliding lowercase arg is silent.
prop_sc9014_evalNonCollidingSilent = verifyNot checkOutParamNaming
    "foo() { eval \"$1=x\"; }\nfoo repo"

-- C. Positive -- self-reference collision: caller's argument matches the
-- callee's own nameref alias name.
prop_sc9014_namerefSelfCollision = verifyCode checkOutParamNaming 9014
    "foo() { local -n REF=$1; REF=x; }\nfoo REF"

-- C2. Positive -- collision with an ordinary (non-nameref) sibling local.
prop_sc9014_collidingOtherLocal = verifyCode checkOutParamNaming 9014
    "foo() { local -n REF=$1; local tmp; REF=x; }\nfoo tmp"

-- C3. Positive (#126151 R1 finding -- the false-negative fix): an
-- UPPERCASE argument that collides still fires -- casing was never the
-- real invariant.
prop_sc9014_upperButColliding = verifyCode checkOutParamNaming 9014
    "foo() { local -n OUT=$1; OUT=x; }\nfoo OUT"

-- D. Positive -- double-quoted static call-site arg, colliding.
prop_sc9014_quotedCollidingArg = verifyCode checkOutParamNaming 9014
    "foo() { local -n REF=$1; REF=x; }\nfoo \"REF\""

-- E. Negative (#126151 R1 -- the key false-positive fix, this is
-- `safe()`'s exact real usage): a non-colliding lowercase call-site arg
-- is silent, regardless of case.
prop_sc9014_lowercaseNonCollidingSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo repo"

-- E2. Negative -- non-colliding UPPERCASE call-site arg is also silent
-- (no collision either way; casing alone proves nothing).
prop_sc9014_upperNonCollidingSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo UPPER"

-- F. Negative -- non-literal call-site arg is silent.
prop_sc9014_nonLiteralSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo \"$var\""

-- G. Negative -- function with no out-param write shape is silent.
prop_sc9014_noWriteSilent = verifyNot checkOutParamNaming
    "foo() { echo \"$1\"; }\nfoo lower"

-- G2. Negative -- `declare -g` is NOT function-scoped; a same-named
-- caller argument must not be treated as a collision.
prop_sc9014_globalDeclareExcluded = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; declare -g tmp=1; REF=x; }\nfoo tmp"

-- G3. Negative -- `declare -p` is inspection-only, not a declaration.
prop_sc9014_declarePExcluded = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; declare -p tmp; REF=x; }\nfoo tmp"

-- G4. Positive -- multi-name `local -n a=$2 b=$3` form: BOTH names enter
-- the collision set, not just the one `findNamerefPositional` tracks as
-- an out-param position (it only captures the first assignment's
-- position, an existing, unrelated limitation -- pre-dates #126151).
-- Position 2 (a's position, the one actually registered) is called with
-- "b" -- proving `local -n a=$2 b=$3` declared "b" too, even though only
-- "a"'s position is tracked.
prop_sc9014_multiNameLocalN = verifyCode checkOutParamNaming 9014
    "foo() { local -n a=$2 b=$3; a=x; }\nfoo unused b"

-- G5. Positive -- bare uninitialized `local x` still collides.
prop_sc9014_bareLocalCollides = verifyCode checkOutParamNaming 9014
    "foo() { local -n REF=$1; local tmp; REF=x; }\nfoo tmp"

-- G6. Negative -- cross-function isolation: function A's own local name
-- must never leak into function B's collision set.
prop_sc9014_crossFunctionIsolationSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; local aOnly; REF=x; }\nbar() { local -n REF=$1; REF=x; }\nbar aOnly"

-- H. Positive -- forward-reference call site (call precedes definition),
-- colliding argument.
prop_sc9014_forwardReference = verifyCode checkOutParamNaming 9014
    "foo REF\nfoo() { local -n REF=$1; REF=x; }"

-- I. Positive -- recursive self-call with a colliding (self-reference) arg.
prop_sc9014_recursiveSelfCall = verifyCode checkOutParamNaming 9014
    "foo() { local -n REF=$1; foo REF; }"

-- J. Negative -- function containing shift anywhere is silent regardless
-- of naming, even with an argument that WOULD collide (proves the
-- shift-touched exclusion, not a coincidentally-non-colliding name).
prop_sc9014_shiftTouchedSilent = verifyNot checkOutParamNaming
    "foo() { shift; local -n REF=$1; REF=x; }\nfoo REF"

-- K. Negative -- shift nested inside an if branch is still caught, with
-- a colliding argument.
prop_sc9014_shiftNestedInIfSilent = verifyNot checkOutParamNaming
    "foo() { if true; then shift; fi; local -n REF=$1; REF=x; }\nfoo REF"

-- L. Negative -- ambiguous redefinition (differing positions) is silent,
-- with colliding arguments at both positions.
prop_sc9014_ambiguousRedefinitionSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo() { local -n REF=$2; REF=x; }\nfoo REF REF"

-- M. Negative -- write inside a subshell does not register the function.
prop_sc9014_subshellWriteSilent = verifyNot checkOutParamNaming
    "foo() { ( local -n REF=$1; REF=x; ); }\nfoo REF"

-- N. Negative -- non-identifier literal reaching the case-check is silent.
prop_sc9014_nonIdentifierSilent = verifyNot checkOutParamNaming
    "foo() { local -n REF=$1; REF=x; }\nfoo -x"

-- O. Negative -- no-write definition alongside a write definition of the
-- same name is silent (the R2 "no-write definition" comparison bug),
-- with a colliding argument.
prop_sc9014_noWriteVsWriteSilent = verifyNot checkOutParamNaming
    "foo() { echo hi; }\nfoo() { local -n REF=$1; REF=x; }\nfoo REF"

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
    "( foo() { local -n REF=$1; REF=x; }; foo REF; )"

-- T. Positive, single warning -- the same position established via two
-- different mechanisms across two top-level definitions still resolves,
-- and fires exactly once (verifyCode itself asserts codes == [9014] --
-- i.e. exactly one occurrence, not two). Colliding argument (the
-- nameref definition's own local name).
prop_sc9014_multiMechanismSinglePosition = verifyCode checkOutParamNaming 9014
    "if true; then foo() { local -n REF=$1; REF=x; }; else foo() { printf -v \"$1\" x; }; fi\nfoo REF"

-- U. Positive (#126163) -- indirect nameref binding (`local x=$2;
-- local -n Y=$x`) resolves to position 2, and a colliding call-site
-- argument at that position fires.
prop_sc9014_indirectBindingColliding = verifyCode checkOutParamNaming 9014
    "foo() { local x=$2; local -n Y=$x; Y=v; }\nfoo unused Y"

-- V. Negative (#126163) -- same indirect-binding shape, non-colliding
-- argument stays silent -- the false-positive-fix mirror for the
-- indirect case.
prop_sc9014_indirectBindingNonCollidingSilent = verifyNot checkOutParamNaming
    "foo() { local x=$2; local -n Y=$x; Y=v; }\nfoo unused repo"

-- W. Negative (#126163) -- a `-g`-declared intermediate does not
-- resolve a position (not function-scoped, matches #126151's exclusion).
prop_sc9014_indirectBindingGlobalIntermediateSilent = verifyNot checkOutParamNaming
    "foo() { declare -g x=$2; local -n Y=$x; Y=v; }\nfoo unused Y"

-- X. Negative (#126163 R1 finding 1, BLOCKING -- order sensitivity): a
-- LATER `local x=$2` cannot retroactively establish an EARLIER
-- `local -n Y=$x` -- the function is correctly NOT indexed at all
-- (donor doesn't exist yet at the point the nameref line runs).
prop_sc9014_indirectBindingForwardDonorSilent = verifyNot checkOutParamNaming
    "foo() { local -n Y=$x; local x=$2; Y=v; }\nfoo unused Y"

-- Y. Negative (#126163 R1 finding 2, BLOCKING -- conflicting donor): a
-- name reassigned to a DIFFERENT position is permanently disqualified
-- as a donor, never silently resolved to either position.
prop_sc9014_indirectBindingConflictingDonorSilent = verifyNot checkOutParamNaming
    "foo() { local x=$2; local x=$3; local -n Y=$x; Y=v; }\nfoo unused unused Y"

-- Z. Negative (#126163) -- an indirect-binding donor whose value is a
-- modifier/indirect expansion (`${x:-fallback}`, not a plain `$x`
-- reference) never resolves -- confirms the AST-shape assumption
-- verified for #126163 R1 (raw braced-reference text includes the
-- modifier, which `isBashIdentifier` rejects).
prop_sc9014_indirectBindingModifierExpansionSilent = verifyNot checkOutParamNaming
    "foo() { local x=$2; local -n Y=${x:-fallback}; Y=v; }\nfoo unused Y"

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
