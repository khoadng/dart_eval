# WebAssembly VM Architecture Research
Phase: 1 | Status: COMPLETE

## 1. Binary Format

### Module Header

Every WASM binary begins with an 8-byte preamble:

```
Offset  Bytes               Meaning
0x00    00 61 73 6D         Magic number ("\0asm")
0x04    01 00 00 00          Version (currently 1, little-endian u32)
```

After the preamble, the rest of the file is a sequence of sections.

### Section Layout

Each section is encoded as:

```
[section_id: u8] [size: u32_leb128] [contents: byte*]
```

The section ID is a single byte. The size is a LEB128-encoded u32 giving the
byte length of the contents. Every section is optional; omitting a section is
equivalent to an empty one.

Sections must appear in ascending ID order (custom sections excepted):

| ID | Name       | Contents                                              |
|----|------------|-------------------------------------------------------|
|  0 | Custom     | Name string + arbitrary bytes (debug info, metadata)  |
|  1 | Type       | Recursive type definitions (function signatures, etc) |
|  2 | Import     | Import declarations (module + name + descriptor)      |
|  3 | Function   | Vector of type indices for defined functions           |
|  4 | Table      | Table definitions (element type + limits)              |
|  5 | Memory     | Memory definitions (limits)                            |
|  6 | Global     | Global variable definitions (type + init expr)         |
|  7 | Export     | Export declarations (name + descriptor)                |
|  8 | Start      | Index of the start function (optional, at most one)    |
|  9 | Element    | Element segments (table initializers)                  |
| 10 | Code       | Function bodies (local declarations + expression)      |
| 11 | Data       | Data segments (memory initializers)                    |
| 12 | Data Count | u32 count of data segments (required if data indices   |
|    |            | appear in the code section)                            |
| 13 | Tag        | Exception tag definitions                              |

Custom sections (ID 0) may appear anywhere between other sections and are
ignored by the validator. They carry debug info (the "name" section), source
maps, or third-party metadata.

The Function section and Code section are paired: Function section declares
type indices, Code section declares bodies. They must have matching lengths.
This split allows streaming compilation -- a compiler can begin generating code
for earlier functions while later function signatures are still being decoded.

### LEB128 Encoding

All variable-length integers (counts, offsets, indices, sizes) use LEB128
(Little-Endian Base 128). This is a variable-length encoding that uses fewer
bytes for smaller values:

- Values 0-127 encode in 1 byte
- Values 128-16383 encode in 2 bytes
- And so on, up to 5 bytes for u32 / i32, 10 bytes for u64 / i64

Each byte uses 7 bits for data and 1 bit (MSB) as a continuation flag. Signed
integers (i32, i64) use signed LEB128 with sign extension on the final byte.

This encoding is critical for compact binaries: most indices and small constants
fit in 1-2 bytes, which is significantly better than fixed-width encoding.

### Why This Design Matters

The section-based layout enables:
- **Streaming compilation**: engines can compile function N while decoding function N+1
- **Parallel compilation**: the Function section provides all signatures upfront, so all functions can be compiled independently
- **Lazy compilation**: engines can skip to the Code section entry for a specific function without decoding the whole module
- **Validation before execution**: the type system information comes before code, enabling full type checking during a single pass


## 2. Instruction Encoding

### Opcode Format

Instructions are encoded as a single-byte opcode followed by zero or more
immediate arguments:

```
[opcode: u8] [immediate_0] [immediate_1] ...
```

Most instructions are a single byte with no immediates (e.g., `i32.add` is
just `0x6A`). Instructions that reference indices, constants, or memory
offsets include LEB128-encoded immediates.

Examples:

```
Instruction        Encoding
i32.const 42       0x41 0x2A              (opcode + signed LEB128)
local.get 0        0x20 0x00              (opcode + index)
i32.add            0x6A                   (opcode only)
i32.load offset=8  0x28 0x02 0x08        (opcode + align + offset)
call 5             0x10 0x05              (opcode + function index)
```

### Structured Control Flow Encoding

Control flow instructions are unique: they use bracket-like nesting rather
than jump targets.

```
block (result i32)      0x02 0x7F
  ...
end                     0x0B

loop (result i32)       0x03 0x7F
  ...
end                     0x0B

if (result i32)         0x04 0x7F
  ...
else                    0x05
  ...
end                     0x0B
```

