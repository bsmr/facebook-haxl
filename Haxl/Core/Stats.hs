-- Copyright (c) 2014-present, Facebook, Inc.
-- All rights reserved.
--
-- This source code is distributed under the terms of a BSD license,
-- found in the LICENSE file.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Types and operations for statistics and profiling.  Most users
-- should import "Haxl.Core" instead of importing this module
-- directly.
--
module Haxl.Core.Stats
  (
  -- * Data-source stats
    Stats(..)
  , FetchStats(..)
  , Microseconds
  , Timestamp
  , getTimestamp
  , emptyStats
  , numFetches
  , ppStats
  , ppFetchStats

  -- * Profiling
  , Profile
  , emptyProfile
  , profile
  , ProfileLabel
  , ProfileData(..)
  , emptyProfileData
  , AllocCount
  , LabelHitCount
  , MemoHitCount

  -- * Allocation
  , getAllocationCounter
  , setAllocationCounter
  ) where

import Data.Aeson
import Data.HashMap.Strict (HashMap)
import Data.HashSet (HashSet)
import Data.Int
import Data.List (intercalate, maximumBy, minimumBy)
import Data.Semigroup (Semigroup)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Time.Clock.POSIX
import Text.Printf
import qualified Data.HashMap.Strict as HashMap
import qualified Data.HashSet as HashSet
import qualified Data.Text as Text

import GHC.Conc (getAllocationCounter, setAllocationCounter)

-- ---------------------------------------------------------------------------
-- Measuring time

type Microseconds = Int64
type Timestamp = Microseconds -- since an epoch

getTimestamp :: IO Timestamp
getTimestamp = do
  t <- getPOSIXTime -- for now, TODO better
  return (round (t * 1000000))

-- ---------------------------------------------------------------------------
-- Stats

-- | Stats that we collect along the way.
newtype Stats = Stats [FetchStats]
  deriving (Show, ToJSON, Semigroup, Monoid)

-- | Pretty-print Stats.
ppStats :: Stats -> String
ppStats (Stats rss) =
  intercalate "\n"
    [ "["
    ++ [
      if fetchWasRunning rs
          (minStartTime + (t - 1) * usPerDash)
          (minStartTime + t * usPerDash)
        then '*'
        else '-'
      | t <- [1..numDashes]
      ]
    ++ "] " ++ show i ++ " - " ++ ppFetchStats rs
    | (i, rs) <- zip [(1::Int)..] validFetchStats ]
  where
    isFetchStats FetchStats{} = True
    isFetchStats _ = False
    validFetchStats = filter isFetchStats (reverse rss)
    numDashes = 50
    minStartTime = fetchStart $ minimumBy (comparing fetchStart) validFetchStats
    lastFs = maximumBy (comparing (\fs -> fetchStart fs + fetchDuration fs))
      validFetchStats
    usPerDash = (fetchStart lastFs + fetchDuration lastFs - minStartTime)
      `div` numDashes
    fetchWasRunning :: FetchStats -> Timestamp -> Timestamp -> Bool
    fetchWasRunning fs t1 t2 =
      (fetchStart fs + fetchDuration fs) >= t1 && fetchStart fs < t2


-- | Maps data source name to the number of requests made in that round.
-- The map only contains entries for sources that made requests in that
-- round.
data FetchStats
    -- | Timing stats for a (batched) data fetch
  = FetchStats
    { fetchDataSource :: Text
    , fetchBatchSize :: {-# UNPACK #-} !Int
    , fetchStart :: !Timestamp          -- TODO should be something else
    , fetchDuration :: {-# UNPACK #-} !Microseconds
    , fetchSpace :: {-# UNPACK #-} !Int64
    , fetchFailures :: {-# UNPACK #-} !Int
    }

    -- | The stack trace of a call to 'dataFetch'.  These are collected
    -- only when profiling and reportLevel is 5 or greater.
  | FetchCall
    { fetchReq :: String
    , fetchStack :: [String]
    }
  deriving (Show)

-- | Pretty-print RoundStats.
ppFetchStats :: FetchStats -> String
ppFetchStats FetchStats{..} =
  printf "%s: %d fetches (%.2fms, %d bytes, %d failures)"
    (Text.unpack fetchDataSource) fetchBatchSize
    (fromIntegral fetchDuration / 1000 :: Double)  fetchSpace fetchFailures
ppFetchStats (FetchCall r ss) = show r ++ '\n':show ss

instance ToJSON FetchStats where
  toJSON FetchStats{..} = object
    [ "datasource" .= fetchDataSource
    , "fetches" .= fetchBatchSize
    , "start" .= fetchStart
    , "duration" .= fetchDuration
    , "allocation" .= fetchSpace
    , "failures" .= fetchFailures
    ]
  toJSON (FetchCall req strs) = object
    [ "request" .= req
    , "stack" .= strs
    ]

emptyStats :: Stats
emptyStats = Stats []

numFetches :: Stats -> Int
numFetches (Stats rs) = sum [ fetchBatchSize | FetchStats{..} <- rs ]


-- ---------------------------------------------------------------------------
-- Profiling

type ProfileLabel = Text
type AllocCount = Int64
type LabelHitCount = Int64
type MemoHitCount = Int64

newtype Profile = Profile
  { profile      :: HashMap ProfileLabel ProfileData
     -- ^ Data on individual labels.
  }

emptyProfile :: Profile
emptyProfile = Profile HashMap.empty

data ProfileData = ProfileData
  { profileAllocs :: {-# UNPACK #-} !AllocCount
     -- ^ allocations made by this label
  , profileDeps :: HashSet ProfileLabel
     -- ^ labels that this label depends on
  , profileFetches :: HashMap Text Int
     -- ^ map from datasource name => fetch count
  , profileLabelHits :: {-# UNPACK #-} !LabelHitCount
     -- ^ number of hits at this label
  , profileMemoHits :: {-# UNPACK #-} !MemoHitCount
     -- ^ number of hits to memoized computation at this label
  }
  deriving Show

emptyProfileData :: ProfileData
emptyProfileData = ProfileData 0 HashSet.empty HashMap.empty 0 0
