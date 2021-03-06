-- | Private module. Evaluates a ruby template from what's generated by "Erb.Parser".
module Puppet.Runner.Erb.Evaluate (
    rubyEvaluate
  ) where

import           XPrelude

import           Data.Aeson.Lens
import qualified Data.Char          as Char
import qualified Data.Text          as Text
import qualified Data.Vector        as V

import           Erb.Ruby
import           Puppet.Interpreter

rubyEvaluate :: Container ScopeInformation -> Text -> [RubyStatement] -> Either Doc Text
rubyEvaluate vars ctx = foldl (evalruby vars ctx) (Right "") . optimize
    where
        optimize []                             = []
        optimize (Puts x : DropPrevSpace' : xs) = optimize $ DropPrevSpace (Puts x) : xs
        optimize (x:xs)                         = x : optimize xs

spaceNotCR :: Char -> Bool
spaceNotCR c = Char.isSpace c && c /= '\n' && c /= '\r'

evalruby :: Container ScopeInformation -> Text -> Either Doc Text -> RubyStatement -> Either Doc Text
evalruby _  _   (Left err)     _        = Left err
evalruby _ _  (Right _) (DropPrevSpace') = Left "Could not evaluate a non optimize DropPrevSpace'"
evalruby mp ctx (Right curstr) (DropNextSpace x) =
  case evalruby mp ctx (Right curstr) x of
    Left err -> Left err
    Right y  -> Right (Text.dropWhile spaceNotCR y)
evalruby mp ctx (Right curstr) (DropPrevSpace x) =
  case evalruby mp ctx (Right curstr) x of
    Left err -> Left err
    Right y  -> Right (Text.dropWhileEnd spaceNotCR y)
evalruby mp ctx (Right curstr) (Puts e) = case evalExpression mp ctx e of
    Left err -> Left err
    Right ex -> Right (curstr <> ex)

evalExpression :: Container ScopeInformation -> Text -> Expression -> Either Doc Text
evalExpression mp ctx (LookupOperation varname varindex) = do
  rvname <- evalExpression mp ctx varname
  rvindx <- evalExpression mp ctx varindex
  getVariable mp ctx rvname >>= \case
    PArray arr ->
        case a2i rvindx of
            Nothing -> Left $ "Can't convert index to integer when resolving" <+> ppline rvname <> brackets (ppline rvindx)
            Just  i -> if fromIntegral (V.length arr) <= i
              then Left $ "Array out of bound" <+> ppline rvname <> brackets (ppline rvindx)
              else evalValue (arr V.! fromIntegral i)
    PHash hs -> case hs ^. at rvindx of
                  Just x -> evalValue x
                  _ -> Left $ "Can't index variable" <+> ppline rvname <+> ", it is " <+> pretty (PHash hs)
    varvalue -> Left $ "Can't index variable" <+> ppline rvname <+> ", it is " <+> pretty varvalue
evalExpression _  _   (Value (Literal x))          = Right x
evalExpression mp ctx (Object (Value (Literal x))) = getVariable mp ctx x >>= evalValue
evalExpression _  _   x = Left $ "Can't evaluate" <+> pretty x

evalValue :: PValue -> Either Doc Text
evalValue (PString x) = Right x
evalValue (PNumber x) = Right (scientific2text x)
evalValue x           = Right $ show x

a2i :: Text -> Maybe Integer
a2i x = case text2Scientific x of
            Just y -> y ^? _Integer
            _      -> Nothing
