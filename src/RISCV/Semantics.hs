{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeApplications           #-}

{-|
Module      : RISCV.Semantics
Copyright   : (c) Benjamin Selfridge, 2018
                  Galois Inc.
License     : None (yet)
Maintainer  : benselfridge@galois.com
Stability   : experimental
Portability : portable

Several types and functions enabling specification of semantics for RISC-V
instructions.
-}

module RISCV.Semantics
  ( -- * Types for semantic formulas
    LocExpr(..)
  , Expr(..)
  , Stmt(..)
  , Formula, fComments, fDefs
    -- * FormulaBuilder monad
  , FormulaBuilder
  , getFormula
    -- * FormulaBuilder operations
    -- ** Auxiliary
  , comment
  , operandEs
  , instBytes
  , litBV
    -- ** Access to state
  , readPC
  , readReg
  , readMem
  , readCSR
  , readPriv
  , checkReserved
    -- ** State actions
  , assignPC
  , assignReg
  , assignMem
  , assignCSR
  , assignPriv
  , reserve
  , branch
  , ($>)
  ) where

import Control.Lens ( (%=), (^.), Simple, Lens, lens )
import Control.Monad.State
import Data.Foldable (toList)
import Data.Parameterized
import Data.Parameterized.List
import Data.Parameterized.TH.GADT
import qualified Data.Sequence as Seq
import           Data.Sequence (Seq)
import GHC.TypeLits
import Text.PrettyPrint.HughesPJClass

import Data.BitVector.Sized.App
import RISCV.Types

----------------------------------------
-- Expressions, statements, and formulas

-- | This type represents an abstract component of the global state, and should be
-- used both for building expressions in our expression language and for interpreting
-- those expressions.
data LocExpr expr arch fmt w where
  PCExpr   ::                                   LocExpr expr arch fmt (ArchWidth arch)
  RegExpr  :: expr 5                         -> LocExpr expr arch fmt (ArchWidth arch)
  MemExpr  :: NatRepr bytes -> Expr arch fmt (ArchWidth arch) -> LocExpr expr arch fmt (8*bytes)
  ResExpr  :: expr (ArchWidth arch)          -> LocExpr expr arch fmt 1
  CSRExpr  :: expr 12                        -> LocExpr expr arch fmt (ArchWidth arch)
  PrivExpr ::                                   LocExpr expr arch fmt 2

instance Pretty (LocExpr (Expr arch fmt) arch fmt w) where
  pPrint PCExpr      = text "pc"
  pPrint (RegExpr e) = text "x[" <> pPrint e <> text "]"
  pPrint (MemExpr bytes e) = text "M[" <> pPrint e <> text "]_" <> pPrint (natValue bytes)
  pPrint (ResExpr e) = text "MReserved[" <> pPrint e <> text "]"
  pPrint (CSRExpr e) = text "CSR[" <> pPrint e <> text "]"
  pPrint PrivExpr    = text "current_priv"

-- | Expressions for computations over the RISC-V machine state, in the context of
-- executing an instruction.
data Expr (arch :: BaseArch) (fmt :: Format) (w :: Nat) where
  -- Accessing the instruction
  OperandExpr :: !(OperandID fmt w) -> Expr arch fmt w
  InstBytes :: Expr arch fmt (ArchWidth arch)

  -- Accessing state
  LocExpr :: LocExpr (Expr arch fmt) arch fmt w -> Expr arch fmt w

  -- BVApp with Expr subexpressions
  AppExpr :: !(BVApp (Expr arch fmt) w) -> Expr arch fmt w

$(return [])
instance TestEquality (LocExpr (Expr arch fmt) arch fmt) where
  testEquality = $(structuralTypeEquality [t|LocExpr|]
                   [(ConType [t|NatRepr|] `TypeApp` AnyType, [|testEquality|])])
instance TestEquality (Expr arch fmt) where
  testEquality = $(structuralTypeEquality [t|Expr|]
                    [ (AnyType `TypeApp` AnyType `TypeApp` AnyType, [|testEquality|])
                    , (ConType [t|NatRepr|] `TypeApp` AnyType, [|testEquality|])
                    ])
instance Eq (Expr arch fmt w) where
  x == y = isJust (testEquality x y)

instance Pretty (Expr arch fmt w) where
  pPrint = pPrintExpr' True

pPrintExpr' :: Bool -> Expr arch fmt w -> Doc
pPrintExpr' _ (OperandExpr (OperandID oid)) = text "arg" <> pPrint (indexValue oid)
pPrintExpr' _ InstBytes = text "step"
pPrintExpr' _ (LocExpr loc) = pPrint loc
pPrintExpr' top (AppExpr app) = pPrintApp' top app

pPrintApp' :: Bool -> BVApp (Expr arch fmt) w -> Doc
pPrintApp' _ (NotApp e) = text "!" <> pPrintExpr' False e
pPrintApp' _ (LitBVApp bv) = text $ show bv
pPrintApp' _ (ZExtApp _ e) = text "zext(" <> pPrintExpr' True e <> text ")"
pPrintApp' _ (SExtApp _ e) = text "sext(" <> pPrintExpr' True e <> text ")"
pPrintApp' top (ExtractApp w ix e) =
  pPrintExpr' top e <> text "[" <> pPrint ix <> text ":" <>
  pPrint (ix + fromIntegral (natValue w) - 1) <> text "]"
pPrintApp' False e = parens (pPrintApp' True e)
pPrintApp' _ (AndApp e1 e2) = pPrintExpr' False e1 <+> text "&" <+> pPrintExpr' False e2
pPrintApp' _ (OrApp  e1 e2) = pPrintExpr' False e1 <+> text "|" <+> pPrintExpr' False e2
pPrintApp' _ (XorApp e1 e2) = pPrintExpr' False e1 <+> text "^" <+> pPrintExpr' False e2
pPrintApp' _ (SllApp e1 e2) = pPrintExpr' False e1 <+> text "<<" <+> pPrintExpr' False e2
pPrintApp' _ (SrlApp e1 e2) = pPrintExpr' False e1 <+> text ">l>" <+> pPrintExpr' False e2
pPrintApp' _ (SraApp e1 e2) = pPrintExpr' False e1 <+> text ">a>" <+> pPrintExpr' False e2
pPrintApp' _ (AddApp e1 e2) = pPrintExpr' False e1 <+> text "+" <+> pPrintExpr' False e2
pPrintApp' _ (SubApp e1 e2) = pPrintExpr' False e1 <+> text "-" <+> pPrintExpr' False e2
pPrintApp' _ (MulApp e1 e2) = pPrintExpr' False e1 <+> text "*" <+> pPrintExpr' False e2
pPrintApp' _ (QuotUApp e1 e2) = pPrintExpr' False e1 <+> text "/u" <+> pPrintExpr' False e2
pPrintApp' _ (QuotSApp e1 e2) = pPrintExpr' False e1 <+> text "/s" <+> pPrintExpr' False e2
pPrintApp' _ (RemUApp e1 e2) = pPrintExpr' False e1 <+> text "%u" <+> pPrintExpr' False e2
pPrintApp' _ (RemSApp e1 e2) = pPrintExpr' False e1 <+> text "%s" <+> pPrintExpr' False e2
pPrintApp' _ (EqApp  e1 e2) = pPrintExpr' False e1 <+> text "==" <+> pPrintExpr' False e2
pPrintApp' _ (LtuApp e1 e2) = pPrintExpr' False e1 <+> text "<u" <+> pPrintExpr' False e2
pPrintApp' _ (LtsApp e1 e2) = pPrintExpr' False e1 <+> text "<s" <+> pPrintExpr' False e2
pPrintApp' _ (ConcatApp e1 e2) =
  text "{" <> pPrintExpr' True e1 <> text ", " <> pPrintExpr' True e2 <> text "}"