Branch instructions (`br`, `br_if`, `br_table`) reference control structures
by nesting depth (a u32 label index), not by byte offset. `br 0` branches to
the innermost enclosing block, `br 1` to the next outer, and so on.

### Multi-byte Opcodes

The single-byte opcode space (0x00-0xFF) was nearly exhausted by MVP. Extended
instructions use prefix bytes:

| Prefix | Category              |
|--------|-----------------------|
| 0xFC   | Saturating truncation, bulk memory, table ops |
| 0xFD   | SIMD (v128) operations |
| 0xFE   | Atomic operations      |
| 0xFB   | GC operations          |

After the prefix byte, a LEB128-encoded sub-opcode follows.

### Memory Instruction Immediates

Load and store instructions carry a `memarg` immediate with two fields:
- **alignment** (as log2, encoded in LEB128): hint for the engine, not enforced
- **offset** (LEB128 u32): added to the dynamic address operand

The offset immediate enables the compiler to fold static offsets into the
instruction rather than emitting a separate `i32.add`, which both shrinks the
binary and simplifies the engine's bounds-check optimization.


## 3. Type System

### Value Types

```
Category    Types              Size     Description
Numeric     i32                32-bit   Integer (signed/unsigned via instruction)
            i64                64-bit   Integer
            f32                32-bit   IEEE 754 float
            f64                64-bit   IEEE 754 float
Vector      v128               128-bit  SIMD vector (interpreted as i8x16,
                                        i16x8, i32x4, i64x2, f32x4, f64x2)
Reference   funcref                     Nullable function reference
            externref                   Opaque host reference
            (ref $type)                 Non-nullable typed reference (GC)
            (ref null $type)            Nullable typed reference (GC)
            i31ref                      Unboxed 31-bit tagged integer (GC)
```

WASM has no implicit type coercion. Every instruction declares exact input and
output types. There is no "untyped" mode. Integer signedness is not part of
the type -- it is part of the instruction (e.g., `i32.div_s` vs `i32.div_u`).

### Function Types

A function type is a mapping from a vector of parameter types to a vector of
result types:

```
[i32 i32] -> [i32]       (two i32 params, one i32 result)
[] -> []                  (no params, no results)
[f64] -> [f64 f64]       (multi-value: one param, two results)
```

Function types are declared in the Type section and referenced by index
throughout the module.

### Block Types

Every structured control instruction (`block`, `loop`, `if`) has a block type
that declares the expected stack signature. This enables the validator to
type-check each block independently.

### Locals

Functions declare typed local variables in addition to their parameters.
Locals are mutable and function-scoped. They serve as an "infinite register
file" -- values that do not need to be on the operand stack can be stored in
locals. This is a deliberate hybrid: stack encoding for compact representation,
locals for values that need longer lifetimes.


## 4. Structured Control Flow

### The Core Principle

WASM has no `goto`. All control flow is expressed through four constructs:

- **block**: a forward-only branch target (br exits the block)
- **loop**: a backward branch target (br re-enters the loop header)
- **if/else**: conditional with optional else branch
- **br_table**: indexed multi-way branch (switch)

These constructs nest, forming a tree. Branch targets are specified by
nesting depth, not byte offsets. This makes the control flow graph statically
knowable from the structure alone.

### Branch Semantics

```
block $outer
  block $inner
    br 0          ;; branches to end of $inner
    br 1          ;; branches to end of $outer
  end
end

loop $L
  br 0            ;; branches to start of $L (re-enters loop)
end
```

`br` targeting a `block` jumps forward to the block's `end`. `br` targeting a
`loop` jumps backward to the loop's header. This asymmetry encodes both
forward jumps (break) and backward jumps (continue) without general goto.

### Why No Goto

The structured control flow design provides several guarantees:

1. **Single-pass validation**: the validator maintains a stack of control
   frames. Each `block`/`loop`/`if` pushes a frame, each `end` pops one.
   Branch targets are validated by checking the label depth against the
   current frame stack. No fixpoint iteration is needed (unlike JVM bytecode
   verification before stack maps).

2. **Reducible control flow**: all WASM control flow graphs are reducible,
   which means every loop has a single entry point. This guarantees that
   standard compiler algorithms (SSA construction, register allocation,
   dominance) work correctly without special-case handling.

3. **CFI (Control Flow Integrity)**: branch targets are implicitly valid.
   There is no way to construct a branch to an arbitrary bytecode offset.
   This is a structural security property, not a runtime check.

