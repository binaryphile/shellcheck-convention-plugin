{-
    IFS/noglob convention domain helpers.
    These are specific to the _ suffix taint-tracking naming convention.
    See docs/design.md section 3 for details.
-}
module Convention (
    hasTaintSuffix,
    hasListSuffix,
    hasListSuffixOnBare,
    stripTaintSuffix,
    fileHasIfsNoglobDiscipline,
    isIntegerTyped
    ) where

import Data.Char (isAsciiUpper)
import Data.Foldable (toList)
import Data.List (isPrefixOf, isSuffixOf, find)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map
import qualified Data.Set as Set

import ShellCheck.AST
import ShellCheck.ASTLib (getPath, getWordParts)

-- | True if the variable name ends in '_' and is longer than 1 character.
-- Excludes the special $_ variable (last argument of previous command).
hasTaintSuffix :: String -> Bool
hasTaintSuffix name = length name > 1 && last name == '_'

-- | Strip the trailing '_' from a taint-suffixed name.
stripTaintSuffix :: String -> String
stripTaintSuffix s
    | hasTaintSuffix s = init s
    | otherwise        = s

-- | True if the bare name (no taint suffix) ends in 'List' or 'List<X>'
-- where X is a single uppercase ASCII library suffix letter.
-- Examples: hostList (yes), hostListQ (yes), listItems (no), hostlist (no).
hasListSuffixOnBare :: String -> Bool
hasListSuffixOnBare name =
    "List" `isSuffixOf` name
    || (length name >= 5
        && isAsciiUpper (last name)
        && "List" `isSuffixOf` init name)

-- | True if the name (which must already have a taint suffix) also has
-- a List suffix. Strips '_' first and delegates to hasListSuffixOnBare.
hasListSuffix :: String -> Bool
hasListSuffix = hasListSuffixOnBare . stripTaintSuffix

