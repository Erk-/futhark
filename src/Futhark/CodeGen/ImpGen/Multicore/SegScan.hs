module Futhark.CodeGen.ImpGen.Multicore.SegScan
  (compileSegScan
  )
  where

import Control.Monad
import Data.List
import Prelude hiding (quot, rem)

import qualified Futhark.CodeGen.ImpCode.Multicore as Imp

import Futhark.CodeGen.ImpGen
import Futhark.IR.MCMem
import Futhark.CodeGen.ImpGen.Multicore.Base

import Futhark.Util.IntegralExp (quot, rem)

-- Compile a SegScan construct
compileSegScan :: Pattern MCMem
               -> SegSpace
               -> [SegBinOp MCMem]
               -> KernelBody MCMem
               -> VName
               -> MulticoreGen Imp.Code
compileSegScan pat space reds kbody nsubtasks
  | [_] <- unSegSpace space =
      nonsegmentedScan pat space reds kbody nsubtasks
  | otherwise =
      segmentedScan pat space reds kbody


xParams, yParams :: SegBinOp MCMem -> [LParam MCMem]
xParams scan =
  take (length (segBinOpNeutral scan)) (lambdaParams (segBinOpLambda scan))
yParams scan =
  drop (length (segBinOpNeutral scan)) (lambdaParams (segBinOpLambda scan))

lamBody :: SegBinOp MCMem -> Body MCMem
lamBody = lambdaBody . segBinOpLambda


nonsegmentedScan :: Pattern MCMem
                 -> SegSpace
                 -> [SegBinOp MCMem]
                 -> KernelBody MCMem
                 -> VName
                 -> MulticoreGen Imp.Code
