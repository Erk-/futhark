{-# LANGUAGE TypeFamilies, FlexibleContexts #-}
-- | Playground for work on merging memory blocks
module Futhark.Optimise.MemBlockCoalesce.ArrayCoalescing
       ( mkCoalsTab )
       where

import Prelude
import Data.Maybe
import qualified Data.List as L
import Control.Arrow
import qualified Data.Map.Strict as M
import qualified Control.Exception.Base as Exc
import Debug.Trace

import Futhark.IR.Prop.Scope
import Futhark.Analysis.PrimExp.Convert
import Futhark.IR.Aliases
import qualified Futhark.IR.SeqMem as ExpMem
import qualified Futhark.IR.Mem.IxFun as IxFun
import Futhark.Optimise.MemBlockCoalesce.DataStructs
import Futhark.Optimise.MemBlockCoalesce.TopDownAn
import Futhark.Optimise.MemBlockCoalesce.MemRefAggreg
import Futhark.Optimise.MemBlockCoalesce.LastUse

emptyTopDnEnv :: TopDnEnv
emptyTopDnEnv = TopDnEnv { alloc = mempty, scope = M.empty
                         , inhibited = M.empty, ranges = M.empty
                         , v_alias = M.empty, m_alias = M.empty }

emptyBotUpEnv :: BotUpEnv
emptyBotUpEnv = BotUpEnv { scals = M.empty, activeCoals = M.empty
                         , successCoals = M.empty, inhibit = M.empty }


-- | basic conversion of a Var Expression to a PrimExp
basePMconv :: ScopeTab
           -> ScalarTab
           -> VName
           -> Maybe (ExpMem.PrimExp VName)
basePMconv scopetab scaltab v =
  case M.lookup v scaltab of
    Just pexp -> Just pexp
    Nothing -> case M.lookup v scopetab of
                Just info ->
                    case typeOf info of
                      Prim tp -> Just $ ExpMem.LeafExp v tp
                      _ -> Nothing
                _ -> Nothing

-- | promotion from active-to-successful coalescing tables
--   should be handled with this function (for clarity).
markSuccessCoal :: (CoalsTab, CoalsTab) -> VName -> CoalsEntry
                -> (CoalsTab, CoalsTab)
markSuccessCoal (actv,succc) m_b info_b =
  ( M.delete m_b actv
  , appendCoalsInfo m_b info_b succc )

prettyInhibitTab :: InhibitTab -> String
prettyInhibitTab tab =
  let list_tups = map (second namesToList) (M.toList tab)
  in  pretty list_tups

--------------------------------------------------------------------------------
--- Main Coalescing Transformation computes a successful coalescing table    ---
--------------------------------------------------------------------------------

mkCoalsTab :: Prog (Aliases ExpMem.SeqMem) -> CoalsTab
mkCoalsTab prg = foldl M.union M.empty $ map mkCoalsTabFun $ progFuns prg

mkCoalsTabFun :: FunDef (Aliases ExpMem.SeqMem) -> CoalsTab
mkCoalsTabFun fun@(FunDef _ _ _ _ fpars body) =
  let (_, lutab) = lastUseFun fun
      unique_mems = namesFromList $ M.keys $ getUniqueMemFParam fpars
      topenv = emptyTopDnEnv { scope = scopeOfFParams fpars
                             , alloc = unique_mems
                             }
  in  fixPointCoalesce lutab fpars body topenv
  where
    fixPointCoalesce :: LUTabFun
                     -> [FParam (Aliases ExpMem.SeqMem)]
                     -> Body (Aliases ExpMem.SeqMem)
                     -> TopDnEnv -> CoalsTab
    fixPointCoalesce lutab fpar bdy topenv =
      let buenv = mkCoalsTabBdy lutab bdy topenv emptyBotUpEnv
          (succ_tab, actv_tab, inhb_tab) = (successCoals buenv, activeCoals buenv, inhibit buenv)
          -- remove @fpar@ from @actv_tab@, as function's parameters cannot be merged
          mems = map ((\(MemBlock _ _ m _) -> m) . snd) $ getArrMemAssocFParam fpar
          (actv_tab', inhb_tab') = trace ("HAHAHAHAHAHAHAHAHAHA!!!! active: "++pretty (M.keys actv_tab)++" mems: "++pretty mems++" inhbtab: "++pretty inhb_tab) $
            foldl markFailedCoal (actv_tab, inhb_tab) mems

          (succ_tab', failed_optdeps) = fixPointFilterDeps succ_tab M.empty
          inhb_tab'' = M.unionWith (<>) failed_optdeps inhb_tab'
          --new_inhibited = M.unionWith (<>) inhb_tab'' (inhibited topenv)
      in  if not (M.null actv_tab')
          then  error ("COALESCING ROOT: BROKEN INV, active not empty: " ++ pretty (M.keys actv_tab') )
          else  if trace ("COALESCING ROOT, new inhibitions : "++prettyInhibitTab inhb_tab'') $
                    M.null (M.difference inhb_tab'' (inhibited topenv))
                then succ_tab'
                else fixPointCoalesce lutab fpar bdy (topenv { inhibited = inhb_tab'' }) --new_inhibited })
    -- helper to helper
    fixPointFilterDeps :: CoalsTab -> InhibitTab -> (CoalsTab, InhibitTab)
    fixPointFilterDeps coaltab inhbtab=
      let (coaltab', inhbtab') = foldl filterDeps (coaltab, inhbtab) (M.keys coaltab)
      in  if length (M.keys coaltab) == length (M.keys coaltab')
          then (coaltab', inhbtab')
          else fixPointFilterDeps coaltab' inhbtab'
    -- helper to helper to helper
    filterDeps (coal, inhb) mb
      | not (M.member mb coal) = (coal, inhb)
    filterDeps (coal, inhb) mb
      | Just coal_etry <- M.lookup mb coal =
        let failed = M.filterWithKey (failedOptDep coal) (optdeps coal_etry)
        in  if   M.null failed
            then (coal, inhb) -- all ok
            else -- optimistic dependencies failed for the current
                 -- memblock; extend inhibited mem-block mergings.
                 trace ("COALESCING: OPTDEPS FAILED for "++pretty mb++" set: "++pretty (M.keys failed)) $
                  markFailedCoal (coal, inhb) mb
    filterDeps _ _ = error "In ArrayCoalescing.hs, fun filterDeps, impossible case reached!"
    failedOptDep coal _ mr
      | not (mr `M.member` coal) = True
    failedOptDep coal r mr
      | Just coal_etry <- M.lookup mr coal = not $ r `M.member` (vartab coal_etry)
    failedOptDep _ _ _ = error "In ArrayCoalescing.hs, fun failedOptDep, impossible case reached!"

mkCoalsTabBdy :: LUTabFun -> Body (Aliases ExpMem.SeqMem)
              -> TopDnEnv -> BotUpEnv -> BotUpEnv
mkCoalsTabBdy lutab (Body _ bnds _) = traverseBindings $ stmsToList bnds
  where
    traverseBindings :: [Stm (Aliases ExpMem.SeqMem)]
                     -> TopDnEnv -> BotUpEnv -> BotUpEnv
    traverseBindings [] _ bu_env = bu_env
    traverseBindings (bd:bds) td_env bu_env =
      let td_env' = topdwnTravBinding td_env bd
          bu_env' = traverseBindings bds td_env' bu_env
          res_env = mkCoalsTabBnd lutab bd td_env' bu_env'
      in  res_env

-- | Array (register) coalescing can have one of three shapes:
--      a) @let y    = copy(b^{lu})@
--      b) @let y    = concat(a, b^{lu})@
--      c) @let y[i] = b^{lu}@
--   The intent is to use the memory block of the left-hand side
--     for the right-hand side variable, meaning to store @b@ in
--     @m_y@ (rather than @m_b@).
--   The following five safety conditions are necessary:
--      1. the right-hand side is lastly-used in the current statement
--      2. the allocation of @m_y@ dominates the creation of @b@
--         ^ relax it by hoisting the allocation of @m_y@
--      3. there is no use of the left-hand side memory block @m_y@
--           during the liveness of @b@, i.e., in between its last use
--           and its creation.
--         ^ relax it by pointwise/interval-based checking
--      4. @b@ is a newly created array, i.e., does not aliases anything
--         ^ relax it to support exitential memory blocks for if-then-else
--      5. the new index function of @b@ corresponding to memory block @m_y@
--           can be translated at the definition of @b@, and the
--           same for all variables aliasing @b@. 
--   Observation: during the live range of @b@, @m_b@ can only be used by
--                variables aliased with @b@, because @b@ is newly created.
--                relax it: in case @m_b@ is existential due to an if-then-else
--                          then the checks should be extended to the actual
--                          array-creation points.
mkCoalsTabBnd :: LUTabFun -> Stm (Aliases ExpMem.SeqMem)
              -> TopDnEnv -> BotUpEnv -> BotUpEnv

mkCoalsTabBnd _ (Let (Pattern [] [pe]) _ e) td_env bu_env
  | Just primexp <- primExpFromExp (basePMconv (scope td_env) (scals bu_env)) e =
  bu_env { scals = M.insert (patElemName pe) primexp (scals bu_env) }

-- | Assume the if-result is a candidate for coalescing (further in the code).
--   For now we conservatively treat only the case when both then and else
--   result arrays are created inside their corresponding branches of the @if@.
--   Otherwise we need more complex analysis, and may open pandora box.
--   For example, the code below:
--        @let a = map f a0                @
--        @let (c,x) = if cond             @
--        @            then (a,x)          @
--        @            else let b = map g a@
--        @                 let x[1] = a   @
--        @                 in (b,x)       @
--        @let y[3] = c                    @
--  If coalescing of the if-result succeeds than both @a@ and @b@ are placed
--  to @m_y[3]@. First, this is buggy because @b = map g a@ on the else branch.
--  Second this is buggy because @a@ will be associated to @m_y[3]@ on the then
--  branch, and with @m_x[1]@ on the else branch. Currently, unifying two
--  mappings with different memory destinations, just picks one of them.
--  If @m_x[1]@ is picked than we have an inconsisstent state. All these
--  because we allow such cases, which is unclear whether appear and can
--  be optimized in practice.
mkCoalsTabBnd lutab (Let patt _ (If _ body_then body_else _)) td_env bu_env =
  let pat_val_elms = patternValueElements patt
  -- ToDo: 1. we need to record existential memory blocks in alias table on the top-down pass.
  --       2. need to extend the scope table

  --  i) Filter @activeCoals@ by the 2ND AND 5th safety conditions:
      (activeCoals0, inhibit0) =
        filterSafetyCond2and5 (activeCoals bu_env) (inhibit bu_env) (scals bu_env)
                              td_env pat_val_elms
      successCoals0 = successCoals bu_env

  -- ii) extend @activeCoals@ by transfering the pattern-elements bindings existent
  --     in @activeCoals@ to the body results of the then and else branches, but only
  --     if the current pattern element can be potentially coalesced and also
  --     if the current pattern element satisfies safety conditions 2 & 5.
      res_mem_then = findMemBodyResult activeCoals0 (scope td_env) pat_val_elms body_then
      res_mem_else = findMemBodyResult activeCoals0 (scope td_env) pat_val_elms body_else

      subs_then = mkSubsTab patt (bodyResult body_then)
      subs_else = mkSubsTab patt (bodyResult body_else)

      actv_then_i = foldl (transferCoalsToBody subs_then) activeCoals0 res_mem_then 
      actv_else_i = foldl (transferCoalsToBody subs_else) activeCoals0 res_mem_else

      -- eliminate the original pattern binding of the if statement,
      -- @let x = if y[0,0] > 0 then map (+y[0,0) a else map (+1) b@
      -- @let y[0] = x@
      -- should succeed because @m_y@ is used before @x@ is created.
      (actv_then, actv_else) =
        foldl (\(acth,acel) (m_b,_,_,m_r) ->
                  if m_b == m_r
                  then (acth, acel)
                  else (M.delete m_b acth, M.delete m_b acel)
              ) (actv_then_i, actv_else_i) res_mem_then

  --iii) process the then and else bodies
      res_then = mkCoalsTabBdy lutab body_then td_env (bu_env {activeCoals = actv_then})
      res_else = mkCoalsTabBdy lutab body_else td_env (bu_env {activeCoals = actv_else})
      (actv_then0, succ_then0, inhb_then0) = (activeCoals res_then, successCoals res_then, inhibit res_then)
      (actv_else0, succ_else0, inhb_else0) = (activeCoals res_else, successCoals res_else, inhibit res_else)

  -- iv) optimistically mark the pattern succesful:
      ((activeCoals1, inhibit1), successCoals1) =
        foldl (foldfun ((actv_then0, succ_then0), (actv_else0, succ_else0)))
              ((activeCoals0, inhibit0), successCoals0)
              (zip res_mem_then res_mem_else)

  --  v) unify coalescing results of all branches by taking the union
  --     of all entries in the current/then/else success tables.
      then_failed = M.difference actv_then0 $
                    M.intersectionWith unionCoalsEntry actv_then0 activeCoals0
      (_,inhb_then1)= --trace ("DIFF COM: "++prettyCoalTab then_diff_com ++ " INHIBIT: "++prettyInhibitTab inhb_then0) $
                      foldl markFailedCoal (then_failed,inhb_then0) (M.keys then_failed)

      else_failed = M.difference actv_else0 $
                    M.intersectionWith unionCoalsEntry actv_else0 activeCoals0
      (_,inhb_else1)= foldl markFailedCoal (else_failed,inhb_else0) (M.keys else_failed)

      actv_res  = M.intersectionWith unionCoalsEntry actv_then0 $
                  M.intersectionWith unionCoalsEntry actv_else0 activeCoals1

      succ_res  = M.unionWith unionCoalsEntry succ_then0 $
                  M.unionWith unionCoalsEntry succ_else0 successCoals1
  --
  -- vi) The step of filtering by 3rd safety condition is not
  --       necessary, because we perform index analysis of the
  --       source/destination uses, and they should have been
  --       filtered during the analysis of the then/else bodies.
