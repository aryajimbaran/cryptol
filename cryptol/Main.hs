-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2014 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main where

import OptParser
import CodeGen
import REPL.Command (loadCmd,loadPrelude)
import REPL.Haskeline
import REPL.Monad (REPL,setREPLTitle,io,DotCryptol(..))
import REPL.Logo
import qualified REPL.Monad as REPL
import Paths_cryptol (version)

import Cryptol.Version (commitHash, commitBranch, commitDirty)
import Data.Version (showVersion)
import Cryptol.Utils.PP(pp)
import Cryptol.ModuleSystem (loadModuleByPath)
import Data.List (intercalate)
import Data.String (fromString)
import Data.Monoid (mconcat)
import System.Environment (getArgs,getProgName)
import System.Exit (exitFailure)
import System.IO (hPrint, hPutStrLn, stderr)
import System.Console.GetOpt
    (OptDescr(..),ArgOrder(..),ArgDescr(..),getOpt,usageInfo)

data Options = Options
  { optLoad       :: [FilePath]
  , optVersion    :: Bool
  , optHelp       :: Bool
  , optBatch      :: Maybe FilePath
  , optDotCryptol :: DotCryptol
  , optDirectory      :: Maybe FilePath
  , optGenerationRoot :: Maybe GenerationRoot
  , optTarget  :: GenerationTarget
  } deriving (Show)

defaultOptions :: Options
defaultOptions  = Options
  { optLoad       = []
  , optVersion    = False
  , optHelp       = False
  , optBatch      = Nothing
  , optDotCryptol = DotCDefault
  , optDirectory      = Nothing
  , optGenerationRoot = Nothing
  , optTarget         = SBVC
  }

options :: [OptDescr (OptParser Options)]
options  =
  [ Option "b" ["batch"] (ReqArg setBatchScript "FILE")
    "run the script provided and exit"

  , Option "v" ["version"] (NoArg setVersion)
    "display version number"

  , Option "h" ["help"] (NoArg setHelp)
    "display this message"

  , Option ""  ["ignore-dot-cryptol"] (NoArg setDotCDisabled)
    "disable reading of .cryptol files"

  , Option ""  ["cryptol-script"] (ReqArg addDotC "FILE")
    "read additional .cryptol files"

  , Option "o" ["output-dir"] (ReqArg setDirectory "DIR")
    "output directory for code generation (default stdout)"

  , Option ""  ["root"] (ReqArg setGenerationRoot "UNIT")
    "generate code for the specified identifier, module, file, or directory"

  , Option "t" ["target"] (ReqArg setTarget "BACKEND")
    "code generation backend (default SBV-C)"
  ]

-- | Set a single file to be loaded.  This should be extended in the future, if
-- we ever plan to allow multiple files to be loaded at the same time.
addFile :: String -> OptParser Options
addFile path = modify $ \ opts -> opts { optLoad = [ path ] }

-- | Set a batch script to be run.
setBatchScript :: String -> OptParser Options
setBatchScript path = modify $ \ opts -> opts { optBatch = Just path }

-- | Signal that version should be displayed.
setVersion :: OptParser Options
setVersion  = modify $ \ opts -> opts { optVersion = True }

-- | Signal that help should be displayed.
setHelp :: OptParser Options
setHelp  = modify $ \ opts -> opts { optHelp = True }

-- | Disable .cryptol files entirely
setDotCDisabled :: OptParser Options
setDotCDisabled  = modify $ \ opts -> opts { optDotCryptol = DotCDisabled }

-- | Add another file to read as a .cryptol file, unless .cryptol
-- files have been disabled
addDotC :: String -> OptParser Options
addDotC path = modify $ \ opts ->
  case optDotCryptol opts of
    DotCDefault  -> opts { optDotCryptol = DotCFiles [path] }
    DotCDisabled -> opts
    DotCFiles xs -> opts { optDotCryptol = DotCFiles (path:xs) }

-- | Choose an output directory.
setDirectory :: FilePath -> OptParser Options
setDirectory path = modify $ \opts -> opts { optDirectory = Just path }

-- | Choose a unit for code generation. Heuristic: it's always an identifier.
-- This also signals that code generation should be performed instead of
-- dropping into the REPL.
-- XXX Use a better heuristic.
setGenerationRoot :: String -> OptParser Options
setGenerationRoot id = modify $ \opts -> opts { optGenerationRoot = Just (Identifier id) }

-- | Check whether code-generation mode was requested.
hasRoot :: Options -> Bool
hasRoot Options { optGenerationRoot = Just _ } = True
hasRoot _ = False

-- | Choose a code generation target.
setTarget target = case fromString target of
  Just t  -> modify $ \opts -> opts { optTarget = t }
  Nothing -> report $ "Unknown backend " ++ target ++
                      ". Choices are " ++ intercalate ", " knownTargets

-- | Parse arguments.
parseArgs :: [String] -> Either [String] Options
parseArgs args = case getOpt (ReturnInOrder addFile) options args of
  (ps,[],[]) -> runOptParser defaultOptions (mconcat ps)
  (_,_,errs) -> Left errs

displayVersion :: IO ()
displayVersion = do
    let ver = showVersion version
    putStrLn ("Cryptol " ++ ver)
    putStrLn ("Git commit " ++ commitHash)
    putStrLn ("    branch " ++ commitBranch ++ dirtyLab)
      where
      dirtyLab | commitDirty = " (non-committed files present during build)"
               | otherwise   = ""

displayHelp :: [String] -> IO ()
displayHelp errs = do
  prog <- getProgName
  let banner = "Usage: " ++ prog ++ " [OPTIONS]"
  putStrLn (usageInfo (unlines errs ++ banner) options)

main :: IO ()
main  = do
  args <- getArgs
  case parseArgs args of

    Left errs -> do
      displayHelp errs
      exitFailure

    Right opts
      | optHelp opts    -> displayHelp []
      | optVersion opts -> displayVersion
      | hasRoot opts    -> codeGenFromOpts opts
      | otherwise       -> repl (optDotCryptol opts)
                                (optBatch opts)
                                (setupREPL opts)

-- | Precondition: the generation root must be 'Just'.
codeGenFromOpts :: Options -> IO ()
codeGenFromOpts Options
  { optGenerationRoot = Just root
  , optDirectory      = outDir
  , optTarget         = impl
  , optLoad           = inFiles
  } = case inFiles of
  [f] -> loadModuleByPath f >>= either (hPrint stderr . pp) (codeGen outDir root impl) . fst
  _   -> hPutStrLn stderr "Must specify exactly one file to load."

setupREPL :: Options -> REPL ()
setupREPL opts = do
  displayLogo True
  setREPLTitle
  case optLoad opts of
    []  -> loadPrelude `REPL.catch` \x -> io $ print $ pp x
    [l] -> loadCmd l `REPL.catch` \x -> io $ print $ pp x
    _   -> io $ putStrLn "Only one file may be loaded at the command line."
