{-# Language DeriveDataTypeable, RecordWildCards, TypeSynonymInstances,
    FlexibleInstances #-}
module Main where
import Control.Applicative
import Control.Concurrent (getNumCapabilities)
import Control.DeepSeq
import Control.Monad 
import Control.Monad.State
import Control.Monad.Writer
import Control.Parallel.Strategies
import Data.Binary.Strict.Get
import Data.List
import Data.List.Split (chunk)
import Data.Maybe
import Data.Word
import Foreign.Storable (sizeOf)
import OpenSSL.Random
import System.Console.CmdArgs
import System.Directory
import System.Exit
import System.IO
import System.Random.Mersenne.Pure64 
import Text.Printf
import qualified Data.BanditSolver.LTS as LTS
import Data.BanditSolver.OBFinder
import qualified Data.BanditSolver.Poker as Poker
import qualified Data.BanditSolver.UCB1 as UCB1

main :: IO ()
main = do
    opts <- cmdArgs prgMode
    checkOpts opts
    runMode opts

runMode :: Args -> IO ()
runMode opts@Bandit{..} = do
    print opts
    threads <- getNumCapabilities
    let roundsList = takeWhile (< rounds) ([10,20..90]++[100,200..900]++[1000,2000..9000]) ++ [rounds]
        (bestArmList, badArmList, numArmsList) = makeParamLists opts
        strat = case algo of
            LTS -> StratLTS
            UCB1 -> StratUCB1
            Poker -> error "Poker is not available."
        paramLength = length bestArmList 
                        * length badArmList 
                        * length numArmsList
    gs <- replicateM (paramLength * length roundsList)
                     $ pureMT `fmap` getOpenSSLRand
    let results = parMap' threads deepid . getZipList 
          $ ZipList (evalState <$> (findOB 
                                    <$> roundsList
                                    <*> bestArmList
                                    <*> badArmList
                                    <*> [armEstimate]
                                    <*> numArmsList 
                                    <*> [strat])
                    ) <*> ZipList gs
    showProgress results
    writeResults opts $ chunk paramLength results
  where parMap' n f = withStrategy (parBuffer n rseq) . map f
        deepid e = e `deepseq` e

runMode opts@BruteForce{..}  = do
    print opts
    let obNoiseRange = [obStart
                       ,obStart + obStep
                       .. obEnd]
    results <- mapM (execWriterT . LTS.runAveragedLTS bestArm badArm 
                                        armEstimate numArms rounds repetitions)
                    obNoiseRange
    let resultsTr = transpose results -- rows: rounds, columns: ob
    showProgress results
    writeResults opts resultsTr

runMode opts@InstantRewards{..} = do
    print opts
    gen <- pureMT `fmap` getOpenSSLRand
    let result = 
            case algo of
                 LTS -> LTS.runAveragedInstantRewards bestArm badArm 
                                armEstimate numArms rounds repetitions obNoise
                                gen
                 UCB1 -> UCB1.runAveragedInstantRewards bestArm badArm numArms 
                                rounds repetitions gen
                 Poker -> Poker.runAveragedInstantRewards bestArm badArm 
                                    numArms rounds repetitions gen
    writeResults opts [result]

makeParamLists ::  Args -> ([(Double, Double)], [(Double, Double)], [Int])
makeParamLists Bandit{..} =
    case vary of 
         Just BestArmMean ->
              (makeMeanRange bestArm
              ,[badArm]
              ,[numArms])
         Just BestArmStdDev -> 
            (makeStdDevRange bestArm
            ,[badArm]
            ,[numArms])
         Just BadArmMean -> 
            ([bestArm]
            ,makeMeanRange badArm
            ,[numArms])
         Just BadArmStdDev -> 
            ([bestArm]
            ,makeStdDevRange badArm
            ,[numArms])
         Just NumArms ->
            ([bestArm]
            ,[badArm]
            ,[ n | let start = numArms
                 , let step = (round.fst.fromJust) stepEnd      
                 , let stop = (round.snd.fromJust) stepEnd      
                 , n <- makeRange start stop step ])
         _ -> ([bestArm], [badArm], [numArms])
  where
    makeRange start stop step = [start, start + step .. stop]
    makeMeanRange arm = 
        [(m, snd arm) | let start = fst arm
             , let (step, stop) = fromJust stepEnd
             , m <- makeRange start stop step ]
    makeStdDevRange arm = 
        [(fst arm, s ) | let start = snd arm
             , let (step, stop) = fromJust stepEnd
             , s <- makeRange start stop step ]

makeParamLists _ = undefined

writeResults :: Args -> [[String]] -> IO ()
writeResults mode resultlist = do
    let dir  = case mode of
                BruteForce{} -> "bruteforce"
                InstantRewards{} -> "instantrewards"
                Bandit{} -> "bandit"
        file = dir ++ "/" ++ filename mode
        hdr = header mode
    createDirectoryIfMissing True dir
    h <- openFile file WriteMode
    hSetBuffering h LineBuffering
    hPutStrLn h hdr
    hPutStrLn h . unlines $ intercalate [""] resultlist 
    hClose h
    
showDouble :: Double -> String
showDouble = printf "%f" 

-- Get a decent random seed
-- randBytes is not thread-safe!
getOpenSSLRand :: IO Word64
getOpenSSLRand = do
    bytes <- randBytes n 
    let (Right w64, _) = runGet getWord64host bytes
    return w64
  where n = sizeOf (undefined :: Word64)


putProgress :: String -> IO ()
putProgress s = hPutStr stderr $ '\r' : s

drawProgressBar :: Int -> Rational -> String
drawProgressBar width progress = 
    "[" ++ replicate bars '×' ++ replicate spaces '·' ++ "]"
    where bars   = round (progress * fromIntegral width)
          spaces = width - bars
          
drawPercentage :: Rational -> String
drawPercentage progress = printf "%3d%%" ( round (progress * 100) :: Int )

showProgress :: [a] -> IO ()
showProgress xs = do
    let len = fromIntegral $ length xs
    putProgress $ drawProgressBar 80 0 ++ " " ++ drawPercentage 0
    flip evalStateT 0 $ forM_ xs $ \e -> e `seq` do
        modify (+1)
        progress <- (/len) `fmap` get
        lift . putProgress $ drawProgressBar 80 progress 
                                ++ " " 
                                ++ drawPercentage progress
    hPutStrLn stderr " Done." 


data WhatRange = BestArmMean | BestArmStdDev | BadArmMean | BadArmStdDev
                 | NumArms
    deriving (Eq,Show,Data,Typeable)
data Algorithm  = LTS | UCB1 | Poker
    deriving (Eq,Show,Data,Typeable)

data Args = BruteForce
        { obStart :: Double
        , obEnd   :: Double
        , obStep  :: Double
        , rounds  :: Int
        , repetitions :: Int
        , bestArm :: (Double, Double)
        , badArm  :: (Double, Double)
        , armEstimate  :: (Double, Double)
        , numArms  :: Int }
        | Bandit
        { rounds  :: Int
        , bestArm :: (Double, Double)
        , badArm  :: (Double, Double)
        , armEstimate  :: (Double, Double)
        , numArms  :: Int
        , vary  :: Maybe WhatRange
        , stepEnd  :: Maybe (Double, Double)
        , algo     :: Algorithm}
        | InstantRewards
        { obNoise :: Double 
        , rounds  :: Int
        , repetitions :: Int
        , bestArm :: (Double, Double)
        , badArm  :: (Double, Double)
        , armEstimate  :: (Double, Double)
        , numArms  :: Int
        , algo     :: Algorithm}
        deriving (Data, Typeable, Show, Eq)

bruteforce :: Args
bruteforce = BruteForce
    {rounds      = def
    ,bestArm     = def
    ,badArm      = def
    ,armEstimate = def
    ,numArms     = def
    ,obStart = def &= help "Start for observation noise"
    ,obEnd   = def
    ,obStep  = def
    ,repetitions = def
    } &= help "Use a brute-force method to test all observation noises\
             \ in the specified range."

bandit :: Args
bandit = Bandit
    {rounds      = def
    ,bestArm     = def
    ,badArm      = def
    ,armEstimate = def
    ,numArms     = def
    ,vary        = def
    ,stepEnd     = def
    ,algo        = UCB1
    } &= help "Use a bandit solver to find the best observation noise\
             \ for the specified scenario."

instant :: Args
instant = InstantRewards
    {obNoise     = def
    ,rounds      = def
    ,repetitions = def
    ,bestArm     = def
    ,badArm      = def
    ,armEstimate = def
    ,numArms     = def
    ,algo        = LTS
    } &= help "Get the instant rewards\
             \ for the specified scenario."

{- 
 - good-5.0-2.0_bad-4.0,4.0_est-10.0,0.5_num-2_ob-0.6_rounds-1000_repetitions-1000000.data
 -}

filename :: Args -> String
filename BruteForce{..} = concat 
    ["good-", showDouble $ fst bestArm, ",", showDouble $ snd bestArm
    ,"_bad-", showDouble $ fst badArm, ",", showDouble $ snd badArm
    ,"_est-", showDouble $ fst armEstimate, ",", showDouble $ snd armEstimate
    ,"_num-", show numArms
    ,"_obnoise-(", showDouble obStart, ",", showDouble obEnd, ",", showDouble obStep, ")"
    ,"_rounds-", show rounds
    ,"_reps-", show repetitions
    ,".data"
    ]
filename InstantRewards{..} = concat 
    ["good-", showDouble $ fst bestArm, ",", showDouble $ snd bestArm
    ,"_bad-", showDouble $ fst badArm, ",", showDouble $ snd badArm
    ,est
    ,"_num-", show numArms
    ,ob
    ,"_rounds-", show rounds
    ,"_reps-", show repetitions
    ,"_algo-", show algo
    ,".data"
    ]
  where
    est = case algo of
               LTS -> concat ["_est-", showDouble $ fst armEstimate, ",", showDouble $ snd armEstimate]
               _   -> ""
    ob = case algo of
              LTS -> "_obnoise-" ++ showDouble obNoise
              _   -> "" 
 
filename Bandit{..} = concat 
    ["good-", good
    ,"_bad-", bad
    ,"_est-", showDouble $ fst armEstimate, ",", showDouble $ snd armEstimate
    ,"_num-", num
    ,"_rounds-", show rounds
    ,"_algo-",   show algo
    ,".data"
    ]
  where
    good = case vary of
        Just BestArmMean   -> concat [vari $ fst bestArm, ",", showDouble $ snd bestArm] 
        Just BestArmStdDev -> concat [showDouble $ fst bestArm, ",", vari $ snd bestArm] 
        _                  -> concat [showDouble $ fst bestArm, ",", showDouble $ snd bestArm]
    bad = case vary of
        Just BadArmMean   -> concat [vari $ fst badArm, ",", showDouble $ snd badArm] 
        Just BadArmStdDev -> concat [showDouble $ fst badArm, ",", vari $ snd badArm] 
        _                  -> concat [showDouble $ fst badArm, ",", showDouble $ snd badArm]
    vari x =
        let step = fst . fromJust $ stepEnd
            end  = snd . fromJust $ stepEnd
        in  concat ["(", showDouble x, ",", showDouble end, ",", showDouble step, ")"]
    num = case vary of
        Just NumArms -> let step = fst . fromJust $ stepEnd
                            end  = snd . fromJust $ stepEnd
                        in concat ["(", show numArms, "," , show end, ",", show step, ")"]
        _            -> show numArms

header :: Args -> String
header BruteForce{..} =
            "# Round | Observation noise | Cumulative reward"
header InstantRewards{..} =
            "# Round | Instant reward | standard deviation"
header Bandit{..} =
            "# best arm mean | best arm standard deviation\
            \ | bad arm mean | bad arm standard deviation\
            \ | arm count | rounds | best observation noise"

prgMode :: Args
prgMode = modes [bandit &= auto, bruteforce, instant] 
        &= help "Find the best observation noise for LTS."
        &= program "Noisy" &= summary "Noisy v0.2"

checkOpts :: Args -> IO ()
checkOpts opts = 
    let requirements = case opts of 
            BruteForce{..} -> 
                [(repetitions < 1, "Repetitions must be > 0.", True)
                ,(obStart <= 0,
                    "Start of observation noise range must be > 0.", True)
                ,(obEnd < obStart,
                    "End of observation noise range must be greater than start.",
                    True)
                ,(obStep <= 0,
                    "Observation noise step must be > 0.", True)
                ,(armEstimate == (0.0,0.0),
                    "Estimate has default value (0.0, 0.0).", False)
                ]
            Bandit{..} -> 
                [((isJust vary && isNothing stepEnd)
                    || (isNothing vary && isJust stepEnd) 
                    , "Either both or none of vary and stepend must be specified"
                    , True)
                ,(armEstimate == (0.0,0.0),
                    "Estimate has default value (0.0, 0.0).", False)
                ]
            InstantRewards{..} ->
                [(algo == LTS && obNoise <= 0, "Observation noise must be > 0.", True)
                ,(algo == LTS && armEstimate == (0.0,0.0),
                    "Estimate has default value (0.0, 0.0).", False)
                ,(algo == UCB1 && numArms > rounds,
                    "UCB1 does not work when the number of arms is > rounds.", True)
                ,(repetitions < 1, "Repetitions must be > 0.", True)
                ]

            ++  [(rounds opts < 1, "Rounds must be > 0.", True)
                ,(numArms opts < 2, "Number of arms must be > 1.", True)
                ,(badArm opts == (0.0,0.0),
                    "Bad arm has default value (0.0, 0.0).", False)
                ,(bestArm opts == (0.0,0.0),
                    "Best arm has default value (0.0, 0.0).", False)
                ,((fst.badArm) opts > (fst.bestArm) opts,
                    "Bad arm must be worse than best arm.", True)
                ]
    in mapM_ handle requirements
  where handle (predicate, msg, fatal) = when predicate $ 
                                            putStrLn (msgType fatal ++ msg) >> when fatal quit
        quit = exitWith (ExitFailure 1)
        msgType fatal = if fatal then "\x1b[1;31mError: \x1b[0m" else "\x1b[0;33mWarning: \x1b[0m"

