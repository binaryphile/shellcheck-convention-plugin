{-
    IFS/noglob convention domain helpers.
    These are specific to the _ suffix taint-tracking naming convention.
    See docs/design.md section 3 for details.
-}
module Convention (
    hasTaintSuffix,
    hasListSuffix,
    hasListSuffixOnBare,
    stripTaintSuffix
    ) where

import Data.Char (isAsciiUpper)
import Data.List (isSuffixOf)

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