--      body_free_vars = freeIn body_then <> freeIn body_else
--      (actv_res, inhibit_res0) =
--        trace ("COALESCING IF: active == "++prettyCoalTab actv_res0++" res_mem_then: "++pretty res_mem_then++" else: "++pretty res_mem_else) $
--        mkCoalsHelper1FilterActive patt body_free_vars (scope td_env)
--                                   (scals bu_env) actv_res0 inhibit1

      inhibit_res = --trace ("COALESCING IF inhibits: " ++ prettyInhibitTab inhibit_res0 ++ " " ++ prettyInhibitTab inhb_then1 ++ " " ++ prettyInhibitTab inhb_else1) $
                    M.unionWith (<>) inhibit1 $ -- inhibit_res0 $
                    M.unionWith (<>) inhb_then1 inhb_else1
  in  bu_env { activeCoals = actv_res, successCoals = succ_res, inhibit = inhibit_res }
  where
    mkSubsTab pat res =
      let pat_elms = patternContextElements pat ++ patternValueElements pat
      in  M.fromList $ mapMaybe mki64subst $ zip pat_elms res -- mkSubsPE
    mki64subst (a, Var v)
      | (_,ExpMem.MemPrim (IntType Int64)) <- patElemDec a = Just (patElemName a, le64 v)
    mki64subst (a, se@(Constant (IntValue (Int64Value _)))) = Just (patElemName a, pe64 se)
    mki64subst _ = Nothing
    foldfun _ ((act,inhb),succc) ((m_b,_,_,_),(_,_,_,_))
      | Nothing <- M.lookup m_b act =
          trace ("Imposible Case!!!") $ Exc.assert False ((act,inhb),succc)
    foldfun ((_,succ_then0), (_,succ_else0))
            ((act,inhb),succc)
            ((m_b,b,r1,mr1),(_,_,r2,mr2))
      | Just info <- M.lookup m_b act,
        Just _ <- M.lookup mr1 succ_then0,
        Just _ <- M.lookup mr2 succ_else0 =
          -- Optimistically promote to successful coalescing and append!
          let info' = info { optdeps = M.insert r2 mr2 $
                             M.insert r1 mr1 $ optdeps info }
              (act',succc') = markSuccessCoal (act,succc) m_b info'
          in trace  ("COALESCING: if-then-else promotion: "++pretty b++pretty m_b)
                    ((act',inhb), succc')
    foldfun ((actv_then0,_), (actv_else0,_))
            ((act,inhb),succc) 
            ((m_b,b,_,mr1),(_,_,_,mr2))
      | Just info <- M.lookup m_b act,
        m_b == mr1 && m_b == mr2,
        Just info_then <- M.lookup mr1 actv_then0,
        Just info_else <- M.lookup mr2 actv_else0 =
          -- Treating special case resembling:
          -- @let x0 = map (+1) a                                  @
          -- @let x3 = if cond then let x1 = x0 with [0] <- 2 in x1@
          -- @                 else let x2 = x0 with [1] <- 3 in x2@
          -- @let z[1] = x3                                        @
          -- In this case the result active table should be the union
          -- of the @m_x@ entries of the then and else active tables.
          let info' = unionCoalsEntry info $
                      unionCoalsEntry info_then info_else
              act'  = M.insert m_b info' act
          in  trace ("COALESCING: if-then-else succeeds, case m_b == mr1 == mr2 "++pretty b++" "++pretty m_b)
                    ((act',inhb),succc)
    foldfun _ ((act,inhb),succc) ((m_b,b,_,_),(_,_,_,_)) =
      -- one of the branches has failed coalescing,
      -- hence remove the coalescing of the result.
      trace ("COALESCING: if-then-else fails "++pretty b++pretty m_b)
            (markFailedCoal (act,inhb) m_b, succc)
{--
    mkSubsPE (a, Var v)
      | (_,ExpMem.MemPrim (IntType Int64)) <- patElemDec a =
        Just (patElemName a, LeafExp v (IntType Int64))
    mkSubsPE (a, Constant v@(IntValue (Int64Value _))) =
        Just (patElemName a, ValueExp v)
    mkSubsPE _ = Nothing
--}
--
--mkCoalsTabBnd lutab (Let pat _ (Op (ExpMem.Inner (ExpMem.Kernel str cs ker_space tps ker_bdy)))) td_env bu_env =
--  bu_env
--
mkCoalsTabBnd lutab lstm@(Let pat _ (DoLoop arginis_ctx arginis _lform body)) td_env bu_env =
  let pat_val_elms  = patternValueElements pat

  --  i) Filter @activeCoals@ by the 2nd, 3rd AND 5th safety conditions:
      (activeCoals00,inhibit00) =
        filterSafetyCond2and5 (activeCoals bu_env) (inhibit bu_env) (scals bu_env)
                              td_env pat_val_elms
  --  this should probably dissapear, i.e., be replaced with code that analyse
  --    whether lmads overlap.
      loop_fv = freeIn body <>
                  namesFromList (mapMaybe justVars arginis)
      (actv0,inhibit0) =
        mkCoalsHelper1FilterActive pat loop_fv (scope td_env)
                                   (scals bu_env) activeCoals00 inhibit00

      td_env' = topDownLoop td_env lstm

  -- ii) Extend @activeCoals@ by transfering the pattern-elements bindings
  --     existent in @activeCoals@ to the loop-body results, but only if:
  --       (a) the pattern element is a candidate for coalescing,        &&
  --       (b) the pattern element satisfies safety conditions 2 & 5,
  --           (conditions (a) and (b) have already been checked above), &&
  --       (c) the memory block of the corresponding body result is
  --           allocated outside the loop, i.e., non-existential,        &&
  --       (d) the init name is lastly-used in the initialization
  --           of the loop variant.
  --     Otherwise fail and remove from active-coalescing table!
      bdy_ress = drop (length arginis_ctx) $ bodyResult body
      (patmems, argmems, inimems, resmems) =
        trace ("COALESCING loop input: "++pretty (map patElemName pat_val_elms)) $
        L.unzip4 $
        mapMaybe (mapmbFun td_env' actv0) (zip3 pat_val_elms arginis bdy_ress)

      -- remove the other pattern elements from the active coalescing table:
      coal_pat_names = namesFromList $ map fst patmems
      (actv1,inhibit1) =
        foldl (\(act,inhb) (b, MemBlock _ _ m_b _) ->
                 if   nameIn b coal_pat_names then (act,inhb) -- ok
                 else markFailedCoal (act,inhb) m_b -- remove from active
              ) (actv0,inhibit0) (getArrMemAssoc pat)

  -- iii) Process the loop's body.
  --      If the memory blocks of the loop result and loop variant param differ
  --      then make the original memory block of the loop result conflict with
  --      the original memory block of the loop parameter. This is done in
  --      order to prevent the coalescing of @a1@, @a0@, @x@ and @db@ in the
  --      same memory block of @y@ in the example below:
  --      @loop(a1 = a0) = for i < n do @
  --      @    let x = map (stencil a1) (iota n)@
  --      @    let db = copy x          @
  --      @    in db                    @
  --      @let y[0] = a1                @
  --      Meaning the coalescing of @x@ in @let db = copy x@ should fail because
  --      @a1@ appears in the definition of @let x = map (stencil a1) (iota n)@.
      res_mem_bdy = zipWith (\(b,m_b) (r,m_r) -> (m_b,b,r,m_r)) patmems resmems
      res_mem_arg = zipWith (\(b,m_b) (r,m_r) -> (m_b,b,r,m_r)) patmems argmems
      res_mem_ini = zipWith (\(b,m_b) (r,m_r) -> (m_b,b,r,m_r)) patmems inimems
      -- ToDo: check that an optimistic dependency is placed on the ini.
      actv2 = foldl (transferCoalsToBody M.empty) actv1 (res_mem_bdy++res_mem_arg++res_mem_ini)
      -- The code below adds an aliasing relation to the loop-arg memory
      --   so that to prevent, for example an iterative stencil to be
      --   coalesced, you need a buffer for the result and a separate
      --   one for the stencil.
      actv3 = foldl (\ tab ((_,_,_,m_r),(_,_,_,m_a)) ->
                        if m_r == m_a then tab
                        else case M.lookup m_r tab of
                                Nothing   -> tab
                                Just etry -> M.insert m_r (etry { alsmem = alsmem etry <> oneName m_a }) tab
                    ) actv2 (zip res_mem_bdy res_mem_arg)

      res_env_body = mkCoalsTabBdy lutab body td_env'
                                    (bu_env { activeCoals = actv3
                                            , inhibit = inhibit1  })
  -- ToDo: add code to aggregate memory references across loop
  --       and to filter insuccessful coalescing relations.

  -- iv) optimistically mark the pattern succesful if there is any chance to succeed
      (res_actv, res_succ, res_inhb) = (activeCoals res_env_body, successCoals res_env_body, inhibit res_env_body)
      ((fin_actv1,fin_inhb1), fin_succ1) =
        optimPromotion argmems resmems inimems $
        optimPromotion patmems resmems inimems ((res_actv,res_inhb),res_succ)

  in bu_env { activeCoals = fin_actv1, successCoals = fin_succ1, inhibit = fin_inhb1 }
  where
    justVars (_,Var v) = Just v
    justVars _         = Nothing
    --
    mapmbFun td_env' actv0 (patel, (arg,ini), bdyres)
      | b <- patElemName patel,
        (_,ExpMem.MemArray _ _ _ (ExpMem.ArrayIn m_b _)) <- patElemDec patel,
        a <- paramName arg,
        Var a0 <- ini,
        Var r  <- bdyres,
        Just coal_etry <- M.lookup m_b actv0,
        Just _ <- M.lookup b (vartab coal_etry),
        Just (MemBlock _ _ m_a _) <- getScopeMemInfo a  (scope td_env'),
        Just (MemBlock _ _ m_a0 _)<- getScopeMemInfo a0 (scope td_env'),
        Just (MemBlock _ _ m_r _) <- getScopeMemInfo r  (scope td_env'),
        Just nms <- M.lookup a lutab,
        nameIn a0 nms,
        nameIn m_r (alloc td_env) =
          trace ("COALESCING loop candidate: "++pretty b++" "++pretty m_b++" "++pretty r++" "++pretty m_r) $
                Just ((b,m_b), (a,m_a), (a0,m_a0), (r,m_r))
    mapmbFun _ _ (patel, (arg,ini), bdyres) =
      trace ("COALESCING loop FAILED "++pretty patel++" "++pretty arg ++ pretty ini ++ pretty bdyres)
            Nothing
    --
    optimPromotion othmems resmems inimems ((actv_tab,inhb_tab),succ_tab) =
      -- the use of @inimems@ and the test for @m_i@ are probably redundant
      foldl (\ ((act,inhb),succc) ((b,m_b), (r,m_r), (_,m_i)) ->
              case M.lookup m_b act of
                Nothing   -> trace "IMPOSSIBLE!!!!" ((act,inhb), succc) -- impossible
                Just info -> -- Optimistically promote and append!
                  let failed = markFailedCoal (act,inhb) m_b
                      has_no_chance = case (M.lookup m_r act, M.lookup m_r succc, M.lookup m_i act) of
                                        (Nothing, Nothing,_) -> True
                                        (_, _, Nothing)      -> True
                                        _                    -> False
                  in  if has_no_chance
                      -- the result has already failed coalescing,
                      -- hence the loop-result already failed coalescing; remove it.
                      -- we can additionally do some filtering of the loop tables,
                      -- but I feel lazy so we will carry them around.
                      then trace ("COALESCING: optimistic loop fails "++pretty has_no_chance)
                                 (failed, succc)
                      else  let info' = info { optdeps = M.insert r m_r $ optdeps info }
                                (act1, succc1) = markSuccessCoal (act,succc) m_b info'
                            in  trace ("COALESCING: optimistic loop promotion: "++pretty b++" "++pretty m_b)
                                      ((act1,inhb), succc1)
            ) ((actv_tab,inhb_tab), succ_tab) (zip3 othmems resmems inimems)
-- The case of in-place update:
--   @let x' = x with slice <- elm@
mkCoalsTabBnd lutab stm@(Let pat@(Pattern [] [x']) _ e@(BasicOp (Update x _ _elm))) td_env bu_env
  | [(_,MemBlock _ _ m_x _)] <- getArrMemAssoc pat =
  -- (a) filter by the 3rd safety for @elm@ and @x'@
  let (actv, inhbt) = recordMemRefUses td_env bu_env stm
        -- mkCoalsHelper1FilterActive pat (se2names elm) (scope td_env) (scals bu_env)
        --                                      (activeCoals bu_env) (inhibit bu_env)
  -- (b) if @x'@ is in active coalesced table, then add an entry for @x@ as well
      (actv', inhbt') =
        case M.lookup m_x actv of
          Nothing -> (actv, inhbt)
          Just info ->
            case M.lookup (patElemName x') (vartab info) of
              Nothing ->
                error "In ArrayCoalescing.hs, fun mkCoalsTabBnd, case in-place update!"
                -- ^ this case should not happen, but if it can that just fail conservatively
                -- markFailedCoal (actv, inhbt) m_x
              Just (Coalesced k mblk@(MemBlock _ _ _ x_indfun) _) ->
                let (ok, fv_subs) = translateIndFunFreeVar (scope td_env) (scals bu_env) $ Just x_indfun
                in  if not ok
                    -- conservatively fail free-var translation fails
                    then markFailedCoal (actv, inhbt) m_x
                    -- successfully transitions to x
                    else  let coal_etry_x = Coalesced k mblk fv_subs
                              info' = info { vartab = M.insert x coal_etry_x $
                                             M.insert (patElemName x') coal_etry_x (vartab info) }
                          in  (M.insert m_x info' actv, inhbt)
  -- (c) this stm is also a potential source for coalescing, so process it
      actv'' = mkCoalsHelper3PatternMatch pat e lutab td_env (successCoals bu_env) actv' inhbt'
  in  bu_env { activeCoals = actv'', inhibit = inhbt' }
--
mkCoalsTabBnd _ (Let pat _ (BasicOp (Update{}))) _ _ =
  error $ "In ArrayCoalescing.hs, fun mkCoalsTabBnd, illegal pattern for in-place update: "++pretty pat
-- default handling
mkCoalsTabBnd lutab stm@(Let pat _ e) td_env bu_env =
  --   i) Filter @activeCoals@ by the 3rd safety condition:
  --      this is now relaxed by use of LMAD eqs:
  --      the memory referenced in stm are added to memrefs::dstrefs
  --      in corresponding coal-tab entries.
  let (activeCoals',inhibit') = recordMemRefUses td_env bu_env stm
        -- mkCoalsHelper1FilterActive pat (freeIn e) (scope td_env) (scals bu_env)
        --                           (activeCoals bu_env) (inhibit bu_env)

  --  ii) promote any of the entries in @activeCoals@ to @successCoals@ as long as
  --        - this statement defined a variable consumed in a coalesced statement
  --        - and safety conditions 2, 4, and 5 are satisfied.
  --      AND extend @activeCoals@ table for any definition of a variable that
  --      aliases a coalesced variable.
      safe_4    = createsNewArrOK e
      ((activeCoals'',inhibit''), successCoals') =
        foldl (foldfun safe_4) ((activeCoals',inhibit'), successCoals bu_env) (getArrMemAssoc pat)

  -- iii) record a potentially coalesced statement in @activeCoals@
      activeCoals''' = mkCoalsHelper3PatternMatch pat e lutab td_env successCoals' activeCoals'' (inhibited td_env)

  in  bu_env { activeCoals = activeCoals''', inhibit = inhibit'', successCoals = successCoals' }
  where
    foldfun safe_4 ((a_acc,inhb),s_acc) (b,MemBlock tp shp mb _b_indfun) =
      case M.lookup mb a_acc of
        Nothing -> ((a_acc,inhb),s_acc)
        Just info@(CoalsEntry x_mem _ _ vtab _ _) ->
          let failed = markFailedCoal (a_acc,inhb) mb in
          case M.lookup b vtab of
            Nothing ->  -- we hit the definition of some variable @b@ aliased with
                        --    the coalesced variable @x@, hence extend @activeCoals@, e.g.,
                        --       @let x = map f arr  @
                        --       @let b = alias x  @ <- current statement
                        --       @ ... use of b ...  @
                        --       @let c = alias b    @ <- currently fails
                        --       @let y[i] = x       @
                        -- where @alias@ can be @transpose@, @slice@, @rotate@, @reshape@.
                        -- We use getTransitiveAlias helper function to track the aliasing
                        --    through the td_env, and to find the updated ixfun of @b@:
                        case getDirAliasedIxfn td_env a_acc b of
                          Nothing -> (failed, s_acc)
                          Just (_, _, b_indfun') ->
                            case translateIndFunFreeVar (scope td_env) (scals bu_env) (Just b_indfun') of
                              (False, _) -> (failed, s_acc)
                              (True, fv_subst) ->
                                let mem_info = Coalesced Trans (MemBlock tp shp x_mem b_indfun') fv_subst
                                    info' = info { vartab = M.insert b mem_info vtab }
                                in  ((M.insert mb info' a_acc,inhb), s_acc)
            Just (Coalesced k mblk@(MemBlock _ _ _ new_indfun) _) ->
              -- we are at the definition of the coalesced variable @b@
              -- if 2,4,5 hold promote it to successful coalesced table,
              -- or if e = transpose, etc. then postpone decision for later on
              let safe_2 = safety2 td_env x_mem -- nameIn x_mem (alloc td_env)
                  (safe_5, fv_subst) = translateIndFunFreeVar (scope td_env) (scals bu_env) (Just new_indfun)
              in  if safe_2 && safe_5
                  then  let mem_info = Coalesced k mblk fv_subst
                            info' = info { vartab = M.insert b mem_info vtab }
                        in  if safe_4
                            then -- array creation point, successful coalescing verified!
                                 let (a_acc',s_acc') = markSuccessCoal (a_acc,s_acc) mb info'
                                 in  trace ("COALESCING: successfull promote: "++pretty b++" "++pretty mb)
                                      ((a_acc',inhb), s_acc')
                            else -- this is an invertible alias case of the kind
                                 -- @ let b    = alias a @
                                 -- @ let x[i] = b @
                                 -- do not promote, but update the index function
                                 trace ("COALESCING: postponed promotion: "++pretty b)
                                  ((M.insert mb info' a_acc,inhb), s_acc)
                  else  (failed, s_acc) -- fail!

-- | 1. Filters @activeCoals@ by the 3rd safety condition, namely:
--      "there is no use of the left-hand side memory block @m_y@
--       during the liveness of right-hand side @b@, i.e., in between
--       its creation and its last use."
--   2. Treats pattern in-place updates by updating the optdeps field
--       of the dst variable with the info of the fist.
--   3. Returns a new pair of active-coalescing table and inhibited table
mkCoalsHelper1FilterActive :: Pattern (Aliases ExpMem.SeqMem)
                           -> Names
                           -> ScopeTab -> ScalarTab -> CoalsTab -> InhibitTab
                           -> (CoalsTab,InhibitTab)
mkCoalsHelper1FilterActive pat inner_free_vars scope_tab _scals_tab active_tab inhibit_tab =
  let e_mems  = mapMaybe (`getScopeMemInfo` scope_tab) $ namesToList inner_free_vars
      -- ToDo: understand why the memory block of pattern must be filtered:
      --       this definitely needs to be relaxed, e.g., because the src
      --       and sink can be created in the same loop.
      memasoc = getArrMemAssoc pat
      -- get memory-block names that are used in the current stmt.
      stm_mems= namesFromList $ map (\(MemBlock _ _ mnm _) -> mnm) $
                e_mems ++ map snd memasoc

      -- BIG BUG/ToDo: take the aliasing transitive closure of @all_mems@
      all_mems = stm_mems

      -- keep only the entries that do not overlap with the memory
      -- blocks defined in @pat@ or @inner_free_vars@.
      -- the others must be recorded in @inhibit_tab@ because
      -- they violate the 3rd safety condition.
      active_tab1 = M.filter (\etry -> mempty == namesIntersection all_mems (alsmem etry)) active_tab
      failed_tab  = M.difference active_tab active_tab1
      (_,inhibit_tab1) = foldl markFailedCoal (failed_tab,inhibit_tab) (M.keys failed_tab)
  in  (active_tab1, inhibit_tab1)

-- | Check safety conditions 2 and 5 and update new substitutions:
--   called on the pat-elements of loop and if-then-else expressions.
filterSafetyCond2and5 :: CoalsTab -> InhibitTab -> ScalarTab -> TopDnEnv
                      -> [PatElem (Aliases ExpMem.SeqMem)]
                      -> (CoalsTab, InhibitTab)
filterSafetyCond2and5 act_coal inhb_coal scals_env td_env =
  foldl (\ (acc,inhb) patel ->
           case (patElemName patel, patElemDec patel) of
             (b, (_,ExpMem.MemArray _ _ _ (ExpMem.ArrayIn m_b _idxfn_b))) ->
               case M.lookup m_b acc of
                 Nothing -> (acc,inhb)
                 Just info@(CoalsEntry x_mem _ _ vtab _ _) ->
                   let failed = markFailedCoal (acc,inhb) m_b
                   in
                    case M.lookup b vtab of
                     Nothing -> trace ("Too drastic case: "++pretty (b,m_b,x_mem)) failed
                        -- ^ This is not too drastic, because it applies to the patelems of loop/if-then-else
                     Just (Coalesced k mblk@(MemBlock _ _ _ new_indfun) _) ->
                       let (safe_5, fv_subst) = translateIndFunFreeVar (scope td_env) scals_env (Just new_indfun)
                           safe_2 = safety2 td_env x_mem
                       in  if safe_5 && safe_2
                           then let mem_info = Coalesced k mblk fv_subst
                                    info' = info { vartab = M.insert b mem_info vtab }
                                in  (M.insert m_b info' acc, inhb)
                           else failed
             _ -> (acc,inhb)
        ) (act_coal,inhb_coal)

-- |   Pattern matches a potentially coalesced statement and
--     records a new association in @activeCoals@
mkCoalsHelper3PatternMatch :: Pattern (Aliases ExpMem.SeqMem)
                           -> Exp (Aliases ExpMem.SeqMem)
                           -> LUTabFun -> TopDnEnv -> CoalsTab -> CoalsTab -> InhibitTab
                           -> CoalsTab
mkCoalsHelper3PatternMatch pat e lutab td_env _ activeCoals_tab _
  | Nothing <- genCoalStmtInfo lutab (scope td_env) pat e = 
      activeCoals_tab
mkCoalsHelper3PatternMatch pat e lutab td_env successCoals_tab activeCoals_tab inhibit_tab
  | Just clst <- genCoalStmtInfo lutab (scope td_env) pat e =
      foldl processNewCoalesce activeCoals_tab clst
    where
      processNewCoalesce acc (knd,alias_fn,x,m_x,ind_x, b,m_b,_,tp_b,shp_b) =
        -- test whether we are in a transitive coalesced case, i.e.,
        --      @let b = scratch ...@
        --      @.....@
        --      @let x[j] = b@
        --      @let y[i] = x@
        -- and compose the index function of @x@ with that of @y@,
        -- and update aliasing of the @m_b@ entry to also contain @m_y@
        -- on top of @m_x@, i.e., transitively, any use of @m_y@ should
        -- be checked for the lifetime of @b@.
        let proper_coals_tab = case knd of
                                InPl -> activeCoals_tab
                                _    -> successCoals_tab
            (m_yx, ind_yx, mem_yx_al, x_deps) =
              case M.lookup m_x proper_coals_tab of
                Nothing ->
                  (m_x, alias_fn ind_x, oneName m_x, M.empty)
                Just (CoalsEntry m_y ind_y y_al _ x_deps0 _) ->
                  (m_y, alias_fn ind_y, oneName m_x <> y_al, x_deps0)      
            success0 = IxFun.hasOneLmad ind_yx
            m_b_aliased_m_yx = areAnyAliased td_env m_b [m_yx] -- m_b \= m_yx
        in  case (success0, not m_b_aliased_m_yx, nameIn m_yx (alloc td_env)) of
              (True, True, True) ->
                -- Finally update the @activeCoals@ table with a fresh
                --   binding for @m_b@; if such one exists then overwrite.
                -- Also, add all variables from the alias chain of @b@ to
                --   @vartab@, for example, in the case of a sequence:
                --   @ b0 = if cond then ... else ... @
                --   @ b1 = alias0 b0 @
                --   @ b  = alias1 b1 @
                --   @ x[j] = b @
                -- Then @b1@ and @b0@ should also be added to @vartab@ if
                --   @alias1@ and @alias0@ are invertible, otherwise fail early!
                let mem_info  = Coalesced knd (MemBlock tp_b shp_b m_yx ind_yx) M.empty
                    opts' = if m_yx == m_x then M.empty
                            else M.insert x m_x x_deps
                    vtab = M.singleton b mem_info
                    mvtab= addInvAliassesVarTab td_env vtab b
                    
                    is_inhibited = case M.lookup m_b inhibit_tab of
                                    Just nms -> nameIn m_yx nms
                                    Nothing  -> False
                in  case (is_inhibited, mvtab) of
                      (True, _)    -> acc -- fail due to inhibited
                      (_, Nothing) -> acc -- fail early due to non-invertible aliasing
                      (_, Just vtab') ->  -- successfully adding a new coalesced entry
                        let coal_etry = CoalsEntry m_yx ind_yx mem_yx_al vtab'
                                                    opts' mem_empty
                        in  M.insert m_b coal_etry acc
              _ -> acc
mkCoalsHelper3PatternMatch _ _ _ _ _ _ _ =
  error "In ArrayCoalescing.hs, fun mkCoalsHelper3PatternMatch: Unreachable!!!"

genCoalStmtInfo :: LUTabFun
                -> ScopeTab
                -> Pattern (Aliases ExpMem.SeqMem)
                -> Exp (Aliases ExpMem.SeqMem)
                -> Maybe [(CoalescedKind,ExpMem.IxFun->ExpMem.IxFun,VName,VName,ExpMem.IxFun,VName,VName,ExpMem.IxFun,PrimType,Shape)]
-- CASE a) @let x <- copy(b^{lu})@ 
genCoalStmtInfo lutab scopetab pat (BasicOp (Copy b))
  | Pattern _ [PatElem x (_,ExpMem.MemArray _ _ _ (ExpMem.ArrayIn m_x ind_x))] <- pat =
    case (M.lookup x lutab, getScopeMemInfo b scopetab) of
      (Just last_uses, Just (MemBlock tpb shpb m_b ind_b)) ->
        if not (nameIn b last_uses) then Nothing
        else Just [(Ccopy,id,x,m_x,ind_x,b,m_b,ind_b,tpb,shpb)]
      _ -> Nothing
-- CASE c) @let x[i] = b^{lu}@
genCoalStmtInfo lutab scopetab pat (BasicOp (Update x slice_x (Var b)))
  | Pattern _ [PatElem x' (_,ExpMem.MemArray _ _ _ (ExpMem.ArrayIn m_x ind_x))] <- pat =
    case (M.lookup x' lutab, getScopeMemInfo b scopetab) of
      (Just last_uses, Just (MemBlock tpb shpb m_b ind_b)) ->
        if trace ("COALESCING: in-place pattern found for "++pretty b) $ not (nameIn b last_uses)
        then Nothing
        else -- let ind_x_slice = updateIndFunSlice ind_x slice_x
             Just [(InPl,(`updateIndFunSlice` slice_x), x,m_x,ind_x,b,m_b,ind_b,tpb,shpb)]
      _ -> Nothing
  where
    updateIndFunSlice :: ExpMem.IxFun -> Slice SubExp -> ExpMem.IxFun
    updateIndFunSlice ind_fun slc_x =
      let slc_x' = map (fmap pe64) slc_x
      in  IxFun.slice ind_fun slc_x'

-- CASE b) @let x = concat(a, b^{lu})@
genCoalStmtInfo lutab scopetab pat (BasicOp (Concat 0 b0 bs _))
  | Pattern _ [PatElem x (_,ExpMem.MemArray _ _ _ (ExpMem.ArrayIn m_x ind_x))] <- pat =
    case M.lookup x lutab of
      Nothing -> Nothing
      Just last_uses ->
        let zero = pe64 $ intConst Int64 0
            (res,_,_) =
              foldl (\ (acc,offs,succ0) b ->
                      if not succ0 then (acc, offs, succ0)
                      else
                        case getScopeMemInfo b scopetab of
                          Just (MemBlock tpb shpb@(Shape (fd:rdims)) m_b ind_b) ->
                            let offs' = offs + pe64 fd
                            in  if nameIn b last_uses
                                then let slc = unitSlice offs (pe64 fd) : map (unitSlice zero . pe64) rdims
                                         -- ind_x_slice = IxFun.slice ind_x slc
                                     in  (acc++[(Conc, (`IxFun.slice` slc), x,m_x,ind_x,b,m_b,ind_b,tpb,shpb)],offs',True)
                                else (acc,offs',True)
                          _ ->  (acc,offs,False)
                    ) ([],zero,True) (b0:bs)
        in  if null res then Nothing else Just res
-- CASE other than a), b), or c) not supported
genCoalStmtInfo _ _ _ _ = Nothing

-- | merges entries in the coalesced table.
appendCoalsInfo :: VName -> CoalsEntry -> CoalsTab -> CoalsTab
appendCoalsInfo mb info_new coalstab =
  case M.lookup mb coalstab of
    Nothing       -> M.insert mb info_new coalstab
    Just info_old -> M.insert mb (unionCoalsEntry info_old info_new) coalstab

-- | Results in pairs of pattern-blockresult pairs of (var name, mem block)
--   for those if-patterns that are candidates for coalescing.
findMemBodyResult :: CoalsTab
                  -> ScopeTab
                  -> [PatElem (Aliases ExpMem.SeqMem)]
                  -> Body (Aliases ExpMem.SeqMem)
                  -> [(VName, VName, VName, VName)]
findMemBodyResult activeCoals_tab scope_env patelms bdy =
  let scope_env' = scope_env <> scopeOf (bodyStms bdy)
  in  mapMaybe (\(patel, se_r) ->
                  case (patElemName patel, patElemDec patel, se_r) of
                    (b, (_,ExpMem.MemArray _ _ _ (ExpMem.ArrayIn m_b _)), Var r) ->
                      case getScopeMemInfo r scope_env' of
                        Nothing -> Nothing
                        Just (MemBlock _ _ m_r _) ->
                          case M.lookup m_b activeCoals_tab of
                            Nothing -> Nothing
                            Just coal_etry ->
                              case M.lookup b (vartab coal_etry) of
                                Nothing -> Nothing
                                Just _  -> Just (m_b,b,r,m_r)
                    _ ->     Nothing
               ) (zip patelms (bodyResult bdy))

-- | transfers coalescing from if-pattern to then|else body result
--   in the active coalesced table. The transfer involves, among
--   others, inserting @(r,m_r)@ in the optimistically-dependency
--   set of @m_b@'s entry and inserting @(b,m_b)@ in the opt-deps
--   set of @m_r@'s entry. Meaning, ultimately, @m_b@ can be merged
--   if @m_r@ can be merged (and vice-versa). This is checked by a
--   fix point iteration at the function-definition level.
transferCoalsToBody ::   M.Map VName (TPrimExp Int64 VName) -- (ExpMem.PrimExp VName)
                      -> CoalsTab
                      -> (VName, VName, VName, VName)
                      -> CoalsTab
transferCoalsToBody exist_subs activeCoals_tab (m_b, b, r, m_r) =
  -- the @Nothing@ pattern for the two @case ... of@ cannot happen
  -- because they were already cheked in @findMemBodyResult@
  case M.lookup m_b activeCoals_tab of
    Nothing -> Exc.assert False activeCoals_tab -- cannot happen
    Just etry ->
      case M.lookup b (vartab etry) of
        Nothing -> Exc.assert False activeCoals_tab -- cannot happen
        Just (Coalesced knd (MemBlock btp shp _ ind_b) subst_b) ->
          -- by definition of if-stmt, r and b have the same basic type, shape and
          -- index function, hence, for example, do not need to rebase
          -- We will check whether it is translatable at the definition point of r.
          let ind_r = IxFun.substituteInIxFun exist_subs ind_b
              subst_r = M.union exist_subs subst_b
              mem_info = Coalesced knd (MemBlock btp shp (dstmem etry) ind_r) subst_r
          in  if m_r == m_b -- already unified, just add binding for @r@
              then let etry' = etry { optdeps = M.insert b m_b (optdeps etry)
                                    , vartab  = M.insert r mem_info (vartab etry) }
                   in  M.insert m_r etry' activeCoals_tab
              else -- make them both optimistically depend on each other
                   let opts_x_new = M.insert r m_r (optdeps etry)
                       -- Here we should translate the @ind_b@ field of @mem_info@
                       -- across the existential introduced by the if-then-else
                       coal_etry  = etry{ vartab = M.singleton r mem_info
                                        , optdeps= M.insert b m_b (optdeps etry)
                                        }
                                    
                   in  M.insert m_b (etry {optdeps = opts_x_new} ) $
                       M.insert m_r coal_etry activeCoals_tab
