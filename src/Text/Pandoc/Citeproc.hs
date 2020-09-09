{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
module Text.Pandoc.Citeproc
  ( fromPandocCitations
  , processCitations
  , BibFormat(..)
  , formatFromExtension
  , getRefs
  )
where

import Citeproc as Citeproc
import Citeproc.Pandoc ()
import Text.Pandoc.Citeproc.Locator (parseLocator)
import Text.Pandoc.Citeproc.CslJson (cslJsonToReferences)
import Text.Pandoc.Citeproc.BibTeX (readBibtexString, Variant(..))
import Text.Pandoc.Citeproc.MetaValue (metaValueToReference, metaValueToText,
                                  metaValueToPath)
import Data.ByteString (ByteString)
import Text.Pandoc.Definition as Pandoc
import Text.Pandoc.Walk
import Text.Pandoc.Builder as B
import Text.Pandoc (PandocMonad(..), PandocError(..), readMarkdown,
                    readDataFile, ReaderOptions(..), pandocExtensions,
                    report, LogMessage(..) )
import Text.Pandoc.Shared (stringify, ordNub, blocksToInlines)
import Data.Default
import Data.Ord ()
import qualified Data.Map as M
import qualified Data.Set as Set
import Data.Char (isPunctuation)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Control.Monad.Trans.State
import qualified Data.Sequence as Seq
import qualified Data.Foldable as Foldable
import System.FilePath
import Control.Applicative
import Control.Monad.Except
import Data.Maybe (mapMaybe, fromMaybe, isNothing)
import Safe (lastMay, initSafe)
import Debug.Trace as Trace (trace, traceShowId)


processCitations :: PandocMonad m => Pandoc -> m Pandoc
processCitations (Pandoc meta bs)
  | isNothing (lookupMeta "bibliography" meta)
  , isNothing (lookupMeta "references" meta) = return $ Pandoc meta bs
processCitations (Pandoc meta bs) = do
  let cslfile = (lookupMeta "csl" meta <|> lookupMeta "citation-style" meta)
                >>= metaValueToPath
  cslContents <- maybe (readDataFile "citeproc/chicago-author-date.csl")
                       readFileStrict cslfile

  let getParentStyle url = do
         (raw, _) <- openURL url
         return $ TE.decodeUtf8 raw

  -- TODO check .csl directory if not found
  styleRes <- Citeproc.parseStyle getParentStyle (TE.decodeUtf8 cslContents)
  style <-
    case styleRes of
       Left err    -> throwError $ PandocAppError $ prettyCiteprocError err
       Right style -> return style
  let mblang = parseLang <$> (lookupMeta "lang" meta >>= metaValueToText)
  let locale = Citeproc.mergeLocales mblang style
  let getCiteId (Cite cs _) = Set.fromList $ map B.citationId cs
      getCiteId _ = mempty
  let metanocites = lookupMeta "nocite" meta
  let meta' = deleteMeta "nocite" meta
  let nocites = maybe mempty (query getCiteId) metanocites
  let citeIds = query getCiteId (Pandoc meta bs)
  let idpred = if "*" `Set.member` nocites
                  then const True
                  else (\c -> c `Set.member` citeIds ||
                              c `Set.member` nocites)
  refs <- map (linkifyVariables . legacyDateRanges) <$>
          case lookupMeta "references" meta of
            Just (MetaList rs) -> return $ mapMaybe metaValueToReference rs
            _                  ->
              case lookupMeta "bibliography" meta of
                 Just (MetaList xs) ->
                   mconcat <$>
                     mapM (getRefsFromBib locale idpred)
                       (mapMaybe metaValueToText xs)
                 Just x ->
                   case metaValueToText x of
                     Just fp -> getRefsFromBib locale idpred fp
                     Nothing -> return []
                 Nothing -> return []
  let otherIdsMap = foldr (\ref m ->
                             case T.words . extractText <$>
                                  M.lookup "other-ids" (referenceVariables ref) of
                                Nothing  -> m
                                Just ids -> foldr
                                  (\id' ->
                                    M.insert id' (referenceId ref)) m ids)
                          M.empty refs
  let citations = getCitations locale otherIdsMap $ Pandoc meta' bs
  let linkCites = maybe False truish $ lookupMeta "link-citations" meta
  let opts = defaultCiteprocOptions{ linkCitations = linkCites }
  let result = Citeproc.citeproc opts style (localeLanguage locale)
                  refs citations
  mapM_ (report . CiteprocWarning) (resultWarnings result)
  let classes = "references" : ["hanging-indent" | styleHangingIndent
                                    (styleOptions style)]
  let bibs = mconcat $ map (\(ident, out) ->
                     B.divWith ("ref-" <> ident,[],[]) . B.para $
                       walk (convertQuotes locale) out)
                      (resultBibliography result)
  let moveNotes = maybe True truish $
                        lookupMeta "notes-after-punctuation" meta
  let cits = map (walk (convertQuotes locale)) $
               resultCitations result

  let fixQuotes = case localePunctuationInQuote locale of
                    Just True ->
                      B.toList . movePunctuationInsideQuotes .  B.fromList
                    _ -> id

  let Pandoc meta'' bs' =
         maybe id (setMeta "nocite") metanocites $
         walk (fixQuotes .  mvPunct moveNotes locale) $ walk deNote $
         evalState (walkM insertResolvedCitations $ Pandoc meta' bs)
         $ cits
  return $ Pandoc meta'' $ insertRefs classes meta'' (B.toList bibs) bs'

getRefsFromBib :: PandocMonad m
               => Locale -> (Text -> Bool) -> Text -> m [Reference Inlines]
getRefsFromBib locale idpred t = do
  let fp = T.unpack t
  raw <- readFileStrict fp
  case formatFromExtension fp of
    Just f -> getRefs locale f idpred raw
    Nothing -> throwError $ PandocAppError $
                 "Could not deterine bibliography format for " <> t

getRefs :: PandocMonad m
        => Locale
        -> BibFormat
        -> (Text -> Bool)
        -> ByteString
        -> m [Reference Inlines]
getRefs locale format idpred raw =
  case format of
    Format_bibtex ->
      either (throwError . PandocAppError . T.pack . show) return .
        readBibtexString Bibtex locale idpred . TE.decodeUtf8 $ raw
    Format_biblatex ->
      either (throwError . PandocAppError . T.pack . show) return .
        readBibtexString Biblatex locale idpred . TE.decodeUtf8 $ raw
    Format_json ->
      either (throwError . PandocAppError . T.pack)
             (return . filter (idpred . unItemId . referenceId)) .
        cslJsonToReferences $ raw
    Format_yaml -> do
      Pandoc meta _ <-
           readMarkdown
             def{ readerExtensions = pandocExtensions }
             (TE.decodeUtf8 raw)
      case lookupMeta "references" meta of
          Just (MetaList rs) ->
               return $ filter (idpred . unItemId . referenceId)
                      $ mapMaybe metaValueToReference rs
          _ -> throwError $ PandocAppError "No references field"

-- localized quotes
convertQuotes :: Locale -> Inline -> Inline
convertQuotes locale (Quoted qt ils) =
  case (M.lookup openterm terms, M.lookup closeterm terms) of
    (Just ((_,oq):_), Just ((_,cq):_)) ->
         Span ("",[],[]) (Str oq : ils ++ [Str cq])
    _ -> Quoted qt ils
  where
   terms = localeTerms locale
   openterm = case qt of
                DoubleQuote -> "open-quote"
                SingleQuote -> "open-inner-quote"
   closeterm = case qt of
                 DoubleQuote -> "close-quote"
                 SingleQuote -> "close-inner-quote"
convertQuotes _ x = x

-- assumes we walk in same order as query
insertResolvedCitations :: Inline -> State [Inlines] Inline
insertResolvedCitations (Cite cs ils) = do
  resolved <- get
  case resolved of
    [] -> return (Cite cs ils)
    (x:xs) -> do
      put xs
      return $ Cite cs (B.toList x)
insertResolvedCitations x = return x

getCitations :: Locale
             -> M.Map Text ItemId
             -> Pandoc
             -> [Citeproc.Citation Inlines]
getCitations locale otherIdsMap = Foldable.toList . query getCitation
 where
  getCitation (Cite cs _fallback) = Seq.singleton $
    Citeproc.Citation { Citeproc.citationId = Nothing
                      , Citeproc.citationNoteNumber =
                          case cs of
                            []    -> Nothing
                            (Pandoc.Citation{ Pandoc.citationNoteNum = n }:
                               _) | n > 0     -> Just n
                                  | otherwise -> Nothing
                      , Citeproc.citationItems =
                           fromPandocCitations locale otherIdsMap cs
                      }
  getCitation _ = mempty

fromPandocCitations :: Locale
                    -> M.Map Text ItemId
                    -> [Pandoc.Citation]
                    -> [CitationItem Inlines]
fromPandocCitations locale otherIdsMap = concatMap go
 where
  go c =
    let (loclab, suffix) = parseLocator locale (citationSuffix c)
        (mblab, mbloc) = case loclab of
                           Just (loc, lab) -> (Just loc, Just lab)
                           Nothing         -> (Nothing, Nothing)
        cit = CitationItem
               { citationItemId = fromMaybe
                   (ItemId $ Pandoc.citationId c)
                   (M.lookup (Pandoc.citationId c) otherIdsMap)
               , citationItemLabel = mblab
               , citationItemLocator = mbloc
               , citationItemType = NormalCite
               , citationItemPrefix = case citationPrefix c of
                                        [] -> Nothing
                                        ils -> Just $ B.fromList ils <>
                                                      B.space
               , citationItemSuffix = case suffix of
                                        [] -> Nothing
                                        ils -> Just $ B.fromList ils
               }
     in if Pandoc.citationId c == "*"
           then []
           else
             case citationMode c of
                  AuthorInText   -> [ cit{ citationItemType = AuthorOnly
                                         , citationItemSuffix = Nothing }
                                    , cit{ citationItemType =
                                              Citeproc.SuppressAuthor
                                         , citationItemPrefix = Nothing } ]
                  NormalCitation -> [ cit ]
                  Pandoc.SuppressAuthor
                                 -> [ cit{ citationItemType =
                                              Citeproc.SuppressAuthor } ]



data BibFormat =
    Format_biblatex
  | Format_bibtex
  | Format_json
  | Format_yaml
  deriving (Show, Eq, Ord)

formatFromExtension :: FilePath -> Maybe BibFormat
formatFromExtension fp = case dropWhile (== '.') $ takeExtension fp of
                           "biblatex" -> Just Format_biblatex
                           "bibtex"   -> Just Format_bibtex
                           "bib"      -> Just Format_biblatex
                           "json"     -> Just Format_json
                           "yaml"     -> Just Format_yaml
                           _          -> Nothing


isNote :: Inline -> Bool
isNote (Note _)          = True
isNote (Cite _ [Note _]) = True
 -- the following allows citation styles that are "in-text" but use superscript
 -- references to be treated as if they are "notes" for the purposes of moving
 -- the citations after trailing punctuation (see <https://github.com/jgm/pandoc-citeproc/issues/382>):
isNote (Cite _ [Superscript _]) = True
isNote _                 = False

isSpacy :: Inline -> Bool
isSpacy Space     = True
isSpacy SoftBreak = True
isSpacy _         = False


mvPunct :: Bool -> Locale -> [Inline] -> [Inline]
mvPunct moveNotes locale (x : xs)
  | isSpacy x = x : mvPunct moveNotes locale xs
-- 'x [^1],' -> 'x,[^1]'
mvPunct moveNotes locale (q : s : x : ys)
  | isSpacy s
  , isNote x
  = let spunct = T.takeWhile isPunctuation $ stringify ys
    in  if moveNotes
           then if T.null spunct
                   then q : x : mvPunct moveNotes locale ys
                   else q : Str spunct : x : mvPunct moveNotes locale
                        (B.toList
                          (dropTextWhile isPunctuation (B.fromList ys)))
           else q : x : mvPunct moveNotes locale ys
-- 'x[^1],' -> 'x,[^1]'
mvPunct moveNotes locale (Cite cs ils : ys)
   | not (null ils)
   , isNote (last ils)
   , startWithPunct ys
   , moveNotes
   = let s = stringify ys
         spunct = T.takeWhile isPunctuation s
     in  Cite cs (init ils
                  ++ [Str spunct | not (endWithPunct False (init ils))]
                  ++ [last ils]) :
         mvPunct moveNotes locale
           (B.toList (dropTextWhile isPunctuation (B.fromList ys)))
mvPunct moveNotes locale (s : x : ys) | isSpacy s, isNote x =
  x : mvPunct moveNotes locale ys
mvPunct moveNotes locale (s : x@(Cite _ (Superscript _ : _)) : ys)
  | isSpacy s = x : mvPunct moveNotes locale ys
mvPunct moveNotes locale (Cite cs ils : Str "." : ys)
  | "." `T.isSuffixOf` (stringify ils)
  = Cite cs ils : mvPunct moveNotes locale ys
mvPunct moveNotes locale (x:xs) = x : mvPunct moveNotes locale xs
mvPunct _ _ [] = []

endWithPunct :: Bool -> [Inline] -> Bool
endWithPunct _ [] = False
endWithPunct onlyFinal xs@(_:_) =
  case reverse (T.unpack $ stringify xs) of
       []                       -> True
       -- covers .), .", etc.:
       (d:c:_) | isPunctuation d
                 && not onlyFinal
                 && isEndPunct c -> True
       (c:_) | isEndPunct c      -> True
             | otherwise         -> False
  where isEndPunct c = c `elem` (".,;:!?" :: String)



startWithPunct :: [Inline] -> Bool
startWithPunct ils =
  case T.uncons (stringify ils) of
    Just (c,_) -> c `elem` (".,;:!?" :: [Char])
    Nothing -> False

truish :: MetaValue -> Bool
truish (MetaBool t) = t
truish (MetaString s) = isYesValue (T.toLower s)
truish (MetaInlines ils) = isYesValue (T.toLower (stringify ils))
truish (MetaBlocks [Plain ils]) = isYesValue (T.toLower (stringify ils))
truish _ = False

isYesValue :: Text -> Bool
isYesValue "t" = True
isYesValue "true" = True
isYesValue "yes" = True
isYesValue _ = False

-- if document contains a Div with id="refs", insert
-- references as its contents.  Otherwise, insert references
-- at the end of the document in a Div with id="refs"
insertRefs :: [Text] -> Meta -> [Block] -> [Block] -> [Block]
insertRefs _ _  []   bs = bs
insertRefs refclasses meta refs bs =
  if isRefRemove meta
     then bs
     else case runState (walkM go bs) False of
               (bs', True) -> bs'
               (_, False)
                 -> case refTitle meta of
                      Nothing ->
                        case reverse bs of
                          Header lev (id',classes,kvs) ys : xs ->
                            reverse xs ++
                            [Header lev (id',addUnNumbered classes,kvs) ys,
                             Div ("refs",refclasses,[]) refs]
                          _ -> bs ++ [refDiv]
                      Just ils -> bs ++
                        [Header 1 ("bibliography", ["unnumbered"], []) ils,
                         refDiv]
  where
   refDiv = Div ("refs", refclasses, []) refs
   addUnNumbered cs = "unnumbered" : [c | c <- cs, c /= "unnumbered"]
   go :: Block -> State Bool Block
   go (Div ("refs",cs,kvs) xs) = do
     put True
     -- refHeader isn't used if you have an explicit references div
     let cs' = ordNub $ cs ++ refclasses
     return $ Div ("refs",cs',kvs) (xs ++ refs)
   go x = return x

refTitle :: Meta -> Maybe [Inline]
refTitle meta =
  case lookupMeta "reference-section-title" meta of
    Just (MetaString s)           -> Just [Str s]
    Just (MetaInlines ils)        -> Just ils
    Just (MetaBlocks [Plain ils]) -> Just ils
    Just (MetaBlocks [Para ils])  -> Just ils
    _                             -> Nothing

isRefRemove :: Meta -> Bool
isRefRemove meta =
  maybe False truish $ lookupMeta "suppress-bibliography" meta

legacyDateRanges :: Reference Inlines -> Reference Inlines
legacyDateRanges ref =
  ref{ referenceVariables = M.map go $ referenceVariables ref }
 where
  go (DateVal d)
    | null (dateParts d)
    , Just lit <- dateLiteral d
    = case T.splitOn "_" lit of
        [x,y] -> case Citeproc.rawDateEDTF (x <> "/" <> y) of
                   Just d' -> DateVal d'
                   Nothing -> DateVal d
        _ -> DateVal d
  go x = x

linkifyVariables :: Reference Inlines -> Reference Inlines
linkifyVariables ref =
  ref{ referenceVariables = M.mapWithKey go $ referenceVariables ref }
 where
  go "URL" x    = tolink "https://" x
  go "DOI" x    = tolink "https://doi.org/" x
  go "ISBN" x   = tolink "https://worldcat.org/isbn/" x
  go "PMID" x   = tolink "https://www.ncbi.nlm.nih.gov/pubmed/" x
  go "PMCID" x  = tolink "https://www.ncbi.nlm.nih.gov/pmc/articles/" x
  go _ x        = x
  tolink pref x = let x' = extractText x
                      x'' = if "://" `T.isInfixOf` x'
                               then x'
                               else pref <> x'
                  in  FancyVal (B.link x'' "" (B.str x'))

extractText :: Val Inlines -> Text
extractText (TextVal x)  = x
extractText (FancyVal x) = toText x
extractText (NumVal n)   = T.pack (show n)
extractText _            = mempty

deNote :: Inline -> Inline
deNote (Note bs) = Note $ walk go bs
 where
  go (Note bs')
       = Span ("",[],[]) (Space : Str "(" :
                          (removeFinalPeriod
                            (blocksToInlines bs')) ++ [Str ")"])
  go x = x
deNote x = x

-- Note: we can't use dropTextWhileEnd because this would
-- remove the final period on abbreviations like Ibid.
-- But removing a final Str "." is safe.
removeFinalPeriod :: [Inline] -> [Inline]
removeFinalPeriod ils =
  case lastMay ils of
    Just (Str ".") -> initSafe ils
    _              -> ils


