{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Simple tool to push all blobs from the Pantry database to Casa.

module Main where

import           Casa.Client
import           Control.Lens.TH
import           Control.Monad
import           Control.Monad.Logger (NoLoggingT)
import           Control.Monad.Trans.Resource
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Parser
import qualified Data.Aeson.Types as Aeson
import           Data.Conduit
import           Data.Generics
import           Data.List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time
import           Database.Persist
import           Database.Persist.Sqlite
import           Database.Persist.TH
import           Network.HTTP.Simple
import           Options.Applicative
import           Options.Applicative.Simple
import           Pantry
import           Pantry.Internal.Stackage hiding (migrateAll)
import           RIO
import           RIO.Orphans
import           RIO.Process
import           System.Environment

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
LastPushed
  blobId BlobId
SnapshotLoaded
  name Text
  timestamp UTCTime default=now()
  Unique SnapshotLoadedNameUnique name
|]

data CasaPush =
  CasaPush
    { _casaPushPantry :: !PantryApp
    , _casaPushResourceMap :: !ResourceMap
    }

$(makeLenses ''CasaPush)

instance HasLogFunc CasaPush where logFuncL = casaPushPantry . logFuncL
instance HasResourceMap CasaPush where resourceMapL = casaPushResourceMap

data PushConfig =
  PushConfig
    { configCasaUrl :: String
    }
  deriving (Show)

-- | Command-line config.
pushConfigParser :: Parser PushConfig
pushConfigParser =
  PushConfig <$>
  strOption (long "push-url" <> metavar "URL" <> help "Casa push URL")

data PopulateConfig =
  PopulateConfig
    { populateConfigSnapshot :: Unresolved RawSnapshotLocation
    , populateConfigConcurrentDownloads :: Int
    }

-- | Command-line config.
populateConfigParser :: Parser PopulateConfig
populateConfigParser =
  PopulateConfig <$>
  fmap
    (parseRawSnapshotLocation . T.pack)
    (strOption
       (long "snapshot" <> metavar "SNAPSHOT" <>
        help "Snapshot in usual Stack format (lts-1.1, nightly-...)")) <*>
  downloadConcurrencyParser

data ContinuousPopulatePushConfig =
  ContinuousPopulatePushConfig
    { continuousPopulatePushConfigSleepFor :: Int
    , continuousPopulatePushConfigSqliteFile :: Text
    , continuousPopulatePushConfigPopulateConfig :: PopulateConfig
    }

continuousPopulatePushConfig :: Parser ContinuousPopulatePushConfig
continuousPopulatePushConfig =
  ContinuousPopulatePushConfig <$>
  option
    auto
    (long "sleep-for" <> help "Sleep for at least n minutes between polling" <>
     metavar "INT") <*>
  fmap
    T.pack
    (strOption
       (long "sqlite-file" <> help "Filepath to use for sqlite database" <>
        metavar "PATH")) <*>
  populateConfigParser

downloadConcurrencyParser :: Parser Int
downloadConcurrencyParser =
  option
    auto
    (long "download-concurrency" <>
     help "How many package downloads to do at once" <>
     metavar "INT")

-- | Main entry point.
main :: IO ()
main = do
  ((), runCmd) <-
    simpleOptions
      "0"
      "casa-curator"
      "casa-curator"
      (pure ())
      (do addCommand "push" "Push ALL blobs to Casa" pushCommand pushConfigParser
          addCommand "status" "Give some stats about the pantry database" (const statusCommand) (pure ())
          addCommand
            "populate"
            "Populate the pantry database with blobs from a given snapshot"
            populateCommand
            populateConfigParser
          addCommand
            "continuous-populate-push"
            "Poll stackage for new snapshots, \"populate\" then \"push\", repeatedly"
            continuousPopulatePushCommand
            continuousPopulatePushConfig)
  runCmd

continuousPopulatePushCommand :: ContinuousPopulatePushConfig -> IO ()
continuousPopulatePushCommand continuousPopulatePushConfig = do
  runSqlite
    (continuousPopulatePushConfigSqliteFile continuousPopulatePushConfig)
    (runMigration migrateAll)
  runPantryApp
    (forever
       (do runSqlite
             (continuousPopulatePushConfigSqliteFile
                continuousPopulatePushConfig)
             pullAndPush
           delay))
  where
    delay =
      threadDelay
        (1000 * 60 *
         (continuousPopulatePushConfigSleepFor continuousPopulatePushConfig))
    pullAndPush = do
      availableNames <- liftIO downloadAllSnapshotTextNames
      loadedSnapshots :: [Entity SnapshotLoaded] <-
        selectList [] [] :: ReaderT SqlBackend (NoLoggingT (ResourceT (RIO env))) [Entity SnapshotLoaded]
      let loadedNames =
            Set.fromList (map (snapshotLoadedName . entityVal) loadedSnapshots)
          newNames = Set.difference availableNames loadedNames
          liftRIO = lift . lift . lift
      liftRIO
        (for_
           newNames
           (\snapshotTextName -> do
              let unresoledRawSnapshotLocation =
                    parseRawSnapshotLocation snapshotTextName
              rawSnapshot <-
                loadSnapshotByUnresolvedSnapshotLocation
                  unresoledRawSnapshotLocation
              populateFromRawSnapshot
                (populateConfigConcurrentDownloads
                   (continuousPopulatePushConfigPopulateConfig
                      continuousPopulatePushConfig))
                rawSnapshot))
      for_
        newNames
        (\name -> do
           now <- liftIO getCurrentTime
           insert_
             (SnapshotLoaded
                {snapshotLoadedName = name, snapshotLoadedTimestamp = now}))

