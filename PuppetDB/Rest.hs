module PuppetDB.Rest where

import Puppet.Utils

import Network.HTTP.Conduit
import qualified Network.HTTP.Types as W
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.ByteString.Char8 as BC
import Data.Aeson
import qualified Codec.Text.IConv as IConv
import qualified Control.Exception as X
import Control.Monad.Error
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Either.Strict as S

import Debug.Trace

runRequest req = do
    let doRequest = withManager (fmap responseBody . httpLbs req) :: IO L.ByteString
        eHandler :: X.SomeException -> IO (Either String  L.ByteString)
        eHandler e = return $ Left $ show e ++ ", with queryString " ++ BC.unpack (queryString req)
    liftIO (fmap Right doRequest `X.catch` eHandler) >>= \case
        Right o -> do
            let utf8 = IConv.convert "LATIN1" "UTF-8" o
            case decode' utf8 of
                Just x                   -> return x
                Nothing                  -> throwError "Json decoding has failed"
        Left err -> throwError err

pdbRequest :: (FromJSON a, ToJSON b) => T.Text -> T.Text -> b -> IO (S.Either String a)
pdbRequest url querytype query = fmap strictifyEither $ runErrorT $ do
    unless (querytype `elem` ["resources", "nodes", "facts"]) (throwError $ "Invalid query type " ++ T.unpack querytype)
    let jsonquery = L.toStrict (encode query)
    q <- case querytype of
             "facts" -> case decode (encode [query]) of -- :(
                                         Just [t] -> return (T.cons '/' t)
                                         x -> traceShow (encode query) $ throwError $ "Invalid query for facts, need a string: " ++ show x
             _       -> return $ T.decodeUtf8 $ "?" <> W.renderSimpleQuery False [("query", jsonquery)]
    let fullurl = url <> "/v1/" <> querytype <> q
    initReq <- case (parseUrl (T.unpack fullurl) :: Maybe (Request a)) of
        Just x -> return x
        Nothing -> throwError "Something failed when parsing the PuppetDB URL"
    let req = initReq { requestHeaders = [("Accept", "application/json")] }
    runRequest req