4. **Composability**: structured control flow can be composed -- inlining a
   function body preserves the structure. Arbitrary goto would require
   renumbering labels.

### Handling Irreducible Control Flow

Source languages with `goto` (C, C++) compile to WASM using the Relooper
algorithm (or Stackifier), which transforms irreducible control flow into
structured form with bounded code size overhead. This pushes complexity to
the ahead-of-time compiler (running on the developer's machine) rather than
the runtime (running on the user's machine).


## 5. Linear Memory

### Model

Linear memory is a contiguous, resizable byte array. Each module can declare
(or import) one or more memories, though the MVP supports only one.

```
Memory layout:
 ┌─────────────────────────────────────────────────────────────┐
 │  byte 0  │  byte 1  │  ...  │  byte N-1                    │
 └─────────────────────────────────────────────────────────────┘
 0                                                           N = pages * 64Ki
```

Memory size is measured in pages of 64 KiB (65,536 bytes). A memory declares
initial size and optional maximum size.

### Access and Bounds Checking

Load and store instructions compute an effective address:

```
effective_address = i32_operand + offset_immediate
```

If the access (effective_address + access_size) exceeds the current memory
size, a trap occurs. This is a hard guarantee: no out-of-bounds read or write
is ever possible.

In practice, engines optimize bounds checks using virtual memory:
- Reserve a large virtual address range (e.g., 4 GiB + guard pages)
- Map only the currently allocated pages
- Out-of-bounds accesses hit unmapped guard pages, triggering a hardware trap
- This makes bounds checks free for most accesses on 64-bit platforms

### memory.grow

The `memory.grow` instruction takes a delta (in pages) and returns the
previous size (or -1 on failure):

```
(memory.grow (i32.const 1))   ;; grow by 1 page (64 KiB)
;; returns old size in pages, or -1 if allocation failed
```

Growth is capped by the declared maximum. The newly allocated bytes are
zero-initialized. Existing memory contents are preserved.

### Sandboxing Properties

Linear memory is the foundation of WASM's memory safety:

- **Isolated**: each module instance has its own linear memory. Module A
  cannot access module B's memory unless explicitly shared.
- **No pointer leakage**: pointers into linear memory are u32 offsets, not
  host addresses. A WASM program cannot construct a pointer to the host's
  address space.
- **No stack access**: the call stack (return addresses, spilled registers)
  is stored outside linear memory, in engine-managed storage. Stack buffer
  overflows in linear memory cannot corrupt return addresses.
- **Deterministic traps**: out-of-bounds access is always caught, never
  silently reads garbage or corrupts adjacent data.


## 6. Function Tables and Indirect Calls

### Tables

A table is a vector of typed references. In the MVP, tables hold `funcref`
values. Tables enable indirect calls (function pointers, vtables, closures).

```
(table 10 funcref)           ;; table of 10 function references
```

Tables are populated by Element segments (section 9), which initialize
ranges of the table with function references at module load time.

### call_indirect

The `call_indirect` instruction performs a type-checked indirect function call:

```
(call_indirect (type $sig)    ;; expected function signature
  (local.get $args...)        ;; function arguments
  (local.get $table_index))   ;; index into the table (i32 on top of stack)
```

Execution:
1. Pop the table index from the stack
2. Load the function reference from `table[index]`
3. If the index is out of bounds: trap
4. If the table entry is null: trap
5. If the function's actual type does not match `$sig`: trap
6. Call the function with the arguments on the stack

The runtime type check at step 5 is the key security feature. It prevents
calling a function with the wrong signature, which would break type safety.
In C/C++, this corresponds to calling through a mistyped function pointer --
in native code this is undefined behavior and a common exploit vector. In
WASM, it is a deterministic trap.

### Why Tables Instead of Raw Function Pointers

- Function indices are not stable addresses. Tables provide an indirection
  layer that decouples the "function pointer" (table index) from the actual
  function location.
- The host can inspect and modify tables, enabling capability-based function
  access.
- Type-checked dispatch prevents signature confusion attacks.
- Multiple tables (post-MVP) enable separation of concerns: different tables
  for different interfaces.


## 7. Validation

### Single-Pass Type Checking

WASM validation verifies that a module is well-formed before any execution.
The validator runs in a single forward pass over the bytecode, maintaining:

- An operand stack of types (tracking what is on the stack at each point)
- A control stack of block frames (tracking nesting of block/loop/if)

For each instruction, the validator:
1. Pops the expected input types from the operand type stack
2. Checks that they match the instruction's declared inputs
3. Pushes the instruction's declared output types

At `end` instructions, the validator checks that the operand stack matches
the block's declared result type. At branch instructions, it checks that the
stack matches the target block's expected signature.

### Guarantees After Validation

A validated WASM module has the following properties:
- Every instruction receives operands of the correct type
- Every branch targets a valid control structure at the correct depth
- Every function call has the correct number and type of arguments
- Every memory access uses the correct alignment hint
- Every local access is in bounds
- The operand stack never underflows
- Every control structure is properly nested

These guarantees mean the engine can skip runtime type checks during execution.
The only runtime checks remaining are:
- Memory bounds checking (cannot be statically proven in general)
- Table bounds and null checks (for call_indirect)
- Integer division by zero
- Stack overflow (call depth)

### Comparison to JVM Bytecode Verification

The JVM verifier requires a fixpoint computation to handle arbitrary jumps
between basic blocks. WASM's structured control flow eliminates this entirely:
the nesting structure means every merge point (block end) has a known,
statically declared type signature. No iteration is needed.

This makes WASM validation linear-time in the size of the bytecode, which is
critical for startup performance.


## 8. Stack Machine Design

### Why Stack-Based

The WASM design team chose a stack machine for encoding after evaluating
register-based and SSA-based alternatives. The key factors:

**Binary size**: Stack encoding is 25-30% smaller than register encoding for
the same program. In a register machine, every instruction must name its
source and destination registers. In a stack machine, operands are implicit
(top of stack). For a format designed for network transmission, this size
difference matters.

**Verification simplicity**: A structured stack machine with block types can
be verified in a single forward pass with no fixpoint iteration. Register
machines require liveness analysis for equivalent safety guarantees.

**Compilation target**: Compilers (LLVM, etc.) already produce expression
trees internally. Serializing these as stack operations is natural and
produces compact output.

### The Hybrid Reality

WASM is not a pure stack machine. It has locals (mutable variables scoped to
a function), which act as a register file. The stack is used for expression
evaluation; locals are used for values that outlive a single expression.

This hybrid model means:
- Expression evaluation uses the stack (compact encoding)
- Variable storage uses locals (named, typed, like registers)
- The engine can internally convert to registers/SSA trivially

In practice, every major engine immediately converts the stack-based encoding
to SSA or register form during compilation. The stack encoding is a wire
format optimization, not an execution model.

### Implications for Interpreter Design

For interpreters, the stack encoding creates overhead: every instruction must
push/pop the operand stack. Engines that interpret WASM directly (without
rewriting) pay this cost. Engines like wasm3 and WAMR mitigate it by
rewriting to a register-based or fused internal format during loading.


## 9. Compilation Strategies

### V8's Tiered Compilation

V8 uses two tiers for WebAssembly:

**Liftoff (Baseline Compiler)**:
- Single-pass: generates machine code directly from bytecode in one pass
- No intermediate representation (IR), no optimization passes
- Maintains a "virtual stack" during compilation tracking where each value
  lives (register or spill slot)
- Constants are tracked symbolically and only materialized when consumed
- Generates code 5-10x faster than TurboFan
- Generated code runs 18-70% slower than optimized code
- Enables streaming compilation: can start compiling while bytes arrive

**TurboFan (Optimizing Compiler)**:
- Multi-pass: builds a sea-of-nodes IR, runs optimization passes
- Register allocation, instruction selection, code motion, inlining
- Generates near-native-speed code
- Runs on background threads while Liftoff code executes

**Tier-Up Strategy**:
V8 uses eager tier-up: background threads compile all functions with TurboFan
immediately. When TurboFan finishes a function, its code replaces the Liftoff
version. Hot functions may also trigger priority recompilation.

### SpiderMonkey (Firefox)

Similar tiered approach:
- **Baseline**: single-pass compiler generating unoptimized machine code
- **Ion/Cranelift**: optimizing backend using Cranelift as the code generator

### Interpretation Tier

Some engines add an interpreter tier below the baseline compiler:
- Even faster startup (no code generation at all)
- Useful for cold functions that run only once
- V8 added "Liftoff as interpreter" mode for debugging
- Wizard engine demonstrates that in-place interpretation can match
  rewriting interpreters in performance


## 10. wasm3 Interpreter Architecture

wasm3 is the fastest pure (non-JIT) WebAssembly interpreter. Its architecture
is fundamentally different from traditional switch-dispatch interpreters.

### The Meta-Machine Concept

Instead of a central dispatch loop with a switch statement, wasm3 compiles
WASM bytecode into a chain of C function pointers. Each "operation" is a C
function that performs its work and then tail-calls the next operation. There
is no loop, no switch, no central dispatcher.

### Operation Signature

Every operation has an identical C function signature:

```c
void* Operation(pc_t pc, u64* sp, u8* mem, reg_t r0, f64 fp0);
```

| Parameter | x86-64 Register | Purpose                       |
|-----------|-----------------|-------------------------------|
| pc        | rdi             | Program counter (op stream)   |
| sp        | rsi             | Stack pointer                 |
| mem       | rdx             | Linear memory base            |
| r0        | rcx             | Integer accumulator           |
| fp0       | xmm0            | Float accumulator             |

Because all operations share this signature, the C compiler maps these
parameters to real CPU registers via the calling convention. The "virtual
registers" are actual hardware registers throughout execution.

### Dispatch Mechanism

The compiled operation stream is an array of function pointers interleaved
with immediate data:

```
[op_ptr] [immediate] [op_ptr] [immediate] [op_ptr] ...
```

Each operation:
1. Reads its immediates from `pc`
2. Performs its computation
3. Advances `pc` past its immediates
4. Loads the next operation pointer from `pc`
5. Tail-calls the next operation

When the C compiler applies tail-call optimization (which GCC/Clang do
reliably for this pattern), step 5 becomes an indirect `jmp` rather than a
`call`. This eliminates stack frame setup/teardown for each operation.

### Example: Compiled x86-64 for an OR Operation

```asm
movslq (%rdi), %rax        ; load stack offset from pc
orq    (%rsi,%rax,8), %rcx ; OR stack value with r0 register
movq   0x8(%rdi), %rax     ; load next operation address
addq   $0x10, %rdi         ; advance pc
jmpq   *%rax               ; tail-call next operation
```

Five instructions. The actual computation (OR) is one instruction. Dispatch
overhead is four instructions. This is close to the theoretical minimum for
an interpreter.

### Translation Phase

WASM bytecodes are not executed directly. During loading, each WASM opcode
is expanded into 1-3 specialized operations:

- **Operand specialization**: `i32.or` with stack operands generates a
  different operation than `i32.or` with the r0 register operand
- **Commutative variants**: for non-commutative operations, separate ops
  handle swapped operand order
- **Fusion**: common sequences (like `local.get` followed by `i32.add`)
  may be fused into a single operation

This expansion increases the operation vocabulary but reduces per-operation
branching.

### Register Strategy

wasm3 uses exactly two accumulator registers: one integer (r0) and one float
(fp0). Values flow through these registers when possible, spilling to the
stack only when necessary.

The two-register design is a deliberate trade-off:
- One register: too many spills, poor performance
- Two registers: good balance, manageable operation count
- Three registers: exponential explosion of operation variants (each op
  would need variants for every combination of register/stack operands)

### Control Flow and Stack Unwinding

Loops and function calls cannot use tail-call optimization because they need
to unwind. These operations allocate actual stack frames. When a loop's body
executes `br 0` (continue), the operation returns a special "continue"
pointer. The loop operation checks this pointer and either re-enters the
body or propagates the return upward.

Traps similarly return trap pointers that bubble up the call chain.

### Performance

Benchmarks show wasm3 runs 4-15x slower than native code:

| Benchmark   | wasm3  | Native (GCC -O3) | Ratio |
|-------------|--------|-------------------|-------|
| Mandelbrot  | 17.9s  | 4.1s              | 4.4x  |
| CRC32       | 5.1s   | 0.6s              | 8.5x  |

wasm3 beats Lua by approximately 3x on comparable benchmarks.


## 11. WAMR (WebAssembly Micro Runtime)

### Overview

WAMR is a lightweight WebAssembly runtime from the Bytecode Alliance, targeting
embedded, IoT, and edge devices. Runtime binary size is approximately 85 KB for
the interpreter and 50 KB for AOT mode.

### Execution Modes

| Mode              | Description                                    |
|-------------------|------------------------------------------------|
| Classic Interpreter | Standard switch-dispatch, for debugging      |
| Fast Interpreter  | Precompiled bytecode, 2x faster than classic   |
| Fast JIT          | Lightweight single-pass JIT                    |
| LLVM JIT          | Full optimization via LLVM backend             |
| AOT               | Ahead-of-time via wamrc compiler (LLVM-based)  |

WAMR supports dynamic tier-up from Fast JIT to LLVM JIT.

### Fast Interpreter Design

The fast interpreter pre-compiles WASM bytecode into an internal format with
three key optimizations:

**1. Labels-as-Values Dispatch**

Uses GCC's computed goto extension (`&&label`) to create a dispatch table of
label addresses. Instead of:

```c
switch (opcode) {
  case OP_ADD: ... break;
  case OP_SUB: ... break;
}
```

The fast interpreter uses:

```c
static void* dispatch_table[] = { &&op_add, &&op_sub, ... };
goto *dispatch_table[opcode];
op_add: ... goto *dispatch_table[next_opcode];
op_sub: ... goto *dispatch_table[next_opcode];
```

This eliminates the switch overhead (bounds check, jump table lookup) and
gives the CPU's branch predictor a separate indirect branch site for each
opcode, improving prediction accuracy. Contributes approximately 7%
performance improvement.

**2. Bytecode Fusion**

WASM's stack-based encoding requires frequent push/pop of intermediate values.
The fast interpreter identifies "provider" instructions (like `local.get`,
`i32.const`) that push a value, followed by "consumer" instructions (like
`i32.add`, `i32.store`) that pop it. These are fused into a single internal
operation that skips the stack round-trip.

Example: `local.get 0; local.get 1; i32.add` might fuse into a single
"add_local_local" operation that reads both locals directly.

**3. Stack-to-Register Refactoring**

The precompilation pass partially converts the stack-based encoding to a
register-based form, reducing stack traffic.

### Performance

The fast interpreter achieves approximately 150% improvement over the classic
interpreter on CoreMark, at the cost of 2x memory for the precompiled code.

### Wizard Engine (In-Place Interpretation)

An alternative approach from Ben Titzer's research. Instead of rewriting
bytecode, Wizard interprets WASM bytecode in-place using a side table for
control transfer information.

The side table stores pre-computed branch targets for each control flow
instruction. During interpretation, branch instructions look up their target
in the side table rather than scanning forward through the bytecode.

Key advantage: the side table is an order of magnitude cheaper to generate
than a full bytecode rewrite. The hand-written x86-64 interpreter achieves
performance competitive with rewriting interpreters while using less memory.


## 12. GC Proposal

### Motivation

Languages with garbage collection (Dart, Kotlin, Java, OCaml) historically
compiled to WASM by shipping their own GC implementation in linear memory.
This duplicates work (every language brings its own GC), prevents interop
between languages (each has its own object layout), and misses optimization
opportunities (the engine cannot see into the managed heap).

The GC proposal adds managed heap types to WASM, letting the engine's own GC
manage objects.

### New Types

**Struct types** -- heterogeneous fixed-layout aggregates:
```wasm
(type $point (struct (field $x f64) (field $y f64)))
```

**Array types** -- homogeneous dynamically-sized sequences:
```wasm
(type $buffer (array (mut i32)))
```

**i31ref** -- an unboxed 31-bit tagged integer for efficient polymorphism:
```wasm
(ref.i31 (i32.const 42))       ;; box
(i31.get_s (local.get $ref))   ;; unbox signed
```

The 31-bit restriction ensures the value fits in a tagged pointer on all
platforms (one bit reserved for the tag).

### Reference Type Hierarchy

```
        anyref
       /      \
  eqref      funcref
  /    \
i31ref  structref / arrayref
          |
     (ref $concrete_type)
```

- `anyref`: top type for all GC references
- `eqref`: references that support equality comparison
- `i31ref`: unboxed scalar
- `structref` / `arrayref`: abstract supertypes

### Operations

| Instruction       | Description                        |
|-------------------|------------------------------------|
| struct.new        | Allocate struct with field values   |
| struct.new_default| Allocate with default (zero) values|
| struct.get        | Read a field                       |
| struct.set        | Write a mutable field              |
| array.new         | Allocate array with initial value  |
| array.new_data    | Allocate from data segment         |
| array.get         | Read element by index              |
| array.set         | Write element by index             |
| array.len         | Get array length                   |
| ref.cast          | Cast or trap                       |
| ref.test          | Test type, return i32 boolean      |
| br_on_cast        | Branch if cast succeeds            |

### Subtyping

Struct subtyping: a subtype can add fields but cannot remove or change
existing ones (width subtyping). Immutable fields are covariant; mutable
fields are invariant.

### Integration

GC objects live outside linear memory. They are accessed through typed
references, not through load/store on raw byte offsets. This means:
- The engine controls object layout (can optimize for cache, compaction)
- The GC can move objects (no pinning required)
- Cross-language interop is possible (shared struct definitions)
- Pay-as-you-go: modules that don't use GC types pay zero cost


## 13. Security Model

### Defense in Depth

WASM's security is not a single mechanism but a layered design:

**Layer 1 -- Validation (compile time)**:
- Type safety: every instruction is type-checked
- Control flow integrity: structured control flow, no arbitrary jumps
- Memory safety: all accesses go through linear memory with bounds checks

**Layer 2 -- Linear memory isolation (runtime)**:
- Each module instance has its own linear memory
- No access to host address space
- Call stack is stored outside linear memory (no stack smashing)
- Deterministic traps on out-of-bounds access

**Layer 3 -- Capability-based access (system interface)**:
- WASM modules have zero privileges by default
- All system access (files, network, clock) must be explicitly granted
- WASI models capabilities as handle types passed to the module
- No ambient authority: a module cannot discover or create capabilities

### What WASM Prevents

| Attack                    | Prevention mechanism              |
|---------------------------|-----------------------------------|
| Buffer overflow to code   | Code and data in separate spaces  |
| ROP / JOP                 | Structured control flow, no goto  |
| Stack smashing            | Call stack outside linear memory   |
| Type confusion            | Validated type system              |
| Signature confusion       | call_indirect runtime type check   |
| Privilege escalation      | Capability-based WASI model        |
| Side-channel (Spectre)    | Engine-level mitigations           |

### What WASM Does Not Prevent

Within linear memory, WASM provides no object-level protection. A buffer
overflow in linear memory can corrupt adjacent data (other objects allocated
in the same linear memory). This is by design: WASM provides process-level
isolation, not object-level memory safety. Languages that want object-level
safety must implement it themselves (or use the GC proposal's managed types).


## 14. Component Model

### Purpose

The Component Model extends WASM from a single-module execution format to a
multi-module composition system. It defines:

- **WIT (WebAssembly Interface Types)**: an IDL for declaring interfaces
- **Canonical ABI**: a standard calling convention for crossing component
  boundaries
- **Composition**: linking components together at their interfaces

### WIT (WebAssembly Interface Types)

WIT is a language-agnostic IDL for defining component interfaces:

```wit
interface math {
    add: func(a: f64, b: f64) -> f64
    record point { x: f64, y: f64 }
    distance: func(a: point, b: point) -> f64
}

world calculator {
    import math
    export evaluate: func(expr: string) -> f64
}
```

A **world** declares a component's full contract: what it imports and what
it exports. An **interface** groups related types and functions.

### Composition

Components can be composed: one component's exports satisfy another's imports.
The composed result is a new component. Calls between composed components are
in-process function calls (nanoseconds), not network requests (milliseconds).

### Relevance to Interpreter Design

The Component Model demonstrates how a bytecode format can be extended from
single-module execution to a full module system with typed interfaces, without
breaking backward compatibility.


## 15. What deval Can Learn from WASM

### Binary Format Design

**Section-based layout**: deval should organize its binary format into typed
sections with length prefixes. This enables:
- Skipping sections the runtime does not need
- Streaming/parallel loading
- Forward compatibility (unknown sections can be skipped)

**LEB128 for variable integers**: most indices and small constants fit in 1-2
bytes. Using LEB128 instead of fixed-width encoding can shrink bytecode by
20-30%.

**Separate type and code sections**: declaring all function signatures before
any function bodies enables the runtime to set up all call targets before
compiling/interpreting any code. This eliminates forward-reference problems.

### Structured Control Flow

**Replace goto-style jumps with block/loop/br**: this is probably the single
highest-value lesson. Structured control flow enables:
- Single-pass validation (linear time, no fixpoint)
- Guaranteed reducible control flow (simpler compilation)
- Implicit CFI (no need for runtime branch-target validation)
- Smaller bytecode (branch targets are small depth indices, not large offsets)

If deval currently uses byte-offset jumps, converting to structured control
flow would simplify the validator, improve security, and potentially improve
interpreter performance (branch prediction is better when the structure is
known).

### Validation-First Design

**Type-check at load time, execute without checks**: deval should aim to
validate all bytecode before execution begins. If the validator proves that
all operations receive correct types, the interpreter can skip type checks
on every instruction. This is a significant performance win.

### Interpreter Dispatch

**wasm3's meta-machine for Dart**: Dart does not have computed goto or
reliable tail-call optimization, so wasm3's exact technique is not directly
portable. However, the principles apply:

- **Precompile to internal format**: translate stack-based bytecode to a
  register-friendly internal representation during loading
- **Fuse common sequences**: identify provider-consumer pairs and fuse them
  into single operations
- **Minimize stack traffic**: use a small number of "accumulator" variables
  to pass values between operations without going through a stack array
- **Specialize operations**: instead of one generic "add" operation that
  checks operand sources at runtime, generate separate operations for
  "add from stack+stack", "add from local+const", etc.

**Labels-as-values equivalent**: Dart's switch statement compiles to
efficient jump tables in AOT mode. A well-structured switch dispatch with
dense opcode numbering may achieve similar performance to computed goto.

### Memory Model

**Linear memory with bounds checking**: if deval exposes memory to user
programs, a flat byte array with bounds-checked access is the simplest
secure model. The host runtime controls the memory allocation and can
enforce size limits.

### Sandboxing

**Capability-based access**: deval programs should not have ambient access to
Dart APIs. Instead, the host should explicitly grant capabilities (functions,
objects) that the deval program can call. This prevents a deval program from
doing anything the host did not intend.

### Side Tables for Control Flow

**Wizard's in-place interpretation**: if deval wants to interpret bytecode
without rewriting it (saving memory and load time), pre-computing a side
table of branch targets during validation is an efficient approach. The side
table is small (one entry per branch instruction) and eliminates the need
to scan forward through bytecode at runtime.

### Type System

**Fixed-width numeric types**: WASM's type system (i32, i64, f32, f64) maps
directly to hardware. If deval needs to support numeric computation, using
fixed-width types rather than arbitrary-precision numbers enables the
interpreter to use hardware arithmetic directly.

**Reference types for managed objects**: if deval needs to handle Dart objects,
typed references (like WASM's funcref/externref) provide a type-safe way to
pass opaque host objects through the interpreter without boxing/unboxing.


## Sources

- [WebAssembly 3.0 Binary Format: Modules](https://webassembly.github.io/spec/core/binary/modules.html)
- [WebAssembly 3.0 Binary Format: Instructions](https://webassembly.github.io/spec/core/binary/instructions.html)
- [WebAssembly Design Rationale](https://github.com/WebAssembly/design/blob/main/Rationale.md)
- [WebAssembly Security](https://webassembly.org/docs/security/)
- [V8 WebAssembly Compilation Pipeline](https://v8.dev/docs/wasm-compilation-pipeline)
- [Liftoff: Baseline Compiler for WebAssembly in V8](https://v8.dev/blog/liftoff)
- [wasm3 Interpreter Documentation](https://github.com/wasm3/wasm3/blob/main/docs/Interpreter.md)
- [wasm3 GitHub Repository](https://github.com/wasm3/wasm3)
- [WAMR (WebAssembly Micro Runtime)](https://github.com/bytecodealliance/wasm-micro-runtime)
- [WAMR Fast Interpreter Introduction](https://bytecodealliance.github.io/wamr.dev/blog/wamr-fast-interpreter-introduction/)
- [WebAssembly GC Proposal Overview](https://github.com/WebAssembly/gc/blob/main/proposals/gc/Overview.md)
- [WasmGC in V8](https://v8.dev/blog/wasm-gc-porting)
- [WebAssembly Component Model](https://component-model.bytecodealliance.org/)
- [Wizard Research Engine](https://github.com/titzer/wizard-engine)
- [A Fast In-Place Interpreter for WebAssembly (Titzer, 2022)](https://arxiv.org/abs/2205.01183)
- [WebAssembly Is Not a Stack Machine](http://troubles.md/wasm-is-not-a-stack-machine/)
- [Dynamic Dispatch in WebAssembly](https://fitzgen.com/2018/04/26/how-does-dynamic-dispatch-work-in-wasm.html)
- [Wasmtime Security Model](https://docs.wasmtime.dev/security.html)
- [Wasm 3.0 Release Announcement](https://webassembly.org/news/2025-09-17-wasm-3.0/)
- [Learning WebAssembly: Binary Format](https://blog.ttulka.com/learning-webassembly-2-wasm-binary-format/)
