module Futhark.CodeGen.ImpGen.Multicore.Base
 ( toParam
 , compileKBody
 , extractAllocations
 , compileThreadResult
 , HostEnv(..)
 , AtomicBinOp
 , MulticoreGen
 , getNumThreads
 , getNumThreads'
 , decideScheduling
 , decideScheduling'
 , groupResultArrays
 , renameSegBinOp
 , resultArrays
 , freeParams
 , renameHistOpLambda
 , atomicUpdateLocking
 , AtomicUpdate(..)
 , Locking(..)
 , getSpace
 , getIterationDomain
 , getReturnParams
 , segOpString
 )
 where

import Data.List
import Data.Bifunctor
import Data.Maybe

import Control.Monad
import Prelude hiding (quot, rem)
import Futhark.Error
import qualified Futhark.CodeGen.ImpCode.Multicore as Imp
import Futhark.CodeGen.ImpGen
import Futhark.IR.MCMem
import Futhark.Transform.Rename
import Futhark.Util (maybeNth)
import Futhark.MonadFreshNames

-- | Is there an atomic t'BinOp' corresponding to this t'BinOp'?
type AtomicBinOp =
  BinOp ->
  Maybe (VName -> VName -> Imp.Count Imp.Elements Imp.Exp -> Imp.Exp -> Imp.AtomicOp)

newtype HostEnv = HostEnv
  { hostAtomics :: AtomicBinOp }

type MulticoreGen = ImpM MCMem HostEnv Imp.Multicore



segOpString :: SegOp () MCMem -> MulticoreGen String
segOpString SegMap{} = return "segmap"
segOpString SegRed{} = return "segred"
segOpString SegScan{} = return "segscan"
segOpString SegHist{} = return "seghist"


toParam :: VName -> TypeBase shape u -> MulticoreGen Imp.Param
toParam name (Prim pt)      = return $ Imp.ScalarParam name pt
toParam name (Mem space)    = return $ Imp.MemParam name space
toParam name Array{} = do
  name_entry <- lookupVar name
  case name_entry of
    ArrayVar _ (ArrayEntry (MemLocation mem _ _) _) ->
      return $ Imp.MemParam mem DefaultSpace
    _ -> error $ "[toParam] Could not handle array for " ++ show name


getSpace :: SegOp () MCMem -> SegSpace
getSpace (SegHist _ space _ _ _ ) = space
getSpace (SegRed _ space _ _ _ ) = space
getSpace (SegScan _ space _ _ _ ) = space
getSpace (SegMap _ space _ _) = space