nonsegmentedScan pat space scan_ops kbody nsubtasks = do
  emit $ Imp.DebugPrint "nonsegmented segScan" Nothing

  collect $ do
    scanStage1 pat space nsubtasks scan_ops kbody

    nsubtasks' <- toExp $ Var nsubtasks
    sWhen (nsubtasks' .>. 1) $ do
      scan_ops2 <- renameSegBinOp scan_ops
      scanStage2 pat nsubtasks space scan_ops2 kbody
      scan_ops3 <- renameSegBinOp scan_ops
      scanStage3 pat nsubtasks space scan_ops3 kbody

scanStage1 :: Pattern MCMem
           -> SegSpace
           -> VName
           -> [SegBinOp MCMem]
           -> KernelBody MCMem
           -> MulticoreGen ()
scanStage1 pat space nsubtasks scan_ops kbody = do
  let (all_scan_res, map_res) = splitAt (segBinOpResults scan_ops) $ kernelBodyResult kbody
      per_scan_res           = segBinOpChunks scan_ops all_scan_res
      per_scan_pes           = segBinOpChunks scan_ops $ patternValueElements pat
  let (is, ns) = unzip $ unSegSpace space
  ns' <- mapM toExp ns
  iter <- dPrimV "iter" 0

  -- Stage 1 : each thread partially scans a chunk of the input
  -- Writes directly to the resulting array
  tid' <- toExp $ Var $ segFlat space

  -- Accumulator array for each thread to use
  accs <- groupResultArrays "scan_stage_1_accum_arr" (Var nsubtasks) scan_ops
  prebody <- collect $
    forM_ (zip scan_ops accs) $ \(scan_op, acc) ->
      sLoopNest (segBinOpShape scan_op) $ \vec_is ->
        forM_ (zip acc $ segBinOpNeutral scan_op) $ \(acc', ne) ->
          copyDWIMFix acc' (tid' : vec_is) ne []

  body <- collect $ do
    zipWithM_ dPrimV_ is $ unflattenIndex ns' $ Imp.vi32 iter
    dScope Nothing $ scopeOfLParams $ concatMap (lambdaParams . segBinOpLambda) scan_ops
    sComment "stage 1 scan body" $
      compileStms mempty (kernelBodyStms kbody) $ do
        sComment "write mapped values results to memory" $ do
          let map_arrs = drop (segBinOpResults scan_ops) $ patternElements pat
          zipWithM_ (compileThreadResult space) map_arrs map_res

        forM_ (zip4 per_scan_pes scan_ops per_scan_res accs) $ \(pes, scan_op, scan_res, acc) ->
          sLoopNest (segBinOpShape scan_op) $ \vec_is -> do

          -- Read accum value
          forM_ (zip (xParams scan_op) acc) $ \(p, acc') ->
            copyDWIMFix (paramName p) [] (Var acc') (tid' : vec_is)

          -- Read next value
          sComment "Read next values" $
            forM_ (zip (yParams scan_op) scan_res) $ \(p, se) ->
              copyDWIMFix (paramName p) [] (kernelResultSubExp se) vec_is

          compileStms mempty (bodyStms $ lamBody scan_op) $
            forM_ (zip3 acc pes (bodyResult $ lamBody scan_op)) $
              \(acc', pe, se) -> do
                copyDWIMFix (patElemName pe) (map Imp.vi32 is ++ vec_is) se []
                copyDWIMFix acc' (tid' : vec_is) se []

  free_params <- freeParams (prebody <> body) (segFlat space : [iter])
  emit $ Imp.Op $ Imp.MCFunc "scan_stage_1" iter prebody body free_params $
    Imp.MulticoreInfo Imp.Static (segFlat space)


scanStage2 :: Pattern MCMem
           -> VName
           -> SegSpace
           -> [SegBinOp MCMem]
           -> KernelBody MCMem
           -> MulticoreGen ()
scanStage2 pat nsubtasks space scan_ops kbody = do
  emit $ Imp.DebugPrint "nonsegmentedScan stage 2" Nothing
  let (is, ns) = unzip $ unSegSpace space
      per_scan_pes = segBinOpChunks scan_ops $ patternValueElements pat
  ns' <- mapM toExp ns
  nsubtasks' <- toExp $ Var nsubtasks

  -- |
  -- Begin stage two of scan
  dScope Nothing $ scopeOfLParams $ concatMap (lambdaParams . segBinOpLambda) scan_ops

  offset <- dPrimV "offset" 0
  offset' <- toExp $ Var offset

  offset_index <- dPrimV "offset_index" 0
  offset_index' <- toExp $ Var offset_index

  let iter_pr_subtask = product ns' `quot` nsubtasks'
      remainder       = product ns' `rem` nsubtasks'

  accs <- resultArrays "scan_stage_2_accum" scan_ops
  forM_ (zip scan_ops accs) $ \(scan_op, acc) ->
    sLoopNest (segBinOpShape scan_op) $ \vec_is ->
    forM_ (zip acc $ segBinOpNeutral scan_op) $ \(acc', ne) ->
      copyDWIMFix acc' vec_is ne []

  sFor "i" (nsubtasks'-1) $ \i -> do
     offset <-- iter_pr_subtask
     sWhen (i .<. remainder) (offset <-- offset' + 1)
     offset_index <-- offset_index' + offset'
     zipWithM_ dPrimV_ is $ unflattenIndex ns' $ Imp.vi32 offset_index

     compileStms mempty (kernelBodyStms kbody) $
       forM_ (zip3 per_scan_pes scan_ops accs) $ \(pes, scan_op, acc) ->
         sLoopNest (segBinOpShape scan_op) $ \vec_is -> do

         sComment "Read carry in" $
           forM_ (zip (xParams scan_op) acc) $ \(p, acc') ->
             copyDWIMFix (paramName p) [] (Var acc') vec_is

         sComment "Read next values" $
           forM_ (zip (yParams scan_op) pes) $ \(p, pe) ->
             copyDWIMFix (paramName p) [] (Var $ patElemName pe) ((offset_index'-1) : vec_is)

         compileStms mempty (bodyStms $ lamBody scan_op) $
            forM_ (zip3 acc pes (bodyResult $ lamBody scan_op)) $
              \(acc', pe, se) -> do copyDWIMFix (patElemName pe) ((offset_index'-1) : vec_is) se []
                                    copyDWIMFix acc' vec_is se []



-- Stage 3 : Finally each thread partially scans a chunk of the input
--           reading it's corresponding carry-in
scanStage3 :: Pattern MCMem
           -> VName
           -> SegSpace
           -> [SegBinOp MCMem]
           -> KernelBody MCMem
           -> MulticoreGen ()
scanStage3 pat nsubtasks space scan_ops kbody = do
  emit $ Imp.DebugPrint "nonsegmentedScan stage 3" Nothing

  let (is, ns) = unzip $ unSegSpace space
      all_scan_res = take (segBinOpResults scan_ops) $ kernelBodyResult kbody
      per_scan_res = segBinOpChunks scan_ops all_scan_res
      per_scan_pes = segBinOpChunks scan_ops $ patternValueElements pat

  iter <- dPrimV "iter" 0
  iter' <- toExp $ Var iter
  ns' <- mapM toExp ns
  tid' <- toExp $ Var $ segFlat space

  accs <- groupResultArrays "scan_stage_3_accum_arr" (Var nsubtasks) scan_ops
  prebody <- collect $ do
    -- Read carry in or neutral element
    let read_carry_in = forM_ (zip3 scan_ops accs per_scan_pes) $ \(scan_op, acc, pes) ->
                          sLoopNest (segBinOpShape scan_op) $ \vec_is ->
                            forM_ (zip acc pes) $ \(acc', pe) ->
                              copyDWIMFix acc' (tid' : vec_is) (Var $ patElemName pe) (iter' - 1 : vec_is)

        read_neutral = forM_ (zip scan_ops accs) $ \(scan_op, acc) ->
                         sLoopNest (segBinOpShape scan_op) $ \vec_is ->
                           forM_ (zip acc $ segBinOpNeutral scan_op) $ \(acc', ne) ->
                             copyDWIMFix acc' (tid' : vec_is) ne []

    sIf (iter' .==. 0) read_neutral read_carry_in

  body <- collect $ do
    zipWithM_ dPrimV_ is $ unflattenIndex ns' $ Imp.vi32 iter
    dScope Nothing $ scopeOfLParams $ concatMap (lambdaParams . segBinOpLambda) scan_ops
    sComment "stage 3 scan body" $
      compileStms mempty (kernelBodyStms kbody) $
        forM_ (zip4 per_scan_pes scan_ops per_scan_res accs) $ \(pes, scan_op, scan_res, acc) ->
          sLoopNest (segBinOpShape scan_op) $ \vec_is -> do

          -- Read accum value
          forM_ (zip (xParams scan_op) acc) $ \(p, acc') ->
            copyDWIMFix (paramName p) [] (Var acc') (tid' : vec_is)

          -- Read next value
          forM_ (zip (yParams scan_op) scan_res) $ \(p, se) ->
            copyDWIMFix (paramName p) [] (kernelResultSubExp se) vec_is

          compileStms mempty (bodyStms $ lamBody scan_op) $
            forM_ (zip3 pes (bodyResult $ lamBody scan_op) acc) $
              \(pe, se, acc') -> do
                copyDWIMFix (patElemName pe) (map Imp.vi32 is ++ vec_is) se []
                copyDWIMFix acc' (tid' : vec_is) se []

  free_params' <- freeParams (prebody <> body)  (segFlat space : [iter])
  emit $ Imp.Op $ Imp.MCFunc "scan_stage_3" iter prebody body free_params' $
    Imp.MulticoreInfo Imp.Static (segFlat space)

segmentedScan :: Pattern MCMem
              -> SegSpace
              -> [SegBinOp MCMem]
              -> KernelBody MCMem
              -> MulticoreGen Imp.Code
segmentedScan pat space scan_ops kbody = do
  emit $ Imp.DebugPrint "segmented segScan" Nothing
  collect $ do
    n_par_segments <- dPrim "segment_iter" $ IntType Int32
    -- iteration variable
    fbody <- compileSegScanBody n_par_segments pat space scan_ops kbody
    free_params <- freeParams fbody  (segFlat space : [n_par_segments])
    let sched = decideScheduling fbody
    emit $ Imp.Op $ Imp.MCFunc "seg_scan" n_par_segments mempty fbody free_params $
      Imp.MulticoreInfo sched (segFlat space)


compileSegScanBody :: VName
                   -> Pattern MCMem
                   -> SegSpace
                   -> [SegBinOp MCMem]
                   -> KernelBody MCMem
                   -> MulticoreGen Imp.Code
compileSegScanBody idx pat space scan_ops kbody = do
  let (is, ns) = unzip $ unSegSpace space
  ns' <- mapM toExp ns

  idx' <- toExp $ Var idx

  let per_scan_pes = segBinOpChunks scan_ops $ patternValueElements pat
  collect $ do
    emit $ Imp.DebugPrint "segmented segScan stage 1" Nothing
    forM_ (zip scan_ops per_scan_pes) $ \(scan_op, scan_pes) -> do
      dScope Nothing $ scopeOfLParams $ lambdaParams $ segBinOpLambda scan_op
      let (scan_x_params, scan_y_params) = splitAt (length $ segBinOpNeutral scan_op) $ (lambdaParams . segBinOpLambda) scan_op

      forM_ (zip scan_x_params $ segBinOpNeutral scan_op) $ \(p, ne) ->
        copyDWIMFix (paramName p) [] ne []

      let inner_bound = last ns'
      sFor "i" inner_bound $ \i -> do
        zipWithM_ dPrimV_ (init is) $ unflattenIndex (init ns') idx'
        dPrimV_ (last is) i
        compileStms mempty (kernelBodyStms kbody) $ do
          let (scan_res, map_res) = splitAt (length $ segBinOpNeutral scan_op) $ kernelBodyResult kbody
          sComment "write to-scan values to parameters" $
            forM_ (zip scan_y_params scan_res) $ \(p, se) ->
              copyDWIMFix (paramName p) [] (kernelResultSubExp se) []

          sComment "write mapped values results to memory" $
            forM_ (zip (drop (length $ segBinOpNeutral scan_op) $ patternElements pat) map_res) $ \(pe, se) ->
              copyDWIMFix (patElemName pe) (map Imp.vi32 is) (kernelResultSubExp se) []

          sComment "combine with carry and write to memory" $
            compileStms mempty (bodyStms $ lambdaBody $ segBinOpLambda scan_op) $
            forM_ (zip3 scan_x_params scan_pes (bodyResult $ lambdaBody $ segBinOpLambda scan_op)) $ \(p, pe, se) -> do
              copyDWIMFix (patElemName pe) (map Imp.vi32 is)  se []
              copyDWIMFix (paramName p) [] se []


-- nonsegmentedScan pat space scan_ops kbody ModeSequential = do
--   let ns = map snd $ unSegSpace space
--   ns' <- mapM toExp ns

--   collect $ localMode ModeSequential $ do
--     flat_seq_idx <- dPrimV "seq_iter" 0
--     seq_code_body <- sequentialScan flat_seq_idx pat space scan_ops kbody
--     sFor "i" (product ns') $ \i -> do
--       flat_seq_idx <-- i
--       emit seq_code_body

-- sequentialScan :: VName
--                -> Pattern MCMem
--                -> SegSpace
--                -> [SegBinOp MCMem]
--                -> KernelBody MCMem
--                -> MulticoreGen Imp.Code
-- sequentialScan iter pat space scan_ops kbody = do
--   let (is, ns) = unzip $ unSegSpace space
--   ns' <- mapM toExp ns

--   let (all_scan_res, map_res) = splitAt (segBinOpResults scan_ops) $ kernelBodyResult kbody
--       per_scan_res            = segBinOpChunks scan_ops all_scan_res
--       per_scan_pes            = segBinOpChunks scan_ops $ patternValueElements pat

--   collect $ do
--     dScope Nothing $ scopeOfLParams $ concatMap (lambdaParams . segBinOpLambda) scan_ops
--     zipWithM_ dPrimV_ is $ unflattenIndex ns' $ Imp.vi32 iter
--     compileStms mempty (kernelBodyStms kbody) $ do
--       sComment "write mapped values results to memory" $ do
--         let map_arrs = drop (segBinOpResults scan_ops) $ patternElements pat
--         zipWithM_ (compileThreadResult space) map_arrs map_res

--       forM_ (zip3 per_scan_pes scan_ops per_scan_res) $ \(pes, scan_op, scan_res) ->
--         sLoopNest (segBinOpShape scan_op) $ \vec_is -> do

--         -- Read accum value
--         let last_is = last is
--         last_is' <- toExp $ Var last_is

--         sComment "Read accum value" $
--           sIf (last_is' .==. 0)
--               (forM_ (zip (xParams scan_op) $ segBinOpNeutral scan_op) $ \(p, ne) ->
--                 copyDWIMFix (paramName p) [] ne [])
--               (forM_ (zip (xParams scan_op) pes) $ \(p, pe) ->
--                 copyDWIMFix (paramName p) [] (Var $ patElemName pe) (map Imp.vi32 (init is) ++ [last_is'-1] ++ vec_is))
--         -- Read next value
--         sComment "Read next values" $
--           forM_ (zip (yParams scan_op) scan_res) $ \(p, se) ->
--             copyDWIMFix (paramName p) [] (kernelResultSubExp se) vec_is

--         compileStms mempty (bodyStms $ lamBody scan_op) $
--           forM_ (zip pes (bodyResult $ lamBody scan_op)) $
--             \(pe, se) -> copyDWIMFix (patElemName pe) (map Imp.vi32 is ++ vec_is) se []