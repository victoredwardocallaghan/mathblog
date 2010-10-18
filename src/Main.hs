module Main where

import Control.Applicative
    ( (<*>)
    , pure
    )
import Control.Monad
    ( when
    , forM_
    , forM
    )
import Control.Concurrent
    ( threadDelay
    )
import System.IO
    ( IOMode(WriteMode)
    , Handle
    , openFile
    , hPutStr
    , hClose
    )
import System.Exit
    ( exitFailure
    )
import System.Environment
    ( getEnvironment
    , getArgs
    )
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , removeFile
    , copyFile
    , createDirectory
    )
import System.FilePath
    ( (</>)
    )
import System.Posix.Files
    ( createSymbolicLink
    )
import Data.Maybe
    ( isNothing
    )
import Data.Time.LocalTime
    ( TimeZone(timeZoneName)
    , getCurrentTimeZone
    )
import Data.Time.Clock
    ( getCurrentTime
    , UTCTime(utctDay)
    )
import Data.Time.Calendar
    ( addDays
    )
import qualified Text.Pandoc as Pandoc
import qualified MB.Config as Config
import MB.Templates
    ( loadTemplate
    , renderTemplate
    )
import MB.Processing
    ( processPost
    )
import MB.Util
    ( copyTree
    , toLocalTime
    , rssModificationTime
    , loadPostIndex
    , getModificationTime
    , allPostFilenames
    , dirFilenames
    )
import MB.Gladtex
    ( gladTex
    , checkForGladtex
    )
import MB.Types
import qualified MB.Files as Files
import Paths_mathblog
    ( getDataFileName
    )

skelDir :: IO FilePath
skelDir = getDataFileName "skel"

baseDirEnvName :: String
baseDirEnvName = "MB_BASE_DIR"

configFilename :: String
configFilename = "blog.cfg"

commonTemplateAttrs :: Config -> [(String, String)]
commonTemplateAttrs config = [ ( "baseUrl", baseUrl config )
                             , ( "title", title config )
                             , ( "authorName", authorName config )
                             , ( "authorEmail", authorEmail config )
                             ]

fillTemplate :: Config -> Template -> [(String, String)] -> String
fillTemplate config t attrs = renderTemplate attrs' t
    where attrs' = commonTemplateAttrs config ++ attrs

writeTemplate :: Config -> Handle -> Template -> [(String, String)] -> IO ()
writeTemplate config h t attrs = hPutStr h $ fillTemplate config t attrs

pandocWriterOptions :: Pandoc.WriterOptions
pandocWriterOptions =
    Pandoc.defaultWriterOptions { Pandoc.writerHTMLMathMethod = Pandoc.GladTeX
                                }

writePost :: Handle -> Post -> IO ()
writePost h post = do
  created <- postModificationString post
  hPutStr h $ "<h1>" ++ postTitle post 175 ++ "</h1>"
  hPutStr h $ "<span class=\"post-created\">Posted " ++ created ++ "</span>"
  hPutStr h $ Pandoc.writeHtmlString pandocWriterOptions (postAst post)

buildLinks :: Config -> Maybe Post -> Maybe Post -> String
buildLinks config prev next =
    "<div id=\"prev-next-links\">"
      ++ link "next-link" "older" next
      ++ link "prev-link" "newer" prev
      ++ "</div>"
        where
          link cls name Nothing =
              "<span class=\"" ++ cls ++ "-subdued\">" ++ name ++ "</span>"
          link cls name (Just p) =
              "<a class=\"" ++ cls ++ "\" href=\"" ++ Files.postUrl config p ++
                                "\">" ++ name ++ "</a>"

jsInfo :: Post -> String
jsInfo post =
    "<script type=\"text/javascript\">\n" ++
    "Blog = {\n" ++
    "  pageName: " ++ show (Files.postBaseName post) ++
    "\n" ++
    "};\n" ++
    "</script>\n"

buildPage :: Handle -> Config -> String -> Maybe String -> IO ()
buildPage h config content extraTitle = do
  eTmpl <- loadTemplate $ Files.pageTemplatePath config

  case eTmpl of
    Left msg -> putStrLn msg >> exitFailure
    Right tmpl ->
        do
          let attrs = [ ("content", content)
                      ] ++ maybe [] (\t -> [("extraTitle", t)]) extraTitle

          writeTemplate config h tmpl attrs
          hClose h

buildPost :: Handle -> Config -> Post -> (Maybe Post, Maybe Post) -> IO ()
buildPost h config post prevNext = do
  eTmpl <- loadTemplate $ Files.postTemplatePath config

  case eTmpl of
    Left msg -> putStrLn msg >> exitFailure
    Right tmpl ->
        do
          html <- readFile $ Files.postIntermediateHtml config post

          let attrs = [ ("post", html)
                      , ("nextPrevLinks", uncurry (buildLinks config) prevNext)
                      , ("jsInfo", jsInfo post)
                      ]

          let out = (fillTemplate config tmpl attrs)
          buildPage h config out $ Just $ postTitleRaw post

