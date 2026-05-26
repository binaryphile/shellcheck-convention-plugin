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
    fileHasIfsNoglobDiscipline
    ) where

import Data.Char (isAsciiUpper)
import Data.List (isSuffixOf, find)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map

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
