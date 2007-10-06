-----------------------------------------------------------------------------
-- |
-- Module      :  Network.Hackage.CabalInstall.Fetch
-- Copyright   :  (c) David Himmelstrup 2005
-- License     :  BSD-like
--
-- Maintainer  :  lemmih@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
--
-----------------------------------------------------------------------------
module Network.Hackage.CabalInstall.Fetch
    (
     -- * Commands
     fetch
    , -- * Utilities
      fetchPackage
    , pkgURL
    , packageFile
    , packagesDirectory
    , isFetched
    , readURI
    , downloadIndex
    ) where

import Network.URI (URI,parseURI,uriScheme,uriPath)
import Network.HTTP (ConnError(..), Request (..), simpleHTTP
                           , Response(..), RequestMethod (..))

import Control.Exception (bracket)
import Control.Monad (filterM)
import Data.List (intersperse)
import Data.Version
import Text.Printf (printf)
import System.Directory (doesFileExist, createDirectoryIfMissing)

import Network.Hackage.CabalInstall.Types (ConfigFlags (..), OutputGen (..), UnresolvedDependency (..), Repo(..))
import Network.Hackage.CabalInstall.Config (packagesDirectory, repoCacheDir, packageFile, packageDir)
import Network.Hackage.CabalInstall.Dependency (filterFetchables, resolveDependencies)

import Distribution.Package (PackageIdentifier(..), showPackageId)
import Distribution.Verbosity
import System.FilePath ((</>), (<.>))
import System.Directory (copyFile)
import System.IO (IOMode(..), hPutStr, Handle, hClose, openBinaryFile)
import Text.ParserCombinators.ReadP (readP_to_S)
import Distribution.ParseUtils (parseDependency)


readURI :: URI -> IO String
readURI uri
    | uriScheme uri == "file:" = (readFile $ uriPath uri)
    | otherwise = do
        eitherResult <- simpleHTTP (Request uri GET [] "")
        case eitherResult of
           Left err -> fail $ printf "Failed to download '%s': %s" (show uri) (show err)
           Right rsp
               | rspCode rsp == (2,0,0) -> return (rspBody rsp)
               | otherwise -> fail $ "Failed to download '" ++ show uri ++ "': Invalid HTTP code: " ++ show (rspCode rsp)

downloadURI :: FilePath -- ^ Where to put it
            -> URI      -- ^ What to download
            -> IO (Maybe ConnError)
downloadURI path uri
    | uriScheme uri == "file:" = do
        copyFile (uriPath uri) path
        return Nothing
    | otherwise = do
        eitherResult <- simpleHTTP request
        case eitherResult of
           Left err -> return (Just err)
           Right rsp
               | rspCode rsp == (2,0,0) -> withBinaryFile path WriteMode (`hPutStr` rspBody rsp) 
				                          >> return Nothing
               | otherwise -> return (Just (ErrorMisc ("Invalid HTTP code: " ++ show (rspCode rsp))))
    where request = Request uri GET [] ""



downloadFile :: FilePath
             -> String
             -> IO (Maybe ConnError)
downloadFile path url
    = case parseURI url of
        Just parsed -> downloadURI path parsed
        Nothing -> return (Just (ErrorMisc ("Failed to parse url: " ++ show url)))


-- Downloads a package to [config-dir/packages/package-id] and returns the path to the package.
downloadPackage :: ConfigFlags -> PackageIdentifier -> Repo -> IO String
downloadPackage cfg pkg repo
    = do let url = pkgURL pkg repo
             dir = packageDir cfg pkg repo
             path = packageFile cfg pkg repo
         message (configOutputGen cfg) verbose $ "GET " ++ show url
         createDirectoryIfMissing True dir
         mbError <- downloadFile path url
         case mbError of
           Just err -> fail $ printf "Failed to download '%s': %s" (showPackageId pkg) (show err)
           Nothing -> return path

-- | Generate the URL of the tarball for a given package.
pkgURL :: PackageIdentifier -> Repo -> String
pkgURL pkg repo = joinWith "/" [repoURL repo, pkgName pkg, showVersion (pkgVersion pkg), showPackageId pkg] 
                           ++ ".tar.gz"
                      where joinWith tok = concat . intersperse tok

-- Downloads an index file to [config-dir/packages/serv-id].
downloadIndex :: ConfigFlags -> Repo -> IO FilePath
downloadIndex cfg repo
    = do let url = repoURL repo ++ "/" ++ "00-index.tar.gz"
             dir = repoCacheDir cfg repo
             path = dir </> "00-index" <.> "tar.gz"
         createDirectoryIfMissing True dir
         mbError <- downloadFile path url
         case mbError of
           Just err -> fail $ printf "Failed to download index '%s'" (show err)
           Nothing  -> return path

-- |Returns @True@ if the package has already been fetched.
isFetched :: ConfigFlags -> PackageIdentifier -> Repo -> IO Bool
isFetched cfg pkg repo
    = doesFileExist (packageFile cfg pkg repo)

-- |Fetch a package if we don't have it already.
fetchPackage :: ConfigFlags -> PackageIdentifier -> Repo -> IO String
fetchPackage cfg pkg repo
    = do fetched <- isFetched cfg pkg repo
         if fetched
            then do pkgIsPresent (configOutputGen cfg) pkg
                    return (packageFile cfg pkg repo)
            else do downloadingPkg (configOutputGen cfg) pkg
                    downloadPackage cfg pkg repo

-- |Fetch a list of packages and their dependencies.
fetch :: ConfigFlags -> [String] -> IO ()
fetch cfg pkgs
    = do apkgs <- fmap filterFetchables (resolveDependencies cfg [] (map parseDep pkgs))
         mapM_ (\(pkg,repo)
                    -> fetchPackage cfg pkg repo
               ) =<< filterM isNotFetched apkgs
    where parseDep dep
              = case readP_to_S parseDependency dep of
                 [] -> error ("Failed to parse package dependency: " ++ show dep)
                 x  -> UnresolvedDependency
                       { dependency = (fst (last x))
                       , depOptions = [] }
          isNotFetched (pkg,repo)
              = do fetched <- isFetched cfg pkg repo
                   pkgIsPresent output pkg
                   return (not fetched)
          output = configOutputGen cfg

withBinaryFile :: FilePath -> IOMode -> (Handle -> IO r) -> IO r
withBinaryFile name mode = bracket (openBinaryFile name mode) hClose
