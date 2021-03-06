-- | The module works in IO and throws a 'PrettyError' exception at each failure.
-- These exceptions can be caught (see the exceptions package).
module Puppet.Runner.Daemon.OptionalTests (testCatalog) where

import           XPrelude

import           Control.Monad.Catch       (throwM)
import qualified Data.HashSet              as Set
import qualified Data.Text                 as Text
import           System.Posix.Files        (fileExist)

import           Puppet.Language
import           Puppet.Runner.Preferences


-- | Entry point for all optional tests
testCatalog :: Preferences IO -> FinalCatalog -> IO ()
testCatalog prefs c =
     testFileSources (prefs ^. prefPuppetPaths.baseDir) c
  *> testUsersGroups (prefs ^. prefKnownusers) (prefs ^. prefKnowngroups) c

-- | Tests that all users and groups are defined
testUsersGroups :: [Text] -> [Text] -> FinalCatalog -> IO ()
testUsersGroups kusers kgroups c = do
  let users = Set.fromList $ "" : "0" : map (view (rid . iname)) (getResourceFrom "user") ++ kusers
      groups = Set.fromList $ "" : "0" : map (view (rid . iname)) (getResourceFrom "group") ++ kgroups
      checkResource lu lg = mapM_ (checkResource' lu lg)
      checkResource' lu lg res = do
          let msg att name = align (vsep [ "Resource" <+> ppline (res^.rid.itype)
                                           <+> ppline (res^.rid.iname) <+> showPos (res^.rpos._1)
                                         , "references the unknown" <+> att <+> squotes (ppline name)])
                             <> line
          case lu of
              Just lu' -> do
                  let u = res ^. rattributes . lu' . _PString
                  unless (Set.member u users) $ throwM $ PrettyError (msg "user" u)
              Nothing -> pure ()
          case lg of
              Just lg' -> do
                  let g = res ^. rattributes . lg' . _PString
                  unless (Set.member g groups) $ throwM $ PrettyError (msg "group" g)
              Nothing -> pure ()
  do
      checkResource (Just $ ix "owner") (Just $ ix "group") (getResourceFrom "file")
      checkResource (Just $ ix "user")  (Just $ ix "group") (getResourceFrom "exec")
      checkResource (Just $ ix "user")  Nothing             (getResourceFrom "cron")
      checkResource (Just $ ix "user")  Nothing             (getResourceFrom "ssh_authorized_key")
      checkResource (Just $ ix "user")  Nothing             (getResourceFrom "ssh_authorized_key_secure")
      checkResource Nothing             (Just $ ix "gid")   (getResourceFrom "users")
  where
    getResourceFrom t = c ^.. traverse . filtered (\r -> r ^. rid . itype == t && r ^. rattributes . at "ensure" /= Just "absent")

-- | Test source for every file resources in the catalog.
testFileSources :: FilePath -> FinalCatalog -> IO ()
testFileSources basedir c = do
    let getfiles = filter presentFile . toList
        presentFile r = r ^. rid . itype == "file"
                        && (r ^. rattributes . at "ensure") `elem` [Nothing, Just "present"]
                        && r ^. rattributes . at "source" /= Just PUndef
        getsource = mapMaybe (\r -> (,) <$> pure r <*> r ^. rattributes . at "source")
    checkAllSources basedir $ (getsource . getfiles) c

-- | Check source for all file resources and append failures along.
checkAllSources :: FilePath -> [(Resource, PValue)] -> IO ()
checkAllSources fp fs = go fs []
  where
    go ((res, filesource):xs) es =
      runExceptT (checkFile fp filesource) >>= \case
        Right () -> go xs es
        Left err -> go xs ((PrettyError $ "Could not find " <+> pretty filesource <> semi
                           <+> align (vsep [getError err, showPos (res^.rpos^._1)])):es)
    go [] [] = pure ()
    go [] es = traverse_ throwM es

testFile :: FilePath -> ExceptT PrettyError IO ()
testFile fp = do
    p <-  liftIO (fileExist fp)
    unless p (throwE $ PrettyError $ "searched in" <+> squotes (pptext fp))

-- | Only test the `puppet:///` protocol (files managed by the puppet server)
--   we don't test absolute path (puppet client files)
checkFile :: FilePath -> PValue -> ExceptT PrettyError IO ()
checkFile basedir (PString f) = case Text.stripPrefix "puppet:///" f of
    Just stringdir -> case Text.splitOn "/" stringdir of
        ("modules":modname:rest) -> testFile (basedir <> "/modules/" <> toS modname <> "/files/" <> toS (Text.intercalate "/" rest))
        ("files":rest)           -> testFile (basedir <> "/files/" <> toS (Text.intercalate "/" rest))
        ("private":_)            -> pure ()
        _                        -> throwE (PrettyError $ "Invalid file source:" <+> ppline f)
    Nothing        -> return ()
-- source is always an array of possible paths. We only fails if none of them check.
checkFile basedir (PArray xs) = asum [checkFile basedir x | x <- toList xs]
checkFile _ x = throwE (PrettyError $ "Source was not a string, but" <+> pretty x)
