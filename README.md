GRIFT - Galois RISC-V ISA Formal Tools
===

*Galois RISC-V Formal Tools* (hereafter, *GRIFT*) is part of the BESSPIN
software suite, developed by Galois, Inc. It contains a concrete representation
of the semantics of the RISC-V instruction set, along with an elegant
encoding/decoding mechanism, and simulation and analysis front-ends. It is
intended for broad use in the RISC-V community - simulation, binary analysis,
and software & hardware verification/validation are all current and/or
potential future uses for *GRIFT*, and we have designed it specifically with
these broad application domains in mind.

*GRIFT* differs from other Haskell-based RISC-V formalizations in its coding
style (using highly dependently-typed GHC Haskell) and some of its foundational
design decisions. Its primary use is as a library, providing mechanisms for the
encoding/decoding of instructions, as well as running RISC-V programs in
simulation. However, the semantics of the instructions themselves are
represented, not as Haskell functions on a RISC-V machine state (registers, PC,
memory, etc.), but as symbolic expressions in a general-purpose bitvector
expression language. This extra layer of representation, while sub-optimal for
fast simulation, facilitates the library's use as a general-purpose encoding of
the semantics, and makes *GRIFT* a general-purpose, "golden reference" model
that can be easily translated into the syntax of other tools by providing
minimal pretty printers, written in Haskell, for the underlying bitvector
expression language. Having explicit semantic data for each instruction also
facilitates the library's incorporation with other Haskell-based tooling, such
as coverage analysis (where a notion of coverage is encoded in the same
bitvector language as the semantics), binary analysis, and verification, both
within and without the Haskell programming environment.

Requirements
===

The following are a list of mandatory and secondary requirements for GRIFT.

Mandatory Requirements
===

## General

- Must represent semantics of all RISC-V behavior in a manipulatable and
  inspectable embedded bitvector expression language.
- Must be open source.
- Must have straightforward integration with other languages, tools, and
  frameworks (Coq, Verilog, ...)

## RISC-V support

- Must support RV32G/RV64G.
- Must support all privilege modes (M, S, U), modeling exceptional behavior
  accurately and completely.
- Must capture all other "customizable" aspects of the ISA (e.g. misaligned
  accesses in hardware).

## Simulation

## Analysis

Secondary Requirements
===

Current Status
===
