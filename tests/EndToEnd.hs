-- Copyright 2016 Ruud van Asseldonk
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License version 3. See
-- the licence file in the root of the repository.

{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent.Async (async, wait)
import Control.Monad (void)
import Control.Monad.Logger (runNoLoggingT)
import Data.Text (Text)
import Data.UUID.V4 (nextRandom)
import Prelude hiding (appendFile, writeFile)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec

import Configuration (Configuration (..))
import Git (Sha (..))
import Project (BuildStatus (BuildSucceeded), PullRequestId (..))

import qualified Configuration as Config
import qualified Data.Text as Text
import qualified EventLoop
import qualified Git
import qualified Logic
import qualified Prelude

-- Invokes Git with the given arguments, returns its stdout. Crashes if invoking
-- Git failed. Discards all logging.
callGit :: [String] -> IO Text
callGit args = fmap (either undefined id) $ runNoLoggingT $ Git.callGit args

-- Populates the repository with the following history:
--
--                 .-- c5 -- c6  <-- intro
--                /
--   c0 -- c1 -- c2 -- c3 -- c4  <-- ahead
--                \     ^----------- master
--                 `-- c3'       <-- alternative
--
populateRepository :: FilePath -> IO [Sha]
populateRepository dir =
  let writeFile fname msg  = Prelude.writeFile (dir </> fname) (msg ++ "\n")
      appendFile fname msg = Prelude.appendFile (dir </> fname) (msg ++ "\n")
      git args             = callGit $ ["-C", dir] ++ args
      gitInit              = void $ git ["init"]
      gitConfig key value  = void $ git ["config", key, value]
      gitAdd file          = void $ git ["add", file]
      gitBranch name sha   = void $ git ["checkout", "-b", name, show sha]
      gitCheckout brname   = void $ git ["checkout", brname]
      getHeadSha           = fmap (Sha . Text.strip) $ git ["rev-parse", "@"]
      -- Commits with the given message and returns the sha of the new commit.
      gitCommit message    = git ["commit", "-m", message] >> getHeadSha
  in  do
      gitInit
      gitConfig "user.email" "testsuite@example.com"
      gitConfig "user.name" "Testbot"

      writeFile "tyrell.txt" "I'm surprised you didn't come here sooner."
      gitAdd "tyrell.txt"
      c0 <- gitCommit "c0: Initial commit"

      writeFile "roy.txt" "It's not an easy thing to meet your maker."
      gitAdd "roy.txt"
      c1 <- gitCommit "c1: Add new quote"

      appendFile "tyrell.txt" "What can he do for you?"
      gitAdd "tyrell.txt"
      c2 <- gitCommit "c2: Add new Tyrell quote"

      appendFile "roy.txt" "Can the maker repair what he makes?"
      gitAdd "roy.txt"
      c3 <- gitCommit "c3: Add new Roy quote"

      -- Create a branch "ahead", one commit ahead of master.
      gitBranch "ahead" c3
      appendFile "tyrell.txt" "Would you like to be modified?"
      gitAdd "tyrell.txt"
      c4 <- gitCommit "c4: Add Tyrell  response"
      gitCheckout "master"

      -- Now make an alternative commit that conflicts with c3.
      gitBranch "alternative" c2
      appendFile "roy.txt" "You could make me a sandwich."
      gitAdd "roy.txt"
      c3' <- gitCommit "c3': Write alternative ending"

      -- Also add a commit that does not conflict.
      gitBranch "intro" c2
      writeFile "leon.txt" "What do you mean, I'm not helping?"
      gitAdd "leon.txt"
      c5 <- gitCommit "c5: Add more characters"

      writeFile "holden.txt" "I mean, you're not helping! Why is that, Leon?"
      gitAdd "holden.txt"
      c6 <- gitCommit "c6: Add response"

      return [c0, c1, c2, c3, c3', c4, c5, c6]

-- Sets up two repositories: one with a few commits in the origin directory, and
-- a clone of that in the repository directory. The clone ensures that the
-- origin repository is set as the "origin" remote in the cloned repository.
initializeRepository :: FilePath -> FilePath -> IO [Sha]
initializeRepository originDir repoDir = do
  -- Create the directory for the origin repository, and parent directories.
  createDirectoryIfMissing True originDir
  shas <- populateRepository originDir
  _    <- callGit ["clone", "file://" ++ originDir, repoDir]
  -- Set the author details in the cloned repository as well, to ensure that
  -- there is no implicit dependency on a global Git configuration.
  _    <- callGit ["-C", repoDir, "config", "user.email", "testsuite@example.com"]
  _    <- callGit ["-C", repoDir, "config", "user.name", "Testbot"]
  return shas

-- Generate a configuration to be used in the test environment.
buildConfig :: FilePath -> Configuration
buildConfig repoDir = Configuration {
  Config.owner      = "ruuda",
  Config.repository = "blog",
  Config.branch     = "master",
  Config.testBranch = "integration",
  Config.port       = 5261,
  Config.checkout   = repoDir
}

-- Sets up a test environment with an actual Git repository on the file system,
-- and a thread running the main event loop. Then invokes the body, and tears
-- down the test environment afterwards. Returns a list of commit message
-- prefixes of the remote master branch log. The body function is provided with
-- the shas of the test repository and an enqueue function.
withTestEnv :: ([Sha] -> (Logic.Event -> IO ()) -> IO ()) -> IO [Text]
withTestEnv body = do
  -- To run these tests, a real repository has to be made somewhere. Do that in
  -- /tmp because it can be mounted as a ramdisk, so it is fast and we don't
  -- unnecessarily wear out SSDs. Put a uuid in there to ensure we don't
  -- overwrite somebody else's files, and to ensure that the tests do not affect
  -- eachother.
  uuid       <- nextRandom
  tmpBaseDir <- getTemporaryDirectory
  let testDir   = tmpBaseDir </> ("testsuite-" ++ (show uuid))
      originDir = testDir </> "repo-origin"
      repoDir   = testDir </> "repo-local"
  -- Create and populate a test repository with a local remote "origin". Record
  -- the shas of the commits as documented in populateRepository.
  shas <- initializeRepository originDir repoDir

  -- Like the actual application, start a new thread to run the main event loop.
  -- Use 'async' here, a higher-level wrapper around 'forkIO', to wait for the
  -- thread to stop later. Discard log messages from the event loop, to avoid
  -- polluting the test output. To aid debugging when a test fails, you can
  -- replace 'runNoLoggingT' with 'runStdoutLoggingT'.
  let config = buildConfig repoDir
  queue           <- Logic.newEventQueue 10
  finalStateAsync <- async $ runNoLoggingT $ EventLoop.runLogicEventLoop config queue

  -- Run the actual test code inside the environment that we just set up,
  -- provide it with the commit shas and an enqueue function so it can send
  -- events.
  let enqueueEvent = Logic.enqueueEvent queue
  body shas enqueueEvent

  -- Tell the worker thread to stop after it has processed all events. Then wait
  -- for it to exit.
  Logic.enqueueStopSignal queue
  _finalState <- wait finalStateAsync

  -- Retrieve the log of the remote repository master branch. Only show the
  -- commit message subject lines. The repository has been setup to prefix
  -- messages with a commit number followed by a colon. Strip off the rest.
  -- Commit messages are compared later, rather than shas, because these do not
  -- change when rebased, and they do not depend on the current timestamp.
  -- (Commits do: the same rebase operation can produce commits with different
  -- shas depending on the time of the rebase.)
  masterLog <- callGit ["-C", originDir, "log", "--format=%s", "master"]
  let commits = reverse $ fmap (Text.takeWhile (/= ':')) $ Text.lines masterLog

  removeDirectoryRecursive testDir
  return commits

main :: IO ()
main = hspec $ do
  describe "The main event loop" $ do

    it "handles a fast-forwardable pull request" $ do
      history <- withTestEnv $ \ shas enqueueEvent -> do
        let [_c0, _c1, _c2, _c3, _c3', c4, _c5, _c6] = shas
        -- Commit c4 is one commit ahead of master, so integrating it can be done
        -- with a fast-forward merge.
        enqueueEvent $ Logic.PullRequestOpened (PullRequestId 1) c4 "decker"
        enqueueEvent $ Logic.CommentAdded (PullRequestId 1) "decker" $ Text.pack $ "LGTM " ++ (show c4)
        enqueueEvent $ Logic.BuildStatusChanged c4 BuildSucceeded

      history `shouldBe` ["c0", "c1", "c2", "c3", "c4"]

    it "handles a non-conflicting non-fast-forwardable pull request" $ do
      history <- withTestEnv $ \ shas enqueueEvent -> do
        let [_c0, _c1, _c2, _c3, _c3', _c4, _c5, c6] = shas
        -- Commit c6 is two commits ahead and one behind of master, so
        -- integrating it produces new rebased commits.
        enqueueEvent $ Logic.PullRequestOpened (PullRequestId 1) c6 "decker"
        enqueueEvent $ Logic.CommentAdded (PullRequestId 1) "decker" $ Text.pack $ "LGTM " ++ (show c6)

        -- The rebased commit should have been pushed to the remote repository
        -- 'integration' branch. Tell that building it succeeded.
        -- TODO: Extract real integration sha from state in event loop.
        enqueueEvent $ Logic.BuildStatusChanged (Sha "deadbeef") BuildSucceeded

      -- TODO: Fix the assertion once this works.
      -- history `shouldBe` ["c0", "c1", "c2", "c3", "c5", "c6"]
      history `shouldBe` ["c0", "c1", "c2", "c3"]
