{-# LANGUAGE CPP #-}
-- | Need to prevent output to the terminal, a file, or stderr? Need to capture it and use it for
-- your own means? Now you can, with 'silence' and 'capture'.

module System.IO.Silently (
  silence, hSilence,
  capture, hCapture
) where

import Prelude hiding (catch)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO
import Control.Exception (bracket, catch)
import Control.DeepSeq
import System.Directory (removeFile,getTemporaryDirectory)

mNullDevice :: Maybe FilePath
#ifdef WINDOWS
mNullDevice = Just "NUL"
#elif UNIX
mNullDevice = Just "/dev/null"
#else
mNullDevice = Nothing
#endif

-- | Run an IO action while preventing all output to stdout.
silence :: IO a -> IO a
silence = hSilence [stdout]

-- | Run an IO action while preventing all output to the given handles.
hSilence :: [Handle] -> IO a -> IO a
hSilence handles action = case mNullDevice of
  Just nullDevice -> bracket (openFile nullDevice AppendMode)
                             hClose
                             prepareAndRun

  Nothing -> do
    tmpDir <- getTempOrCurrentDirectory
    bracket (openTempFile tmpDir "silence")
                               cleanup
                               (prepareAndRun . snd)

 where
  cleanup (tmpFile,tmpHandle) = do
    hClose tmpHandle
    removeFile tmpFile
  prepareAndRun tmpHandle = go handles
    where
      go [] = action
      go hs = goBracket go tmpHandle hs


getTempOrCurrentDirectory :: IO String
getTempOrCurrentDirectory = getTemporaryDirectory `catchIOError` (\_ -> return ".")
  where
    -- NOTE: We can not use `catchIOError` from "System.IO.Error", it is only
    -- availabel in base >= 4.4.
    catchIOError :: IO a -> (IOError -> IO a) -> IO a
    catchIOError = catch

-- | Run an IO action while preventing and capturing all output to stdout.
-- This will, as a side effect, create and delete a temp file in the temp directory or current directory if there is no temp directory.
capture :: IO a -> IO (String, a)
capture = hCapture [stdout]

-- | Run an IO action while preventing and capturing all output to the given handles.
-- This will, as a side effect, create and delete a temp file in the temp directory or current directory if there is no temp directory.
hCapture :: [Handle] -> IO a -> IO (String, a)
hCapture handles action = do
  tmpDir <- getTempOrCurrentDirectory
  bracket (openTempFile tmpDir "capture")
                             cleanup
                             (prepareAndRun . snd)
 where
  cleanup (tmpFile,tmpHandle) = do
    hClose tmpHandle
    removeFile tmpFile
  prepareAndRun tmpHandle = go handles
    where
      go [] = do
              a <- action
              mapM_ hFlush handles
              hSeek tmpHandle AbsoluteSeek 0
              str <- hGetContents tmpHandle
              str `deepseq` return (str,a)
      go hs = goBracket go tmpHandle hs

goBracket :: ([Handle] -> IO a) -> Handle -> [Handle] -> IO a
goBracket go tmpHandle (h:hs) = bracket (do old <- hDuplicate h
                                            hDuplicateTo tmpHandle h
                                            return old)
                                        (\old -> hDuplicateTo old h >> hClose old)
                                        (\_   -> go hs)
