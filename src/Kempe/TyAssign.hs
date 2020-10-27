{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Kempe.TyAssign ( TypeM
                      , runTypeM
                      , checkModule
                      , assignModule
                      ) where

import           Control.Composition        (thread)
import           Control.Monad              (foldM, replicateM, unless, when, zipWithM_)
import           Control.Monad.Except       (throwError)
import           Control.Monad.State.Strict (StateT, get, gets, modify, put, runStateT)
import           Data.Bifunctor             (second)
import           Data.Foldable              (traverse_)
import           Data.Functor               (void, ($>))
import qualified Data.IntMap                as IM
import           Data.List                  (foldl')
import           Data.List.NonEmpty         (NonEmpty (..))
import           Data.Maybe                 (fromMaybe)
import           Data.Semigroup             ((<>))
import qualified Data.Set                   as S
import qualified Data.Text                  as T
import           Kempe.AST
import           Kempe.Error
import           Kempe.Name
import           Kempe.Unique
import           Lens.Micro                 (Lens', over)
import           Lens.Micro.Mtl             (modifying, (.=))
import           Prettyprinter              (Doc, Pretty (pretty), hardline, indent, vsep, (<+>))

type TyEnv a = IM.IntMap (StackType a)

data TyState a = TyState { maxU             :: Int -- ^ For renamer
                         , tyEnv            :: TyEnv a
                         , renames          :: IM.IntMap Int
                         , constructorTypes :: IM.IntMap (StackType a)
                         , constraints      :: S.Set (KempeTy a, KempeTy a) -- Just need equality between simple types? (do have tyapp but yeah)
                         }

infixr 6 <#>

(<#>) :: Doc a -> Doc a -> Doc a
(<#>) x y = x <> hardline <> y

(<#*>) :: Doc a -> Doc a -> Doc a
(<#*>) x y = x <> hardline <> indent 2 y

instance Pretty (TyState a) where
    pretty (TyState _ te r _ cs) =
        "type environment:" <#> vsep (prettyBound <$> IM.toList te)
            <#> "renames:" <#*> prettyDumpBinds r
            <#> "constraints:" <#> prettyConstraints cs

prettyConstraints :: S.Set (KempeTy a, KempeTy a) -> Doc ann
prettyConstraints cs = vsep (prettyEq <$> S.toList cs)

prettyBound :: (Int, StackType a) -> Doc b
prettyBound (i, e) = pretty i <+> "←" <#*> pretty e

prettyEq :: (KempeTy a, KempeTy a) -> Doc ann
prettyEq (ty, ty') = pretty ty <+> "≡" <+> pretty ty'

prettyDumpBinds :: Pretty b => IM.IntMap b -> Doc a
prettyDumpBinds b = vsep (prettyBind <$> IM.toList b)

prettyBind :: Pretty b => (Int, b) -> Doc a
prettyBind (i, j) = pretty i <+> "→" <+> pretty j

emptyStackType :: StackType a
emptyStackType = StackType mempty [] []

maxULens :: Lens' (TyState a) Int
maxULens f s = fmap (\x -> s { maxU = x }) (f (maxU s))

constructorTypesLens :: Lens' (TyState a) (IM.IntMap (StackType a))
constructorTypesLens f s = fmap (\x -> s { constructorTypes = x }) (f (constructorTypes s))

tyEnvLens :: Lens' (TyState a) (TyEnv a)
tyEnvLens f s = fmap (\x -> s { tyEnv = x }) (f (tyEnv s))

renamesLens :: Lens' (TyState a) (IM.IntMap Int)
renamesLens f s = fmap (\x -> s { renames = x }) (f (renames s))

constraintsLens :: Lens' (TyState a) (S.Set (KempeTy a, KempeTy a))
constraintsLens f s = fmap (\x -> s { constraints = x }) (f (constraints s))

dummyName :: T.Text -> TypeM () (Name ())
dummyName n = do
    pSt <- gets maxU
    Name n (Unique $ pSt + 1) ()
        <$ modifying maxULens (+1)

type TypeM a = StateT (TyState a) (Either (Error a))

onType :: (Int, KempeTy a) -> KempeTy a -> KempeTy a
onType _ ty'@TyBuiltin{} = ty'
onType _ ty'@TyNamed{}   = ty'
onType (k, ty) ty'@(TyVar _ (Name _ (Unique i) _)) | i == k = ty
                                                   | otherwise = ty'
onType (k, ty) (TyApp l ty' ty'') = TyApp l (onType (k, ty) ty') (onType (k, ty) ty'') -- I think this is right
onType (k, ty) (TyTuple l tys) = TyTuple l (onType (k, ty) <$> tys)

renameForward :: (Int, KempeTy a) -> [(KempeTy a, KempeTy a)] -> [(KempeTy a, KempeTy a)]
renameForward _ []                      = []
renameForward (k, ty) ((ty', ty''):tys) = (onType (k, ty) ty', onType (k, ty) ty'') : renameForward (k, ty) tys

unify :: [(KempeTy a, KempeTy a)] -> Either (Error ()) (IM.IntMap (KempeTy ()))
unify []                                                             = Right mempty
unify ((ty@(TyBuiltin _ b0), ty'@(TyBuiltin _ b1)):tys) | b0 == b1   = unify tys
                                                        | otherwise  = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@(TyNamed _ n0), ty'@(TyNamed _ n1)):tys) | n0 == n1       = unify tys
                                                    | otherwise      = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@(TyNamed _ _), TyVar  _ (Name _ (Unique k) _)):tys)       = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys) -- is this O(n^2) or something bad?
unify ((TyVar _ (Name _ (Unique k) _), ty@(TyNamed _ _)):tys)        = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys) -- FIXME: is renameForward enough?
unify ((ty@(TyBuiltin _ _), TyVar  _ (Name _ (Unique k) _)):tys)     = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys)
unify ((TyVar _ (Name _ (Unique k) _), ty@(TyBuiltin _ _)):tys)      = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys)
unify ((TyVar _ (Name _ (Unique k) _), ty@(TyVar _ _)):tys)          = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys)
unify ((ty@TyBuiltin{}, ty'@TyNamed{}):_)                            = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyNamed{}, ty'@TyBuiltin{}):_)                            = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyBuiltin{}, ty'@TyApp{}):_)                              = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyNamed{}, ty'@TyApp{}):_)                                = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyApp{}, ty'@TyBuiltin{}):_)                              = Left (UnificationFailed () (void ty) (void ty'))
unify ((TyVar _ (Name _ (Unique k) _), ty@TyApp{}):tys)              = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys)
unify ((ty@TyApp{}, TyVar  _ (Name _ (Unique k) _)):tys)             = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys)
unify ((TyApp _ ty ty', TyApp _ ty'' ty'''):tys)                     = unify ((ty, ty'') : (ty', ty''') : tys) -- TODO: I think this is right?
unify ((ty@TyApp{}, ty'@TyNamed{}):_)                                = Left (UnificationFailed () (void ty) (void ty'))
unify ((TyTuple _ tys, TyTuple _ tys'):tys'')                        = unify (zip tys tys' ++ tys'')
unify ((ty@(TyTuple _ _), TyVar  _ (Name _ (Unique k) _)):tys)       = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys)
unify ((TyVar _ (Name _ (Unique k) _), ty@(TyTuple _ _)):tys)        = IM.insert k (void ty) <$> unify (renameForward (k, ty) tys)
unify ((ty@TyBuiltin{}, ty'@TyTuple{}):_)                            = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyNamed{}, ty'@TyTuple{}):_)                              = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyTuple{}, ty'@TyBuiltin{}):_)                            = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyTuple{}, ty'@TyNamed{}):_)                              = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyApp{}, ty'@TyTuple{}):_)                                = Left (UnificationFailed () (void ty) (void ty'))
unify ((ty@TyTuple{}, ty'@TyApp{}):_)                                = Left (UnificationFailed () (void ty) (void ty'))

