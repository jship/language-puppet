{-# LANGUAGE GADTs         #-}
{-# LANGUAGE TupleSections #-}
module Puppet.Runner.Daemon (
    Daemon(..)
  , initDaemon
) where

import           XPrelude

import qualified Data.Either.Strict          as S
import           Data.FileCache              as FileCache
import qualified Data.HashMap.Strict         as HM
import qualified Data.Text                   as Text
import           Debug.Trace                 (traceEventIO)
import           Foreign.Ruby.Safe
import qualified System.Directory            as Directory
import qualified System.Log.Formatter        as Log (simpleLogFormatter)
import qualified System.Log.Handler          as Log (setFormatter)
import qualified System.Log.Handler.Simple   as Log (streamHandler)
import qualified System.Log.Logger           as Log

import           Facter
import           Hiera.Server
import           Puppet.Runner.Daemon.FileParser
import           Puppet.Runner.Daemon.OptionalTests
import           Puppet.Runner.Erb
import           Puppet.Interpreter
import           Puppet.Parser
import           Puppet.Runner.Preferences
import           Puppet.Runner.Stats


{-| API for the Daemon.
The main method is `getCatalog`: given a node and a list of facts, it returns the result of the compilation.
This will be either an error, or a tuple containing:

- all the resources in this catalog
- the dependency map
- the exported resources
- a list of known resources, that might not be up to date, but are here for code coverage tests.

Notes :

* It might be buggy when top level statements that are not class\/define\/nodes are altered.
-}
data Daemon = Daemon
  { getCatalog :: NodeName -> Facts -> IO (Either PrettyError (FinalCatalog, EdgeMap, FinalCatalog, [Resource]))
  , parserStats :: MStats
  , catalogStats :: MStats
  , templateStats :: MStats
  }

{-| Entry point to get a Daemon.
It will initialize the parsing and interpretation infrastructure from the 'Preferences'.

Cache the AST of every .pp file. It could use a bit of memory. As a comparison, it
fits in 60 MB with the author's manifests, but really breathes when given 300 MB
of heap space. In this configuration, even if it spawns a ruby process for every
template evaluation, it is way faster than the puppet stack.

It can optionally talk with PuppetDB, by setting an URL via the 'prefPDB'.
The recommended way to set it to http://localhost:8080 and set a SSH tunnel :

> ssh -L 8080:localhost:8080 puppet.host
-}
initDaemon :: Preferences IO
           -> IO Daemon
initDaemon pref = do
  setupLogger (pref ^. prefLogLevel)
  logDebug "Initialize daemon"
  traceEventIO "initDaemon"
  hquery      <- hieraQuery pref
  fcache      <- newFileCache
  intr        <- startRubyInterpreter
  templStats  <- newStats
  getTemplate <- initTemplateDaemon intr pref templStats
  catStats    <- newStats
  parseStats  <- newStats
  return (Daemon
            (getCatalog' pref (parseFunc (pref ^. prefPuppetPaths) fcache parseStats) getTemplate catStats hquery)
            parseStats
            catStats
            templStats
         )

getCatalog' :: Preferences IO
         -> ( TopLevelType -> Text -> IO (S.Either PrettyError Statement) )
         -> (Either Text Text -> InterpreterState -> InterpreterReader IO -> IO (S.Either PrettyError Text))
         -> MStats
         -> HieraQueryLayers IO
         -> NodeName
         -> Facts
         -> IO (Either PrettyError (FinalCatalog, EdgeMap, FinalCatalog, [Resource]))
getCatalog' pref parsingfunc getTemplate stats hquery node facts = do
  logDebug ("Received query for node " <> node)
  traceEventIO ("START getCatalog' " <> Text.unpack node)
  let catalogComputation = interpretCatalog (InterpreterReader
                                                (pref ^. prefNatTypes)
                                                parsingfunc
                                                getTemplate
                                                (pref ^. prefPDB)
                                                (pref ^. prefExtFuncs)
                                                node
                                                hquery
                                                defaultImpureMethods
                                                (pref ^. prefIgnoredmodules)
                                                (pref ^. prefExternalmodules)
                                                (pref ^. prefStrictness == Strict)
                                                (pref ^. prefPuppetPaths)
                                                (pref ^. prefRebaseFile)
                                            )
                                            node
                                            facts
                                            (pref ^. prefPuppetSettings)
  (stmts :!: warnings) <- measure stats node catalogComputation
  mapM_ (\(p :!: m) -> Log.logM loggerName p (displayS (renderCompact (ppline node <> ":" <+> m)) "")) warnings
  traceEventIO ("STOP getCatalog' " <> toS node)
  if pref ^. prefExtraTests
     then runOptionalTests stmts
     else pure stmts
  where
    runOptionalTests stm = case stm ^? _Right._1 of
      Nothing  -> pure stm
      (Just c) -> catching _PrettyError
                          (do {testCatalog pref c; pure stm})
                          (pure . Left)

-- Build the 'HieraQueryLayers' needed by the interpreter to lookup hiera values.
hieraQuery :: Preferences IO -> IO (HieraQueryLayers IO)
hieraQuery pref = do
  api0 <- case pref ^. prefHieraPath of
    Just p  -> startHiera p
    Nothing -> pure dummyHiera
  modapis <- getModApis
  pure (HieraQueryLayers api0 modapis)
  where
    getModApis :: IO (Container (HieraQueryFunc IO))
    getModApis = do
      let ignored_modules = pref^.prefIgnoredmodules
          modpath = pref^.prefPuppetPaths.modulesPath
      dirs <- Directory.listDirectory modpath
      (HM.fromList . catMaybes) <$>
        for dirs (\dir -> runMaybeT $ do
          let modname = toS dir
              path = modpath <> "/" <> dir <> "/hiera.yaml"
          guard (modname `notElem` ignored_modules)
          guard =<< liftIO (Directory.doesFileExist path)
          liftIO $ (modname, ) <$> startHiera path)


defaultImpureMethods :: MonadIO m => IoMethods m
defaultImpureMethods =
  IoMethods (liftIO currentCallStack) (liftIO . file) (liftIO . traceEventIO)
  where
    file [] = return $ Left ""
    file (x:xs) = (Right <$> readFile (Text.unpack x)) `catch` (\SomeException {} -> file xs)

setupLogger :: Log.Priority -> IO ()
setupLogger p = do
  Log.updateGlobalLogger loggerName (Log.setLevel p)
  hs <- consoleLogHandler
  Log.updateGlobalLogger Log.rootLoggerName $ Log.setHandlers [hs]
  where
    consoleLogHandler = Log.setFormatter
                       <$> Log.streamHandler stdout Log.DEBUG
                       <*> pure (Log.simpleLogFormatter "$prio: $msg")