pPrintApp' _ (IteApp e1 e2 e3) =
  text "if" <+> pPrintExpr' True e1 <+>
  text "then" <+> pPrintExpr' True e2 <+>
  text "else" <+> pPrintExpr' True e3

-- | A 'Stmt' represents an atomic state transformation -- typically, an assignment
-- of a state component (register, memory location, etc.) to a 'Expr' of the
-- appropriate width.
data Stmt (arch :: BaseArch) (fmt :: Format) where
  -- | Assign a piece of state to a value.
  AssignStmt :: !(LocExpr (Expr arch fmt) arch fmt w) -> !(Expr arch fmt w) -> Stmt arch fmt
  -- | If-then-else branch statement.
  BranchStmt :: !(Expr arch fmt 1)
             -> !(Seq (Stmt arch fmt))
             -> !(Seq (Stmt arch fmt))
             -> Stmt arch fmt

instance Pretty (Stmt arch fmt) where
  pPrint (AssignStmt le e) = pPrint le <+> text ":=" <+> pPrint e
  pPrint (BranchStmt test s1s s2s) =
    text "IF" <+> pPrint test
    $$ nest 2 (text "THEN")
    $$ nest 4 (vcat (pPrint <$> toList s1s))
    $$ nest 2 (text "ELSE")
    $$ nest 4 (vcat (pPrint <$> toList s2s))

