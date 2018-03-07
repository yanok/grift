{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module RISCV.BitVector
  ( -- * BitVector type
    BitVector
  , bv
    -- * Bitwise ops
  -- , bvAnd, bvOr, bvXor
  -- , bvComplement
  -- , bvShift, bvRotate
  -- , bvWidth
  -- , bvTestBit
  -- , bvBit
  -- , bvPopCount
  , bvConcat
  , bvTrunc
  , bvExtract
  ) where

import Data.Bits
import Data.Parameterized.Classes
import Data.Parameterized.NatRepr
import GHC.TypeLits

import RISCV.Utils

----------------------------------------
-- A few utilities

-- TODO: put this in Utils

----------------------------------------
-- BitVector data type definitions

-- | BitVector datatype
data BitVector (w :: Nat) :: * where
  BV :: NatRepr w -> Integer -> BitVector w

-- | Construct a bit vector in a context where the width is known
bv :: KnownNat w => Integer -> BitVector w
bv x = BV repr (truncBits width (fromIntegral x))
  where repr  = knownNat
        width = natValue repr

----------------------------------------
-- BitVector bit operations

bvAnd :: BitVector w -> BitVector w -> BitVector w
bvAnd (BV repr x) (BV _ y) = BV repr (x .&. y)

bvOr :: BitVector w -> BitVector w -> BitVector w
bvOr (BV repr x) (BV _ y) = BV repr (x .|. y)

bvXor :: BitVector w -> BitVector w -> BitVector w
bvXor (BV repr x) (BV _ y) = BV repr (x `xor` y)

bvComplement :: BitVector w -> BitVector w
bvComplement (BV repr x) = BV repr (truncBits width (complement x))
  where width = natValue repr

bvShift :: BitVector w -> Int -> BitVector w
bvShift (BV repr x) shf = BV repr (truncBits width (x `shift` shf))
  where width = natValue repr

bvRotate :: BitVector w -> Int -> BitVector w
bvRotate bvec rot' = leftChunk `bvOr` rightChunk
  where rot = rot' `mod` (bvWidth bvec)
        leftChunk = bvShift bvec rot
        rightChunk = bvShift bvec (rot - bvWidth bvec)

bvWidth :: BitVector w -> Int
bvWidth (BV repr _) = fromIntegral (natValue repr)

bvTestBit :: BitVector w -> Int -> Bool
bvTestBit (BV _ x) b = testBit x b

bvBit :: KnownNat w => Int -> BitVector w
bvBit b = bv (bit b)

bvPopCount :: BitVector w -> Int
bvPopCount (BV _ x) = popCount x

-- | Concatenate two bit vectors.
bvConcat :: BitVector v -> BitVector w -> BitVector (v+w)
bvConcat (BV hiRepr hi) (BV loRepr lo) =
  BV (hiRepr `addNat` loRepr) ((hi `shiftL` fromIntegral loWidth) .|. lo)
  where loWidth = natValue loRepr

-- | Truncate a bit vector to one of smaller length. If the input has shorter length
-- than the result type, this function zero extends the vector.
bvTrunc :: forall w w' . (KnownNat w')
        => BitVector w
        -> BitVector w'
bvTrunc (BV _ x) = bv x -- bv function handles the truncation.

-- | Slice out a smaller bit vector from a larger one. The lowest significant bit is
-- given explicitly as an argument of type 'Int', and the width of the result type is
-- inferred from a type-level context.
bvExtract :: forall w w' . (KnownNat w')
          => Int
          -> BitVector w
          -> BitVector w'
bvExtract pos bvec = bvTrunc (bvShift bvec (- pos))

----------------------------------------
-- Class instances

instance Show (BitVector w) where
  show (BV repr val) = prettyHex width val
    where width        = natValue repr

instance ShowF BitVector

instance Eq (BitVector w) where
  (BV _ x) == (BV _ y) = x == y

instance EqF BitVector where
  (BV _ x) `eqF` (BV _ y) = x == y

instance KnownNat w => Bits (BitVector w) where
  (.&.)        = bvAnd
  (.|.)        = bvOr
  xor          = bvXor
  complement   = bvComplement
  shift        = bvShift
  rotate       = bvRotate
  bitSize      = bvWidth
  bitSizeMaybe = Just . bvWidth
  isSigned     = const False
  testBit      = bvTestBit
  bit          = bvBit
  popCount     = bvPopCount
