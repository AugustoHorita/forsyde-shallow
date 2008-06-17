{-# LANGUAGE ScopedTypeVariables #-} 
-----------------------------------------------------------------------------
-- |
-- Module      :  ForSyDe.Backend.Simulate
-- Copyright   :  (c) The ForSyDe Team 2007
-- License     :  BSD-style (see the file LICENSE)
-- 
-- Maintainer  :  ecs_forsyde_development@ict.kth.se
-- Stability   :  experimental
-- Portability :  non-portable (Template Haskell, LSTV)
--
-- This module provides the simulation backend of ForSyDe's embedded compiler
--
-- /This module is based on Lava2000/: <http://www.cs.chalmers.se/~koen/Lava/>
--
-----------------------------------------------------------------------------
module ForSyDe.Backend.Simulate (simulate) where

import ForSyDe.OSharing
import ForSyDe.Netlist
import ForSyDe.Netlist.Traverse
import ForSyDe.System.SysDef
import ForSyDe.System.SysFun(SysFunToSimFun(..))
import ForSyDe.ForSyDeErr
import ForSyDe.Process.ProcVal

import Control.Monad (liftM, mapM_, zipWithM_)
import Data.Maybe (fromJust)
import Control.Monad.ST
import Data.STRef
import qualified Data.Traversable as DT
import Data.List (lookup, transpose)
import Data.Dynamic

-- | 'simulate' takes a system definition and generates a function 
--   able simulate a System using a list-based representation 
--   of its signals.
simulate :: SysFunToSimFun sysFun simFun => SysDef sysFun -> simFun
simulate sysDef = fromListSimFun (simulateDyn (unSysDef sysDef)) []

-- FIXME: clean and document the following horrible code!

--------------------------------------
-- The following was adapted from Lava
--------------------------------------

type Var s
  = (STRef s Dynamic, STRef s (Wire s))

data Wire s
  = Wire
    { dependencies :: [Var s]
    , kick         :: ST s ()
    }

----------------------------------------------------------------
-- simulateDyn


simulateDyn :: PrimSysDef  -> [[Dynamic]] -> [[Dynamic]]
simulateDyn pSysDef inps | any null inps = replicate outN []
   where outN = (length . oIface . readURef . unPrimSysDef) pSysDef
simulateDyn pSysDef inps = runST (
  do let sysDefVal = (readURef . unPrimSysDef) pSysDef
         sysDefInIface = iIface sysDefVal
     -- List where to store the Vars generated by delay processes
     roots <- newSTRef []
     -- Input port ids paired with a reference to each input value list
     inpPairs <- zipWithM (\(id,_) inputL -> 
                            do {ref <- newSTRef inputL; return (id,ref)}) 
                         sysDefInIface inps

     let -- Add a Var to the roots list 
         root r =
           do rs <- readSTRef roots
              writeSTRef roots (r:rs)

         -- Create an empty var
         empty = do rval <- newSTRef (error "val?")
                    rwir <- newSTRef (error "wire?")
                    return (rval, rwir)
         new node = 
           do mapM (\tag -> do {e <- empty; return (tag, e)}) (outTags node)
         newInstance varPairs node =
           let funName = "ForSyDe.Backend.Simulate.simulateDyn" 
           in case node of
             InPort id ->
                 case lookup id varPairs of
                     -- FIXME: replace the Other error with a custom one
                     Nothing  -> intError funName (Other "inconsistency")
                     Just var -> return [(InPortOut, var)]
             _      -> new node
         
         -- define for the general traversal
         define  nodeVarPairs childVars = 
           case (nodeVarPairs,childVars) of
            ([(InPortOut, var)], InPort name) -> do
              let inputRef = fromJust $ lookup name inpPairs
              relate var [] $
                do (curr:rest) <- readSTRef inputRef
                   writeSTRef inputRef rest
                   return curr
                   
            _ -> defineShared nodeVarPairs childVars

         -- define for instances
         defineInstance nodeVarPairs childVars = 
           case (nodeVarPairs,childVars) of
            ([(InPortOut, _)], InPort _) -> return ()
            _ -> defineShared nodeVarPairs childVars
         
         -- Shared part of define define for instances and the main traversal
         defineShared  nodeVarPairs childVars = -- r s =
           case (nodeVarPairs,childVars) of
            ([(InPortOut, _)], InPort _) -> return ()

            (nodeVarPairs,
             Proc _ (SysIns pSysDef ins)) ->
               -- FIXME: ugly ugly ugly
               do let sysDefVal = (readURef . unPrimSysDef) pSysDef
                      taggedIns = zipWith (\(id,_) var -> (id,var)) 
                                          (iIface sysDefVal) ins
                  sr  <- traverseST 
                           (newInstance taggedIns)
                           defineInstance 
                           (netlist sysDefVal)

                  let relateIns prevVar@(prevValR,_) (_,nextVar) =
                         relate nextVar [prevVar] (readSTRef prevValR)
 
                  zipWithM_ relateIns sr nodeVarPairs

            ([(DelaySYOut, nodeVar)], 
             Proc _ (DelaySY (ProcVal init _) sigVar)) ->
               do valVar <- empty
                  relate valVar [] (return init)                    
                  delay nodeVar valVar sigVar
            _ ->
              do let evalPairs = eval `fmap` DT.mapM (readSTRef.fst) childVars
                     args = arguments childVars
                     relEval (tag, var) = 
                         relate var args $
                            -- FIXME: remove fromJust and write a proper error
                            liftM (fromJust.(lookup tag)) evalPairs
                 mapM_ relEval  nodeVarPairs  
          where
           delay r ri@(rinit,_) r1@(pre,_) =
               do state <- newSTRef Nothing
                  r2 <- empty
                  root r2

                  relate r [ri] $
                    do ms <- readSTRef state
                       case ms of
                         Just s  -> return s
                         Nothing ->
                           do s <- readSTRef rinit
                              writeSTRef state (Just s)
                              return s

                  relate r2 [r,r1] $
                    do s <- readSTRef pre
                       writeSTRef state (Just s)
                       return s
     
     sr   <- traverseST new define (netlist sysDefVal)
     rs   <- readSTRef roots
     -- remove tags of the resulting vars (all the root nodes should only
     -- have one output and thus a must return a unique list)
     step <- drive (sr ++ rs)

     outs <- lazyloop $
       do step
          s <- DT.mapM (readSTRef . fst) sr
          return s
     -- Since the simulation is done in a per-cycle basis
     -- the results (outs) are transposed (not what we want)
     -- e.g.
     -- imagine a system whose outputs are its inputs plus 1
     -- then, for this these two inputs [[1,2,3],[4,5,6]]
     -- outs would be [[2,5],[3,6],[4,7]]
     --
     -- We need as well to check that all inputs are defined in
     -- each simulation cycle e.g. [[1,2,3],[4,5,6,7]] as input
     -- makes imposible to simulate cycle 4
     --
     -- NOTE: having to check this makes simulation really inneficient
     -- a solution would providing a cycle-based simulation input/output
     -- which wouldn't suffer from this problems
     -- Or, even better, a simulation which showed a diffierent type of output 
     let inN = length sysDefInIface
         res = if inN == 0 then
                 transpose outs
               else transpose (checkIns inN (transpose inps) outs)
     return res
  )

   
-- evaluation order

relate :: Var s -> [Var s] -> ST s Dynamic -> ST s ()
relate (rval, rwir) rs f =
  do writeSTRef rwir $ 
       Wire{ dependencies = rs
           , kick = do b <- f
                       writeSTRef rval b
           }

drive :: [Var s] -> ST s (ST s ())
drive [] =
  do return (return ())

drive ((rval,rwir):rs) =
  do wire <- readSTRef rwir
     writeSTRef rwir (error "detected combinational loop")
     driv1 <- drive (dependencies wire)
     writeSTRef rwir $
       Wire { dependencies = [], kick = return () }
     driv2 <- drive rs
     return $
       do driv1
          kick wire
          driv2

----------------------------------------------------------------
-- helper functions

lazyloop :: ST s a -> ST s [a]
lazyloop m = 
  do a  <- m
     as <- unsafeInterleaveST (lazyloop m)
     return (a:as)

-- | check that there will only be output as long as there are inputs 
checkIns :: Int -- ^ number of inputs 
         -> [[a]] -- ^ transposed inputs 
         -> [[b]] -- ^ transposed outputs (infinitie list) 
         -> [[b]] -- ^ selected outputs

-- The lazy pattern match is used to avoid evaluating the output list 
-- if length i /= nIns. If that happens the input lists of simulate will 
-- implicitly be simulated, and due to lack of inputs it will cause an error. 
checkIns nIns (i:is) ~(o:os) |  length i == nIns = o : checkIns nIns is os  
checkIns _ _ _ = []




