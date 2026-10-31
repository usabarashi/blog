{-# LANGUAGE OverloadedStrings #-}

-- | Static site generator for <https://usabarashi.github.io/blog/>.
--
-- Content lives in plain Markdown with YAML front matter:
--
-- * @posts/YYYY-MM-DD-slug.md@ — articles (published when merged to @main@)
-- * @posts/drafts/@ — never matched by any rule, so never published
-- * @pages/*.md@ — standalone pages such as @about.md@
--
-- URLs are written root-absolute (@\/css\/style.css@) and relativized on
-- output, so the same HTML works locally (@\/@) and under the project page
-- path (@\/blog\/@).
module Main (main) where

import Hakyll
import Text.Pandoc.Highlighting (pygments, styleToCss)
import Text.Pandoc.Options (HTMLMathMethod (MathML), WriterOptions (..))

--------------------------------------------------------------------------------
-- Site configuration
--------------------------------------------------------------------------------

-- | Absolute root of the deployed site. Used for feeds and the sitemap only;
-- HTML pages use relativized URLs.
siteRoot :: String
siteRoot = "https://usabarashi.github.io/blog"

siteTitle :: String
siteTitle = "usabarashi blog"

siteDescription :: String
siteDescription = "Technical notes by usabarashi"

authorName :: String
authorName = "usabarashi"

authorEmail :: String
authorEmail = "19676305+usabarashi@users.noreply.github.com"

-- | Articles. @posts/drafts\/**@ is intentionally not matched by this pattern.
postPattern :: Pattern
postPattern = "posts/*.md"

pagePattern :: Pattern
pagePattern = "pages/*.md"

-- | Identifier of the per-tag page for a tag name.
tagId :: String -> Identifier
tagId = fromCapture "tags/*.html"

--------------------------------------------------------------------------------
-- Compilers
--------------------------------------------------------------------------------

-- | Pandoc writer options: math is rendered as MathML so that pages stay
-- self-contained (no MathJax/KaTeX runtime download, no server-side work).
pandocOptions :: WriterOptions
pandocOptions = defaultHakyllWriterOptions { writerHTMLMathMethod = MathML }

-- | @posts\/2026-01-01-hello.md@ becomes @\/posts\/hello.html@.
postRoute :: Routes
postRoute =
    gsubRoute "posts/[0-9]{4}-[0-9]{2}-[0-9]{2}-" (const "posts/")
        `composeRoutes` setExtension "html"

-- | @pages\/about.md@ becomes @\/about.html@.
pageRoute :: Routes
pageRoute =
    gsubRoute "pages/" (const "") `composeRoutes` setExtension "html"

--------------------------------------------------------------------------------
-- Contexts
--------------------------------------------------------------------------------

-- | Fields shared by every page template.
siteCtx :: Context a
siteCtx =
    constField "siteTitle" siteTitle
        <> constField "author" authorName

-- | Text for the HTML @title@ element.
documentTitle :: String -> String
documentTitle title = title ++ " - " ++ siteTitle

-- | Derive @documentTitle@ from the @title@ metadata field (articles, pages).
metadataTitleCtx :: Context a
metadataTitleCtx = field "documentTitle" $ \item -> do
    mtitle <- getMetadataField (itemIdentifier item) "title"
    return $ case mtitle of
        Just title -> documentTitle title
        Nothing -> siteTitle

-- | Link to the page listing all articles of one tag.
tagLinkCtx :: Context String
tagLinkCtx =
    field "name" (return . itemBody)
        <> field "url" (return . toUrl . toFilePath . tagId . itemBody)

-- | Context for articles and article listings.
postCtx :: Context String
postCtx =
    siteCtx
        <> metadataTitleCtx
        <> dateField "date" "%Y-%m-%d"
        <> ( listFieldWith "tags" tagLinkCtx $ \item -> do
                tags <- getTags (itemIdentifier item)
                if null tags
                    then fail "no tags"
                    else return [Item (fromFilePath tag) tag | tag <- tags]
           )
        <> defaultContext

-- | Context for the entries of @sitemap.xml@.
sitemapEntryCtx :: Context String
sitemapEntryCtx =
    field "loc" locField
        <> field "lastmod" lastmodField
  where
    locField item = do
        mroute <- getRoute (itemIdentifier item)
        case mroute of
            Nothing -> fail $ "no route for " ++ show (itemIdentifier item)
            Just r -> return (siteRoot ++ toUrl r)
    lastmodField item = do
        mdate <- getMetadataField (itemIdentifier item) "date"
        case mdate of
            Just date -> return date
            Nothing -> fail "no date metadata"

feedConfiguration :: FeedConfiguration
feedConfiguration =
    FeedConfiguration
        { feedTitle = siteTitle
        , feedDescription = siteDescription
        , feedAuthorName = authorName
        , feedAuthorEmail = authorEmail
        , feedRoot = siteRoot
        }

--------------------------------------------------------------------------------
-- Rules
--------------------------------------------------------------------------------

main :: IO ()
main = hakyll $ do
    match "assets/**" $ do
        route $ gsubRoute "assets/" (const "")
        compile copyFileCompiler

    match "templates/**" $ compile templateBodyCompiler

    -- Syntax highlighting CSS, derived from the Pandoc style actually used
    -- for rendering, so the two can never drift apart.
    create ["css/syntax.css"] $ do
        route idRoute
        compile $ makeItem (styleToCss pygments)

    match postPattern $ do
        route postRoute
        compile $ do
            pandocCompilerWith defaultHakyllReaderOptions pandocOptions
                >>= saveSnapshot "content"
                >>= loadAndApplyTemplate "templates/post.html" postCtx
                >>= loadAndApplyTemplate "templates/default.html" postCtx
                >>= relativizeUrls

    match pagePattern $ do
        route pageRoute
        compile $
            pandocCompilerWith defaultHakyllReaderOptions pandocOptions
                >>= loadAndApplyTemplate "templates/page.html" postCtx
                >>= loadAndApplyTemplate "templates/default.html" postCtx
                >>= relativizeUrls

    create ["index.html"] $ do
        route idRoute
        compile $ do
            posts <- fmap (take 10) . recentFirst =<< loadAll postPattern
            let ctx =
                    siteCtx
                        <> listField "posts" postCtx (return posts)
                        <> constField "description" siteDescription
                        <> constField "documentTitle" siteTitle
                        <> constField "home" "yes"
                        <> defaultContext
            makeItem ""
                >>= loadAndApplyTemplate "templates/home.html" ctx
                >>= loadAndApplyTemplate "templates/default.html" ctx
                >>= relativizeUrls

    create ["archive.html"] $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll postPattern
            let ctx =
                    siteCtx
                        <> listField "posts" postCtx (return posts)
                        <> constField "title" "All posts"
                        <> constField "documentTitle" (documentTitle "All posts")
                        <> defaultContext
            makeItem ""
                >>= loadAndApplyTemplate "templates/archive.html" ctx
                >>= loadAndApplyTemplate "templates/default.html" ctx
                >>= relativizeUrls

    tags <- buildTags postPattern tagId

    tagsRules tags $ \tag pattern -> do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll pattern
            let ctx =
                    siteCtx
                        <> listField "posts" postCtx (return posts)
                        <> constField "title" ("Tag: " ++ tag)
                        <> constField "documentTitle" (documentTitle ("Tag: " ++ tag))
                        <> defaultContext
            makeItem ""
                >>= loadAndApplyTemplate "templates/archive.html" ctx
                >>= loadAndApplyTemplate "templates/default.html" ctx
                >>= relativizeUrls

    create ["tags.html"] $ do
        route idRoute
        compile $ do
            let tagItems =
                    [ Item (fromFilePath tag) (tag, length identifiers)
                    | (tag, identifiers) <- tagsMap tags
                    ]
                tagListCtx =
                    field "name" (return . fst . itemBody)
                        <> field "url" (return . toUrl . toFilePath . tagId . fst . itemBody)
                        <> field "count" (return . show . snd . itemBody)
                ctx =
                    siteCtx
                        <> listField "tagList" tagListCtx (return tagItems)
                        <> constField "title" "All tags"
                        <> constField "documentTitle" (documentTitle "All tags")
                        <> defaultContext
            makeItem ""
                >>= loadAndApplyTemplate "templates/tags.html" ctx
                >>= loadAndApplyTemplate "templates/default.html" ctx
                >>= relativizeUrls

    create ["rss.xml"] $ do
        route idRoute
        compile $ do
            posts <- fmap (take 20) . recentFirst =<< loadAllSnapshots postPattern "content"
            let feedCtx = postCtx <> bodyField "description"
            renderRss feedConfiguration feedCtx posts

    create ["sitemap.xml"] $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll postPattern
            pages <- loadAll pagePattern
            let ctx =
                    constField "siteRoot" siteRoot
                        <> listField "entries" sitemapEntryCtx (return (posts ++ pages))
            makeItem ("" :: String) >>= loadAndApplyTemplate "templates/sitemap.xml" ctx
