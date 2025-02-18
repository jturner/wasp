module Wasp.Generator.NpmInstall
  ( installProjectNpmDependencies,
    installNpmDependenciesWithInstallRecord,
  )
where

import Control.Concurrent (Chan, newChan, readChan, threadDelay, writeChan)
import Control.Concurrent.Async (concurrently)
import Control.Monad.Except (MonadError (throwError), runExceptT, when)
import Control.Monad.IO.Class (liftIO)
import Data.Function ((&))
import Data.Functor ((<&>))
import qualified Data.Text as T
import StrongPath (Abs, Dir, Path')
import qualified StrongPath as SP
import System.Exit (ExitCode (..))
import UnliftIO (race)
import Wasp.AppSpec (AppSpec (waspProjectDir))
import Wasp.Generator.Common (ProjectRootDir)
import Wasp.Generator.Job (Job, JobMessage, JobType)
import qualified Wasp.Generator.Job as J
import Wasp.Generator.Job.IO.PrefixedWriter (PrefixedWriter, printJobMessagePrefixed, runPrefixedWriter)
import Wasp.Generator.Monad (GeneratorError (..))
import Wasp.Generator.NpmInstall.Common (AllNpmDeps (..), getAllNpmDeps)
import Wasp.Generator.NpmInstall.InstalledNpmDepsLog (forgetInstalledNpmDepsLog, loadInstalledNpmDepsLog, saveInstalledNpmDepsLog)
import qualified Wasp.Generator.SdkGenerator as SdkGenerator
import qualified Wasp.Generator.ServerGenerator.Setup as ServerSetup
import qualified Wasp.Generator.WebAppGenerator.Setup as WebAppSetup
import Wasp.Project.Common (WaspProjectDir, nodeModulesDirInWaspProjectDir)
import qualified Wasp.Util.IO as IOUitl

-- Runs `npm install` for:
--   1. User's Wasp project (based on their package.json): user deps.
--   2. Wasp's generated webapp project: wasp deps.
--   3. Wasp's generated server project: wasp deps.
-- (1) runs first, (2) and (3) run concurrently after it.
-- It collects the output produced by these commands to pass them along to IO with a prefix.
installNpmDependenciesWithInstallRecord ::
  AppSpec ->
  Path' Abs (Dir ProjectRootDir) ->
  IO (Either GeneratorError ())
installNpmDependenciesWithInstallRecord spec dstDir = runExceptT $ do
  messagesChan <- liftIO newChan

  allNpmDeps <- getAllNpmDeps spec & onLeftThrowError

  shouldInstallNpmDeps <-
    liftIO $
      or
        <$> sequence
          [ -- Users might by accident delete node_modules dir, so we check if it exists
            -- before assuming that we don't need to install npm deps.
            not <$> doesNodeModulesDirExist waspProjectDirPath,
            areThereNpmDepsToInstall allNpmDeps dstDir
          ]

  when shouldInstallNpmDeps $ do
    -- In case anything fails during installation that would leave node modules in
    -- a broken state, we remove the log of installed npm deps before we start npm install.
    liftIO $ forgetInstalledNpmDepsLog dstDir

    liftIO (installProjectNpmDependencies messagesChan waspProjectDirPath)
      >>= onLeftThrowError

    liftIO (installWebAppAndServerNpmDependencies messagesChan dstDir)
      >>= onLeftThrowError

    liftIO $ saveInstalledNpmDepsLog allNpmDeps dstDir
  where
    onLeftThrowError =
      either (\e -> throwError $ GenericGeneratorError $ "npm install failed: " ++ e) pure

    waspProjectDirPath = waspProjectDir spec

-- Installs npm dependencies from the user's package.json, by running `npm install` .
installProjectNpmDependencies ::
  Chan JobMessage -> SP.Path SP.System Abs (Dir WaspProjectDir) -> IO (Either String ())
installProjectNpmDependencies messagesChan projectDir =
  handleProjectInstallMessages messagesChan `concurrently` installProjectDepsJob
    <&> snd
    <&> \case
      ExitFailure code -> Left $ "Project setup failed with exit code " ++ show code ++ "."
      _success -> Right ()
  where
    installProjectDepsJob =
      installNpmDependenciesAndReport (SdkGenerator.installNpmDependencies projectDir) messagesChan J.Wasp
    handleProjectInstallMessages :: Chan J.JobMessage -> IO ()
    handleProjectInstallMessages = runPrefixedWriter . processMessages
      where
        processMessages :: Chan J.JobMessage -> PrefixedWriter ()
        processMessages chan = do
          jobMsg <- liftIO $ readChan chan
          case J._data jobMsg of
            J.JobOutput {} -> printJobMessagePrefixed jobMsg >> processMessages chan
            J.JobExit {} -> return ()

-- Install npm dependencies for the Wasp's generated webapp and server projects.
installWebAppAndServerNpmDependencies ::
  Chan JobMessage -> SP.Path SP.System Abs (Dir ProjectRootDir) -> IO (Either String ())
installWebAppAndServerNpmDependencies messagesChan dstDir =
  handleSetupJobsMessages messagesChan
    `concurrently` (installServerDepsJob `concurrently` installWebAppDepsJob)
    <&> snd
    <&> \case
      (ExitSuccess, ExitSuccess) -> Right ()
      exitCodes -> Left $ setupFailedMessage exitCodes
  where
    installServerDepsJob = installNpmDependenciesAndReport (ServerSetup.installNpmDependencies dstDir) messagesChan J.Server
    installWebAppDepsJob = installNpmDependenciesAndReport (WebAppSetup.installNpmDependencies dstDir) messagesChan J.WebApp

    handleSetupJobsMessages = runPrefixedWriter . processMessages (False, False)
      where
        processMessages :: (Bool, Bool) -> Chan J.JobMessage -> PrefixedWriter ()
        processMessages (True, True) _ = return ()
        processMessages (isWebAppDone, isServerDone) chan = do
          jobMsg <- liftIO $ readChan chan
          case J._data jobMsg of
            J.JobOutput {} ->
              printJobMessagePrefixed jobMsg
                >> processMessages (isWebAppDone, isServerDone) chan
            J.JobExit {} -> case J._jobType jobMsg of
              J.WebApp -> processMessages (True, isServerDone) chan
              J.Server -> processMessages (isWebAppDone, True) chan
              J.Db -> error "This should never happen. No Db job should be active."
              J.Wasp -> error "This should never happen. No Wasp job should be active."

    setupFailedMessage (serverExitCode, webAppExitCode) =
      let serverErrorMessage = case serverExitCode of
            ExitFailure code -> " Server setup failed with exit code " ++ show code ++ "."
            _success -> ""
          webAppErrorMessage = case webAppExitCode of
            ExitFailure code -> " Web app setup failed with exit code " ++ show code ++ "."
            _success -> ""
       in "Setup failed!" ++ serverErrorMessage ++ webAppErrorMessage

installNpmDependenciesAndReport :: Job -> Chan JobMessage -> JobType -> IO ExitCode
installNpmDependenciesAndReport installJob chan jobType = do
  writeChan chan $ J.JobMessage {J._data = J.JobOutput "Starting npm install\n" J.Stdout, J._jobType = jobType}
  result <- installJob chan `race` reportInstallationProgress chan jobType
  case result of
    Left exitCode -> return exitCode
    Right _ -> error "This should never happen, reporting installation progress should run forever."

reportInstallationProgress :: Chan JobMessage -> JobType -> IO ()
reportInstallationProgress chan jobType = reportPeriodically allPossibleMessages
  where
    reportPeriodically messages = do
      threadDelay $ secToMicroSec 5
      writeChan chan $ J.JobMessage {J._data = J.JobOutput (T.append (head messages) "\n") J.Stdout, J._jobType = jobType}
      threadDelay $ secToMicroSec 5
      reportPeriodically $ drop 1 messages
    secToMicroSec = (* 1000000)
    allPossibleMessages =
      cycle $
        [ "Still installing npm dependencies!",
          "Installation going great - we'll get there soon!",
          "The installation is taking a while, but we'll get there!",
          "Yup, still not done installing.",
          "We're getting closer and closer, everything will be installed soon!",
          "Still waiting for the installation to finish? You should! We got too far to give up now!",
          "You've been waiting so patiently, just wait a little longer (for the installation to finish)..."
        ]

-- | Figure out if installation of npm deps is needed, be it for user npm deps (top level
-- package.json), for wasp framework npm deps (web app, server), or for wasp sdk npm deps.
--
-- To this end, this code keeps track of the dependencies installed with a metadata file, which
-- it updates after each install.
--
-- TODO(martin): Here, we do a single check for all the deps. This means we don't know if user deps
--   or wasp sdk deps or wasp framework deps need installing, and so the user of this function will
--   likely run `npm install` for all of them, which means 3 times (for user npm deps (+ wasp sdk
--   deps, those are all done with single npm install), for wasp webapp npm deps, for wasp server
--   npm deps). We could, relatively easily, since we already differentiate all these deps, return
--   exact info on which deps need installation, and therefore run only needed npm installs. We
--   could return such info by either returning a triple (Bool, Bool, Bool) for (user+sdk, webapp,
--   server) deps, or we could return a list of enum which says which deps to install.
areThereNpmDepsToInstall :: AllNpmDeps -> Path' Abs (Dir ProjectRootDir) -> IO Bool
areThereNpmDepsToInstall allNpmDeps dstDir = do
  installedNpmDeps <- loadInstalledNpmDepsLog dstDir
  return $ installedNpmDeps /= Just allNpmDeps

doesNodeModulesDirExist :: Path' Abs (Dir WaspProjectDir) -> IO Bool
doesNodeModulesDirExist waspProjectDirPath = IOUitl.doesDirectoryExist nodeModulesDirInWaspProjectDirAbs
  where
    nodeModulesDirInWaspProjectDirAbs = waspProjectDirPath SP.</> nodeModulesDirInWaspProjectDir
