{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

-- | IR loosely based on Appel book.
module Kempe.IR ( writeModule
                , Stmt (..)
                , Exp (..)
                , RelBinOp (..)
                , IntBinOp (..)
                , Label
                , Temp (..)
                , runTempM
                , TempM
                , prettyIR
                -- , foldStmt
                , WriteSt (..)
                , size
                ) where

import           Control.DeepSeq            (NFData)
-- strict b/c it's faster according to benchmarks
import           Control.Monad.State.Strict (State, gets, modify, runState)
import           Data.Bifunctor             (second)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Lazy       as BSL
import           Data.Foldable.Ext
import           Data.Int                   (Int64)
import qualified Data.IntMap                as IM
import           Data.Text.Encoding         (decodeUtf8, encodeUtf8)
import           GHC.Generics               (Generic)
import           Kempe.AST
import           Kempe.Name
import           Kempe.Unique
import           Lens.Micro                 (Lens')
import           Lens.Micro.Mtl             (modifying)
import           Prettyprinter              (Doc, Pretty (pretty), braces, colon, concatWith, hardline, parens, (<+>))

type Label = Word

data Temp = Temp64 !Int
          | Temp8 !Int
          | DataPointer -- RBP on x86 and x19 on aarch64?
          deriving (Eq, Generic, NFData)

instance Pretty Temp where
    pretty (Temp64 i)  = "t_" <> pretty i
    pretty (Temp8 i)   = "t8_" <> pretty i
    pretty DataPointer = "datapointer"

data WriteSt = WriteSt { wlabels :: [Label]
                       , temps   :: [Int]
                       }

data TempSt = TempSt { labels     :: [Label]
                     , tempSupply :: [Int]
                     , atLabels   :: IM.IntMap Label
                     -- TODO: type sizes in state
                     }

asWriteSt :: TempSt -> WriteSt
asWriteSt (TempSt ls ts _) = WriteSt ls ts

-- TODO: return temp supply?
-- also label supply ig
runTempM :: TempM a -> (a, WriteSt)
runTempM = second asWriteSt . flip runState (TempSt [1..] [1..] mempty)

atLabelsLens :: Lens' TempSt (IM.IntMap Label)
atLabelsLens f s = fmap (\x -> s { atLabels = x }) (f (atLabels s))

nextLabels :: TempSt -> TempSt
nextLabels (TempSt ls ts ats) = TempSt (tail ls) ts ats

nextTemps :: TempSt -> TempSt
nextTemps (TempSt ls ts ats) = TempSt ls (tail ts) ats

type TempM = State TempSt

getTemp :: TempM Int
getTemp = gets (head . tempSupply) <* modify nextTemps

getTemp64 :: TempM Temp
getTemp64 = Temp64 <$> getTemp

getTemp8 :: TempM Temp
getTemp8 = Temp8 <$> getTemp

newLabel :: TempM Label
newLabel = gets (head . labels) <* modify nextLabels

broadcastName :: Unique -> TempM Label
broadcastName (Unique i) = do
    l <- newLabel
    modifying atLabelsLens (IM.insert i l)
    pure l

lookupName :: Name a -> TempM Label
lookupName (Name _ (Unique i) _) =
    gets
        (IM.findWithDefault (error "Internal error in IR phase: could not look find label for name") i . atLabels)

-- foldStmt :: NonEmpty (Stmt ()) -> Stmt ()
-- foldStmt (s :| ss) = foldr (Seq ()) s ss

-- TODO: pretty-printer?

prettyIR :: [Stmt a] -> Doc ann
prettyIR = concatWith (\x y -> x <> hardline <> y) . fmap pretty

prettyLabel :: Label -> Doc ann
prettyLabel l = "kmp" <> pretty l

instance Pretty (Stmt a) where
    pretty (Labeled _ l)           = hardline <> prettyLabel l <> colon
    pretty (Jump _ l)              = parens ("j" <+> prettyLabel l)
    pretty (CCall _ ty bs)         = parens ("C" <+> pretty (decodeUtf8 (BSL.toStrict bs)) <+> braces (prettyMonoStackType  ty))
    pretty (KCall _ l)             = parens ("call" <+> prettyLabel l)
    pretty Ret{}                   = parens "ret"
    pretty (MovTemp _ t e)         = parens ("movtemp" <+> pretty t <+> pretty e)
    pretty (MovMem _ e e')         = parens ("movmem" <+> pretty e <+> pretty e')
    pretty (CJump _ e l l')        = parens ("cjump" <+> pretty e <+> prettyLabel l <+> prettyLabel l')
    pretty (WrapKCall _ _ ty fn l) = hardline <> "export" <+> pretty (decodeUtf8 fn) <+> braces (prettyMonoStackType ty) <+> prettyLabel l

instance Pretty Exp where
    pretty (ConstInt i)           = parens ("int" <+> pretty i)
    pretty (ConstBool False)      = parens "bool false"
    pretty (ConstBool True)       = parens "bool true"
    pretty (Named l)              = parens (prettyLabel l)
    pretty (Reg t)                = parens ("reg" <+> pretty t)
    pretty (Mem _ e)              = parens ("mem" <+> pretty e)
    pretty (ExprIntBinOp op e e') = parens (pretty op <+> pretty e <+> pretty e')
    pretty (ExprIntRel op e e')   = parens (pretty op <+> pretty e <+> pretty e')

-- | Type parameter @a@ so we can annotate with 'Int's later.
data Stmt a = Labeled { stmtCost :: a, stmtLabel :: Label }
            -- -- | BsLabel { stmtCost :: a, stmtLabelBS :: BS.ByteString }
            | Jump { stmtCost :: a, stmtJmp :: Label }
            -- conditional jump for ifs
            | CJump { stmtCost :: a, stmtSwitch :: Exp, stmtJmp0 :: Label, stmtJmp1 :: Label }
            | CCall { stmtCost :: a, stmtExtTy :: MonoStackType, stmtCCall :: BSL.ByteString } -- TODO: ShortByteString?
            | KCall { stmtCost :: a, stmtCall :: Label } -- KCall is a jump to a Kempe procedure (and jump back, later)
            | WrapKCall { stmtCost :: a, wrapAbi :: ABI, stmtiFnTy :: MonoStackType, stmtABI :: BS.ByteString, stmtCall :: Label }
            -- enough...)
            | MovTemp { stmtCost :: a, stmtTemp :: Temp, stmtExp :: Exp } -- put e in temp?
            | MovMem { stmtCost :: a, stmtExp0 :: Exp, stmtExp1 :: Exp } -- store e2 at address given by e1
            -- -- | Seq { stmtCost :: a, stmt0 :: Stmt a, stmt1 :: Stmt a }
            | Ret { stmtCost :: a }
           deriving (Generic, NFData, Functor)
            -- -- | MJump { stmtCost :: a, stmtM :: Exp a, stmtLabel :: Label } -- for optimizations/fallthrough?

data Exp = ConstInt Int64
         | ConstPtr Int64
         | ConstBool Bool
         | Named Label
         | Reg Temp  -- TODO: size?
         | Mem Int64 Exp -- fetch from address FIXME: how many bytes?
         | ExprIntBinOp IntBinOp Exp Exp -- SEMANTICS: this is not side-effecting
         | ExprIntRel RelBinOp Exp Exp
         deriving (Generic, NFData)
           -- TODO: one for data, one for C ABI
           -- -- ret?

data RelBinOp = IntEqIR
              | IntNeqIR
              | IntLtIR
              | IntGtIR
              deriving (Generic, NFData)

instance Pretty RelBinOp where
    pretty IntEqIR  = "="
    pretty IntNeqIR = "!="
    pretty IntLtIR  = "<"
    pretty IntGtIR  = ">"

data IntBinOp = IntPlusIR
              | IntTimesIR
              | IntDivIR
              | IntMinusIR
              | IntModIR -- rem?
              | IntXorIR
              | IntShiftRIR
              | IntShiftLIR
              deriving (Generic, NFData)

instance Pretty IntBinOp where
    pretty IntPlusIR   = "+"
    pretty IntTimesIR  = "*"
    pretty IntDivIR    = "/"
    pretty IntMinusIR  = "-"
    pretty IntModIR    = "%"
    pretty IntXorIR    = "xor"
    pretty IntShiftRIR = ">>"
    pretty IntShiftLIR = "<<"

writeModule :: Module () MonoStackType -> TempM [Stmt ()]
writeModule = foldMapA writeDecl

writeDecl :: KempeDecl () MonoStackType -> TempM [Stmt ()]
writeDecl (FunDecl _ (Name _ u _) _ _ as) = do
    bl <- broadcastName u
    (++ [Ret ()]) . (Labeled () bl:) <$> writeAtoms as
writeDecl (ExtFnDecl ty (Name _ u _) _ _ cName) = do
    bl <- broadcastName u
    pure [Labeled () bl, CCall () ty cName, Ret ()]
writeDecl (Export sTy abi n) = pure . WrapKCall () abi sTy (encodeUtf8 $ name n) <$> lookupName n

writeAtoms :: [Atom MonoStackType] -> TempM [Stmt ()]
writeAtoms = foldMapA writeAtom

intOp :: IntBinOp -> TempM [Stmt ()]
intOp cons = do
    t0 <- getTemp64 -- registers are 64 bits for integers
    t1 <- getTemp64
    pure $
        pop 8 t0 ++ pop 8 t1 ++ push 8 (ExprIntBinOp cons (Reg t0) (Reg t1))

-- | Push bytes onto the Kempe data pointer
push :: Int64 -> Exp -> [Stmt ()]
push off e =
    [ MovTemp () DataPointer (ExprIntBinOp IntPlusIR (Reg DataPointer) (ConstInt off)) -- increment instead of decrement b/c this is the Kempe ABI
    , MovMem () (Reg DataPointer) e
    ]

pop :: Int64 -> Temp -> [Stmt ()]
pop sz t =
    [ MovTemp () t (Mem sz (Reg DataPointer))
    , MovTemp () DataPointer (ExprIntBinOp IntMinusIR (Reg DataPointer) (ConstInt sz))
    ]

-- FIXME: just use expressions from memory accesses
intRel :: RelBinOp -> TempM [Stmt ()]
intRel cons = do
    t0 <- getTemp64
    t1 <- getTemp64
    pure $
        pop 8 t0 ++ pop 8 t1 ++ push 1 (ExprIntRel cons (Reg t0) (Reg t1))

-- | This throws exceptions on nonsensical input.
writeAtom :: Atom MonoStackType -> TempM [Stmt ()]
writeAtom (IntLit _ i)              = pure $ push 8 (ConstInt $ fromInteger i)
writeAtom (BoolLit _ b)             = pure $ push 1 (ConstBool b)
writeAtom (AtName _ n)              = pure . KCall () <$> lookupName n -- TODO: when to do tco?
writeAtom (AtBuiltin ([], _) Drop)  = error "Internal error: Ill-typed drop!"
writeAtom (AtBuiltin ([], _) Swap)  = error "Internal error: Ill-typed swap!"
writeAtom (AtBuiltin ([_], _) Swap) = error "Internal error: Ill-typed swap!"
writeAtom (AtBuiltin ([], _) Dup)   = error "Internal error: Ill-typed dup!"
writeAtom (Dip ([], _) _)           = error "Internal error: Ill-typed dip()!"
writeAtom (AtBuiltin _ IntPlus)     = intOp IntPlusIR
writeAtom (AtBuiltin _ IntMinus)    = intOp IntMinusIR
writeAtom (AtBuiltin _ IntTimes)    = intOp IntTimesIR
writeAtom (AtBuiltin _ IntDiv)      = intOp IntDivIR -- what to do on failure?
writeAtom (AtBuiltin _ IntMod)      = intOp IntModIR
writeAtom (AtBuiltin _ IntXor)      = intOp IntXorIR
writeAtom (AtBuiltin _ IntShiftR)   = intOp IntShiftRIR
writeAtom (AtBuiltin _ IntShiftL)   = intOp IntShiftLIR
writeAtom (AtBuiltin _ IntEq)       = intRel IntEqIR
writeAtom (AtBuiltin (is, _) Drop)  =
    let sz = size (last is) in
        pure [ MovTemp () DataPointer (ExprIntBinOp IntMinusIR (Reg DataPointer) (ConstInt sz)) ] -- subtract sz from data pointer (Kempe data pointer grows up)
writeAtom (AtBuiltin (is, _) Dup)   =
    let sz = size (last is) in
        pure $
             [ MovMem () (dataPointerOffset (i + sz)) (Mem 1 $ dataPointerOffset i) | i <- [1..sz] ] -- FIXME: this should be a one-byte fetch each time
                ++ [ MovTemp () DataPointer (ExprIntBinOp IntPlusIR (Reg DataPointer) (ConstInt sz)) ] -- move data pointer over sz bytes
writeAtom (If _ as as') = do
    l0 <- newLabel
    l1 <- newLabel
    let ifIR = CJump () (Mem 1 $ dataPointerOffset 1) l0 l1
    asIR <- writeAtoms as
    asIR' <- writeAtoms as'
    l2 <- newLabel
    pure $ ifIR : (Labeled () l0 : asIR ++ [Jump () l2]) ++ (Labeled () l1 : asIR' ++ [Jump () l2]) ++ [Labeled () l2]
writeAtom (Dip (is, _) as) =
    let sz = size (last is)
        shiftNext = MovTemp () DataPointer (ExprIntBinOp IntMinusIR (Reg DataPointer) (ConstInt sz))
        shiftBack = MovTemp () DataPointer (ExprIntBinOp IntPlusIR (Reg DataPointer) (ConstInt sz))
    in
        do
            aStmt <- writeAtoms as
            pure ((shiftNext : aStmt) ++ [shiftBack])
            -- TODO: possible optimization: don't shift stack pointer but rather
            -- grab Stmts and shift them over to use sz bytes over or whatever?

dataPointerOffset :: Int64 -> Exp
dataPointerOffset off = ExprIntBinOp IntPlusIR (Reg DataPointer) (ConstInt off)

-- need env with size for constructors
size :: KempeTy a -> Int64
size (TyBuiltin _ TyInt)  = 8 -- since we're only targeting x86_64 and aarch64 we have 64-bit 'Int's
size (TyBuiltin _ TyPtr)  = 8
size (TyBuiltin _ TyBool) = 1
size TyVar{}              = error "Internal error: type variables should not be present at this stage."
size (TyTuple _ tys)      = sum (fmap size tys)