unifyM :: S.Set (KempeTy a, KempeTy a) -> TypeM () (IM.IntMap (KempeTy ()))
unifyM s =
    case unify (S.toList s) of
        Right x  -> pure x
        Left err -> throwError err

-- TODO: take constructor types as an argument?..
runTypeM :: Int -- ^ For renamer
         -> TypeM a x -> Either (Error a) (x, Int)
runTypeM maxInt = fmap (second maxU) .
    flip runStateT (TyState maxInt mempty mempty mempty S.empty)

typeOfBuiltin :: BuiltinFn -> TypeM () (StackType ())
typeOfBuiltin Drop = do
    aN <- dummyName "a"
    pure $ StackType (S.singleton aN) [TyVar () aN] []
typeOfBuiltin Swap = do
    aN <- dummyName "a"
    bN <- dummyName "b"
    pure $ StackType (S.fromList [aN, bN]) [TyVar () aN, TyVar () bN] [TyVar () bN, TyVar () aN]
typeOfBuiltin Dup = do
    aN <- dummyName "a"
    pure $ StackType (S.singleton aN) [TyVar () aN] [TyVar () aN, TyVar () aN]
typeOfBuiltin IntEq     = pure $ StackType S.empty [TyBuiltin () TyInt, TyBuiltin () TyInt] [TyBuiltin () TyBool]
typeOfBuiltin IntMod    = pure intBinOp
typeOfBuiltin IntDiv    = pure intBinOp
typeOfBuiltin IntPlus   = pure intBinOp
typeOfBuiltin IntTimes  = pure intBinOp
typeOfBuiltin IntMinus  = pure intBinOp
typeOfBuiltin IntShiftR = pure intBinOp
typeOfBuiltin IntShiftL = pure intBinOp
typeOfBuiltin IntXor    = pure intBinOp