-- | True iff the script enclosing the given token has IFS+noglob
-- discipline at top-level scope (UC-42 #17958). The predicate is
-- LATEST-EFFECTIVE over the DIRECT children of T_Script:
--
--   * IFS discipline: the last top-level T_Assignment to IFS sets
--     value to EXACTLY $'\n' (a single T_DollarSingleQuoted with
--     content "\\n" and no other components).
--   * noglob discipline: the last top-level invocation of `set` with
--     `-o noglob` (enable) or `+o noglob` (disable) is the enabling form.
--
-- Both required. Lexical/static — no source-following, no eval.
-- Direct children only — conditionals/loops/subshells/function-bodies
-- and command-prefix inline assignments do NOT count.
-- See docs/design.md §SC9010 for the full predicate definition.
fileHasIfsNoglobDiscipline :: Map.Map Id Token -> Token -> Bool
fileHasIfsNoglobDiscipline parents token =
    case findScriptRoot parents token of
        Just (T_Script _ _ stmts) ->
            ifsDisciplinePresent stmts && noglobDisciplinePresent stmts
        _ -> False

-- | Walk parent map from the given token to the enclosing T_Script.
findScriptRoot :: Map.Map Id Token -> Token -> Maybe Token
findScriptRoot parents token =
    find isScript (NE.toList (getPath parents token))
  where
    isScript T_Script{} = True
    isScript _          = False

-- | True iff the last T_Assignment whose lvalue is "IFS" among the
-- top-level statements' SimpleCommand assignment-prefixes sets the
-- value to exactly $'\n'. Each statement is unwrapped through
-- T_Pipeline / T_Redirecting / T_Annotation to reach the
-- T_SimpleCommand whose `assignments` field carries IFS=...
ifsDisciplinePresent :: [Token] -> Bool
ifsDisciplinePresent stmts =
    case foldl pickLast Nothing (concatMap topLevelIfsAssignments stmts) of
        Just value -> isCanonicalNewline value
        Nothing    -> False
  where
    pickLast _ value = Just value   -- last-wins (foldl iterates left-to-right)

-- | Extract IFS= assignment values from a top-level statement.
topLevelIfsAssignments :: Token -> [Token]
topLevelIfsAssignments stmt =
    [ value
    | T_SimpleCommand _ assigns _ <- [unwrapStatement stmt]
    , T_Assignment _ Assign "IFS" [] value <- assigns
    ]

-- | Drill through statement-wrapper nodes (Pipeline / Redirecting /
-- Annotation) to reach the T_SimpleCommand if any. Returns the
-- T_SimpleCommand or the original token if it isn't a simple command.
-- Does NOT descend into conditionals, loops, function bodies, etc.
-- (those return their own root, which won't match T_SimpleCommand).
unwrapStatement :: Token -> Token
unwrapStatement t = case t of
    T_Pipeline _ _ [single]   -> unwrapStatement single
    T_Redirecting _ _ inner   -> unwrapStatement inner
    T_Annotation _ _ inner    -> unwrapStatement inner
    _                         -> t

-- | True iff the token is exactly a single T_DollarSingleQuoted "\\n"
-- (i.e., bash $'\n' — newline-only ANSI-C quoted literal).
-- Uses getWordParts to unwrap T_NormalWord (the typical assignment-rhs
-- shape). Anything else (concatenation, multi-char, missing) → False.
isCanonicalNewline :: Token -> Bool
isCanonicalNewline t = case getWordParts t of
    [T_DollarSingleQuoted _ "\\n"] -> True
    _ -> False

-- | True iff the last top-level `set -o noglob` / `set +o noglob`
-- invocation enables noglob. Absent both → False. Walks through
-- statement-wrapper nodes via unwrapStatement.
noglobDisciplinePresent :: [Token] -> Bool
noglobDisciplinePresent stmts =
    case foldl pickLast Nothing (concatMap topLevelSetNoglob stmts) of
        Just enabled -> enabled
        Nothing      -> False
  where
    pickLast _ enabled = Just enabled

-- | Yields [True] for `set -o noglob`, [False] for `set +o noglob`,
-- otherwise []. Unwraps statement-wrappers first.
topLevelSetNoglob :: Token -> [Bool]
topLevelSetNoglob stmt =
    case unwrapStatement stmt of
        T_SimpleCommand _ _ words_ ->
            case map asLiteral words_ of
                Just "set" : Just flag : Just "noglob" : _
                    | flag == "-o" -> [True]
                    | flag == "+o" -> [False]
                _ -> []
        _ -> []

-- | Extract the literal string from a T_NormalWord [T_Literal] shape;
-- returns Nothing for anything more complex (expansions, multi-part words).
asLiteral :: Token -> Maybe String
asLiteral (T_NormalWord _ [T_Literal _ s]) = Just s
asLiteral _ = Nothing

-- | True iff @name@ has been declared with the bash integer attribute
-- (`-i` flag) via @local@, @declare@, @typeset@, or @readonly@ in the
-- scope enclosing @token@ (#36870). Used by SC9001 and SC9002 to suppress
-- IFS/cmdsub-taint nudges on `-i` typed variables: bash coerces every
-- assignment to an integer-typed variable to an integer (failed coercion
-- yields 0), so the IFS-splitting and newline-in-cmdsub hazards do not
-- apply.
--
-- Scope is the nearest enclosing T_Function body or T_Script (top level).
-- Nested function bodies and subshell-creating nodes do not contribute
-- declarations into the enclosing scope; conversely a declaration sitting
-- in the enclosing scope IS visible to subshells nested inside it (bash
-- subshells inherit parent variable attributes).
--
-- Recognised forms (`i` may be bundled with other flag chars; `-ir`, `-iA`,
-- etc. all qualify):
--
--   * @local -i NAME@                — bare declaration
--   * @declare -i NAME=VALUE@        — declaration with init
--   * @typeset -ir NAME@             — bundled flags
--   * @readonly -i NAME@             — readonly integer
isIntegerTyped :: Map.Map Id Token -> Token -> String -> Bool
isIntegerTyped parents token name =
    case findEnclosingVarScope parents token of
        Nothing    -> False
        Just scope -> name `Set.member` integerDeclaredInScope scope

-- | Walk parent map from @token@ to the nearest enclosing T_Function or
-- T_Script. Returns Nothing only if the parent chain terminates without
-- hitting one (defensive — every token in a parsed script is reachable
-- under T_Script).
findEnclosingVarScope :: Map.Map Id Token -> Token -> Maybe Token
findEnclosingVarScope parents token =
    find isVarScope (NE.toList (getPath parents token))
  where
    isVarScope T_Function{} = True
    isVarScope T_Script{}   = True
    isVarScope _            = False

-- | Names declared with the `-i` flag inside @scope@'s body, NOT
-- descending into nested function bodies or subshell-creating nodes.
integerDeclaredInScope :: Token -> Set.Set String
integerDeclaredInScope scope = Set.fromList (concatMap collect (scopeChildren scope))
  where
    collect t = concatMap declaredIntegerNames (flattenScope t)

    scopeChildren (T_Function _ _ _ _ body) = [body]
    scopeChildren (T_Script _ _ stmts)      = stmts
    scopeChildren _                         = []

-- | Walk @t@ collecting every sub-token, stopping at nodes that open a
-- new variable scope (nested functions) or subshell isolation. Mirrors
-- the scope-boundary discipline used by NilAvoidance.collectScope.
flattenScope :: Token -> [Token]
flattenScope t@(OuterToken _ inner) = case t of
    T_Function {}        -> [t]
    T_Subshell {}        -> [t]
    T_DollarExpansion {} -> [t]
    T_ProcSub {}         -> [t]
    T_Backticked {}      -> [t]
    T_CoProc {}          -> [t]
    T_CoProcBody {}      -> [t]
    _                    -> t : concatMap flattenScope (toList inner)

-- | If @t@ is a @local@/@declare@/@typeset@/@readonly@ invocation with
-- a flag bundle containing 'i', yield every var name it declares. Names
-- come from either inline assignments (T_Assignment) or bare-name args
-- (T_NormalWord [T_Literal]). Dash-prefixed args (flags) are excluded.
declaredIntegerNames :: Token -> [String]
declaredIntegerNames
    (T_SimpleCommand _ _ (T_NormalWord _ (T_Literal _ cmd : _) : args))
    | cmd `elem` ["local", "declare", "typeset", "readonly"]
    , hasIntegerFlag args
    = concatMap argName args
  where
    argName (T_Assignment _ _ n _ _)
        | not (null n), not ("-" `isPrefixOf` n) = [n]
    argName (T_NormalWord _ [T_Literal _ n])
        | not (null n), not ("-" `isPrefixOf` n) = [n]
    argName _ = []
declaredIntegerNames _ = []

-- | True if any arg is a bundled flag-token (`-` prefix, length ≥ 2)
-- whose flag chars include 'i'. Single `-` is not a flag bundle (it's
-- a positional placeholder).
hasIntegerFlag :: [Token] -> Bool
hasIntegerFlag = any go
  where
    go (T_NormalWord _ [T_Literal _ ('-':rest@(_:_))]) = 'i' `elem` rest
    go _ = False