-- | Formula representing the semantics of an instruction. A formula has a number of
-- operands (potentially zero), which represent the input to the formula. These are
-- going to the be the operands of the instruction -- register ids, immediate values,
-- and so forth.
--
-- Each definition here should be thought of as executing concurrently rather than
-- sequentially. Each assignment statement in the formula has a left-hand side and a
-- right-hand side. Everything occurring on the right-hand side should be interpreted
-- as the "pre-state" values -- so, for instance, if one statement assigns the pc, and
-- another statement reads the pc, then the latter should use the *original* value of
-- the PC rather than the new one, regardless of the orders of the statements.
data Formula arch (fmt :: Format)
  = Formula { _fComments :: !(Seq String)
              -- ^ multiline comment
            , _fDefs    :: !(Seq (Stmt arch fmt))
              -- ^ sequence of statements defining the formula
            }

instance Pretty (Formula arch fmt) where
  pPrint formula = vcat (pPrint <$> toList (formula ^. fDefs))

-- | Lens for 'Formula' comments.
fComments :: Simple Lens (Formula arch fmt) (Seq String)
fComments = lens _fComments (\(Formula _ d) c -> Formula c d)

-- | Lens for 'Formula' statements.
fDefs :: Simple Lens (Formula arch fmt) (Seq (Stmt arch fmt))
fDefs = lens _fDefs (\(Formula c _) d -> Formula c d)

-- | Every definition begins with the empty formula.
emptyFormula :: Formula arch fmt
emptyFormula = Formula Seq.empty Seq.empty

-- | State monad for defining instruction semantics. When defining an instruction,
-- you shouldn't need to ever read the state directly, so we only export the type.
newtype FormulaBuilder arch (fmt :: Format) a =
  FormulaBuilder { unFormulaBuilder :: State (Formula arch fmt) a }
  deriving (Functor,
            Applicative,
            Monad,
            MonadState (Formula arch fmt))

----------------------------------------
-- FormulaBuilder functions for constructing expressions and statements. Some of
-- these are pure for the moment, but eventually we will want to have a more granular
-- representation of every single operation, so we keep them in a monadic style in
-- order to enable us to add some side effects later if we want to.

----------------------------------------
-- Smart constructors for BVApp functions

instance BVExpr (Expr arch fmt) where
  appExpr = AppExpr

-- | Get the operands for a particular known format
operandEs :: forall arch fmt . (KnownRepr FormatRepr fmt)
          => FormulaBuilder arch fmt (List (Expr arch fmt) (OperandTypes fmt))
operandEs = case knownRepr :: FormatRepr fmt of
  RRepr -> return (OperandExpr (OperandID index0) :<
                   OperandExpr (OperandID index1) :<
                   OperandExpr (OperandID index2) :< Nil)
  IRepr -> return (OperandExpr (OperandID index0) :<
                   OperandExpr (OperandID index1) :<
                   OperandExpr (OperandID index2) :< Nil)
  SRepr -> return (OperandExpr (OperandID index0) :<
                   OperandExpr (OperandID index1) :<
                   OperandExpr (OperandID index2) :< Nil)
  BRepr -> return (OperandExpr (OperandID index0) :<
                   OperandExpr (OperandID index1) :<
                   OperandExpr (OperandID index2) :< Nil)
  URepr -> return (OperandExpr (OperandID index0) :<
                   OperandExpr (OperandID index1) :< Nil)
  JRepr -> return (OperandExpr (OperandID index0) :<
                   OperandExpr (OperandID index1) :< Nil)
  ARepr -> return (OperandExpr (OperandID index0) :<
                   OperandExpr (OperandID index1) :<
                   OperandExpr (OperandID index2) :<
                   OperandExpr (OperandID index3) :<
                   OperandExpr (OperandID index4) :< Nil)
  XRepr -> return (OperandExpr (OperandID index0) :< Nil)
  where index4 = IndexThere index3

-- | Obtain the formula defined by a 'FormulaBuilder' action.
getFormula :: FormulaBuilder arch fmt () -> Formula arch fmt
getFormula = flip execState emptyFormula . unFormulaBuilder