intBinOp :: StackType ()
intBinOp = StackType S.empty [TyBuiltin () TyInt, TyBuiltin () TyInt] [TyBuiltin () TyInt]

tyLookup :: Name a -> TypeM a (StackType a)
tyLookup n@(Name _ (Unique i) l) = do
    st <- gets tyEnv
    case IM.lookup i st of
        Just ty -> pure ty
        Nothing -> throwError $ PoorScope l n

consLookup :: TyName a -> TypeM a (StackType a)
consLookup tn@(Name _ (Unique i) l) = do
    st <- gets constructorTypes
    case IM.lookup i st of
        Just ty -> pure ty
        Nothing -> throwError $ PoorScope l tn

-- expandType 1
dipify :: StackType () -> TypeM () (StackType ())
dipify (StackType fvrs is os) = do
    n <- dummyName "a"
    pure $ StackType (S.insert n fvrs) (TyNamed () n:is) (TyNamed () n:os)

assignName :: Name a -> TypeM () (Name (StackType ()))
assignName n = do { ty <- tyLookup (void n) ; pure (n $> ty) }

tyLeaf :: (Pattern a, [Atom a]) -> TypeM () (StackType ())
tyLeaf (p, as) = do
    -- TODO: Rename here?
    tyP <- tyPattern p
    tyA <- tyAtoms as
    catTypes tyP tyA

