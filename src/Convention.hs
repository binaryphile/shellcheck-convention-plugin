{-
    IFS/noglob convention domain helpers.
    These are specific to the _ suffix taint-tracking naming convention.
    See docs/design.md section 3 for details.
-}
module Convention (
    hasTaintSuffix,
    hasListSuffix,
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

-- | True if the name (which must already have a taint suffix) also has a List suffix.
-- Handles optional single-uppercase library suffix letter between "List" and "_".
-- Examples: hostList_ (yes), hostListQ_ (yes), listItems_ (no), hostlist_ (no).
hasListSuffix :: String -> Bool
hasListSuffix name =
    let base = stripTaintSuffix name
    in "List" `isSuffixOf` base
       || (length base >= 5
           && isAsciiUpper (last base)
           && "List" `isSuffixOf` init base)