generatePost :: Config -> Post -> IO ()
generatePost config post = do
  let tempHtml = htmlTempDir config </> Files.postBaseName post ++ ".html"
      finalHtml = Files.postIntermediateHtml config post

  htmlExists <- doesFileExist finalHtml
  generate <- case htmlExists of
                False -> return True
                True -> do
                  t <- getModificationTime finalHtml
                  return $ (postModificationTime post > t)

  when generate $ do
    putStrLn $ "Processing: " ++ Files.postBaseName post

    h <- openFile (Files.postHtex config post) WriteMode
    writePost h =<< processPost config post
    hClose h

    -- Run gladtex on the temp file to generate the final file.
    gladTex config (Files.postHtex config post) "000000"

    -- Gladtex generates the HTML in the same directory as the source
    -- file, so we need to copy that to the final location.
    copyFile tempHtml finalHtml

    -- Remove the temporary file.
    removeFile $ Files.postHtex config post
    removeFile tempHtml

generatePosts :: Config -> IO ()
generatePosts config = do
  let n = length posts
      posts = blogPosts config
  forM_ (zip posts [0..]) $ \(p, i) ->
      do
        let prevPost = if i == 0 then Nothing else Just (posts !! (i - 1))
            nextPost = if i == n - 1 then Nothing else Just (posts !! (i + 1))

        generatePost config p
        h <- openFile (Files.postFinalHtml config p) WriteMode
        buildPost h config p (prevPost, nextPost)
        hClose h

generateIndex :: Config -> IO ()
generateIndex config = do
  let dest = Files.postFinalHtml config post
      index = Files.indexHtml config
      post = head $ blogPosts config

  exists <- doesFileExist index
  when exists $ removeFile index

  createSymbolicLink dest index

postModificationString :: Post -> IO String
postModificationString p = do
  tz <- getCurrentTimeZone
  localTime <- toLocalTime $ postModificationTime p
  return $ show localTime ++ "  " ++ timeZoneName tz

generateList :: Config -> IO ()
generateList config = do
  putStrLn "Generating all-posts list."

  -- For each post in the order they were given, extract the
  -- unrendered title and construct an htex document.  Then render it
  -- to the listing location.
  entries <- forM (blogPosts config) $ \p ->
             do
               created <- postModificationString p
               return $ concat [ "<div class=\"listing-entry\"><span class=\"post-title\">"
                               , "<a href=\"" ++ Files.postUrl config p ++ "\">"
                               , postTitle p 110
                               , "</a></span><span class=\"post-created\">Posted "
                               , created
                               , "</span></div>\n"
                               ]

  let content = "<div id=\"all-posts\">" ++ concat entries ++ "</div>"

  h <- openFile (Files.listHtex config) WriteMode
  buildPage h config content Nothing
  hClose h

  gladTex config (Files.listHtex config) "0000FF"

  -- Gladtex generates the HTML in the same directory as the source
  -- file, so we need to copy that to the final location.
  copyFile (Files.listTmpHtml config) (Files.listHtml config)

  -- Remove the temporary file.
  removeFile $ Files.listHtex config
  removeFile $ Files.listTmpHtml config

rssItem :: Config -> Post -> String
rssItem config p =
    concat [ "<item>"
           , "<title>" ++ postTitleRaw p ++ "</title>\n"
           , "<link>" ++ Files.postUrl config p ++ "</link>\n"
           , "<pubDate>" ++ rssModificationTime p ++ "</pubDate>\n"
           , "<guid>" ++ Files.postUrl config p ++ "</guid>\n"
           , "</item>\n"
           ]

generateRssFeed :: Config -> IO ()
generateRssFeed config = do
  h <- openFile (Files.rssXml config) WriteMode

  eTmpl <- loadTemplate $ Files.rssTemplatePath config

  case eTmpl of
    Left msg -> putStrLn msg >> exitFailure
    Right tmpl ->
        do
          let items = map (rssItem config) $ blogPosts config
              itemStr = concat items
              attrs = [ ("items", itemStr)
                      ]

          writeTemplate config h tmpl attrs
          hClose h

setup :: FilePath -> IO ()
setup dir = do
  exists <- doesDirectoryExist dir
  dataDir <- skelDir

  when (not exists) $ do
          putStrLn $ "Setting up data directory using skeleton: " ++ dataDir
          copyTree dataDir dir

ensureDirs :: Config -> IO ()
ensureDirs config = do
  let dirs = [ postSourceDir
             , htmlDir
             , stylesheetDir
             , postHtmlDir
             , postIntermediateDir
             , imageDir
             , templateDir
             , htmlTempDir
             , eqPreamblesDir
             ]

  forM_ (dirs <*> pure config) $ \d ->
      do
        exists <- doesDirectoryExist d
        when (not exists) $ createDirectory d

-- The files we look at to decide whether to regenerate the blog.
-- We'll always look at the post input files, but we also want to look
-- at other files to trigger a regeneration.
changedFiles :: Config -> [FilePath]
changedFiles config = [ Files.rssTemplatePath
                      , Files.pageTemplatePath
                      , Files.postTemplatePath
                      ] <*> pure config