statusCommand :: IO ()
statusCommand =
  runPantryApp
    (do pantryApp <- ask
        storage <- fmap (pcStorage . view pantryConfigL) ask
        withResourceMap
          (\resourceMap ->
             runRIO
               (CasaPush
                  { _casaPushResourceMap = resourceMap
                  , _casaPushPantry = pantryApp
                  })
               (withStorage_
                  storage
                  (do count <- allBlobsCount
                      lift (logInfo ("Blobs in database: " <> display count))))))

populateCommand :: MonadIO m => PopulateConfig -> m ()
populateCommand populateConfig =
  runPantryApp
    (do rawSnapshot <-
          loadSnapshotByUnresolvedSnapshotLocation unresoledRawSnapshotLocation
        populateFromRawSnapshot
          (populateConfigConcurrentDownloads populateConfig)
          rawSnapshot)
  where
    unresoledRawSnapshotLocation = populateConfigSnapshot populateConfig

-- | Start pushing.
pushCommand :: MonadIO m => PushConfig -> m ()
pushCommand config =
  runPantryApp
    (do pantryApp <- ask
        storage <- fmap (pcStorage . view pantryConfigL) ask
        withResourceMap
          (\resourceMap ->
             runRIO
               (CasaPush
                  { _casaPushResourceMap = resourceMap
                  , _casaPushPantry = pantryApp
                  })
               (withStorage_
                  storage
                  (do count <- allBlobsCount
                      blobsSink
                        (configCasaUrl config)
                        (allBlobsSource .| stickyProgress count)))))

-- | Output progress of blobs pushed.
stickyProgress ::
     (HasLogFunc env) => Int -> ConduitT i i (ReaderT r (RIO env)) ()
stickyProgress total = go (0 :: Int)
  where
    go i = do
      m <- await
      case m of
        Nothing ->
          lift (lift (logStickyDone ("Pushed " <> display total <> " blobs.")))
        Just v -> do
          let i' = i + 1
          lift
            (lift
               (logSticky
                  ("Pushing blobs: " <> display i' <> "/" <> display total)))
          yield v
          go i'

-- | Download all snapshots from stackage. The results are
-- paginated. We want everything, so we just keep increasing the page
-- index until we get a null result.
downloadAllSnapshotTextNames :: IO (Set Text)
downloadAllSnapshotTextNames = go 1 mempty
  where
    go page acc = do
      request <-
        parseRequest ("https://www.stackage.org/snapshots?page=" ++ show page)
      response :: Response Aeson.Value <- httpJSON request
      case getResponseStatusCode response of
        200 ->
          case Aeson.parseEither snapshotsParser (getResponseBody response) of
            Left err -> error err
            Right snapshots -> loop (acc <> Set.fromList snapshots)
              where loop =
                      if null snapshots
                        then pure
                        else go (page + 1)
        _ -> error ("Failed to download: " ++ show (getResponseStatus response))

-- | Parse the JSON from Stackage.
snapshotsParser :: Aeson.Value -> Aeson.Parser [Text]
snapshotsParser j = do
  o <- Aeson.parseJSON j
  snapshots :: [[[Text]]] <- o Aeson..: "snapshots"
  concatenatedSnapshots <-
    fmap
      concat
      (mapM
         (\grouping ->
            mapM
              (\snapshotSpec ->
                 case listToMaybe snapshotSpec of
                   Nothing -> fail "No snapshot name"
                   Just name -> pure name)
              grouping)
         snapshots)
  pure concatenatedSnapshots

-- | Populate the database with packages from a raw snapshot.
populateFromRawSnapshot ::
     (HasLogFunc env, HasPantryConfig env, HasProcessContext env)
  => Int
  -> RawSnapshot
  -> RIO env ()
populateFromRawSnapshot concurrentDownloads rawSnapshot = do
  let total = length (rsPackages rawSnapshot)
  pooledForConcurrentlyN_
    concurrentDownloads
    (zip [0 :: Int ..] (map rspLocation (M.elems (rsPackages rawSnapshot))))
    (\(i, rawPackageLocationImmutable) -> do
       logSticky
         ("Loading package: " <> display i <> "/" <> display total <> ": " <>
          display rawPackageLocationImmutable)
       loadPackageRaw rawPackageLocationImmutable)
  logStickyDone ("Loaded all " <> display total <> " packages.")

-- | Load a snapshot by its unresolved raw snapshot location (the
-- result of parsing from text).
loadSnapshotByUnresolvedSnapshotLocation ::
     (HasPantryConfig env, HasLogFunc env, HasProcessContext env)
  => Unresolved RawSnapshotLocation
  -> RIO env RawSnapshot
loadSnapshotByUnresolvedSnapshotLocation unresoledRawSnapshotLocation = do
  rawSnapshotLocation <- resolvePaths Nothing unresoledRawSnapshotLocation
  snapshotLocation <- completeSnapshotLocation rawSnapshotLocation
  loadSnapshot snapshotLocation
