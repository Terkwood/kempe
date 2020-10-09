{-# LANGUAGE OverloadedStrings #-}

module Kempe.TypeSynthesis ( TypeM
                           , runTypeM
                           , tyAtoms
                           ) where

import           Control.Monad.Except (ExceptT, runExceptT, throwError)
import           Control.Monad.State
import           Data.Foldable        (traverse_)
import qualified Data.IntMap          as IM
import qualified Data.Set             as S
import qualified Data.Text            as T
import           Kempe.AST
import           Kempe.Error
import           Kempe.Name
import           Kempe.Unique
import           Lens.Micro           (Lens')
import           Lens.Micro.Mtl       (modifying)

type TyEnv a = IM.IntMap (StackType a)

data TyState a = TyState { maxU             :: Int -- ^ For renamer
                         , tyEnv            :: TyEnv a
                         , renames          :: IM.IntMap Int
                         , constructorTypes :: IM.IntMap (StackType a)
                         , constraints      :: S.Set (KempeTy a, KempeTy a) -- Just need equality between simple types? (do have tyapp but yeah)
                         }

emptyStackType :: StackType a
emptyStackType = StackType mempty [] []

maxULens :: Lens' (TyState a) Int
maxULens f s = fmap (\x -> s { maxU = x }) (f (maxU s))

constructorTypesLens :: Lens' (TyState a) (IM.IntMap (StackType a))
constructorTypesLens f s = fmap (\x -> s { constructorTypes = x }) (f (constructorTypes s))

tyEnvLens :: Lens' (TyState a) (TyEnv a)
tyEnvLens f s = fmap (\x -> s { tyEnv = x }) (f (tyEnv s))

dummyName :: T.Text -> TypeM () (Name ())
dummyName n = do
    pSt <- gets maxU
    Name n (Unique $ pSt + 1) ()
        <$ modifying maxULens (+1)

type TypeM a = ExceptT (Error a) (State (TyState a))

-- TODO: take constructor types as an argument?..
runTypeM :: TypeM a x -> Either (Error a) x
runTypeM = flip evalState (TyState 0 mempty mempty mempty S.empty) . runExceptT

-- alpha-equivalence (of 'StackType's?) (note it is quantified *only* on the "exterior" i.e.
-- implicitly) -> except we have to then "back-instantiate"? hm

-- monomorphization

-- dip-ify?

-- renameStackType? or maybe j substitute?

typeOfBuiltin :: BuiltinFn -> TypeM () (StackType ())
typeOfBuiltin Drop = do
    aN <- dummyName "a"
    pure $ StackType (S.singleton aN) [TyVar () aN] []
typeOfBuiltin Swap = do
    aN <- dummyName "a"
    bN <- dummyName "b"
    pure $ StackType (S.fromList [aN, bN]) [TyVar () aN, TyVar () bN] [TyVar () bN, TyVar () aN]

-- maybe constraints? e.g. ("a" = "b") and (3 = "a")
-- but maybe simpler since no function types? lol
--
-- so I can literally just check it's 3 and then pass that back lololol
tyLookup :: Name a -> TypeM a (StackType a)
tyLookup n@(Name _ (Unique i) l) = do
    st <- gets tyEnv
    case IM.lookup i st of
        Just ty -> pure ty
        Nothing -> throwError (PoorScope l n)

dipify :: StackType () -> TypeM () (StackType ())
dipify (StackType fvrs is os) = do
    n <- dummyName "a"
    pure $ StackType (S.insert n fvrs) (TyNamed () n:is) (TyNamed () n:os)

tyAtom :: Atom a -> TypeM () (StackType ())
tyAtom (AtBuiltin _ b) = typeOfBuiltin b
tyAtom BoolLit{}       = pure $ StackType mempty [] [TyBuiltin () TyBool]
tyAtom IntLit{}        = pure $ StackType mempty [] [TyBuiltin () TyInt]
tyAtom (AtName _ n)    = tyLookup (void n)
tyAtom (Dip _ as)      = dipify =<< tyAtoms as
tyAtom (If _ as as')   = do
    tys <- tyAtoms as
    tys' <- tyAtoms as'
    (StackType vars ins out) <- mergeStackTypes tys tys'
    pure $ StackType vars (TyBuiltin () TyBool:ins) out
tyAtom (AtCons _ tn@(Name _ (Unique i) _)) = do
    cSt <- gets constructorTypes
    case IM.lookup i cSt of
        Just st -> pure st
        Nothing -> throwError $ PoorScope () (void tn)

tyAtoms :: [Atom a] -> TypeM () (StackType ())
tyAtoms = foldM
    (\seed a -> do { tys' <- tyAtom a ; catTypes tys' seed })
    emptyStackType

tyInsertLeaf :: Name a -- ^ type being declared
             -> S.Set (Name a) -> (TyName a, [KempeTy a]) -> TypeM () ()
tyInsertLeaf n vars (Name _ (Unique i) _, ins) =
    modifying constructorTypesLens (IM.insert i (voidStackType $ StackType vars ins [TyNamed undefined n]))

extrVars :: KempeTy a -> [Name a]
extrVars TyBuiltin{}      = []
extrVars TyNamed{}        = []
extrVars (TyVar _ n)      = [n]
extrVars (TyApp _ ty ty') = extrVars ty ++ extrVars ty'
extrVars (TyTuple _ tys)  = concatMap extrVars tys

freeVars :: [KempeTy a] -> S.Set (Name a)
freeVars tys = S.fromList (concatMap extrVars tys)

tyInsert :: KempeDecl a -> TypeM () ()
tyInsert (TyDecl _ tn ns ls) = traverse_ (tyInsertLeaf tn (S.fromList ns)) ls
tyInsert (FunDecl _ (Name _ (Unique i) _) ins out as) = do
    let sig = voidStackType $ StackType (freeVars (ins ++ out)) ins out
    inferred <- tyAtoms as
    reconcile <- mergeStackTypes sig inferred
    modifying tyEnvLens (IM.insert i reconcile)

-- just dispatch constraints?
mergeStackTypes :: StackType () -> StackType () -> TypeM () (StackType ())
mergeStackTypes _ _ = pure undefined

-- | Given @x@ and @y@, return the 'StackType' of @x y@
catTypes :: StackType a -- ^ @x@
         -> StackType a -- ^ @y@
         -> TypeM () (StackType ())
catTypes _ _ = pure undefined -- I need unification? :o
