{-# OPTIONS_GHC -fno-warn-orphans #-}
module Puppet.Parser.PrettyPrinter
  ( ppStatements
  ) where

import           XPrelude.Extra               hiding ((<$>))
import           XPrelude.PP

import qualified Data.Maybe.Strict            as S
import qualified Data.Text                    as Text
import qualified Data.Tuple.Strict            as Tuple
import qualified Data.Vector                  as V
import           Text.PrettyPrint.ANSI.Leijen ((<$>))

import           Puppet.Language
import           Puppet.Parser.Types


parensList :: Pretty a => Vector a -> Doc
parensList = tupled . fmap pretty . V.toList

hashComma :: (Pretty a, Pretty b) => Vector (Pair a b) -> Doc
hashComma = encloseSep lbrace rbrace comma . fmap showC . V.toList
  where
    showC (a :!: b) = pretty a <+> ppline "=>" <+> pretty b


instance Pretty UDataType where
  pretty t = case t of
    UDTType              -> "Type"
    UDTString ma mb      -> bounded "String" ma mb
    UDTInteger ma mb     -> bounded "Integer" ma mb
    UDTFloat ma mb       -> bounded "Float" ma mb
    UDTBoolean           -> "Boolean"
    UDTArray dt mi mmx   -> "Array" <> list (pretty dt : pretty mi : maybe [] (pure . pretty) mmx)
    UDTHash kt dt mi mmx -> "Hash" <> list (pretty kt : pretty dt : pretty mi : maybe [] (pure . pretty) mmx)
    UDTUndef             -> "Undef"
    UDTScalar            -> "Scalar"
    UDTData              -> "Data"
    UDTOptional o        -> "Optional" <> brackets (pretty o)
    UNotUndef            -> "NotUndef"
    UDTVariant vs        -> "Variant" <> list (foldMap (pure . pretty) vs)
    UDTPattern vs        -> "Pattern" <> list (foldMap (pure . pretty) vs)
    UDTEnum tx           -> "Enum" <> list (foldMap (pure . pretty) tx)
    UDTAny               -> "Any"
    UDTCollection        -> "Collection"
    where
      bounded :: (Pretty a, Pretty b) => Doc -> Maybe a -> Maybe b -> Doc
      bounded s ma mb = s <> case (ma, mb) of
        (Just a, Nothing) -> list [pretty a]
        (Just a, Just b)  -> list [pretty a, pretty b]
        _                 -> mempty

instance Pretty Expression where
  pretty (Equal a b) = parens (pretty a <+> ppline "==" <+> pretty b)
  pretty (Different a b) = parens (pretty a <+> ppline "!=" <+> pretty b)
  pretty (And a b) = parens (pretty a <+> ppline "and" <+> pretty b)
  pretty (Or a b) = parens (pretty a <+> ppline "or" <+> pretty b)
  pretty (LessThan a b) = parens (pretty a <+> ppline "<" <+> pretty b)
  pretty (MoreThan a b) = parens (pretty a <+> ppline ">" <+> pretty b)
  pretty (LessEqualThan a b) = parens (pretty a <+> ppline "<=" <+> pretty b)
  pretty (MoreEqualThan a b) = parens (pretty a <+> ppline ">=" <+> pretty b)
  pretty (RegexMatch a b) = parens (pretty a <+> ppline "=~" <+> pretty b)
  pretty (NotRegexMatch a b) = parens (pretty a <+> ppline "!~" <+> pretty b)
  pretty (Contains a b) = parens (pretty a <+> ppline "in" <+> pretty b)
  pretty (Addition a b) = parens (pretty a <+> ppline "+" <+> pretty b)
  pretty (Substraction a b) = parens (pretty a <+> ppline "-" <+> pretty b)
  pretty (Division a b) = parens (pretty a <+> ppline "/" <+> pretty b)
  pretty (Multiplication a b) = parens (pretty a <+> ppline "*" <+> pretty b)
  pretty (Modulo a b) = parens (pretty a <+> ppline "%" <+> pretty b)
  pretty (RightShift a b) = parens (pretty a <+> ppline ">>" <+> pretty b)
  pretty (LeftShift a b) = parens (pretty a <+> ppline "<<" <+> pretty b)
  pretty (Lookup a b) = pretty a <> brackets (pretty b)
  pretty (ConditionalValue a b) = parens (pretty a <+> ppline "?" <+> hashComma b)
  pretty (Negate a) = ppline "-" <+> parens (pretty a)
  pretty (Not a) = ppline "!" <+> parens (pretty a)
  pretty (Terminal a) = pretty a
  pretty (FunctionApplication e1 e2) = parens (pretty e1) <> ppline "." <> pretty e2

instance Pretty LambdaFunc where
  pretty LambEach = bold $ red $ ppline "each"
  pretty LambMap = bold $ red $ ppline "map"
  pretty LambReduce = bold $ red $ ppline "reduce"
  pretty LambFilter = bold $ red $ ppline "filter"
  pretty LambSlice = bold $ red $ ppline "slice"
  pretty LambLookup = bold $ red $ ppline "lookup"

instance Pretty LambdaParameters where
  pretty b = magenta (pretty '|') <+> vars <+> magenta (pretty '|')
    where
      pmspace = foldMap ((<> " ") . pretty)
      vars =
        case b of
          BPSingle (LParam mt v) -> pmspace mt <> pretty (UVariableReference v)
          BPPair (LParam mt1 v1) (LParam mt2 v2) ->
            pmspace mt1 <> pretty (UVariableReference v1) <> comma <+> pmspace mt2 <> pretty (UVariableReference v2)

instance Pretty SearchExpression where
  pretty (EqualitySearch t e) = ppline t <+> ppline "==" <+> pretty e
  pretty (NonEqualitySearch t e) = ppline t <+> ppline "!=" <+> pretty e
  pretty AlwaysTrue = mempty
  pretty (AndSearch s1 s2) = parens (pretty s1) <+> ppline "and" <+> parens (pretty s2)
  pretty (OrSearch s1 s2) = parens (pretty s1) <+> ppline "and" <+> parens (pretty s2)

instance Pretty UnresolvedValue where
  pretty (UBoolean True) = dullmagenta $ ppline "true"
  pretty (UBoolean False) = dullmagenta $ ppline "false"
  pretty (UString s) = pretty '"' <> dullcyan (ppline (stringEscape s)) <> pretty '"'
  pretty (UNumber n) = cyan (ppline (scientific2text n))
  pretty (UInterpolable v) = pretty '"' <> hcat (map specific (V.toList v)) <> pretty '"'
    where
      specific (Terminal (UString s)) = dullcyan (ppline (stringEscape s))
      specific (Terminal (UVariableReference vr)) = dullblue (ppline ("${" <> vr <> "}"))
      specific (Lookup (Terminal (UVariableReference vr)) (Terminal x)) =
        dullblue (ppline ("${" <> vr <> "[") <> pretty x <> "]}")
      specific x = bold (red (pretty x))
  pretty UUndef = dullmagenta (ppline "undef")
  pretty (UResourceReference t n) = capitalizeR t <> brackets (pretty n)
  pretty (UArray v) = list (map pretty (V.toList v))
  pretty (UHash g) = hashComma g
  pretty (URegexp r) = pretty r
  pretty (UVariableReference v) = dullblue (pretty '$' <> ppline v)
  pretty (UFunctionCall f args) = showFunc f args
  pretty (UHOLambdaCall c) = pretty c
  pretty (UDataType dt) = pretty dt


instance Pretty HOLambdaCall where
  pretty (HOLambdaCall hf me bp stts mee) =
    pretty hf <> mme <+> pretty bp <+> nest 2 (pretty '{' <> line <> ppStatements stts <> mmee) <$> pretty '}'
    where
      mme =
        case me of
          S.Just x -> mempty <+> pretty x
          S.Nothing -> mempty
      mmee =
        case mee of
          S.Just x -> mempty </> pretty x
          S.Nothing -> mempty
instance Pretty SelectorCase where
  pretty SelectorDefault = dullmagenta (ppline "default")
  pretty (SelectorType t) = pretty t
  pretty (SelectorValue v) = pretty v

instance Pretty ArrowOp where
  pretty AssignArrow = "=>"
  pretty AppendArrow = "+>"


showAss :: Vector AttributeDecl -> Doc
showAss vx = folddoc (\a b -> a <> pretty ',' <$> b) prettyDecl (V.toList vx)
  where
    folddoc _ _ [] = mempty
    folddoc acc docGen (x:xs) = foldl acc (docGen x) (map docGen xs)
    maxlen = maximum (fmap (\(AttributeDecl k _ _) -> Text.length k) vx)
    prettyDecl (AttributeDecl k op v) = dullblue (fill maxlen (ppline k)) <+> pretty op <+> pretty v

showArgs :: Vector (Pair (Pair Text (S.Maybe UDataType)) (S.Maybe Expression)) -> Doc
showArgs vec = tupled (map ra lst)
  where
    lst = V.toList vec
    maxlen = maximum (map (Text.length . Tuple.fst . Tuple.fst) lst)
    ra (argname :!: mtype :!: rval) =
      dullblue (pretty '$' <> foldMap (\t -> pretty t <+> mempty) mtype
                           <> fill maxlen (ppline argname))
                           <> foldMap (\v -> mempty <+> pretty '=' <+> pretty v) rval

showFunc :: Text -> Vector Expression -> Doc
showFunc funcname args = bold (red (ppline funcname)) <> parensList args

braceStatements :: Vector Statement -> Doc
braceStatements stts = nest 2 (pretty '{' <$> ppStatements stts) <$> pretty '}'

instance Pretty NodeDesc where
  pretty NodeDefault = dullmagenta (ppline "default")
  pretty (NodeName n) = pretty (UString n)
  pretty (NodeMatch r) = pretty (URegexp r)

instance Pretty Statement where
    pretty (HigherOrderLambdaDeclaration (HigherOrderLambdaDecl c p)) = pretty c <+> showPPos p
    pretty (ConditionalDeclaration (ConditionalDecl conds p))
        | V.null conds = mempty
        | otherwise = ppline "if" <+> pretty firstcond <+> showPPos p <+> braceStatements firststts <$> vcat (map rendernexts xs)
        where
            ( (firstcond :!: firststts) : xs ) = V.toList conds
            rendernexts (Terminal (UBoolean True) :!: st) = ppline "else" <+> braceStatements st
            rendernexts (c :!: st) | V.null st = mempty
                                   | otherwise = ppline "elsif" <+> pretty c <+> braceStatements st
    pretty (MainFunctionDeclaration (MainFuncDecl funcname args p)) = showFunc funcname args <+> showPPos p
    pretty (ResourceDefaultDeclaration (ResDefaultDecl rtype defaults p)) = capitalizeR rtype <+> nest 2 (pretty '{' <+> showPPos p <$> showAss defaults) <$> pretty '}'
    pretty (ResourceOverrideDeclaration (ResOverrideDecl rtype rnames overs p)) = pretty (UResourceReference rtype rnames) <+> nest 2 (pretty '{' <+> showPPos p <$> showAss overs) <$> pretty '}'
    pretty (ResourceDeclaration (ResDecl rtype rname args virt p)) = nest 2 (red vrt <> dullgreen (ppline rtype) <+> pretty '{' <+> showPPos p
                                                                           <$> nest 2 (pretty rname <> pretty ':' <$> showAss args))
                                                                           <$> pretty '}'
        where
            vrt = case virt of
                      Normal           -> mempty
                      Virtual          -> pretty '@'
                      Exported         -> ppline "@@"
                      ExportedRealized -> ppline "!!"
    pretty (DefineDeclaration (DefineDecl cname args stts p)) = dullyellow (ppline "define") <+> dullgreen (ppline cname) <> showArgs args <+> showPPos p <$> braceStatements stts
    pretty (ClassDeclaration (ClassDecl cname args inherit stts p)) = dullyellow (ppline "class") <+> dullgreen (ppline cname) <> showArgs args <> inheritance <+> showPPos p
                                                               <$> braceStatements stts
        where
            inheritance = case inherit of
                              S.Nothing -> mempty
                              S.Just x -> mempty <+> ppline "inherits" <+> ppline x
    pretty (VarAssignmentDeclaration (VarAssignDecl a b p)) = dullblue (pretty '$' <> ppline a <+> pretty '=' <+> pretty b <+> showPPos p)
    pretty (NodeDeclaration (NodeDecl nodename stmts i p)) = dullyellow (ppline "node") <+> pretty nodename <> inheritance <+> showPPos p <$> braceStatements stmts
        where
            inheritance = case i of
                              S.Nothing -> mempty
                              S.Just n -> mempty <+> ppline "inherits" <+> pretty n
    pretty (DependencyDeclaration (DepDecl (st :!: sn) (dt :!: dn) lt p)) = pretty (UResourceReference st sn) <+> pretty lt <+> pretty (UResourceReference dt dn) <+> showPPos p
    pretty (TopContainer a b) = ppline "TopContainer:" <+> braces ( nest 2 (ppline "TOP" <$> braceStatements a <$> ppline "STATEMENT" <$> pretty b))
    pretty (ResourceCollectionDeclaration (ResCollDecl coltype restype search overrides p)) = capitalizeR restype <> enc (pretty search) <+> overs
        where
            overs | V.null overrides = showPPos p
                  | otherwise = nest 2 (pretty '{' <+> showPPos p <$> showAss overrides) <$> pretty '}'
            enc = case coltype of
                      Collector         -> enclose (ppline "<|")   (ppline "|>")
                      ExportedCollector -> enclose (ppline "<<|")  (ppline "|>>")

-- | Pretty print a series of statements.
ppStatements :: Vector Statement -> Doc
ppStatements = vcat . map pretty . V.toList
