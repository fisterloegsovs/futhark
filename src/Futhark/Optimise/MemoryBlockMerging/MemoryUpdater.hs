{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds #-}
-- | Transform a program (really, a function) based on a mapping from variable
-- to memory and index function: Change every variable in the mapping to its new
-- memory.
module Futhark.Optimise.MemoryBlockMerging.MemoryUpdater
  (transformFromVarMemMappings) where

import qualified Data.Map.Strict as M
import qualified Data.List as L
import Data.Maybe (mapMaybe, fromMaybe)
import Control.Monad.Reader

import Futhark.Representation.AST
import Futhark.Representation.ExplicitMemory
       (ExplicitMemorish, ExplicitMemory)
import qualified Futhark.Representation.ExplicitMemory as ExpMem
import Futhark.Representation.Kernels.Kernel

import Futhark.Optimise.MemoryBlockMerging.Types
import Futhark.Optimise.MemoryBlockMerging.Miscellaneous


newtype FindM lore a = FindM { unFindM :: Reader (VarMemMappings MemoryLoc) a }
  deriving (Monad, Functor, Applicative,
            MonadReader (VarMemMappings MemoryLoc))

type LoreConstraints lore = (ExplicitMemorish lore,
                             FullMap lore,
                             BodyAttr lore ~ (),
                             ExpAttr lore ~ ())

coerce :: (ExplicitMemorish flore, ExplicitMemorish tlore) =>
          FindM flore a -> FindM tlore a
coerce = FindM . unFindM


transformFromVarMemMappings :: LoreConstraints lore =>
                               VarMemMappings MemoryLoc -> FunDef lore
                            -> FunDef lore
transformFromVarMemMappings var_to_mem fundef =
  let m = unFindM $ transformBody $ funDefBody fundef
      body' = runReader m var_to_mem
  in fundef { funDefBody = body' }

transformBody :: LoreConstraints lore =>
                 Body lore -> FindM lore (Body lore)
transformBody (Body () bnds res) = do
  bnds' <- mapM transformStm bnds
  return $ Body () bnds' res

transformKernelBody :: LoreConstraints lore =>
                       KernelBody lore -> FindM lore (KernelBody lore)
transformKernelBody (KernelBody () bnds res) = do
  bnds' <- mapM transformStm bnds
  return $ KernelBody () bnds' res

transformStm :: LoreConstraints lore =>
                Stm lore -> FindM lore (Stm lore)
transformStm (Let (Pattern patctxelems patvalelems) () e) = do
  patvalelems' <- mapM transformPatValElem patvalelems
  e' <- fullMapExpM mapper mapper_kernel e
  var_to_mem <- ask
  e'' <- case e' of
    DoLoop mergectxparams mergevalparams loopform body -> do
      -- More special loop handling because of its extra
      -- pattern-like info.
      mergevalparams' <- mapM transformMergeValParam mergevalparams
      mergectxparams' <- mapM transformMergeCtxParam mergectxparams

      -- The body of a loop can return a memory block in its results.  This is
      -- the memory block used by a variable which is also part of the results.
      -- If the memory block of that variable is changed, we need a way to
      -- record that the memory block in the body result also needs to change.
      --
      -- Should be fine?  Should maybe be patvalelems', important?
      let zipped = zip [(0::Int)..] (patctxelems ++ patvalelems)

          findMemLinks (i, PatElem _x _binding (ExpMem.ArrayMem _ _ _ xmem _)) =
            case L.find (\(_, PatElem ymem _ _) -> ymem == xmem) zipped of
              Just (j, _) -> Just (j, i)
              Nothing -> Nothing
          findMemLinks _ = Nothing

          mem_links = mapMaybe findMemLinks zipped

          res = bodyResult body

          fixResRecord i se
            | Var _mem <- se
            , Just j <- L.lookup i mem_links
            , Var related_var <- res L.!! j
            , Just mem_new <- M.lookup related_var var_to_mem =
                Var $ memLocName mem_new
            | otherwise = se

          res' = zipWith fixResRecord [(0::Int)..] res
          body' = body { bodyResult = res' }
      return $ DoLoop mergectxparams' mergevalparams' loopform body'
    _ -> return e'
  return $ Let (Pattern patctxelems patvalelems') () e''
  where mapper = identityMapper
          { mapOnBody = const transformBody
          , mapOnFParam = transformFParam
          , mapOnLParam = transformLParam
          }
        mapper_kernel = identityKernelMapper
          { mapOnKernelBody = coerce . transformBody
          , mapOnKernelKernelBody = coerce . transformKernelBody
          , mapOnKernelLambda = coerce . transformLambda
          , mapOnKernelLParam = transformLParam
          }

-- Update the actual memory block referred to by a context memory block
-- in a loop.
transformMergeCtxParam :: LoreConstraints lore =>
                          (FParam ExplicitMemory, SubExp)
                       -> FindM lore (FParam ExplicitMemory, SubExp)
transformMergeCtxParam (param@(Param ctxmem ExpMem.MemMem{}), mem) = do
  var_to_mem <- ask
  let mem' = fromMaybe mem ((Var . memLocName) <$> M.lookup ctxmem var_to_mem)
  return (param, mem')
transformMergeCtxParam t = return t

transformMergeValParam :: LoreConstraints lore =>
                          (FParam ExplicitMemory, SubExp)
                       -> FindM lore (FParam ExplicitMemory, SubExp)
transformMergeValParam (Param x membound, se) = do
  membound' <- newMemBound membound x
  return (Param x membound', se)

transformPatValElem :: LoreConstraints lore =>
                       PatElem ExplicitMemory -> FindM lore (PatElem ExplicitMemory)
transformPatValElem (PatElem x bindage membound) = do
  membound' <- newMemBound membound x
  return $ PatElem x bindage membound'

transformFParam :: LoreConstraints lore =>
                   FParam lore -> FindM lore (FParam lore)
transformFParam (Param x membound) = do
  membound' <- newMemBound membound x
  return $ Param x membound'

transformLParam :: LoreConstraints lore =>
                   LParam lore -> FindM lore (LParam lore)
transformLParam (Param x membound) = do
  membound' <- newMemBound membound x
  return $ Param x membound'

transformLambda :: LoreConstraints lore =>
                   Lambda lore -> FindM lore (Lambda lore)
transformLambda (Lambda params body types) = do
  params' <- mapM transformLParam params
  body' <- transformBody body
  return $ Lambda params' body' types

newMemBound :: ExpMem.MemBound u -> VName -> FindM lore (ExpMem.MemBound u)
newMemBound membound var = do
  var_to_mem <- ask

  let membound'
        | ExpMem.ArrayMem pt shape u _ _ <- membound
        , Just (MemoryLoc mem ixfun) <- M.lookup var var_to_mem =
            Just $ ExpMem.ArrayMem pt shape u mem ixfun
        | otherwise = Nothing

  return $ fromMaybe membound membound'
