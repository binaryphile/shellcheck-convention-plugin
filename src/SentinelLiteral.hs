{-# LANGUAGE TemplateHaskell #-}
module SentinelLiteral (check, SentinelLiteral.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib (getBracedReference, getLiteralString, oversimplify)
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

import Control.Monad (forM_)
import Data.Foldable (toList)
import Data.List (dropWhileEnd, isPrefixOf, isSuffixOf)
import qualified Data.Map as Map
import qualified Data.Set as Set

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
                 | ReadHereStringAssign Token | PrintfVAssign Token

-- | Per-scope analysis. Unlike NilAvoidance/SC9009 (existential: "is the
-- write between decl and first read risky"), this is a universal claim
-- ("are ALL writes across the whole scope provably-safe literals") -- see
-- design.md for the full rationale and the /grade trail that shaped it.
analyzeScope :: [Token] -> Analysis
analyzeScope stmts = do
    params <- ask
    let positions   = tokenPositions params
        root        = rootNode params
        shadowed    = Set.fromList (filter (`elem` ["read", "printf"]) (allFunctionNames root))
        scopeToks   = concatMap collectScope stmts
        candidates  = concatMap extractDeclCandidates scopeToks
        dynamicEval = any isEvalSourceOrDot scopeToks
        ifsRisky    = ifsMayBeNonDefault scopeToks
    forM_ candidates $ \(declId, name, initWord, isInteger) ->
        case Map.lookup declId positions of
            Nothing -> return ()
            Just (declStart, _) -> do
                let initSafe = isSafeFor isInteger ifsRisky (LiteralAssign initWord)
                if not initSafe || dynamicEval
                then return ()
                else do
                    let recognized       = [ rw | tok <- scopeToks, Just rw <- [recognizeWrite shadowed name tok] ]
                        positionMap      = Map.fromList [ (rwPositionId rw, rwShape rw) | rw <- recognized ]
                        commandIdSkipSet = Set.fromList (map rwCommandId recognized)
                        laterShapes      = writeShapesAfter positions positionMap declStart name scopeToks
                        escaped          = any (bareNameEscapeExcept commandIdSkipSet name) scopeToks
                        allSafe          = all (isSafeFor isInteger ifsRisky) laterShapes
                    if escaped || not allSafe
                    then return ()
                    else warn declId 9011 (formatMessage name)

-- | Safety judgment for a write shape, parameterized on whether the
-- candidate is `-i`-typed and on whether `IFS` may be non-default
-- anywhere in the enclosing scope. Integer candidates are safe
-- unconditionally (R2 finding: `-i` coerces every successful assignment
-- to a non-empty numeric string regardless of the RHS's own shape --
-- empirically verified). String candidates require the value to resolve
-- to a non-empty, IFS-free literal (via getLiteralString) OR one of the
-- provably-safe expansion forms (via isSafeExpansionWord); a bare
-- arithmetic-command assignment (`(( x = ... ))`) is always safe by
-- construction; `+=` is never safe. `read -r NAME <<< "literal"` is safe
-- iff `IFS` is not scope-risky AND the here-string word passes
-- isSafeReadHereStringWord (#86907); `printf -v NAME "literal"` is safe
-- iff the format word passes isSafePrintfFormatWord (#86907), independent
-- of `IFS` (printf does no field splitting on its own format string).
isSafeFor :: Bool -> Bool -> WriteShape -> Bool
isSafeFor True  _        _                          = True
isSafeFor False _        (LiteralAssign val)        = isSafeLiteralWord val || isSafeExpansionWord val
isSafeFor False _        ArithAssign                = True
isSafeFor False _        AppendWrite                = False
isSafeFor False ifsRisky (ReadHereStringAssign val)
    | ifsRisky  = False
    | otherwise = isSafeReadHereStringWord val
isSafeFor False _        (PrintfVAssign val)        = isSafePrintfFormatWord val

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
-- containing no default-IFS characters (space, tab, newline) and no NUL
-- character (#86907 R2 finding: `getLiteralString`'s ANSI-C-quote
-- decoding, `decodeEscapes` in ShellCheck's ASTLib, can resolve an octal
-- escape like `$'\0suffix'` to an actual NUL character; bash cannot
-- store NUL in a variable, so a Haskell-string-non-empty literal like
-- that would be runtime-empty -- this guard closes that gap uniformly,
-- not just for the two new predicates below that share the same
-- decoding dependency). Uses ShellCheck.ASTLib's getLiteralString, which
-- uniformly handles single-quoted, double-quoted-without-expansion, and
-- unquoted literal forms and returns Nothing the moment any part is an
-- expansion (R1 finding: a hand-rolled `T_NormalWord _ [T_Literal _ s]`
-- pattern misses quote-wrapper AST shapes that getLiteralString already
-- resolves).
isSafeLiteralWord :: Token -> Bool
isSafeLiteralWord w = case getLiteralString w of
    Just s | not (null s), not (any isIFSChar s), not (any (== '\NUL') s) -> True
    _ -> False
  where
    isIFSChar c = c `elem` " \t\n"

-- | A word whose SOLE content (optionally wrapped in one layer of
-- T_DoubleQuoted -- quoting doesn't change these values' safety, so both
-- `x_=$?` and `x_="$?"` are recognized; verified via AST dump that
-- quoting adds exactly one such wrapper, not more) is one of a small set
-- of expansions that are provably non-empty and IFS-free by bash's own
-- semantics, even though they aren't literals:
--
--   * T_DollarArithmetic (`$(( expr ))` as the entire word) -- either the
--     expression evaluates successfully, producing a numeral string
--     (digits, optional leading '-', never empty, never IFS-bearing), or
--     evaluation fails and the OUTER assignment does not complete (it
--     never assigns an empty or partial result). Same guarantee already
--     granted to the bare arithmetic-command form (ArithAssign).
--   * T_DollarBraced where isCountingReference holds -- covers bare `$#`
--     and `${#var}`/`${#arr[@]}` (indexed or associative) uniformly,
--     since all three have raw content starting with '#' (confirmed via
--     AST dump, not inferred) -- a count is always >= 0, and "0" is a
--     non-empty string.
--   * T_DollarBraced whose braced reference is exactly "?" or "$" --
--     bare `$?`/`$$` (confirmed via AST dump: both are T_DollarBraced
--     with the braced flag False, same constructor as `${...}` forms).
--
-- Deliberately NOT included: `$LINENO` (empirically verified
-- unset-sensitive -- `unset LINENO` makes it read empty and reassignable
-- to arbitrary content, the same statefulness class as `$RANDOM`/
-- `$SECONDS` below), `$!` (empty until a background job exists in this
-- shell), `$RANDOM`/`$SECONDS` (survive garbage reassignment via bash's
-- re-seeding behavior but go genuinely empty after `unset` -- stateful,
-- scope-order-dependent, this check has no `unset`-tracking machinery),
-- `$_` (context-dependent content), `$PPID` (reassignment semantics
-- unverified).
isSafeExpansionWord :: Token -> Bool
isSafeExpansionWord (T_NormalWord _ [inner]) = isSafeExpansionInner inner
isSafeExpansionWord _ = False

isSafeExpansionInner :: Token -> Bool
isSafeExpansionInner (T_DoubleQuoted _ [inner]) = isSafeExpansionInner inner
isSafeExpansionInner (T_DollarArithmetic _ _) = True
isSafeExpansionInner t@(T_DollarBraced _ _ innerWord) =
    isCountingReference t ||
    getBracedReference (concat (oversimplify innerWord)) `elem` ["?", "$"]
isSafeExpansionInner _ = False

-- | A `read -r NAME <<< "literal"` here-string word is a safe write iff,
-- after truncating to `read`'s own first-line-only semantics (#86907
-- /grade R1 finding #3 -- `read` consumes only up to the first newline;
-- a blanket trim without this truncation wrongly judges an
-- embedded-newline literal like `$'\nyes'` as safe when `read` actually
-- assigns an empty first line) and then trimming leading/trailing
-- default-IFS whitespace from that line (interior IFS chars are NOT
-- split away -- there's only one target, so the remainder lands in it
-- verbatim), the result is non-empty, IFS-free, and NUL-free (R1 finding
-- #5 -- `decodeEscapes` can produce an actual NUL via ANSI-C quoting,
-- e.g. `$'\0suffix'`, which bash cannot store in a variable).
isSafeReadHereStringWord :: Token -> Bool
isSafeReadHereStringWord w = case getLiteralString w of
    Just s | not (any (== '\NUL') s) ->
        let line    = takeWhile (/= '\n') s
            trimmed = dropWhileEnd isIFSChar (dropWhile isIFSChar line)
        in not (null trimmed) && not (any isIFSChar trimmed)
    _ -> False
  where
    isIFSChar c = c `elem` " \t\n"

-- | A `printf -v NAME "literal"` format word (already structurally
-- guaranteed to carry no format specifiers or extra args -- see
-- printfVFormatWord's exact 4-word match) is a safe write iff it is a
-- non-empty, IFS-free, NUL-free literal (same NUL rationale as
-- isSafeReadHereStringWord above) containing neither a backslash nor a
-- `%` (conservative -- printf interprets backslash escapes and `%%`->`%`
-- in its format string at runtime, and rather than model that grammar,
-- any occurrence of either character disqualifies outright; #86907 1b
-- decision) AND not beginning with `-` (#86907 /grade R2 finding #1,
-- empirically verified against real bash: `printf` only recognizes `-v
-- var` as an option, so ANY other format-position argument starting
-- with `-` -- including a bare `--` or `-v` -- is parsed as an invalid
-- OPTION, not the format string; `printf -v x_ "-x"` errors and leaves
-- `x_` UNCHANGED, it does not assign `"-x"`).
isSafePrintfFormatWord :: Token -> Bool
isSafePrintfFormatWord w = case getLiteralString w of
    Just s | not (any (== '\NUL') s)
           , not (any (`elem` "\\%") s)
           , not (null s)
           , not (any isIFSChar s)
           , not ("-" `isPrefixOf` s)
      -> True
    _ -> False
  where
    isIFSChar c = c `elem` " \t\n"

-- | Blunt, conservative, scope-wide disqualifier (#86907 /grade R1
-- finding #4, same style as the existing eval/source/. disqualifier):
-- isSafeReadHereStringWord's leading/trailing-IFS-trim assumes DEFAULT
-- `IFS` (space/tab/newline); nothing about the AST shape itself
-- establishes that. If `IFS` is assigned, appended, or referenced as a
-- bare command argument (`unset IFS`, `local IFS`, a per-command prefix
-- assignment like `IFS=y read ...`, etc.) ANYWHERE in the scope's
-- flattened token list, every ReadHereStringAssign candidate in that
-- scope is judged unsafe unconditionally, regardless of the literal's
-- own content -- over-conservative when the touch is unrelated to the
-- specific read site (same accepted-false-negative-cost philosophy as
-- bareNameEscapeExcept), never unsound. `collectScope`'s recursion into
-- a T_SimpleCommand's derived-Foldable instance (which folds over its
-- prefix-assignment list before its words list, per AST.hs's
-- DeriveTraversable/DeriveFoldable) already flattens a prefix
-- assignment like `IFS=y` into its own T_Assignment entry, so the scan
-- below sees it without any special-casing.
ifsMayBeNonDefault :: [Token] -> Bool
ifsMayBeNonDefault = any go
  where
    go (T_Assignment _ _ "IFS" _ _) = True
    go (T_SimpleCommand _ _ args)   = any isBareIFS args
    go _ = False
    isBareIFS (T_NormalWord _ [T_Literal _ "IFS"]) = True
    isBareIFS _ = False

-- | Every `T_Function` name anywhere in the WHOLE script (not just the
-- current function-scope's own body) -- used by the command-shadowing
-- disqualifier below. `read`/`printf` can be shadowed by a same-named
-- shell function, giving either command arbitrary mutation semantics no
-- static AST shape can bound (#86907 /grade R1 finding #11); a
-- same-named function ANYWHERE in the file disqualifies recognition of
-- that command's shape globally, not just at call-sites textually
-- reachable from the shadowing definition -- blunt but sound, same
-- philosophy as the rest of this file's disqualifiers. Bash aliases
-- (`alias read=...`) and `enable -n read` are a DIFFERENT shadowing
-- mechanism this scan does not detect -- documented as an accepted
-- residual limitation in design.md (#86907 /grade R2 finding #5), same
-- class as the eval/source/.-aliasing gap already accepted there.
allFunctionNames :: Token -> [String]
allFunctionNames t@(OuterToken _ inner) = case t of
    T_Function _ _ _ name body -> name : concatMap allFunctionNames (toList inner)
    _                          -> concatMap allFunctionNames (toList inner)

-- | A write site recognized as one of the two exact shapes this cycle
-- can prove safe, plus the two ids callers need: `rwPositionId` (the
-- ENCLOSING T_Redirecting's own id -- #86907 /grade R1 finding #7,
-- confirmed via `prTokenPositions` dump: a redirect may textually
-- precede its command, `<<< "x" read -r y` is legal bash, and the
-- Redirecting node's span reliably covers the whole statement) for
-- `after`-bounded position checks, and `rwCommandId` (the inner
-- T_SimpleCommand's own id, matching how bareNameEscapeExcept already
-- keys on T_SimpleCommand) for escape-exclusion. `recognizeWrite` is
-- the ONLY place shape-matching logic lives (#86907 /grade R1 finding
-- #6) -- both the position-keyed WriteShape map (safety judgment) and
-- the command-id skip-set (escape exclusion) that analyzeScope derives
-- are pure projections of this single function's output, so a command
-- id in the skip-set structurally cannot lack a corresponding
-- WriteShape.
data RecognizedWrite = RecognizedWrite
    { rwPositionId :: Id
    , rwCommandId  :: Id
    , rwShape      :: WriteShape
    }

recognizeWrite :: Set.Set String -> String -> Token -> Maybe RecognizedWrite
recognizeWrite shadowed name (T_Redirecting rid redirs cmd) = case cmd of
    T_SimpleCommand cid _ _
        | "read" `Set.notMember` shadowed
        , [T_FdRedirect _ "" (T_HereString _ word)] <- redirs
        , isReadDashRTarget name cmd
        -> Just (RecognizedWrite rid cid (ReadHereStringAssign word))
        | "printf" `Set.notMember` shadowed
        , Just fmt <- printfVFormatWord name cmd
        -> Just (RecognizedWrite rid cid (PrintfVAssign fmt))
    _ -> Nothing
recognizeWrite _ _ _ = Nothing

-- | `read -r NAME` -- exactly this 3-word shape (no other flags, exactly
-- one target). Requiring the fd-label field of the enclosing here-string
-- redirect to be exactly `""` (checked in recognizeWrite, not here) is
-- what excludes a here-string attached to a non-default fd (#86907
-- /grade R1 finding #1 -- `read -r x_ 3<<< "yes"` connects the literal
-- to fd 3, but `read` always consumes fd 0 regardless).
isReadDashRTarget :: String -> Token -> Bool
isReadDashRTarget name (T_SimpleCommand _ _
        [ T_NormalWord _ [T_Literal _ "read"]
        , T_NormalWord _ [T_Literal _ "-r"]
        , T_NormalWord _ [T_Literal _ n]
        ]) = n == name
isReadDashRTarget _ _ = False

-- | `printf -v NAME <format>` -- exactly this 4-word shape, which
-- structurally guarantees no format specifiers can consume extra
-- arguments and no extra positional args are present (the shape itself
-- has no room for them).
printfVFormatWord :: String -> Token -> Maybe Token
printfVFormatWord name (T_SimpleCommand _ _
        [ T_NormalWord _ [T_Literal _ "printf"]
        , T_NormalWord _ [T_Literal _ "-v"]
        , T_NormalWord _ [T_Literal _ n]
        , fmt
        ]) | n == name = Just fmt
printfVFormatWord _ _ = Nothing

-- | Every write to `name` strictly after `declStart` (R1 finding: writes
-- must be bounded to after the candidate's own declaration position, not
-- collected scope-wide, or an unrelated same-named write elsewhere
-- contaminates the judgment). A bare arithmetic-command assignment
-- (`(( name = ... ))`, NOT `name=$(( ... ))` -- R1 finding: these are
-- different AST shapes and must not be conflated; the latter is an
-- ordinary `T_Assignment` whose value contains an expansion) is its own
-- shape. `recognized` (keyed by the enclosing T_Redirecting's own id --
-- see RecognizedWrite/recognizeWrite) supplies the ReadHereStringAssign/
-- PrintfVAssign shapes for the two forms #86907 added.
writeShapesAfter :: Map.Map Id (Position, Position) -> Map.Map Id WriteShape -> Position -> String -> [Token] -> [WriteShape]
writeShapesAfter positions recognized declStart name = concatMap go
  where
    go tok = case tok of
        T_Assignment aid Assign n _ val | n == name, after aid -> [LiteralAssign val]
        T_Assignment aid Append n _ _   | n == name, after aid -> [AppendWrite]
        T_Arithmetic _ inner             -> arithHitsFor inner
        T_DollarArithmetic _ inner       -> arithHitsFor inner
        T_Redirecting rid _ _
            | Just shape <- Map.lookup rid recognized, after rid -> [shape]
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
-- ...`) would otherwise leave open. `mapfile` targets share this exact
-- AST shape and remain fully subsumed by it, unmodified. `read`/
-- `printf -v` targets are now carved out (skipped here) ONLY when
-- their own T_SimpleCommand id is in `skip` -- which analyzeScope
-- derives from the SAME `recognizeWrite` output that independently
-- judges each site's safety (#86907 /grade R1 finding #6), so a
-- command can never be exempted here without also having gotten an
-- independent WriteShape safety verdict.
bareNameEscapeExcept :: Set.Set Id -> String -> Token -> Bool
bareNameEscapeExcept skip name (T_SimpleCommand cid _ (_ : args))
    | cid `Set.member` skip = False
    | otherwise             = any isBareName args
  where
    isBareName (T_NormalWord _ [T_Literal _ n]) = n == name
    isBareName _ = False
bareNameEscapeExcept _ _ _ = False

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
prop_sc9011_emptyInit           = verifyNot checkSentinelLiteral "foo() { local x_=\"\"; echo \"$x_\"; }"
prop_sc9011_ifsCharInit         = verifyNot checkSentinelLiteral "foo() { local x_=\"a b\"; echo \"$x_\"; }"
prop_sc9011_appendAfterSafe     = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; x_+=\"more\"; echo \"$x_\"; }"
prop_sc9011_cmdsubReassign      = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; x_=$(echo yes); echo \"$x_\"; }"

-- J. Positive -- $(( expr )) used directly as a plain assignment's RHS
-- (R1/R2 findings: reversing the original design's arbitrary AST-shape
-- exclusion -- this has the same "always a numeral" guarantee as the
-- bare arithmetic-command form).
prop_sc9011_dollarArithInit     = verifyCode checkSentinelLiteral 9011 "foo() { local x_=$((1+1)); echo \"$x_\"; }"
prop_sc9011_dollarArithReassign = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; x_=$((1+1)); echo \"$x_\"; }"

-- K. Positive -- provably-safe expansion forms, bare and quoted, as
-- initializer AND as later-write (era#80805 closeout live-test found
-- rc_=$? should fire; broadened to the full verified-safe set).
prop_sc9011_exitStatusInit      = verifyCode checkSentinelLiteral 9011 "foo() { true; local rc_=$?; echo \"$rc_\"; }"
prop_sc9011_exitStatusReassign  = verifyCode checkSentinelLiteral 9011 "foo() { local rc_=\"no\"; false; rc_=$?; echo \"$rc_\"; }"
prop_sc9011_exitStatusQuoted    = verifyCode checkSentinelLiteral 9011 "foo() { local rc_=\"no\"; false; rc_=\"$?\"; echo \"$rc_\"; }"
prop_sc9011_pidInit             = verifyCode checkSentinelLiteral 9011 "foo() { local pid_=$$; echo \"$pid_\"; }"
prop_sc9011_positionalCountInit = verifyCode checkSentinelLiteral 9011 "foo() { local count_=$#; echo \"$count_\"; }"
prop_sc9011_stringLengthInit    = verifyCode checkSentinelLiteral 9011 "foo() { local y=abc; local len_=${#y}; echo \"$len_\"; }"
prop_sc9011_arrayLengthInit     = verifyCode checkSentinelLiteral 9011 "foo() { local arr=(a b); local n_=${#arr[@]}; echo \"$n_\"; }"

-- L. Negative -- explicit exclusions verified NOT unconditionally safe.
prop_sc9011_bgPidExcluded       = verifyNot checkSentinelLiteral "foo() { local pid_=$!; echo \"$pid_\"; }"
prop_sc9011_underscoreExcluded  = verifyNot checkSentinelLiteral "foo() { true; local last_=$_; echo \"$last_\"; }"
prop_sc9011_linenoExcluded      = verifyNot checkSentinelLiteral "foo() { local line_=$LINENO; echo \"$line_\"; }"

-- M. #87110 characterization -- broader arithmetic-write acceptance was
-- already correct (verified via AST dump: TA_Assignment's operator field
-- is wildcarded, and collectScope recurses unconditionally into nested
-- T_DollarArithmetic); these tests prove and document it, asserting the
-- specific target each shape fires on.
prop_sc9011_arithPlusEquals     = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; (( x_ += 1 )); echo \"$x_\"; }"
prop_sc9011_arithChainedFirst   = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; (( x_ = y = 1 )); echo \"$x_\"; }"
prop_sc9011_arithChainedSecond  = verifyCode checkSentinelLiteral 9011 "foo() { local y_=\"no\"; (( x = y_ = 1 )); echo \"$y_\"; }"
prop_sc9011_arithNestedSideEffect = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; y=$(( x_ = 1 )); echo \"$x_\"; }"

-- D. Negative -- escape/unknown-mutator disqualifier. mapfile targets
-- remain fully subsumed by this disqualifier. read/printf -v WITHOUT
-- the exact recognized shape (no here-string at all; format specifier +
-- extra arg) are the shape-boundary regression guard for #86907 --
-- these two MUST keep failing to fire, proving the new carve-out below
-- doesn't over-exempt.
prop_sc9011_customSetterEscape  = verifyNot checkSentinelLiteral "foo() { local x_=\"yes\"; mycustomsetter x_ \"\"; echo \"$x_\"; }"
prop_sc9011_readTarget          = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_; echo \"$x_\"; }"
prop_sc9011_printfVTarget       = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ '%s' \"$1\"; echo \"$x_\"; }"
prop_sc9011_mapfileTarget       = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; mapfile -t x_ <file; echo \"${x_[@]}\"; }"

-- N. #86907 positive -- read -r NAME <<< "literal" / printf -v NAME
-- "literal" are provably-safe writes when the literal clears every
-- guard (default fd, single line, default IFS, non-empty, IFS-free,
-- NUL-free, no leading hyphen for printf).
prop_sc9011_readHereStringLiteral   = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; read -r x_ <<< \"yes\"; echo \"$x_\"; }"
prop_sc9011_readHereStringTrimmed   = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; read -r x_ <<< \"  yes  \"; echo \"$x_\"; }"
prop_sc9011_readHereStringPrefix    = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; <<< \"yes\" read -r x_; echo \"$x_\"; }"
prop_sc9011_printfVLiteral          = verifyCode checkSentinelLiteral 9011 "foo() { local x_=\"no\"; printf -v x_ \"yes\"; echo \"$x_\"; }"

-- O. #86907 negative -- read/printf targets that match the recognized
-- SHAPE but fail the narrow literal-safety test, or that don't match
-- the shape at all. Every one of these must remain silent.
prop_sc9011_readHereStringIfsChar    = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ <<< \"a b\"; echo \"$x_\"; }"
prop_sc9011_readHereStringAllSpace   = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ <<< \"   \"; echo \"$x_\"; }"
prop_sc9011_readHereStringDynamic    = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ <<< \"$1\"; echo \"$x_\"; }"
prop_sc9011_readHereStringTwoTargets = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ y <<< \"a b\"; echo \"$x_\"; }"
prop_sc9011_readNoDashR              = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read x_ <<< \"yes\"; echo \"$x_\"; }"
prop_sc9011_readWrongFd              = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ 3<<< \"yes\"; echo \"$x_\"; }"
prop_sc9011_readExplicitFdZero       = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ 0<<< \"yes\"; echo \"$x_\"; }"
prop_sc9011_readEmbeddedNewline      = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ <<< $'\\nyes'; echo \"$x_\"; }"
prop_sc9011_readTwoHereStrings       = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ <<< \"a\" <<< \"b\"; echo \"$x_\"; }"
prop_sc9011_readIfsReassignedScope   = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; IFS=y read -r x_ <<< \"y\"; echo \"$x_\"; }"
prop_sc9011_readNulByte              = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ <<< $'\\0suffix'; echo \"$x_\"; }"
prop_sc9011_readProcessSubstitution  = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; read -r x_ < <(echo yes); echo \"$x_\"; }"
prop_sc9011_readShadowed             = verifyNot checkSentinelLiteral "read() { printf -v \"$2\" ''; } foo() { local x_=\"no\"; read -r x_ <<< \"yes\"; echo \"$x_\"; }"
prop_sc9011_printfVIfsChar           = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ \"a b\"; echo \"$x_\"; }"
prop_sc9011_printfVEmpty             = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ \"\"; echo \"$x_\"; }"
prop_sc9011_printfVBackslash         = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ \"a\\tb\"; echo \"$x_\"; }"
prop_sc9011_printfVPercent           = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ \"100%%\"; echo \"$x_\"; }"
prop_sc9011_printfVNulByte           = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ $'\\0suffix'; echo \"$x_\"; }"
prop_sc9011_printfVLeadingHyphen     = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ \"-x\"; echo \"$x_\"; }"
prop_sc9011_printfVDashDash          = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ \"--\"; echo \"$x_\"; }"
prop_sc9011_printfVDashV             = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ \"-v\"; echo \"$x_\"; }"
prop_sc9011_printfVShadowed          = verifyNot checkSentinelLiteral "printf() { builtin printf -v \"$3\" ''; } foo() { local x_=\"no\"; printf -v x_ \"yes\"; echo \"$x_\"; }"

-- P. #86907 -- dynamicEval must remain fully independent of the new
-- recognition: a recognized-safe write coexisting with eval in the same
-- scope must still disqualify the whole scope.
prop_sc9011_printfVWithEvalCoexist   = verifyNot checkSentinelLiteral "foo() { local x_=\"no\"; printf -v x_ \"yes\"; eval \"$1\"; echo \"$x_\"; }"

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