-- | Add a comment.
comment :: String -> FormulaBuilder arch fmt ()
comment c = fComments %= \cs -> cs Seq.|> c

-- | Get the width of the instruction word
instBytes :: FormulaBuilder arch fmt (Expr arch fmt (ArchWidth arch))
instBytes = return InstBytes

-- | Read the pc.
readPC :: FormulaBuilder arch fmt (Expr arch fmt (ArchWidth arch))
readPC = return (LocExpr PCExpr)

-- | Read a value from a register. Register x0 is hardwired to 0.
readReg :: KnownArch arch
        => Expr arch fmt 5
        -> FormulaBuilder arch fmt (Expr arch fmt (ArchWidth arch))
readReg ridE = return $ iteE (ridE `eqE` litBV 0) (litBV 0) (LocExpr (RegExpr ridE))

-- | Read a variable number of bytes from memory, with an explicit width argument.
readMem :: NatRepr bytes
                -> Expr arch fmt (ArchWidth arch)
                -> FormulaBuilder arch fmt (Expr arch fmt (8*bytes))
readMem bytes addr = return (LocExpr (MemExpr bytes addr))

-- | Read a value from a CSR.
readCSR :: KnownArch arch
        => Expr arch fmt 12
        -> FormulaBuilder arch fmt (Expr arch fmt (ArchWidth arch))
readCSR csr = return (LocExpr (CSRExpr csr))

-- | Read the current privilege level.
readPriv :: FormulaBuilder arch fmt (Expr arch fmt 2)
readPriv = return (LocExpr PrivExpr)

-- | Add a statement to the formula.
addStmt :: Stmt arch fmt -> FormulaBuilder arch fmt ()
addStmt stmt = fDefs %= \stmts -> stmts Seq.|> stmt

-- | Add a PC assignment to the formula.
assignPC :: Expr arch fmt (ArchWidth arch) -> FormulaBuilder arch fmt ()
assignPC pc = addStmt (AssignStmt PCExpr pc)

-- | Add a register assignment to the formula.
assignReg :: Expr arch fmt 5
          -> Expr arch fmt (ArchWidth arch)
          -> FormulaBuilder arch fmt ()
assignReg r e = addStmt $
  BranchStmt (r `eqE` litBV 0)
  $> Seq.empty
  $> Seq.singleton (AssignStmt (RegExpr r) e)

-- | Add a memory location assignment to the formula, with an explicit width argument.
assignMem :: NatRepr bytes
          -> Expr arch fmt (ArchWidth arch)
          -> Expr arch fmt (8*bytes)
          -> FormulaBuilder arch fmt ()
assignMem bytes addr val = addStmt (AssignStmt (MemExpr bytes addr) val)

-- | Add a CSR assignment to the formula.
assignCSR :: Expr arch fmt 12
          -> Expr arch fmt (ArchWidth arch)
          -> FormulaBuilder arch fmt ()
assignCSR csr val = addStmt (AssignStmt (CSRExpr csr) val)

-- | Add a privilege assignment to the formula.
assignPriv :: Expr arch fmt 2 -> FormulaBuilder arch fmt ()
assignPriv priv = addStmt (AssignStmt PrivExpr priv)

-- | Reserve a memory location.
reserve :: Expr arch fmt (ArchWidth arch) -> FormulaBuilder arch fmt ()
reserve addr = addStmt (AssignStmt (ResExpr addr) (litBV 1))

-- | Check that a memory location is reserved.
checkReserved :: Expr arch fmt (ArchWidth arch) -> FormulaBuilder arch fmt (Expr arch fmt 1)
checkReserved addr = return (LocExpr (ResExpr addr))

-- | Left-associative application (use with 'branch' to avoid parentheses around @do@
-- notation)
($>) :: (a -> b) -> a -> b
($>) = ($)

infixl 1 $>

-- | Add a branch statement to the formula. Note that comments in the subformulas
-- will be ignored.
branch :: Expr arch fmt 1
       -> FormulaBuilder arch fmt ()
       -> FormulaBuilder arch fmt ()
       -> FormulaBuilder arch fmt ()
branch e fbTrue fbFalse = do
  let fTrue  = getFormula fbTrue  ^. fDefs
      fFalse = getFormula fbFalse ^. fDefs
  addStmt (BranchStmt e fTrue fFalse)