preserveM :: (Monad m) => (a -> m b) -> a -> m (a, b)
preserveM act val = act val >>= \r -> return (val, r)

scanForChanges :: Config -> (Config -> IO ()) -> IO ()
scanForChanges config act = do
  t <- getCurrentTime
  scan t
      where
        scan t = do
          posts <- allPostFilenames $ postSourceDir config
          let filesToInspect = posts ++ changedFiles config
          allTimes <- mapM (preserveM getModificationTime) filesToInspect

          let modified = filter ((> t) . snd) allTimes
              nextTime = if null modified
                         then t
                         else maximum $ map snd modified

          when (not $ null modified) $
               do
                 putStrLn ""
                 putStrLn "Changes detected:"
                 forM_ modified $ \(fp, _) -> do
                              putStrLn $ "  " ++ fp
                 act config
          threadDelay $ 1 * 1000 * 1000
          scan nextTime

mkConfig :: FilePath -> IO Config
mkConfig base = do
  let configFilePath = base </> configFilename
  e <- doesFileExist configFilePath

  when (not e) $ do
                  putStrLn $ "Configuration file " ++ configFilePath ++ " not found"
                  exitFailure

  let requiredValues = [ "baseUrl"
                       , "title"
                       , "authorName"
                       , "authorEmail"
                       ]

  cfg <- Config.readConfig configFilePath requiredValues

  let Just cfg_baseUrl = lookup "baseUrl" cfg
      Just cfg_title = lookup "title" cfg
      Just cfg_authorName = lookup "authorName" cfg
      Just cfg_authorEmail = lookup "authorEmail" cfg

  -- Load blog posts from disk
  let postSrcDir = base </> "posts"
  allPosts <- loadPostIndex postSrcDir

  return $ Config { baseDir = base
                  , postSourceDir = postSrcDir
                  , htmlDir = base </> "html"
                  , stylesheetDir = base </> "html" </> "stylesheets"
                  , postHtmlDir = base </> "html" </> "posts"
                  , postIntermediateDir = base </> "generated"
                  , imageDir = base </> "html" </> "generated-images"
                  , templateDir = base </> "templates"
                  , htmlTempDir = base </> "tmp"
                  , baseUrl = cfg_baseUrl
                  , title = cfg_title
                  , authorName = cfg_authorName
                  , authorEmail = cfg_authorEmail
                  , eqPreamblesDir = base </> "eq-preambles"
                  , configPath = configFilePath
                  , blogPosts = allPosts
                  }

summarizeChanges :: Config -> IO ChangeSummary
summarizeChanges config = do
  -- Determine whether the configuration file changed.  Check to see
  -- if it's newer than the index.html file, or if no index.html
  -- exists then that's equivalent to "the config changed"
  configMtime <- getModificationTime $ configPath config
  indexExists <- doesFileExist $ Files.indexHtml config
  baseTime <- case indexExists of
                False -> do
                  t <- getCurrentTime
                  return $ t { utctDay = addDays (- 1) $ utctDay t }
                True -> getModificationTime $ Files.indexHtml config

  let configChanged' = configMtime > baseTime
      modifiedPosts = filter (\p -> postModificationTime p > baseTime) $ blogPosts config

  -- Determine whether any templates changed
  templateFiles <- dirFilenames (templateDir config)
  templateChanges <- forM templateFiles $ \f -> do
                            mtime <- getModificationTime f
                            return $ mtime > baseTime

  return $ ChangeSummary { configChanged = configChanged'
                         , postsChanged = map postFilename modifiedPosts
                         , templatesChanged = or templateChanges
                         }

usage :: IO ()
usage = do
  putStrLn "Usage: mb [-l]\n"
  putStrLn "mb is a tool for creating and managing a mathematically-inclined"
  putStrLn "weblog.  To use mb, you must set a few environment variables:"
  putStrLn ""
  putStrLn $ "  " ++ baseDirEnvName ++ ": path where blog files will be stored"
  putStrLn ""
  putStrLn " -l: make mb poll periodically and regenerate your blog content"
  putStrLn "     when something changes.  This is useful if you want to run a"
  putStrLn "     local web server to view your posts as you're writing them."

regenerateContent :: Config -> IO ()
regenerateContent config = do
  generatePosts config
  generateIndex config
  generateList config
  generateRssFeed config
  putStrLn "Done."

main :: IO ()
main = do
  env <- getEnvironment
  args <- getArgs

  checkForGladtex

  let mBase = lookup baseDirEnvName env

  when (isNothing mBase) $ usage >> exitFailure

  let Just dir = mBase

  when (head dir /= '/') $ do
         putStrLn $ baseDirEnvName ++ " must contain an absolute path"
         exitFailure

  putStrLn $ "mb: using base directory " ++ (show dir)

  setup dir
  config <- mkConfig dir
  ensureDirs config

  case args of
    [] -> regenerateContent config
    ["-l"] -> regenerateContent config >> scanForChanges config regenerateContent
    _ -> usage >> exitFailure