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

module Main where

import Data.List
import Data.List.Split
import Data.Maybe
import Data.Char
import Data.Data()
import Data.Function
import qualified Data.Set as Set

import Control.Exception as E
import Control.Concurrent
import Control.Concurrent.Async
import Control.Monad.STM
import Control.Concurrent.STM.TChan

import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Either
import Control.Applicative

import System.Console.CmdArgs
import System.Directory
import System.FilePath ((</>), takeFileName)
import System.Environment
import System.PosixCompat.Files
import System.IO
import System.Exit

import CGrep.CGrep
import CGrep.Lang
import CGrep.Output
import CGrep.Common

import CmdOptions
import Options
import Util
import Debug
import Config

import qualified Data.ByteString.Char8 as C


-- push file names in Chan...

withRecursiveContents :: Options -> FilePath -> [Lang] -> [String] -> Set.Set FilePath -> ([FilePath] -> IO ()) -> IO ()
withRecursiveContents opts dir langs prunedir visited action = do
    isDir <-  doesDirectoryExist dir
    if isDir then do
               xs <- getDirectoryContents dir
               (dirs,files) <- partitionM doesDirectoryExist [dir </> x | x <- xs, x `notElem` [".", ".."]]
               -- process files
               let files' = mapMaybe
                                (\n -> let filename = takeFileName n
                                       in if isNothing $ getFileLang opts filename >>= (\f -> f `elemIndex` langs <|> toMaybe 0 (null langs))
                                            then Nothing
                                            else Just n) files

               unless (null files') $
                    let chunks = chunksOf (Options.chunk opts) files' in
                    forM_ chunks $ \b -> action b

               -- process dirs
               --
               forM_ dirs $ \path -> do
                    let filename = takeFileName path
                    lstatus <- getSymbolicLinkStatus path
                    when ( deference_recursive opts || not (isSymbolicLink lstatus)) $
                        unless (filename `elem` prunedir) $ do -- this is a good directory (unless already visited)!
                            cpath <- canonicalizePath path
                            unless (cpath `Set.member` visited) $ withRecursiveContents opts path langs prunedir (Set.insert cpath visited) action
             else action [dir]


-- read patterns from file

readPatternsFromFile :: FilePath -> IO [C.ByteString]
readPatternsFromFile f =
    if null f then return []
              else liftM (map trim8 . C.lines) $ C.readFile f

getFilePaths :: Bool        ->     -- pattern(s) from file
                Bool        ->     -- is terminal (no from STDIN)
                [String]    ->     -- list of patterns and files
                [String]

getFilePaths False True xs = if length xs == 1 then [ ] else tail xs
getFilePaths True  True xs = xs
getFilePaths _ False _ = [ ]


parallelSearch :: Config -> Options -> [FilePath] -> [C.ByteString] -> [Lang] -> (Bool, Bool) -> IO ()
parallelSearch conf opts paths patterns langs (isTermIn, _) = do

    -- create Transactional Chan and Vars...

    in_chan  <- newTChanIO
    out_chan <- newTChanIO

    -- launch worker threads...

    forM_ [1 .. jobs opts] $ \_ -> forkIO $
        void $ runEitherT $ forever $ do
            fs <- lift $ atomically $ readTChan in_chan
            lift $ E.catch (case fs of
                    [] -> atomically $ writeTChan out_chan []
                    xs -> void ((if asynch opts then flip mapConcurrently
                                                else forM) xs $ \x -> do
                            out <- let op = sanitizeOptions x opts in (liftM (take (max_count opts)) $ cgrepDispatch op x op patterns x)
                            unless (null out) $ atomically $ writeTChan out_chan out)
                   )
                   (\e -> let msg = show (e :: SomeException) in hPutStrLn stderr (showFile opts (getTargetName (head fs)) ++ ": exception: " ++ if length msg > 80 then take 80 msg ++ "..." else msg))
            when (null fs) $ left ()


    -- push the files to grep for...

    _ <- forkIO $ do

        if recursive opts || deference_recursive opts
            then forM_ (if null paths then ["."] else paths) $ \p -> withRecursiveContents opts p langs (configPruneDirs conf) (Set.singleton p) (atomically . writeTChan in_chan)
            else forM_ (if null paths && not isTermIn then [""] else paths) (atomically . writeTChan in_chan . (:[]))

        -- enqueue EOF messages:

        replicateM_ (jobs opts) ((atomically . writeTChan in_chan) [])

    -- dump output until workers are done

    putPrettyHeader opts

    let stop = jobs opts

    fix (\action n m ->
         unless (n == stop) $ do
                 out <- atomically $ readTChan out_chan
                 case out of
                      [] -> action (n+1) m
                      _  -> do
                          case () of
                            _ | json opts -> when m $ putStrLn ","
                              | otherwise -> return ()
                          prettyOutput opts out >>= mapM_ putStrLn
                          action n True
        )  0 False

    putPrettyFooter opts

main :: IO ()
main = do

    -- check whether this is a terminal device

    isTermIn  <- hIsTerminalDevice stdin
    isTermOut <- hIsTerminalDevice stdout

    -- read Cgrep config options

    conf  <- getConfig

    -- read command-line options

    opts  <- (if isTermOut then (\o@Options{color = c} -> o { color = c || configAutoColor conf})
                           else id) <$> cmdArgsRun options

    -- check for multiple backends...

    when (length (catMaybes [
#ifdef ENABLE_HINT
                hint opts,
#endif
                format opts,
                if xml opts  then Just "" else Nothing,
                if json opts then Just "" else Nothing
               ]) > 1)
        $ error "you can use one back-end at time!"


    -- display lang-map and exit...

    when (lang_maps opts) $ dumpLangMap langMap >> exitSuccess

    -- check whether patterns list is empty, display help message if it's the case

    when (null (others opts) && (isTermIn && null (file opts))) $ withArgs ["--help"] $ void (cmdArgsRun options)

    -- load patterns:

    patterns <- if null (file opts) then return $ (if isTermIn then (:[]) . head else id) $ map C.pack (others opts)
                                    else readPatternsFromFile $ file opts

    let patterns' = map (if ignore_case opts then C.map toLower else id) patterns

    -- load files to parse:

    let paths = getFilePaths (not $ null (file opts)) isTermIn (others opts)

    -- parse cmd line language list:

    let (l0, l1, l2) = splitLangList (lang opts)

    -- language enabled:

    let langs = (if null l0 then configLanguages conf else l0 `union` l1) \\ l2

    putStrLevel1 (debug opts) $ "Cgrep " ++ version ++ "!"
    putStrLevel1 (debug opts) $ "options   : " ++ show opts
    putStrLevel1 (debug opts) $ "languages : " ++ show langs
    putStrLevel1 (debug opts) $ "pattern   : " ++ show patterns
    putStrLevel1 (debug opts) $ "files     : " ++ show paths
    putStrLevel1 (debug opts) $ "isTermIn  : " ++ show isTermIn
    putStrLevel1 (debug opts) $ "isTermOut : " ++ show isTermOut

    -- specify number of cores

    when (cores opts /= 0) $ setNumCapabilities (cores opts)

    parallelSearch conf opts paths patterns' langs (isTermIn, isTermOut)

