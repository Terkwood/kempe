{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}

-- | IR loosely based on Appel book.
module Kempe.IR ( size
                , writeModule
                , Stmt (..)
                , Exp (..)
                , RelBinOp (..)
                , IntBinOp (..)
                , runTempM
                , TempM
                ) where

import           Control.DeepSeq            (NFData)
-- strict b/c it's faster according to benchmarks
import           Control.Monad.State.Strict (State, evalState, gets, modify)
import qualified Data.ByteString.Lazy       as BSL
import           Data.Foldable              (fold)
import           Data.Int                   (Int64)
import qualified Data.IntMap                as IM
import           Data.Word                  (Word8)
import           GHC.Generics               (Generic)
import           Kempe.AST
import           Kempe.Name
import           Kempe.Unique
import           Lens.Micro                 (Lens')
import           Lens.Micro.Mtl             (modifying)

type Label = Word

type Temp = Int

data TempSt = TempSt { labels     :: [Label]
                     , tempSupply :: [Temp]
                     , atLabels   :: IM.IntMap Label
                     -- TODO: type sizes in state
                     }

runTempM :: TempM a -> a
runTempM = flip evalState (TempSt [1..] [1..] mempty)

atLabelsLens :: Lens' TempSt (IM.IntMap Label)
atLabelsLens f s = fmap (\x -> s { atLabels = x }) (f (atLabels s))

nextLabels :: TempSt -> TempSt
nextLabels (TempSt ls ts ats) = TempSt (tail ls) ts ats

nextTemps :: TempSt -> TempSt
nextTemps (TempSt ls ts ats) = TempSt ls (tail ts) ats

type TempM = State TempSt

getTemp :: TempM Temp
getTemp = gets (head . tempSupply) <* modify nextTemps

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

-- TODO figure out dip
-- | Type parameter @a@ so we can annotate with 'Int's later.
data Stmt a = Push { stmtCost :: a, stmtTy :: KempeTy (), stmtExp :: Exp a }
            | Pop { stmtCost :: a, stmtTy :: KempeTy (), stmtTemp :: Temp }
            | Labeled { stmtCost :: a, stmtLabel :: Label }
            -- -- | Seq Stmt Stmt
            | Jump { stmtCost :: a, stmtJmp :: Label }
            -- conditional jump for ifs
            | CJump { stmtCost :: a, stmtSwitch :: Exp a, stmtJmp0 :: Label, stmtJmp1 :: Label }
            | MJump { stmtCost :: a, stmtM :: Exp a, stmtLabel :: Label }
            | CCall { stmtCost :: a, stmtExtTy :: MonoStackType, stmtCCall :: BSL.ByteString } -- TODO: ShortByteString?
            | KCall { stmtCost :: a, stmtCall :: Label } -- KCall is a jump to a Kempe procedure (and jump back, later)
            -- enough...)
            | MovTemp { stmtCost :: a, stmtTemp :: Temp, stmtExp :: Exp a }
            | MovMem { stmtCost :: a, stmtExp0 :: Exp a, stmtExp1 :: Exp a } -- store e2 at address given by e1
            | Eff { stmtCost :: a, stmtExp :: Exp a } -- evaluate an expression for its effects
            deriving (Generic, NFData)

data Exp a = ConstInt { expCost :: a, expI :: Int64 }
           | ConstantPtr { expCost :: a, expP :: Int64 }
           | ConstBool { expCost :: a, expB :: Word8 }
           | Named { expCost :: a, expLabel :: Label }
           | Reg { expCost :: a, regSize :: Int, expReg :: Temp } -- TODO: size?
           | Mem { expCost :: a, expAddr :: Exp a } -- fetch from address
           | Do { expCost :: a, expStmt :: Stmt a, expSeq :: Exp a }
           | ExprIntBinOp { expCost :: a, expBinOp :: IntBinOp, exp0 :: Exp a, exp1 :: Exp a }
           | ExprIntRel { expCost :: a, expRelOp :: RelBinOp, exp0 :: Exp a, exp1 :: Exp a }
           | StackPointer { expCost :: a }
           deriving (Generic, NFData)

data RelBinOp = IntEqIR
              | IntNeqIR
              | IntLtIR
              | IntGtIR
              deriving (Generic, NFData)

data IntBinOp = IntPlusIR
              | IntTimesIR
              | IntDivIR
              | IntMinusIR
              | IntModIR -- rem?
              | IntXorIR
              | IntShiftRIR
              | IntShiftLIR
              deriving (Generic, NFData)

