--
-- Copyright (c) 2013 Bonelli Nicola <bonelli@antifork.org>
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
--
       
{-# LANGUAGE FlexibleContexts #-} 
{-# LANGUAGE ViewPatterns #-}

module CGrep.Common where
 
import qualified Data.ByteString.Char8 as C

import CGrep.Output
import CGrep.StringLike

import Text.Regex.Posix

import Options

spanGroup :: Int -> [a] -> [[a]]
spanGroup _ [] = []
spanGroup 1 xs = map (: []) xs
spanGroup n xs = take n xs : spanGroup n (tail xs)


spanMultiLine :: Int -> C.ByteString -> C.ByteString
spanMultiLine 1 xs = xs
spanMultiLine n xs = C.unlines $ map C.unwords $ spanGroup n (C.lines xs) 


basicGrep :: (StringLike a) => Options -> [a] -> (Int, a) -> [Match]
basicGrep opt patterns (n, line) = 
    if null pfilt then if (invert_match opt) then [ (n, map slToString patterns) ]
                                             else []
                  else if (invert_match opt) then [] 
                                             else [ (n, map slToString pfilt) ]
        where pfilt = slGrep (word_match opt) patterns line
 

basicRegex :: Options -> [C.ByteString] -> (Int, C.ByteString) -> [Match]
basicRegex opt patterns (n, line) = let out = filter (not . C.null) pfilt 
                                        in if null out then [] 
                                                       else [(n, map slToString out)]
    where pfilt = map (\p -> let  s = line =~ p :: C.ByteString in invertMatchString (invert_match opt) (p, s)) patterns 
          

invertMatchString :: Bool -> (C.ByteString, C.ByteString) -> C.ByteString
invertMatchString False (_, xs) = xs 
invertMatchString True  (p, C.uncons -> Nothing) =  p
invertMatchString True  (_, _) = C.empty