assignCase :: (Pattern a, [Atom a]) -> TypeM () (StackType (), Pattern (StackType ()), [Atom (StackType ())])
assignCase (p, as) = do
    (tyP, p') <- assignPattern p
    (as', tyA) <- assignAtoms as
    (,,) <$> catTypes tyP tyA <*> pure p' <*> pure as'

tyAtom :: Atom a -> TypeM () (StackType ())
tyAtom (AtBuiltin _ b) = typeOfBuiltin b
tyAtom BoolLit{}       = pure $ StackType mempty [] [TyBuiltin () TyBool]
tyAtom IntLit{}        = pure $ StackType mempty [] [TyBuiltin () TyInt]
tyAtom (AtName _ n)    = tyLookup (void n)
tyAtom (Dip _ as)      = dipify =<< tyAtoms as
tyAtom (AtCons _ tn)   = consLookup (void tn)
tyAtom (If _ as as')   = do
    tys <- tyAtoms as
    tys' <- tyAtoms as'
    (StackType vars ins out) <- mergeStackTypes tys tys'
    pure $ StackType vars (ins ++ [TyBuiltin () TyBool]) out
tyAtom (Case _ ls) = do
    tyLs <- traverse tyLeaf ls
    -- TODO: one-pass fold?
    mergeMany tyLs

assignAtom :: Atom a -> TypeM () (StackType (), Atom (StackType ()))
assignAtom (AtBuiltin _ b) = do { ty <- typeOfBuiltin b ; pure (ty, AtBuiltin ty b) }
assignAtom (BoolLit _ b)   =
    let sTy = StackType mempty [] [TyBuiltin () TyBool]
        in pure (sTy, BoolLit sTy b)
assignAtom (IntLit _ i)    =
    let sTy = StackType mempty [] [TyBuiltin () TyInt]
        in pure (sTy, IntLit sTy i)
assignAtom (AtName _ n) = do
    sTy <- tyLookup (void n)
    pure (sTy, AtName sTy (n $> sTy))
assignAtom (AtCons _ tn) = do
    sTy <- consLookup (void tn)
    pure (sTy, AtCons sTy (tn $> sTy))
assignAtom (Dip _ as)    = do { (as', ty) <- assignAtoms as ; tyDipped <- dipify ty ; pure (tyDipped, Dip tyDipped as') }
assignAtom (If _ as0 as1) = do
    (as0', tys) <- assignAtoms as0
    (as1', tys') <- assignAtoms as1
    -- TODO: I think this "forgets" renames that should be scoped back to atoms?
    (StackType vars ins out) <- mergeStackTypes tys tys'
    let resType = StackType vars (ins ++ [TyBuiltin () TyBool]) out
    pure (resType, If resType as0' as1')
assignAtom (Case _ ls) = do
    lRes <- traverse assignCase ls
    resType <- mergeMany (fst3 <$> lRes)
    let newLeaves = fmap dropFst lRes
    pure (resType, Case resType newLeaves)
    where dropFst (_, y, z) = (y, z)
          fst3 ~(x, _, _) = x

assignAtoms :: [Atom a] -> TypeM () ([Atom (StackType ())], StackType ())
assignAtoms = foldM
    -- TODO: do I really need traverse renameStack r? (it's slower)
    -- should r' use same renames as ty?
    (\seed a -> do { (ty, r) <- assignAtom a ; (ty', r') <- renameStackAndAtom ty r ; (fst seed ++ [r'] ,) <$> catTypes ty' (snd seed) })
    ([], emptyStackType)

tyAtoms :: [Atom a] -> TypeM () (StackType ())
tyAtoms = foldM
    (\seed a -> do { tys' <- renameStack =<< tyAtom a ; catTypes tys' seed })
    emptyStackType

tyInsertLeaf :: Name b -- ^ type being declared
             -> S.Set (Name b) -> (TyName a, [KempeTy b]) -> TypeM () ()
tyInsertLeaf n vars (Name _ (Unique i) _, ins) | S.null vars =
    modifying constructorTypesLens (IM.insert i (voidStackType $ StackType vars ins [TyNamed undefined n]))
                                               | otherwise =
    modifying constructorTypesLens (IM.insert i (voidStackType $ StackType vars ins [app (TyNamed undefined n) (S.toList vars)]))

assignTyLeaf :: Name b
             -> S.Set (Name b)
             -> (TyName a, [KempeTy b])
             -> TypeM () (TyName (StackType ()), [KempeTy ()])
assignTyLeaf n vars (tn@(Name _ (Unique i) _), ins) | S.null vars =
    let ty = voidStackType $ StackType vars ins [TyNamed undefined n] in
    modifying constructorTypesLens (IM.insert i ty) $> (tn $> ty, fmap void ins)
                                               | otherwise =
    let ty = voidStackType $ StackType vars ins [app (TyNamed undefined n) (S.toList vars)] in
    modifying constructorTypesLens (IM.insert i ty) $> (tn $> ty, fmap void ins)

app :: KempeTy a -> [Name a] -> KempeTy a
app = foldl' (\ty n -> TyApp undefined ty (TyNamed undefined n))

assignDecl :: KempeDecl a b -> TypeM () (KempeDecl () (StackType ()))
assignDecl (TyDecl _ tn ns ls) = TyDecl () (void tn) (void <$> ns) <$> traverse (assignTyLeaf tn (S.fromList ns)) ls
assignDecl (FunDecl _ n ins os a) = do
    let sig = voidStackType $ StackType (freeVars (ins ++ os)) ins os
    (as, inferred) <- assignAtoms a
    reconcile <- mergeStackTypes sig inferred -- FIXME: need to verify the merged type is as general as the signature?
    -- assign comes after tyInsert
    pure $ FunDecl reconcile (n $> reconcile) (void <$> ins) (void <$> os) as
assignDecl (ExtFnDecl _ n ins os cn) = do
    let sig = voidStackType $ StackType S.empty ins os
    -- assign always comes after tyInsert
    pure $ ExtFnDecl sig (n $> sig) (void <$> ins) (void <$> os) cn
assignDecl (Export _ abi n) = do
    ty <- tyLookup (void n)
    Export ty abi <$> assignName n

tyHeader :: KempeDecl a b -> TypeM () ()
tyHeader Export{} = pure ()
tyHeader (FunDecl _ (Name _ (Unique i) _) ins out _) = do
    sig <- renameStack $ voidStackType $ StackType (freeVars (ins ++ out)) ins out
    modifying tyEnvLens (IM.insert i sig)
tyHeader (ExtFnDecl _ (Name _ (Unique i) _) ins os _) = do
    unless (null $ freeVars (ins ++ os)) $
        throwError $ TyVarExt ()
    let sig = voidStackType $ StackType S.empty ins os -- no free variables allowed in c functions
    modifying tyEnvLens (IM.insert i sig)
tyHeader TyDecl{} = pure ()

tyInsert :: KempeDecl a b -> TypeM () ()
tyInsert (TyDecl _ tn ns ls) = traverse_ (tyInsertLeaf tn (S.fromList ns)) ls
tyInsert (FunDecl _ _ ins out as) = do
    let sig = voidStackType $ StackType (freeVars (ins ++ out)) ins out
    inferred <- tyAtoms as
    void $ mergeStackTypes sig inferred -- FIXME: need to verify the merged type is as general as the signature?
tyInsert ExtFnDecl{} = pure ()
tyInsert Export{} = pure ()

tyModule :: Module a b -> TypeM () ()
tyModule m = traverse_ tyHeader m *> traverse_ tyInsert m

checkModule :: Module a b -> TypeM () ()
checkModule m = tyModule m <* (unifyM =<< gets constraints)

assignModule :: Module a b -> TypeM () (Module () (StackType ()))
assignModule m = do
    traverse_ tyHeader m
    m' <- traverse assignDecl m
    backNames <- unifyM =<< gets constraints
    pure (fmap (substConstraintsStack backNames) <$> m')

-- Make sure you don't have cycles in the renames map!
replaceUnique :: Unique -> TypeM a Unique
replaceUnique u@(Unique i) = do
    rSt <- gets renames
    case IM.lookup i rSt of
        Nothing -> pure u
        Just j  -> replaceUnique (Unique j)

renameIn :: KempeTy a -> TypeM a (KempeTy a)
renameIn b@TyBuiltin{}    = pure b
renameIn n@TyNamed{}      = pure n
renameIn (TyApp l ty ty') = TyApp l <$> renameIn ty <*> renameIn ty'
renameIn (TyTuple l tys)  = TyTuple l <$> traverse renameIn tys
renameIn (TyVar l (Name t u l')) = do
    u' <- replaceUnique u
    pure $ TyVar l (Name t u' l')

renameStackIn :: StackType a -> TypeM a (StackType a)
renameStackIn (StackType _ is os) = do
    is' <- traverse renameIn is
    os' <- traverse renameIn os
    pure (StackType (freeVars (is' ++ os')) is' os')

-- has to use the max-iest maximum so we can't use withState
withTyState :: (TyState a -> TyState a) -> TypeM a x -> TypeM a x
withTyState modSt act = do
    preSt <- get
    modify modSt
    res <- act
    postMax <- gets maxU
    put preSt
    maxULens .= postMax
    pure res

withName :: Name a -> TypeM a (Name a, TyState a -> TyState a)
withName (Name t (Unique i) l) = do
    m <- gets maxU
    let newUniq = m+1
    maxULens .= newUniq
    pure (Name t (Unique newUniq) l, over renamesLens (IM.insert i (m+1)))

-- freshen the names in a stack so there aren't overlaps in quanitified variables
renameStack :: StackType a -> TypeM a (StackType a)
renameStack (StackType qs ins outs) = do
    newQs <- traverse withName (S.toList qs)
    let localRenames = snd <$> newQs
        newNames = fst <$> newQs
        newBinds = thread localRenames
    withTyState newBinds $
        StackType (S.fromList newNames) <$> traverse renameIn ins <*> traverse renameIn outs

renameStackAndAtom :: StackType () -> Atom (StackType ()) -> TypeM () (StackType (), Atom (StackType ()))
renameStackAndAtom (StackType qs ins outs) a = do
    newQs <- traverse withName (S.toList qs)
    let localRenames = snd <$> newQs
        newNames = fst <$> newQs
        newBinds = thread localRenames
    withTyState newBinds $ do
        sty <- StackType (S.fromList newNames) <$> traverse renameIn ins <*> traverse renameIn outs
        as' <- traverse renameStackIn a
        pure (sty, as')

mergeStackTypes :: StackType () -> StackType () -> TypeM () (StackType ())
mergeStackTypes st0@(StackType _ i0 o0) st1@(StackType _ i1 o1) = do
    let toExpand = max (abs (length i0 - length i1)) (abs (length o0 - length o1))

    -- freshen stack types (free vars) so no clashing/overwriting happens
    (StackType q ins os) <- expandType toExpand =<< renameStack st0
    (StackType q' ins' os') <- expandType toExpand =<< renameStack st1

    when ((length ins /= length ins') || (length os /= length os')) $
        throwError $ MismatchedLengths () st0 st1

    zipWithM_ pushConstraint ins ins'
    zipWithM_ pushConstraint os os'

    pure $ StackType (q <> q') ins os

tyPattern :: Pattern a -> TypeM () (StackType ())
tyPattern PatternWildcard{} = do
    aN <- dummyName "a"
    pure $ StackType (S.singleton aN) [TyVar () aN] []
tyPattern PatternInt{} = pure $ StackType S.empty [TyBuiltin () TyInt] []
tyPattern PatternBool{} = pure $ StackType S.empty [TyBuiltin () TyBool] []
tyPattern (PatternCons _ tn) = flipStackType <$> consLookup (void tn)

assignPattern :: Pattern a -> TypeM () (StackType (), Pattern (StackType ()))
assignPattern (PatternInt _ i) =
    let sTy = StackType S.empty [TyBuiltin () TyInt] []
        in pure (sTy, PatternInt sTy i)
assignPattern (PatternBool _ i) =
    let sTy = StackType S.empty [TyBuiltin () TyBool] []
        in pure (sTy, PatternBool sTy i)
assignPattern (PatternCons _ tn) = do { ty <- flipStackType <$> consLookup (void tn) ; pure (ty, PatternCons ty (tn $> ty)) }
assignPattern PatternWildcard{} = do
    aN <- dummyName "a"
    let resType = StackType (S.singleton aN) [TyVar () aN] []
    pure (resType, PatternWildcard resType)

flipStackType :: StackType () -> StackType ()
flipStackType (StackType vars is os) = StackType vars os is

mergeMany :: NonEmpty (StackType ()) -> TypeM () (StackType ())
mergeMany (t :| ts) = foldM mergeStackTypes t ts

-- assumes they have been renamed...
pushConstraint :: Ord a => KempeTy a -> KempeTy a -> TypeM a ()
pushConstraint ty ty' =
    modifying constraintsLens (S.insert (ty, ty'))

expandType :: Int -> StackType () -> TypeM () (StackType ())
expandType n (StackType q i o) = do
    newVars <- replicateM n (dummyName "a")
    let newTy = TyVar () <$> newVars
    pure $ StackType (q <> S.fromList newVars) (newTy ++ i) (newTy ++ o)

substConstraints :: IM.IntMap (KempeTy a) -> KempeTy a -> KempeTy a
substConstraints _ ty@TyNamed{}                         = ty
substConstraints _ ty@TyBuiltin{}                       = ty
substConstraints tys ty@(TyVar _ (Name _ (Unique k) _)) =
    fromMaybe ty (IM.lookup k tys) -- TODO: should this loop?
substConstraints tys (TyApp l ty ty')                   =
    TyApp l (substConstraints tys ty) (substConstraints tys ty')
substConstraints tys (TyTuple l tys')                   =
    TyTuple l (substConstraints tys <$> tys')

substConstraintsStack :: IM.IntMap (KempeTy a) -> StackType a -> StackType a
substConstraintsStack tys (StackType _ is os) =
    let is' = substConstraints tys <$> is
        os' = substConstraints tys <$> os
        in StackType (freeVars (is' ++ os')) is' os'

-- do renaming before this
-- | Given @x@ and @y@, return the 'StackType' of @x y@
catTypes :: StackType () -- ^ @x@
         -> StackType () -- ^ @y@
         -> TypeM () (StackType ())
catTypes st0@(StackType _ _ osX) (StackType q1 insY osY) = do
    let lY = length insY
        lDiff = lY - length osX

    -- all of the "ins" of y have to come from x, so we expand x as needed
    (StackType q0 insX osX') <- if lDiff > 0
        then expandType lDiff st0
        else pure st0

    -- zip the last (length insY) of osX' with insY
    zipWithM_ pushConstraint (drop (length osX' - lY) osX') insY -- TODO splitAt

    pure $ StackType (q0 <> q1) insX (take (length osX' - lY) osX' ++ osY)