writeModule :: Module () MonoStackType -> TempM [Stmt ()]
writeModule = foldMapA writeDecl

writeDecl :: KempeDecl () MonoStackType -> TempM [Stmt ()]
writeDecl (FunDecl _ (Name _ u _) _ _ as) = do
    bl <- broadcastName u
    (Labeled () bl:) <$> writeAtoms as
writeDecl (ExtFnDecl ty (Name _ u _) _ _ cName) = do
    bl <- broadcastName u
    pure [Labeled () bl, CCall () ty cName]

writeAtoms :: [Atom MonoStackType] -> TempM [Stmt ()]
writeAtoms = foldMapA writeAtom

foldMapA :: (Applicative f, Traversable t, Monoid m) => (a -> f m) -> t a -> f m
foldMapA = (fmap fold .) . traverse

tyInt :: KempeTy ()
tyInt = TyBuiltin () TyInt

tyBool :: KempeTy ()
tyBool = TyBuiltin () TyBool

intOp :: IntBinOp -> TempM [Stmt ()]
intOp cons = do
    t0 <- getTemp
    t1 <- getTemp
    pure
        [ Pop () tyInt t0
        , Pop () tyInt t1
        , Push () tyInt $ ExprIntBinOp () cons (Reg () 4 t0) (Reg () 4 t1) -- registers are 4 bytes for integers
        ]

intRel :: RelBinOp -> TempM [Stmt ()]
intRel cons = do
    t0 <- getTemp
    t1 <- getTemp
    pure
        [ Pop () tyInt t0 -- TODO: maybe plain mov is better/nicer than pop
        , Pop () tyInt t1
        , Push () tyBool $ ExprIntRel () cons (Reg () 4 t0) (Reg () 4 t1)
        ]

-- | This throws exceptions on nonsensical input.
writeAtom :: Atom MonoStackType -> TempM [Stmt ()]
writeAtom (IntLit _ i)              = pure [Push () tyInt (ConstInt () $ fromInteger i)]
writeAtom (BoolLit _ b)             = pure [Push () tyBool (ConstBool () $ toByte b)]
writeAtom (AtName _ n)              = pure . KCall () <$> lookupName n -- TODO: when to do tco?
writeAtom (AtBuiltin ([], _) Drop)  = error "Internal error: Ill-typed drop!"
writeAtom (AtBuiltin ([], _) Swap)  = error "Internal error: Ill-typed swap!"
writeAtom (AtBuiltin ([_], _) Swap) = error "Internal error: Ill-typed swap!"
writeAtom (AtBuiltin ([], _) Dup)   = error "Internal error: Ill-typed dup!"
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
        pure [Eff () (ExprIntBinOp () IntPlusIR (StackPointer ()) (ExprIntBinOp () IntPlusIR (StackPointer ()) (ConstInt () sz)))]
writeAtom (AtBuiltin (is, _) Dup)   =
    let sz = size (last is) in
        pure ( Eff () (ExprIntBinOp () IntPlusIR (StackPointer ()) (ExprIntBinOp () IntMinusIR (StackPointer ()) (ConstInt () sz))) -- allocate sz bytes on the stack
             : [ MovMem () (stackPointerOffset (i - sz)) (Mem () $ stackPointerOffset i) | i <- [1..sz] ]
             )
writeAtom (If _ as as') = do
    l0 <- newLabel
    l1 <- newLabel
    let reg = stackPointerOffset (-1) -- one byte for bool
        ifIR = CJump () reg l0 l1
    asIR <- writeAtoms as
    asIR' <- writeAtoms as'
    pure $ ifIR : (Labeled () l0 : asIR) ++ (Labeled () l1 : asIR')

stackPointerOffset :: Int64 -> Exp ()
stackPointerOffset off = ExprIntBinOp () IntPlusIR (StackPointer ()) (ConstInt () off)

toByte :: Bool -> Word8
toByte True  = 1
toByte False = 0

-- need env with size for constructors
size :: KempeTy a -> Int64
size (TyBuiltin _ TyInt)  = 8 -- since we're only targeting x86_64 and aarch64 we have 64-bit 'Int's
size (TyBuiltin _ TyPtr)  = 8
size (TyBuiltin _ TyBool) = 1
size TyVar{}              = error "Internal error: type variables should not be present at this stage."
size (TyTuple _ tys)      = sum (fmap size tys)