getIterationDomain :: SegOp () MCMem -> SegSpace -> MulticoreGen Imp.Exp
getIterationDomain SegMap{} space = do
  let ns = map snd $ unSegSpace space
      ns_64 = map (sExt Int64 . toExp' int32) ns
  return $ product ns_64
getIterationDomain _ space = do
  let ns = map snd $ unSegSpace space
      ns_64 = map (sExt Int64 . toExp' int32) ns
  case unSegSpace space of
     [_] -> return $ product ns_64
     _   -> return $ product $ init ns_64 -- Segmented reduction is over the inner most dimension

getReturnParams :: Pattern MCMem -> SegOp () MCMem -> MulticoreGen [Imp.Param]
getReturnParams pat SegRed{} = do
  let retvals = map patElemName $ patternElements pat
  retvals_ts <- mapM lookupType retvals
  zipWithM toParam retvals retvals_ts
getReturnParams _ _ = return mempty



renameSegBinOp :: [SegBinOp MCMem] -> MulticoreGen [SegBinOp MCMem]
renameSegBinOp segbinops =
  forM segbinops $ \(SegBinOp comm lam ne shape) -> do
    lam' <- renameLambda lam
    return $ SegBinOp comm lam' ne shape



compileKBody :: KernelBody MCMem
             -> ([(SubExp, [Imp.Exp])] -> ImpM MCMem () Imp.Multicore ())
             -> ImpM MCMem () Imp.Multicore ()
compileKBody kbody red_cont =
  compileStms (freeIn $ kernelBodyResult kbody) (kernelBodyStms kbody) $ do
    let red_res = kernelBodyResult kbody
    red_cont $ zip (map kernelResultSubExp red_res) $ repeat []



compileThreadResult :: SegSpace
                    -> PatElem MCMem -> KernelResult
                    -> MulticoreGen ()
compileThreadResult space pe (Returns _ what) = do
  let is = map (Imp.vi32 . fst) $ unSegSpace space
  copyDWIMFix (patElemName pe) is what []
compileThreadResult _ _ ConcatReturns{} =
  compilerBugS "compileThreadResult: ConcatReturn unhandled."
compileThreadResult _ _ WriteReturns{} =
  compilerBugS "compileThreadResult: WriteReturns unhandled."
compileThreadResult _ _ TileReturns{} =
  compilerBugS "compileThreadResult: TileReturns unhandled."



freeVariables :: Imp.Code -> [VName] -> [VName]
freeVariables code names  =
  namesToList $ freeIn code `namesSubtract` namesFromList names


freeParams :: Imp.Code -> [VName] -> MulticoreGen [Imp.Param]
freeParams code names = do
  let freeVars = freeVariables code names
  ts <- mapM lookupType freeVars
  zipWithM toParam freeVars ts

-- | Arrays for storing group results.
resultArrays :: String -> [SegBinOp MCMem] -> MulticoreGen [[VName]]
resultArrays s reds =
  forM reds $ \(SegBinOp _ lam _ shape) ->
    forM (lambdaReturnType lam) $ \t -> do
    let pt = elemType t
        full_shape = shape <> arrayShape t
    sDeclStackArray s pt full_shape DefaultSpace


-- | Arrays for storing group results shared between threads
groupResultArrays :: String
                  -> SubExp
                  -> [SegBinOp MCMem]
                  -> MulticoreGen [[VName]]
groupResultArrays s num_threads reds =
  forM reds $ \(SegBinOp _ lam _ shape) ->
    forM (lambdaReturnType lam) $ \t -> do
    let pt = elemType t
        full_shape = Shape [num_threads] <> shape <> arrayShape t
    sDeclStackArray s pt full_shape DefaultSpace


getNumThreads' :: VName -> MulticoreGen ()
getNumThreads' dest =
  emit $ Imp.Op $ Imp.MulticoreCall (Just dest) "futhark_context_get_num_threads"

getNumThreads :: MulticoreGen VName
getNumThreads = do
  v <- dPrim "num_threads" (IntType Int32)
  getNumThreads' v
  return v


isLoadBalanced :: Imp.Code -> Bool
isLoadBalanced (a Imp.:>>: b)    = isLoadBalanced a && isLoadBalanced b
isLoadBalanced (Imp.For _ _ _ a) = isLoadBalanced a
isLoadBalanced (Imp.If _ a b)    = isLoadBalanced a && isLoadBalanced b
isLoadBalanced (Imp.Comment _ a) = isLoadBalanced a
isLoadBalanced Imp.While{}       = False
isLoadBalanced (Imp.Op (Imp.ParLoop _ _ _ code _ _)) = isLoadBalanced code
isLoadBalanced _                 = True


segBinOpComm' :: [SegBinOp lore] -> Commutativity
segBinOpComm' = mconcat . map segBinOpComm

decideScheduling' :: SegOp () lore -> Imp.Code -> Imp.Scheduling
decideScheduling' SegHist{} _ = Imp.Static
decideScheduling' SegScan{} _ = Imp.Static
decideScheduling' (SegRed _ _ reds _ _) code =
  case segBinOpComm' reds of
    Commutative -> decideScheduling code
    Noncommutative ->  Imp.Static
decideScheduling' SegMap{} code = decideScheduling code


decideScheduling :: Imp.Code -> Imp.Scheduling
decideScheduling code  =
  if isLoadBalanced code then
    Imp.Static
  else
    Imp.Dynamic


-- | Try to extract invariant allocations.  If we assume that the
-- given 'Code' is the body of a 'SegOp', then it is always safe to
-- move the immediate allocations to the prebody.
extractAllocations :: Imp.Code -> (Imp.Code, Imp.Code)
extractAllocations segop_code = f segop_code
  where declared = Imp.declaredIn segop_code
        f (Imp.DeclareMem name space) =
          -- Hoisting declarations out is always safe.
          (Imp.DeclareMem name space, mempty)
        f (Imp.Allocate name size space)
          | not $ freeIn size `namesIntersect` declared =
              (Imp.Allocate name size space, mempty)
        f (x Imp.:>>: y) = f x <> f y
        f (Imp.While cond body) =
          (mempty, Imp.While cond body)
        f (Imp.For i it bound body) =
          (mempty, Imp.For i it bound body)
        f (Imp.Comment s code) =
          second (Imp.Comment s) (f code)
        f Imp.Free{} =
          mempty
        f (Imp.If cond tcode fcode) =
          let (ta, tcode') = f tcode
              (fa, fcode') = f fcode
          in (ta <> fa, Imp.If cond tcode' fcode')
        f (Imp.Op (Imp.ParLoop s i prebody body free info)) =
          let (body_allocs, body') = extractAllocations body
              (free_allocs, here_allocs) = f body_allocs
              free' = filter (not .
                              (`nameIn` Imp.declaredIn body_allocs) .
                              Imp.paramName) free
          in (free_allocs, here_allocs <>
              Imp.Op (Imp.ParLoop s i prebody body' free' info))
        f code =
          (mempty, code)




-------------------------
------- SegHist ---------
-------------------------
renameHistOpLambda :: [HistOp MCMem] -> MulticoreGen [HistOp MCMem]
renameHistOpLambda hist_ops =
  forM hist_ops $ \(HistOp w rf dest neutral shape lam) -> do
    lam' <- renameLambda lam
    return $ HistOp w rf dest neutral shape lam'


-- | Locking strategy used for an atomic update.
data Locking =
  Locking { lockingArray :: VName
            -- ^ Array containing the lock.
          , lockingIsUnlocked :: Imp.Exp
            -- ^ Value for us to consider the lock free.
          , lockingToLock :: Imp.Exp
            -- ^ What to write when we lock it.
          , lockingToUnlock :: Imp.Exp
            -- ^ What to write when we unlock it.
          , lockingMapping :: [Imp.Exp] -> [Imp.Exp]
            -- ^ A transformation from the logical lock index to the
            -- physical position in the array.  This can also be used
            -- to make the lock array smaller.
          }

-- | A function for generating code for an atomic update.  Assumes
-- that the bucket is in-bounds.
type DoAtomicUpdate lore r =
  [VName] -> [Imp.Exp] -> MulticoreGen ()

-- | The mechanism that will be used for performing the atomic update.
-- Approximates how efficient it will be.  Ordered from most to least
-- efficient.
data AtomicUpdate lore r
  = AtomicPrim (DoAtomicUpdate lore r)
  | AtomicCAS (DoAtomicUpdate lore r)
    -- ^ Can be done by efficient swaps.
  | AtomicLocking (Locking -> DoAtomicUpdate lore r)
    -- ^ Requires explicit locking.



atomicUpdateLocking :: AtomicBinOp -> Lambda MCMem
                    -> AtomicUpdate MCMem ()
atomicUpdateLocking atomicBinOp lam
  | Just ops_and_ts <- splitOp lam,
    all (\(_, t, _, _) -> supportedPrims $ primBitSize t) ops_and_ts =
    primOrCas ops_and_ts $ \arrs bucket ->
  -- If the operator is a vectorised binary operator on 32-bit values,
  -- we can use a particularly efficient implementation. If the
  -- operator has an atomic implementation we use that, otherwise it
  -- is still a binary operator which can be implemented by atomic
  -- compare-and-swap if 32 bits.
  forM_ (zip arrs ops_and_ts) $ \(a, (op, t, x, y)) -> do

  -- Common variables.
  old <- dPrim "old" t

  (arr', _a_space, bucket_offset) <- fullyIndexArray a bucket

  case opHasAtomicSupport old arr' bucket_offset op of
    Just f -> sOp $ f $ Imp.var y t
    Nothing -> atomicUpdateCAS t a old bucket x $
      x <-- Imp.BinOpExp op (Imp.var x t) (Imp.var y t)

  where opHasAtomicSupport old arr' bucket' bop = do
          let atomic f = Imp.Atomic . f old arr' bucket'
          atomic <$> atomicBinOp bop

        primOrCas ops
          | all isPrim ops = AtomicPrim
          | otherwise      = AtomicCAS

        isPrim (op, _, _, _) = isJust $ atomicBinOp op

atomicUpdateLocking _ op
  | [Prim t] <- lambdaReturnType op,
    [xp, _] <- lambdaParams op,
    supportedPrims (primBitSize t) = AtomicCAS $ \[arr] bucket -> do
      old <- dPrim "old" t
      atomicUpdateCAS t arr old bucket (paramName xp) $
        compileBody' [xp] $ lambdaBody op

atomicUpdateLocking _ op = AtomicLocking $ \locking arrs bucket -> do
  old <- dPrim "old" int32
  continue <- newVName "continue"
  dPrimVol_ continue int32
  continue <-- 0

  -- Correctly index into locks.
  (locks', _locks_space, locks_offset) <-
    fullyIndexArray (lockingArray locking) $ lockingMapping locking bucket

  -- Critical section
  let try_acquire_lock = do
        old <-- 0
        sOp $ Imp.Atomic $
          Imp.AtomicCmpXchg int32 old locks' locks_offset
          continue (lockingToLock locking)
      lock_acquired = Imp.var continue int32 -- .==. lockingIsUnlocked locking
      -- Even the releasing is done with an atomic rather than a
      -- simple write, for memory coherency reasons.
      release_lock = do
        old <-- lockingToLock locking
        sOp $ Imp.Atomic $
          Imp.AtomicCmpXchg int32 old locks' locks_offset
          continue (lockingToUnlock locking)

  -- Preparing parameters. It is assumed that the caller has already
  -- filled the arr_params. We copy the current value to the
  -- accumulator parameters.
  let (acc_params, _arr_params) = splitAt (length arrs) $ lambdaParams op
      bind_acc_params =
        everythingVolatile $
        sComment "bind lhs" $
        forM_ (zip acc_params arrs) $ \(acc_p, arr) ->
        copyDWIMFix (paramName acc_p) [] (Var arr) bucket

  let op_body = sComment "execute operation" $
                compileBody' acc_params $ lambdaBody op

      do_hist =
        everythingVolatile $
        sComment "update global result" $
        zipWithM_ (writeArray bucket) arrs $ map (Var . paramName) acc_params


  -- While-loop: Try to insert your value
  sWhile (Imp.var continue int32 .==. 0) $ do
    try_acquire_lock
    sWhen lock_acquired $ do
      dLParams acc_params
      bind_acc_params
      op_body
      do_hist
      release_lock
  where writeArray bucket arr val = copyDWIMFix arr bucket val []


atomicUpdateCAS :: PrimType
                -> VName -> VName
                -> [Imp.Exp] -> VName
                -> MulticoreGen ()
                -> MulticoreGen ()
atomicUpdateCAS t arr old bucket x do_op = do
  -- Code generation target:
  --
  -- old = d_his[idx];
  -- do {
  --   assumed = old;
  --   x = do_op(assumed, y);
  --   old = atomicCAS(&d_his[idx], assumed, tmp);
  -- } while(assumed != old);
  run_loop <- dPrimV "run_loop" 0
  everythingVolatile $ copyDWIMFix old [] (Var arr) bucket
  (arr', _a_space, bucket_offset) <- fullyIndexArray arr bucket

  bytes <- toIntegral $ primBitSize t
  (to, from) <- getBitConvertFunc $ primBitSize t
  -- While-loop: Try to insert your value
  let (toBits, _fromBits) =
        case t of FloatType _ ->
                    (\v -> Imp.FunExp to [v] bytes,
                     \v -> Imp.FunExp from [v] t)
                  _           -> (id, id)

  sWhile (Imp.var run_loop int32 .==. 0) $ do
    x <-- Imp.var old t
    do_op -- Writes result into x
    sOp $ Imp.Atomic $
      Imp.AtomicCmpXchg bytes old arr' bucket_offset
      run_loop (toBits (Imp.var x t))

-- | Horizontally fission a lambda that models a binary operator.
splitOp :: ASTLore lore => Lambda lore -> Maybe [(BinOp, PrimType, VName, VName)]
splitOp lam = mapM splitStm $ bodyResult $ lambdaBody lam
  where n = length $ lambdaReturnType lam
        splitStm (Var res) = do
          Let (Pattern [] [pe]) _ (BasicOp (BinOp op (Var x) (Var y))) <-
            find (([res]==) . patternNames . stmPattern) $
            stmsToList $ bodyStms $ lambdaBody lam
          i <- Var res `elemIndex` bodyResult (lambdaBody lam)
          xp <- maybeNth i $ lambdaParams lam
          yp <- maybeNth (n+i) $ lambdaParams lam
          guard $ paramName xp == x
          guard $ paramName yp == y
          Prim t <- Just $ patElemType pe
          return (op, t, paramName xp, paramName yp)
        splitStm _ = Nothing


getBitConvertFunc :: Int -> MulticoreGen (String, String)
-- getBitConvertFunc 8 = return $ ("to_bits8, from_bits8")
-- getBitConvertFunc 16 = return $ ("to_bits8, from_bits8")
getBitConvertFunc 32 = return  ("to_bits32", "from_bits32")
getBitConvertFunc 64 = return  ("to_bits64", "from_bits64")
getBitConvertFunc b = error $ "number of bytes is supported " ++ pretty b


supportedPrims :: Int -> Bool
supportedPrims 8  = True
supportedPrims 16 = True
supportedPrims 32 = True
supportedPrims 64 = True
supportedPrims _  = False

-- Supported bytes lengths by GCC (and clang) compiler
toIntegral :: Int -> MulticoreGen PrimType
toIntegral 8  = return int8
toIntegral 16 = return int16
toIntegral 32 = return int32
toIntegral 64 = return int64
toIntegral b  = error $ "number of bytes is not supported for CAS - " ++ pretty b