{-# LANGUAGE TypeFamilies #-}

module Data.Yarr.Benchmarking where

import Prelude as P
import Control.Monad as M
import Text.Printf

import System.IO
import System.Time
import System.CPUTime.Rdtsc

import Data.Yarr.Base
import Data.Yarr.Shape
import Data.Yarr.Utils.FixedVector as V

-- | General IO action benchmarking modifier.
time :: Shape sh
     => String -- ^ Label to print in front of results.
     -> sh     -- ^ Shape of processed array, to compute tics per index metric.
     -> IO a   -- ^ Array loading action.
     -> IO a   -- ^ Modified action, additionaly traces to stderr
               --  it's execution time metrics.
{-# NOINLINE time #-}
time label range action = do
    (res, timings) <- timeIO action
    traceResults label range timings
    return res

-- | /Sequential/ splice-by-slice yarr loaing action modifier.
timeSlices
    :: (UVecSource r slr l sh v e, UVecTarget tr tslr tl sh v2 e,
        Dim v ~ Dim v2)
    => String                 -- ^ Label to print in front of results.
    -> sh                     -- ^ Shape of processed array,
                              --   to compute pics per index metric.
    -> (UArray slr l sh e ->
        UArray tslr tl sh e
        -> IO a)              -- ^ Action to perform on each array slice
    -> UArray r l sh (v e)    -- ^ Source array of vectors
    -> UArray tr tl sh (v2 e) -- ^ Target array of vectors
    -> IO (VecList (Dim v) a) -- ^ Results
{-# INLINE timeSlices #-}
timeSlices label range load arr tarr = do
    let {-# INLINE timeSlice #-}
        timeSlice i sl tsl =
            time (label ++ ": " ++ (show i)) range (load sl tsl)
    V.izipWithM timeSlice (slices arr) (slices tarr)

-- | Repeats (IO ()) action several times and traces timing stats.
bench :: Shape sh
      => String -- ^ Label to print in front of results.
      -> Int    -- ^ Number of repeats.
      -> sh     -- ^ Shape of array to compute tics per index metric.
      -> IO ()  -- ^ Array loading action.
      -> IO ()
{-# NOINLINE bench #-}
bench label repeats range action = do
    (BenchResults avMs devMs avTics devTics)
        <- benchIO repeats action

    let indices = fromIntegral (size range)
        avTicsPerIndex = avTics / indices
        devTicsPerIndex = devTics / indices

        ticsFmt = fmt avTicsPerIndex
        format :: String
        format =
            printf "%%s:\t%s ± %s ms,   %s ± %s tics per index (%%d repeats)"
                   (fmt avMs) (fmt avMs) ticsFmt ticsFmt

    trace $
        printf format
               label avMs devMs avTicsPerIndex devTicsPerIndex repeats

benchMin
    :: Shape sh
    => String
    -> Int
    -> sh
    -> IO ()
    -> IO ()
{-# NOINLINE benchMin #-}
benchMin label repreats range action = do
    minTimings <- benchMinIO repreats action
    traceResults label range minTimings


traceResults :: Shape sh => String -> sh -> (Integer, Integer) -> IO ()
traceResults label range (µss, tics) =
    trace (printf format label ms ticsPerIndex)
  where
    ms = (fromIntegral µss) / 1000

    indices = fromIntegral (size range)
    ticsPerIndex = (fromIntegral tics) / indices

    format :: String
    format = printf "%%-16s %s ms, %s tics per index" (fmt ms) (fmt ticsPerIndex)


benchSlices
    :: (UVecSource r slr l sh v e, UVecTarget tr tslr tl sh v2 e,
        Dim v ~ Dim v2)
    => String
    -> Int
    -> sh
    -> (UArray slr l sh e -> UArray tslr tl sh e -> IO ())
    -> UArray r l sh (v e)
    -> UArray tr tl sh (v2 e)
    -> IO ()
{-# INLINE benchSlices #-}
benchSlices label repeats range load arr tarr = do
    let {-# INLINE benchSlice #-}
        benchSlice i sl tsl =
            bench (label ++ ": " ++ (show i)) repeats range (load sl tsl)
    V.izipWithM benchSlice (slices arr) (slices tarr)
    return ()


data BenchResults =
    BenchResults {
        avMs    :: Float,
        devMs   :: Float,
        avTics  :: Float,
        devTics :: Float
    }

benchIO :: Int -> IO () -> IO BenchResults
benchIO repeats action = do
    results <- M.replicateM repeats (timeIO action)
    let (_, sample) = P.unzip results
        (µss, tics) = P.unzip sample
        (avµs, devµs) = stat repeats µss
        (avTics, devTics) = stat repeats tics
    return $ BenchResults (avµs / 1000) (devµs / 1000) avTics devTics

benchMinIO :: Int -> IO () -> IO (Integer, Integer)
benchMinIO repeats action = do
    results <- M.replicateM repeats (timeIO action)
    let (_, sample) = P.unzip results
    return $ P.minimum sample

stat :: Integral a => Int -> [a] -> (Float, Float)
stat repeats sample =
    let n = fromIntegral repeats
        sample' = P.map fromIntegral sample 
        average = (P.sum sample') / n
        devs2 = P.map (\t -> (t - average) ^ 2) sample'
        dev = sqrt ((P.sum devs2) / n)
    in (average, dev)

timeIO :: IO a -> IO (a, (Integer, Integer)) -- Microseconds, tics
timeIO action = do
    TOD sec1 pico1 <- getClockTime
    tics1 <- rdtsc
    res <- action
    tics2 <- rdtsc
    TOD sec2 pico2 <- getClockTime
    let µs1 = (pico1 + sec1 * 1000000000000) `quot` 1000000
        µs2 = (pico2 + sec2 * 1000000000000) `quot` 1000000
    return (res, (µs2 - µs1, fromIntegral (tics2 - tics1)))

fmt :: Float -> String
fmt t
    | t < 10    = "%5.2f"
    | t < 100   = "%4.1f "
    | otherwise = "%.0f   "

trace = hPutStrLn stderr
