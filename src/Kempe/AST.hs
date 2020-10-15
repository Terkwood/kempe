{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Frontend AST
module Kempe.AST ( BuiltinTy (..)
                 , KempeTy (..)
                 , StackType (..)
                 , Atom (..)
                 , BuiltinFn (..)
                 , KempeDecl (..)
                 , Pattern (..)
                 , Module
                 -- * I resent this...
                 , voidStackType
                 ) where

import           Control.DeepSeq      (NFData)
import qualified Data.ByteString.Lazy as BSL
import           Data.Functor         (void)
import           Data.List.NonEmpty   (NonEmpty)
import qualified Data.Set             as S
import           GHC.Generics         (Generic)
import           Kempe.Name
import           Prettyprinter        (Pretty (pretty), parens, sep, tupled, (<+>))

data BuiltinTy = TyPtr
               | TyInt
               | TyBool
               -- -- | TyFloat
               -- -- | TyArr Word
               deriving (Generic, NFData, Eq, Ord)
               -- tupling builtin for sake of case-matching on two+ things at
               -- once
               --
               -- #1 vs ->1 (lol)

instance Pretty BuiltinTy where
    pretty TyPtr  = "Ptr"
    pretty TyInt  = "Int"
    pretty TyBool = "Bool"

-- what to do about if, dip
--
-- special cases w.r.t. codegen
-- dk what tensor types are (or morphisms) but they look cool?
--
-- recursion > while loop (polymorphic recursion though :o )
--
-- equality for sum types &c.
--
-- what about pattern matches that bind variables??

data KempeTy a = TyBuiltin a BuiltinTy
               | TyNamed a (TyName a)
               | TyVar a (Name a)
               | TyApp a (KempeTy a) (KempeTy a) -- type applied to another, e.g. Just Int
               | TyTuple a [KempeTy a]
               deriving (Generic, NFData, Functor, Eq, Ord) -- questionable eq instance but eh

data StackType b = StackType { quantify :: S.Set (Name b)
                             , inTypes  :: [KempeTy b]
                             , outTypes :: [KempeTy b]
                             } deriving (Generic, NFData, Eq, Ord)

instance Pretty (StackType a) where
    pretty (StackType _ ins outs) = sep (fmap pretty ins) <+> "--" <+> sep (fmap pretty outs)

voidStackType :: StackType a -> StackType ()
voidStackType (StackType vars ins outs) = StackType (S.map void vars) (void <$> ins) (void <$> outs)

instance Pretty (KempeTy a) where
    pretty (TyBuiltin _ b)  = pretty b
    pretty (TyNamed _ tn)   = pretty tn
    pretty (TyVar _ n)      = pretty n
    pretty (TyApp _ ty ty') = parens (pretty ty <+> pretty ty')
    pretty (TyTuple _ tys)  = tupled (pretty <$> tys)

data Pattern b = PatternInt b Integer
               | PatternCons b (TyName b) [Pattern b] -- a constructed pattern
               | PatternVar b (Name b)
               | PatternWildcard b
               | PatternBool b Bool
               -- -- | PatternTuple
               deriving (Generic, NFData, Functor)

data Atom b = AtName b (Name b)
            | Case b (NonEmpty (Pattern b, [Atom b]))
            | If b [Atom b] [Atom b]
            | Dip b [Atom b]
            | IntLit b Integer
            | BoolLit b Bool
            | AtBuiltin b BuiltinFn
            | AtCons b (TyName b)
            deriving (Generic, NFData, Functor)

data BuiltinFn = Drop
               | Swap
               | Dup
               -- -- | Plus
               -- -- | Time
               -- -- | IntEq
               deriving (Generic, NFData)

data KempeDecl a b = TyDecl a (TyName a) [Name a] [(TyName b, [KempeTy a])]
                   | FunDecl b (Name b) [KempeTy a] [KempeTy a] [Atom b]
                   | ExtFnDecl b (Name b) [KempeTy a] [KempeTy a] BSL.ByteString
                   deriving (Generic, NFData, Functor)
                   -- bifunctor

type Module a b = [KempeDecl a b]
