{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Language.Haskell.Liquid.Bare.Resolve (
     Resolvable(..)
  ) where


import           Prelude                             hiding (error)
import           Var
import           Control.Monad.State
import           Data.Char                           (isUpper)
import           Text.Parsec.Pos
import qualified Data.HashMap.Strict                 as M
import qualified Language.Fixpoint.Types            as F -- (prims, unconsSym)
import           Language.Fixpoint.Types (Expr(..), Sort(..))
import qualified Language.Haskell.Liquid.GHC.Misc   as GM 
import           Language.Haskell.Liquid.Misc        (secondM, third3M)
import           Language.Haskell.Liquid.Types
import           Language.Haskell.Liquid.Bare.Env
import           Language.Haskell.Liquid.Bare.Lookup

class Resolvable a where
  resolve :: SourcePos -> a -> BareM a

instance Resolvable a => Resolvable [a] where
  resolve = mapM . resolve

instance Resolvable F.Qualifier where
  resolve _ (F.Q n ps b l) = F.Q n <$> mapM (resolve l) ps <*> resolve l b <*> return l

instance Resolvable F.QualParam where 
  resolve l qp = do 
    t <- resolve l (F.qpSort qp)
    return (qp {F.qpSort = t})

instance Resolvable Expr where
  resolve l (EVar s)        = EVar   <$> resolve l s
  resolve l (EApp s es)     = EApp   <$> resolve l s  <*> resolve l es
  resolve l (ENeg e)        = ENeg   <$> resolve l e
  resolve l (EBin o e1 e2)  = EBin o <$> resolve l e1 <*> resolve l e2
  resolve l (EIte p e1 e2)  = EIte   <$> resolve l p  <*> resolve l e1 <*> resolve l e2
  resolve l (ECst x s)      = ECst   <$> resolve l x  <*> resolve l s
  resolve l (PAnd ps)       = PAnd    <$> resolve l ps
  resolve l (POr  ps)       = POr     <$> resolve l ps
  resolve l (PNot p)        = PNot    <$> resolve l p
  resolve l (PImp p q)      = PImp    <$> resolve l p  <*> resolve l q
  resolve l (PIff p q)      = PIff    <$> resolve l p  <*> resolve l q
  resolve l (PAtom r e1 e2) = PAtom r <$> resolve l e1 <*> resolve l e2
  resolve l (ELam (x,t) e)  = ELam    <$> ((,) <$> resolve l x <*> resolve l t) <*> resolve l e
  resolve l (ECoerc a t e)  = ECoerc  <$> resolve l a <*> resolve l t   <*> resolve l e
  resolve l (PAll vs p)     = PAll    <$> mapM (secondM (resolve l)) vs <*> resolve l p
  resolve l (ETApp e s)     = ETApp   <$> resolve l e <*> resolve l s
  resolve l (ETAbs e s)     = ETAbs   <$> resolve l e <*> resolve l s
  resolve _ (PKVar k s)     = return $ PKVar k s
  resolve l (PExist ss e)   = PExist ss <$> resolve l e
  resolve _ (ESym s)        = return $ ESym s
  resolve _ (ECon c)        = return $ ECon c
  resolve l (PGrad k su i e)  = PGrad k su i <$> resolve l e

instance Resolvable LocSymbol where
  resolve = resolveSym

resolveSym :: SourcePos -> LocSymbol -> BareM LocSymbol
resolveSym _ ls@(Loc _ _ s) = do
  isKnown <- isSpecialSym s
  if isKnown || not (isCon s)
    then return ls
    else resolveCtor ls

resolveCtor :: LocSymbol -> BareM LocSymbol
resolveCtor ls = do
  env1 <- gets propSyms
  case M.lookup (val ls) env1 of
    Just ls' -> return ls'
    Nothing  -> resolveCtorVar ls

resolveCtorVar :: LocSymbol -> BareM LocSymbol
resolveCtorVar ls = do 
  v <- lookupGhcVar ls
  let qs = F.symbol v
  addSym (qs, v)
  return (F.atLoc ls qs)

isSpecialSym :: F.Symbol -> BareM Bool
isSpecialSym s = do
  env0 <- gets (typeAliases . rtEnv)
  return $ or [s `elem` F.prims
              , M.member s env0
              , GM.isWorker s ]

addSym :: MonadState BareEnv m => (F.Symbol, Var) -> m ()
addSym (x, v) = modify $ \be -> be { varEnv = M.insert x v (varEnv be) } --  `L.union` [x] } -- TODO: OMG THIS IS THE SLOWEST THING IN THE WORLD!

isCon :: F.Symbol -> Bool
isCon s
  | Just (c,_) <- F.unconsSym s = isUpper c
  | otherwise                   = False

instance Resolvable F.Symbol where
  resolve l x = fmap val $ resolve l $ Loc l l x

instance Resolvable Sort where
  resolve _ FInt          = return FInt
  resolve _ FReal         = return FReal
  resolve _ FNum          = return FNum
  resolve _ FFrac         = return FFrac
  resolve _ s@(FObj _)    = return s 
  resolve _ s@(FVar _)    = return s
  resolve l (FAbs i  s)   = FAbs i <$> (resolve l s)
  resolve l (FFunc s1 s2) = FFunc <$> (resolve l s1) <*> (resolve l s2)
  resolve _ (FTC c)
    | tcs' `elem` F.prims = FTC <$> return c
    | otherwise           = do ty     <- lookupGhcTyCon "resolve1" tcs
                               emb    <- embeds <$> get
                               let ftc = FTC . F.symbolFTycon . Loc l l' $ F.symbol ty
                               return  $ maybe ftc fst (F.tceLookup ty emb)
    where
      tcs@(Loc l l' tcs') = F.fTyconSymbol c
  resolve l (FApp t1 t2) = FApp <$> resolve l t1 <*> resolve l t2

instance Resolvable (UReft F.Reft) where
  resolve l (MkUReft r p s) = MkUReft <$> resolve l r <*> resolve l p <*> return s

instance Resolvable F.Reft where
  resolve l (F.Reft (s, ra)) = F.Reft . (s,) <$> resolve l ra

instance Resolvable Predicate where
  resolve l (Pr pvs) = Pr <$> resolve l pvs

instance (Resolvable t) => Resolvable (PVar t) where
  resolve l (PV n t v as) = PV n t v <$> mapM (third3M (resolve l)) as

instance Resolvable () where
  resolve _ = return
