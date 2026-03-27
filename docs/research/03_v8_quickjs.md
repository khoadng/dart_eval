# V8 and QuickJS Architecture Research
Phase: 1 | Status: COMPLETE

Research date: 2026-03-27

This report examines the architecture of two JavaScript engines at opposite ends of the
complexity spectrum: V8 (Chrome/Node.js, peak performance via tiered JIT compilation) and
QuickJS (Bellard, minimal footprint embeddable interpreter). The goal is to extract design
patterns transferable to deval, a Dart bytecode interpreter.

---

## Table of Contents

1. [V8 Ignition: Bytecode Interpreter](#1-v8-ignition-bytecode-interpreter)
2. [V8 Hidden Classes and Maps](#2-v8-hidden-classes-and-maps)
3. [V8 Inline Caches and Type Feedback](#3-v8-inline-caches-and-type-feedback)
4. [V8 Object Model](#4-v8-object-model)
5. [V8 TurboFan and Compilation Tiers](#5-v8-turbofan-and-compilation-tiers)
6. [V8 Orinoco Garbage Collector](#6-v8-orinoco-garbage-collector)
7. [QuickJS Architecture Overview](#7-quickjs-architecture-overview)
8. [QuickJS Value Representation](#8-quickjs-value-representation)
9. [QuickJS Atoms and Shapes](#9-quickjs-atoms-and-shapes)
10. [QuickJS Bytecode Interpreter](#10-quickjs-bytecode-interpreter)
11. [QuickJS Garbage Collection](#11-quickjs-garbage-collection)
12. [QuickJS Embedding API](#12-quickjs-embedding-api)
13. [Closures and Scope Chains](#13-closures-and-scope-chains)
14. [Async/Await and Promises at VM Level](#14-asyncawait-and-promises-at-vm-level)
15. [Transferable Lessons for deval](#15-transferable-lessons-for-deval)

---

## 1. V8 Ignition: Bytecode Interpreter

### Register-Based Architecture

Ignition is a **register machine**, not a stack machine. Each bytecode specifies its inputs
and outputs as explicit register operands. The register file lives on the stack frame --
each function activation allocates a fixed-size register window determined at compile time.

The key architectural feature is the **accumulator register**: a dedicated machine register
that serves as implicit input/output for most bytecodes. This design reduces bytecode size
because many operations don't need to encode a destination register. JavaScript expressions
that chain operations left-to-right (e.g., `a + b * c`) keep intermediates in the
accumulator without explicit load/store instructions.

Example bytecode for `return x + y`:

```
Ldar a0          ; Load argument 0 into accumulator
Add a1, [0]      ; Add argument 1, feedback slot [0]
Return            ; Return accumulator value
```

The `[0]` in the `Add` bytecode is a reference to a feedback vector slot where Ignition
stores type profiling information (discussed in section 3).

### Bytecode Format

Bytecodes are variable-length. Each starts with a 1-byte opcode, followed by 0 or more
operand bytes. Operand encoding supports:

- 8-bit register indices (most common)
- 16-bit wide operands (for functions with >256 registers)
- 32-bit immediate values (constants, offsets)
- Feedback slot indices

Wide-prefix bytecodes extend operand size: a `Wide` prefix byte doubles all operand
widths, and an `ExtraWide` prefix quadruples them. This keeps the common case compact
(1-byte operands) while supporting large functions.

The bytecode is 25-50% the size of equivalent baseline machine code, which matters for
memory and cache efficiency.

### Dispatch Mechanism

Ignition uses **indirect threaded dispatch**. A global dispatch table (one per Isolate)
maps each bytecode value to a code pointer for that bytecode's handler. The dispatch table
pointer is kept in a dedicated machine register (`kInterpreterDispatchTableRegister`) to
avoid memory loads on every dispatch.

At the end of each handler:

1. Read the next opcode byte from the bytecode array
2. Index into the dispatch table
3. Tail-call to the next handler

This is equivalent to computed-goto dispatch but uses tail calls instead. The bytecode
handler calling convention pins key state into fixed machine registers:

- Accumulator register
- Bytecode array pointer
- Bytecode offset (program counter)
- Dispatch table pointer
- Register file pointer (frame pointer)

By keeping all interpreter state in registers and using tail calls, Ignition avoids
push/pop overhead between bytecodes.

### Handler Generation

Bytecode handlers are not hand-written assembly. They are generated using TurboFan's
**CodeStubAssembler (CSA)** -- a low-level, architecture-independent macro-assembly API.
TurboFan compiles these handler definitions through its backend, performing instruction
selection and register allocation for each target architecture (x64, ARM64, etc.).

This means adding a new bytecode requires writing one handler in CSA, and it automatically
works on all platforms.

---

## 2. V8 Hidden Classes and Maps

### Concept

JavaScript objects are dictionaries by spec, but dictionary lookups on every property
access would be slow. V8 assigns each object a **Map** (internally called "hidden class"
or "shape") that describes its property layout: which properties exist, at what offsets,
and with what attributes.

Objects with the same sequence of property additions share the same Map, enabling the
engine to compile property accesses as fixed-offset loads rather than hash lookups.

### Map Structure

A Map contains:

- **DescriptorArray**: the full list of property names, their attributes (writable,
  enumerable, configurable), and their storage location (in-object field index or
  properties backing store index)
- **TransitionArray**: edges to sibling Maps, where each edge is labeled with a property
  name ("if I add property X to this Map, I transition to Map Y")
- **Back pointer**: link to parent Map for traversing up the transition tree
- **Prototype pointer**: the object's prototype
- **Instance size**: how many in-object property slots

### Transition Trees

Maps form a tree rooted at the empty Map. Adding properties creates transitions:

```
Empty Map
  |
  +-- "x" --> Map{x}
  |              |
  |              +-- "y" --> Map{x,y}
  |              |
  |              +-- "z" --> Map{x,z}     (branch: different second property)
  |
  +-- "y" --> Map{y}                       (branch: different first property)
```

Objects following the same initialization pattern (same property names in same order)
share the Map chain. Different patterns create branches. This is why consistent object
initialization matters for performance.

### Descriptor Sharing

Multiple Maps in a transition chain can share a single DescriptorArray. Each Map stores a
"descriptor count" indicating how many entries in the shared array belong to it. Map{x}
uses descriptors[0..0], Map{x,y} uses descriptors[0..1], etc. This avoids duplicating
property metadata.

### Slack Tracking

V8 doesn't know upfront how many in-object property slots to allocate. For the first ~7
instances, it over-allocates and then shrinks to the observed maximum. After slack tracking
completes, the in-object field count is locked.

### Map Deprecation and Migration

If a property's representation changes (e.g., from Smi to HeapObject), V8 deprecates the
old Map and creates a new one. Objects with the deprecated Map are lazily migrated: the
next time they're accessed, they transition to the new Map. This avoids scanning the
entire heap.

### Const Property Tracking

Properties that are assigned once during construction get a `const` field type in the Map.
TurboFan exploits this aggressively: if `obj.x` is known to be a constant field, its
value can be inlined directly into optimized code. If the property is later reassigned,
deoptimization occurs.

---

## 3. V8 Inline Caches and Type Feedback

### Inline Cache States

Inline Caches (ICs) are the mechanism that makes hidden classes fast in practice. Each
property access site in the bytecode has an associated IC that remembers what it has seen:

| State | Shapes Seen | Behavior |
|---|---|---|
| **Uninitialized** | 0 | First execution, cold |
| **Monomorphic** | 1 | Single shape: direct offset load |
| **Polymorphic** | 2-4 | Small linear search of cached shapes |
| **Megamorphic** | >4 | Give up, use global hash table or generic lookup |

Monomorphic is the fast path: the IC stores a single (Map, offset) pair, and property
access compiles to: compare object's Map against cached Map, if equal load from cached
offset. This is a single comparison + memory load -- as fast as a field access in a
statically typed language.

Polymorphic ICs store a small array of (Map, offset) pairs and do a linear scan.
Megamorphic ICs fall back to a global hash table where entries are overwritten on
collision -- there is no stable cache.

### Feedback Vectors

Each function has a **FeedbackVector** containing slots for each IC site. Feedback slots
store different kinds of profiling data:

- **BinaryOp slots**: type lattice for arithmetic (None -> SignedSmall -> Number ->
  NumberOrOddball -> String -> BigInt -> Any)
- **Call slots**: target function, call count
- **Property load/store slots**: Map + handler pairs
- **Compare slots**: comparison type feedback
- **Invocation count**: how many times the function has been called

Bytecodes reference feedback slots by index:

```
Add a1, [0]       ; Binary add using feedback slot 0
LdaNamedProperty a0, [2], [4]  ; Load property using name from constant pool [2],
                                ; feedback slot [4]
```

The feedback lattice is monotonic -- once a slot transitions to a more general state, it
never goes back. This prevents deoptimization loops where the optimizer and interpreter
keep disagreeing about types.

### From Feedback to Optimization

When a function is hot enough, TurboFan reads the feedback vector and:

1. Specializes code based on observed types (e.g., emit integer add for SignedSmall)
2. Inserts **CheckMaps** nodes that verify assumptions at runtime
3. If a CheckMaps fails, triggers deoptimization back to the interpreter
4. The interpreter continues collecting feedback with the new broader types
5. The function may be re-optimized with more general assumptions

---

## 4. V8 Object Model

### Pointer Tagging

V8 uses the least significant bit(s) of every "pointer" to distinguish types without
dereferencing:

- **Smi (Small Integer)**: LSB = 0. The upper bits store a 31-bit signed integer. No heap
  allocation needed.
- **HeapObject pointer**: LSB = 1. The remaining bits are the actual pointer (offset by 1
  from the true address).

This allows arithmetic on Smis without unboxing (shift, add, compare) and instant
type discrimination (single bit test). On 64-bit platforms, Smis use the upper 32 bits,
leaving 32-bit precision.

### Pointer Compression

On 64-bit platforms, V8 uses pointer compression: heap pointers are stored as 32-bit
offsets from a base address, with the full 64-bit address reconstructed on load. This
halves pointer memory usage (important for cache).

### Object Layout

A typical JSObject in memory:

```
+-------------------+
| Map pointer       |  --> describes property layout
+-------------------+
| Properties ptr    |  --> out-of-object named properties (or empty_fixed_array)
+-------------------+
| Elements ptr      |  --> indexed properties / array storage
+-------------------+
| In-object field 0 |  (first few named properties, inline)
| In-object field 1 |
| ...               |
+-------------------+
```

### Fast Properties vs Slow Properties

**Fast properties (descriptor mode)**:
- Property metadata stored in the Map's DescriptorArray
- Values stored either in-object (fastest, no indirection) or in the properties backing
  store (one indirection)
- Enables inline caching: Map check + offset load
- Default for most objects

**Slow properties (dictionary mode)**:
- Object has a self-contained hash table as its properties store
- Property name, value, and attributes stored together in the dictionary
- No shared metadata in the Map
- Inline caches don't work
- Triggered by: many property additions/deletions, `delete` operator, too many properties

Transition from fast to slow is one-way in most cases.

### Elements Kinds

V8 tracks the type of array contents with 21 distinct "elements kinds":

```
Lattice (transitions only go downward):

PACKED_SMI_ELEMENTS           (all small integers, no holes)
        |
HOLEY_SMI_ELEMENTS            (small integers with holes)
        |
PACKED_DOUBLE_ELEMENTS        (unboxed doubles, no holes)
        |
HOLEY_DOUBLE_ELEMENTS         (unboxed doubles with holes)
        |
PACKED_ELEMENTS               (any tagged value, no holes)
        |
HOLEY_ELEMENTS                (any tagged value with holes)
        |
DICTIONARY_ELEMENTS           (sparse array, hash table)
```

The key insight: transitions are **irreversible**. Once an array holds a double, it stays
DOUBLE even if that element is later replaced with a Smi. Once a hole is created, it stays
HOLEY forever. This is because the elements kind is stored on the Map, and reverting would
require scanning the entire array to prove it's safe.

**PACKED arrays** are faster because operations can skip prototype chain lookups (no holes
means every index has a value). **SMI/DOUBLE arrays** are faster because values are
unboxed, saving memory and enabling direct arithmetic.

---

## 5. V8 TurboFan and Compilation Tiers

### Four-Tier Pipeline

V8 currently has four execution tiers:

```
Tier 0: Ignition         (bytecode interpreter, collects feedback)
Tier 1: Sparkplug        (non-optimizing baseline JIT, ~instant compilation)
Tier 2: Maglev           (mid-tier optimizing JIT, 10x slower than Sparkplug,
                           10x faster than TurboFan)
Tier 3: TurboFan         (full optimizing JIT, aggressive speculative optimization)
```

**Sparkplug** compiles Ignition bytecodes 1:1 to machine code without analysis or
optimization. It eliminates interpreter dispatch overhead while adding near-zero
compilation latency. It doesn't use feedback and can't deoptimize -- it's just "machine
code that does what the bytecode does."

**Maglev** fills the gap between Sparkplug and TurboFan. It uses feedback from the
feedback vector to perform type specialization, but with a simpler IR and faster
compilation than TurboFan. Its philosophy: "good enough code, fast enough." It handles the
many functions that are moderately hot but don't warrant TurboFan's compilation cost.

**TurboFan** is the heavyweight optimizer with full speculative optimization.

### TurboFan Internals

TurboFan historically used a **Sea of Nodes (SoN)** IR, where nodes represent operations
and edges represent data flow, control flow, and effect dependencies. Pure nodes "float
freely" without fixed positions, theoretically enabling aggressive reordering.

In practice, SoN had significant downsides:

- Most nodes were pinned to effect/control chains anyway (only pure nodes floated)
- Managing effect and control chains was error-prone
- 3x more L1 cache misses than a CFG-based IR (up to 7x in some phases)
- Nodes were visited ~20x on average during optimization (poor traversal order)
- Graphs became unreadable at scale, making debugging difficult
- The scheduler had to re-duplicate instructions that SoN had deduplicated

V8 has since replaced SoN with **Turboshaft**, a traditional CFG-based IR, achieving ~2x
faster compilation while simplifying the codebase.

### Deoptimization

When TurboFan-optimized code encounters a value that violates its speculative assumptions:

1. A **CheckMaps** guard (or similar check) fails
2. The runtime triggers deoptimization
3. Optimized machine code is discarded
4. Execution state is reconstructed for the interpreter (register values, stack state)
5. Execution resumes in Ignition (or Maglev/Sparkplug) at the exact bytecode offset
6. The feedback vector is updated with the new type information
7. The function may be re-optimized later with broader assumptions

Deoptimization is expensive but necessary for correctness. The deoptimizer must maintain
enough metadata to reconstruct interpreter state from any point in the optimized code.

### Tier-Up Heuristics

Functions tier up based on:

- **Invocation count**: tracked in the feedback vector
- **Loop back-edge count**: hot loops can trigger on-stack replacement (OSR)
- **Feedback quality**: megamorphic feedback may prevent TurboFan optimization

---

## 6. V8 Orinoco Garbage Collector

### Generational Design

V8's heap is divided into:

- **Young generation**: small, collected frequently via scavenging. Split into **nursery**
  and **intermediate** sub-generations.
- **Old generation**: large, collected infrequently via mark-sweep-compact.

The generational hypothesis: most objects die young. By collecting the young generation
frequently and cheaply, V8 avoids scanning the entire heap.

### Semi-Space Scavenging (Minor GC)

Young generation uses two semi-spaces. Objects allocate into one space (From-Space) via
bump allocation. When full:

1. Scan roots and From-Space, copying live objects to To-Space
2. Objects that survived one previous GC are promoted to the old generation instead
3. Swap From-Space and To-Space labels

Half the young generation is always empty (the current To-Space), trading space for speed.
V8 uses **parallel scavenging**: multiple helper threads process portions of the root set
simultaneously, using atomic operations for synchronization and thread-local allocation
buffers to avoid contention.

Result: 20-50% reduction in main-thread young GC time.

### Write Barriers

When old-generation objects reference young-generation objects, the runtime must know about
it to use those references as roots during minor GC. V8 uses **write barriers**: every
store to an object field checks if it creates an old-to-new reference and records it in a
remembered set.

### Concurrent Marking (Major GC)

Major GC uses concurrent, incremental marking:

1. **Concurrent marking**: helper threads trace the object graph while JavaScript runs,
   marking reachable objects
2. **Write barriers** track new references created during concurrent marking (objects
   modified by JavaScript while the marker is running)
3. **Finalization pause**: a brief main-thread pause to finalize marking
4. **Concurrent sweeping**: dead objects' memory is added to free lists, done concurrently
5. **Compaction**: selectively copy live objects from highly fragmented pages to compact
   memory (only on pages where fragmentation is worth the copy cost)

Concurrent marking reduced WebGL game pause times by up to 50%.

### Idle-Time GC

V8 schedules GC work during idle periods (e.g., between animation frames). This reduced
Gmail's JS heap by 45% when idle.

---

## 7. QuickJS Architecture Overview

QuickJS is a small, embeddable JavaScript engine written by Fabrice Bellard. It targets a
fundamentally different point in the design space from V8:

| Property | V8 | QuickJS |
|---|---|---|
| Binary size | ~30 MB (Chrome) | ~210 KiB (hello world) |
| Compilation tiers | 4 (Ignition/Sparkplug/Maglev/TurboFan) | 1 (bytecode interpreter) |
| Bytecode type | Register-based | Stack-based |
| GC | Generational tracing | Reference counting + cycle detection |
| JIT | Yes | No |
| Spec compliance | ES2024+ | ES2023 |
| Startup time | ~100ms | ~instant |
| External deps | Many (ICU, zlib, etc.) | Zero |

### Design Principles

1. **Single-pass compilation**: parser emits bytecode directly, no AST. Optimization
   passes run on the bytecode after emission.

2. **Zero external dependencies**: custom Unicode library (compressed tables), custom
   regexp engine (~15 KiB x86), custom bignum library.

3. **Minimal memory overhead**: shapes shared between objects, atoms for string interning,
   pre-computed stack sizes, compressed debug info.

4. **Predictable performance**: no JIT means no warmup, no deoptimization, consistent
   behavior from the first call.

### Compilation Pipeline

```
Source Code
    |
    v
Lexer + Parser (fused, single pass)
    |  emits bytecode directly during parsing
    v
Raw Bytecode
    |
    v
resolve_variables pass
    |  validates scopes, resolves closure vars,
    |  translates temporary opcodes to final ones
    v
Optimization passes (on bytecode)
    |  dead code elimination, constant folding,
    |  short opcode substitution
    v
Final Bytecode (ready for interpreter or serialization)
```

The fused parser/codegen is a deliberate tradeoff: it eliminates the memory cost of an AST
(which can be 10-20x the source size) at the cost of more complex parser code and fewer
optimization opportunities.

### Binary Size Breakdown

QuickJS achieves ~210 KiB for a hello-world binary (x86). The components:

- Core engine: majority of the footprint
- Regexp engine: ~15 KiB
- Unicode tables: compressed, custom library (avoids ICU's ~25 MB)
- BigNum/BigFloat: optional, can be compiled out

### Standalone Executable Compilation

The `qjsc` tool compiles JavaScript to C code by embedding bytecode as a byte array:

```c
// Generated by qjsc
static const uint8_t qjsc_program[] = { ... };
int main() {
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = JS_NewContext(rt);
    js_std_eval_binary(ctx, qjsc_program, sizeof(qjsc_program), 0);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
}
```

This eliminates runtime parsing and produces tiny standalone executables.

---

## 8. QuickJS Value Representation

### JSValue Structure

Every JavaScript value is represented as a JSValue. On 64-bit platforms:

```c
typedef struct JSValue {
    JSValueUnion u;    // 64-bit: int32, float64, or pointer
    int64_t tag;       // 64-bit: type discriminator
} JSValue;
```

Total: 128 bits (16 bytes). This fits exactly in two CPU registers, enabling efficient
pass-by-value in C function calls.

### Tag Values

Tags with reference counting are negative (heap-allocated, reference-counted objects):

```
JS_TAG_FIRST        = -9   (start of refcounted range)
JS_TAG_BIG_INT      = -9
JS_TAG_BIG_FLOAT    = -8
JS_TAG_SYMBOL       = -7
JS_TAG_STRING       = -6
JS_TAG_MODULE       = -5
JS_TAG_FUNC_BYTECODE = -4
JS_TAG_OBJECT       = -3
JS_TAG_BIG_DECIMAL  = -2
JS_TAG_FLOAT64      = -1   (not refcounted, but negative)
```

Primitive (non-refcounted) tags are non-negative:

```
JS_TAG_INT          = 0
JS_TAG_BOOL         = 1
JS_TAG_NULL         = 2
JS_TAG_UNDEFINED    = 3
JS_TAG_UNINITIALIZED = 4
JS_TAG_CATCH_OFFSET = 5
JS_TAG_EXCEPTION    = 6
```

Reference counting check: `tag < 0 && tag != JS_TAG_FLOAT64` means the value is
refcounted.

### 32-bit NaN Boxing

On 32-bit platforms, QuickJS uses NaN boxing to fit a JSValue into 64 bits:

```c
typedef uint64_t JSValue;

// Tag extraction: upper 32 bits
#define JS_VALUE_GET_TAG(v)  ((int32_t)((v) >> 32))

// Value construction
#define JS_MKVAL(tag, val)   (((uint64_t)(tag) << 32) | (uint32_t)(val))
```

IEEE 754 doubles have a special NaN range. QuickJS encodes non-float types in the NaN
space using `JS_FLOAT64_TAG_ADDEND`, allowing a single 64-bit value to represent integers,
booleans, pointers, and floats. Integers and refcounted values can be tested efficiently
with bit operations.

### Number Representation

Numbers are represented as either:

- **32-bit signed integers** (`JS_TAG_INT`): stored inline in the JSValue union, no
  allocation. Most arithmetic operations have fast paths for this case.
- **64-bit IEEE 754 doubles** (`JS_TAG_FLOAT64`): stored inline in the union on 64-bit
  platforms, or as the raw uint64 on 32-bit (NaN-boxed).

The 32-bit integer fast path is critical: most loop counters, array indices, and small
numbers fit in 31 bits. QuickJS checks for integer operands first in arithmetic opcodes
and uses native integer instructions, falling back to double arithmetic only when needed.

---

## 9. QuickJS Atoms and Shapes

### Atom System

An **atom** is a 32-bit integer handle that represents an interned string or a small
integer. All property names, variable names, and commonly used strings are atomized.

```
Atom value ranges:
  0 to 2^31-1  : immediate integer atoms (no allocation, property keys like arr[0])
  >= 2^31      : string atoms (index into the global atom hash table)
```

The atom hash table is stored on the JSRuntime and shared across all contexts. Benefits:

- **O(1) string comparison**: compare two atom integers instead of strcmp
- **Memory deduplication**: each unique string stored once
- **Compact bytecode**: property names stored as 32-bit atoms, not string pointers
- **Fast property lookup**: atoms serve as hash keys

Built-in atoms (keywords, common property names like "length", "prototype", "constructor")
are pre-allocated at runtime startup from `quickjs-atom.h`.

### Shape System

QuickJS uses **shapes** (equivalent to V8's Maps/hidden classes) to share object layout
metadata between objects with the same property structure.

```
JSShape structure:
  - hash            : hash value for the shape itself
  - prop_hash_mask  : mask for the property hash table
  - prop_size       : allocated property slots
  - prop_count      : actual property count (including deleted)
  - deleted_count   : number of deleted properties
  - proto           : prototype object pointer
  - prop_hash_end[] : hash table for property name lookup
  - prop[]          : array of JSShapeProperty entries
```

Each `JSShapeProperty` contains:

- `atom`: the property name (as an atom)
- `flags`: writable, enumerable, configurable, plus internal flags
- `offset`: index into the object's prop array

### Shape Sharing and Caching

The JSRuntime maintains a `shape_hash` cache. When an object adds a property, QuickJS
checks if a shape with that property already exists in the cache. If so, the existing
shape is reused. This is the same concept as V8's transition trees but implemented as a
hash lookup rather than a tree walk.

### Property Access

Property lookup on a JSObject:

1. Get the object's shape
2. Hash the atom (property name)
3. Look up in the shape's property hash table
4. If found, use the offset to index into the object's `prop[]` array
5. If not found, walk the prototype chain

The shape's hash table avoids linear scanning of properties. For objects with very few
properties, the hash table overhead may exceed linear scan cost, but the design scales
well.

---

## 10. QuickJS Bytecode Interpreter

### Stack-Based Design

QuickJS uses a **stack machine**. Operands are pushed onto an evaluation stack, operations
pop their inputs and push results. This produces more compact bytecode than register-based
designs (no register operands needed) at the cost of more push/pop operations.

```
Example: a + b
  get_loc 0    ; push local variable 0 (a) onto stack
  get_loc 1    ; push local variable 1 (b) onto stack
  add          ; pop two values, push result
```

### Opcode Encoding

Opcodes are defined in `quickjs-opcode.h` via a `DEF` macro:

```c
DEF(opname, size, n_pop, n_push, format)
```

Where:
- `size`: total instruction size in bytes (opcode + operands)
- `n_pop`: number of stack values consumed
- `n_push`: number of stack values produced
- `format`: operand encoding format

Operand formats:

| Format | Encoding | Example |
|---|---|---|
| `none` | No operands | `add`, `dup`, `drop` |
| `i32` | 4-byte signed integer | `push_i32` |
| `loc` | 2-byte local index | `get_loc`, `put_loc` |
| `arg` | 2-byte argument index | `get_arg`, `put_arg` |
| `u8` | 1-byte unsigned | Small indices |
| `u16` | 2-byte unsigned | Larger indices |
| `npop` | 1-byte count | `call` (argument count) |

### Short Opcodes

When `SHORT_OPCODES` is enabled (default), frequently used operations get compact 1-byte
encodings:

- `push_0` through `push_7`: push small integer (saves 4 bytes vs `push_i32`)
- `push_minus1`: push -1
- `push_empty_string`: push ""
- `get_loc0` through `get_loc3`: first four local variables (saves 2 bytes)
- `get_arg0` through `get_arg3`: first four arguments (saves 2 bytes)
- `put_loc0` through `put_loc3`: store to first four locals
- `call0` through `call3`: calls with 0-3 arguments (saves 2 bytes)
- `if_false8`: branch with 8-bit offset (saves 3 bytes vs full offset)

This is an effective optimization because the Pareto distribution applies: a small number
of opcodes dominate execution, and those tend to involve small locals, small arguments, and
small integers.

### Opcode Categories

| Category | Examples | Notes |
|---|---|---|
| Value push | `push_i32`, `push_const`, `undefined`, `null`, `push_true` | Load constants |
| Stack mgmt | `drop`, `dup`, `swap`, `nip`, `insert2` | Stack manipulation |
| Variables | `get_loc`, `put_loc`, `get_arg`, `get_var_ref` | Local/arg/closure access |
| Globals | `get_var`, `put_var`, `define_var` | Global variable access |
| Properties | `get_field`, `put_field`, `get_array_el`, `define_field` | Object property ops |
| Calls | `call`, `call_constructor`, `tail_call`, `return` | Function calls |
| Control flow | `if_false`, `goto`, `catch`, `throw` | Branching, exceptions |
| Arithmetic | `add`, `sub`, `mul`, `div`, `mod`, `pow` | Binary operations |
| Comparison | `eq`, `strict_eq`, `lt`, `gt`, `instanceof` | Comparisons |
| Async/Gen | `await`, `yield`, `initial_yield`, `return_async` | Async operations |

### Dispatch Mechanism

QuickJS supports two dispatch strategies:

**Direct threaded dispatch** (GCC/Clang, native builds):
Uses computed goto (`goto *dispatch_table[opcode]`). Each opcode handler has a label
address stored in a dispatch table. After executing, the handler reads the next opcode and
jumps directly via the computed goto. This eliminates the branch predictor overhead of a
switch statement and is approximately **10-20% faster**.

**Switch dispatch** (fallback, required for Emscripten/WASM):
Traditional `switch(opcode)` in a loop. Compatible with all C compilers.

The interpreter entry point is `JS_CallInternal()`, which manages the stack frame and
dispatches opcodes.

### Stack Frame Structure

```c
typedef struct JSStackFrame {
    JSValue *cur_pc;       // current program counter
    JSValue *arg_buf;      // pointer to argument values
    JSValue *var_buf;      // pointer to local variable values
    JSStackFrame *prev_frame;  // caller's frame
    // ... additional fields
} JSStackFrame;
```

Maximum stack size is computed at compile time, so no runtime overflow check is needed per
opcode. A separate stack limit check runs at function entry
(`js_check_stack_overflow`).

Limits: `JS_STACK_SIZE_MAX` = 65534 entries, `JS_MAX_LOCAL_VARS` = 65534.

### Integer Fast Paths

Most arithmetic opcodes have a fast path:

```c
case OP_add:
    if (likely(JS_VALUE_IS_INT(sp[-1]) && JS_VALUE_IS_INT(sp[-2]))) {
        int32_t r;
        if (likely(!__builtin_add_overflow(v1, v2, &r))) {
            sp[-2] = JS_NewInt32(ctx, r);
            sp--;
            DISPATCH();
        }
    }
    // slow path: call js_binary_arith_slow()
```

The `likely()` hints and overflow checks via compiler builtins keep the fast path tight.
Integer arithmetic avoids allocation entirely (the result is stored inline in the JSValue).

---

## 11. QuickJS Garbage Collection

### Reference Counting (Primary Mechanism)

Every heap-allocated JSValue (tag < 0, except FLOAT64) has a reference count. The API
enforces this:

- `JS_DupValue(ctx, val)`: increment refcount, return val
- `JS_FreeValue(ctx, val)`: decrement refcount, free if zero

This gives **deterministic, immediate reclamation** for most objects. When a local variable
goes out of scope or is reassigned, the old value's refcount drops. If it hits zero, the
object is freed immediately, recursively freeing any objects it references.

Advantages over tracing GC:
- No stop-the-world pauses
- Predictable memory usage
- Simple implementation
- Good cache locality (objects freed while still hot in cache)

Disadvantage: cannot reclaim cycles.

### Cycle Detection (Secondary Mechanism)

For reference cycles (A -> B -> A), QuickJS runs a mark-and-sweep cycle detector
periodically. The algorithm has three phases:

**Phase 1: gc_decref**
- Walk all tracked objects (objects that could participate in cycles)
- For each object, decrement the reference counts of all its children
- Objects whose refcount drops to zero are moved to a temporary list (`tmp_obj_list`)
- This "subtracts out" internal references, leaving only external references

**Phase 2: gc_scan**
- Scan objects on `tmp_obj_list`
- If an object's refcount is still > 0 after gc_decref, it has external references and is
  alive. Restore the decremented refcounts of its children (mark it live).
- If refcount is 0, the object is a candidate for collection.

**Phase 3: gc_free_cycles**
- Free all objects that remained at refcount 0 after scanning
- Run finalizers in an unspecified order
- `JS_IsLiveObject()` can be used in finalizers to check if a referenced object is still
  alive (necessary because finalization order is undefined in cycles)

### GC Trigger

The cycle detector runs when `malloc_size > malloc_gc_threshold`. The threshold is
runtime-wide (applies across all contexts in the runtime). It can be configured via
`JS_SetGCThreshold(rt, bytes)`.

### Why Reference Counting?

This design makes sense for an embeddable engine:

1. **Simplicity**: ~500 lines of GC code vs thousands for a generational tracing collector
2. **No separate heap**: objects use the system allocator (malloc/free), no custom heap
   management needed
3. **Predictable latency**: no GC pauses, just per-free overhead
4. **Good for short-lived scripts**: most embedded JS runs briefly, so cycles are rare
5. **Embedding-friendly**: C code can hold JSValue references without worrying about GC
   moving objects (no relocation)

---

## 12. QuickJS Embedding API

### Two-Tier Architecture: Runtime and Context

```
JSRuntime (engine instance)
  |
  +-- memory allocator + limits
  +-- garbage collector
  +-- global atom table (string interning)
  +-- class registry (JSClassDef)
  +-- shape cache
  +-- module loader callbacks
  +-- promise job queue
  +-- stack size limits
  +-- interrupt handler
  |
  +-- JSContext (execution environment / realm)
  |     +-- global object
  |     +-- class prototypes
  |     +-- loaded modules
  |     +-- execution state
  |     +-- user opaque pointer
  |
  +-- JSContext (another realm)
  |     +-- separate global object
  |     +-- separate prototypes
  |     ...
```

**JSRuntime**: global engine state. Memory limits, GC, and atom tables apply to all
contexts within the runtime. Contexts within the same runtime can share objects. Separate
runtimes are fully isolated (no sharing).

**JSContext**: an execution realm. Each has its own global object, prototype chain, and
module namespace. `realm1.Object.prototype !== realm2.Object.prototype`.

### Core Embedding Pattern

```c
JSRuntime *rt = JS_NewRuntime();
JS_SetMemoryLimit(rt, 8 * 1024 * 1024);  // 8 MB limit
JS_SetMaxStackSize(rt, 1024 * 1024);      // 1 MB stack

JSContext *ctx = JS_NewContext(rt);

// Evaluate code
JSValue result = JS_Eval(ctx, "1 + 2", 5, "<input>", JS_EVAL_TYPE_GLOBAL);

// Check result
if (JS_IsException(result)) {
    JSValue exc = JS_GetException(ctx);
    // handle error
    JS_FreeValue(ctx, exc);
} else {
    int32_t val;
    JS_ToInt32(ctx, &val, result);
}
JS_FreeValue(ctx, result);

// Run pending async jobs
while (JS_ExecutePendingJob(rt, &ctx) > 0) {}

JS_FreeContext(ctx);
JS_FreeRuntime(rt);
```

### Binding Native Functions

```c
JSValue my_func(JSContext *ctx, JSValueConst this_val,
                int argc, JSValueConst *argv) {
    int32_t a, b;
    JS_ToInt32(ctx, &a, argv[0]);
    JS_ToInt32(ctx, &b, argv[1]);
    return JS_NewInt32(ctx, a + b);
}

// Register on global object
JSValue global = JS_GetGlobalObject(ctx);
JS_SetPropertyStr(ctx, global, "myAdd",
    JS_NewCFunction(ctx, my_func, "myAdd", 2));
JS_FreeValue(ctx, global);
```

### Custom Classes

```c
JSClassDef my_class = {
    .class_name = "MyObj",
    .finalizer = my_obj_finalizer,    // cleanup callback
    .gc_mark = my_obj_gc_mark,        // mark refs for GC
};

JSClassID my_class_id;
JS_NewClassID(rt, &my_class_id);
JS_NewClass(rt, my_class_id, &my_class);
```

The class system allows native C objects to be wrapped as JavaScript objects with proper
GC integration. The `gc_mark` callback lets the cycle detector trace references held by
native code.

### Interrupt Handler

```c
int my_interrupt(JSRuntime *rt, void *opaque) {
    return should_abort ? 1 : 0;  // non-zero aborts with uncatchable error
}
JS_SetInterruptHandler(rt, my_interrupt, NULL);
```

The interpreter decrements an `interrupt_counter` on backward branches and calls. When it
reaches zero, the interrupt handler is invoked. This enables timeout enforcement without
per-opcode overhead.

### Resource Limits

- `JS_SetMemoryLimit(rt, bytes)`: hard limit on total allocation (0 = unlimited)
- `JS_SetMaxStackSize(rt, bytes)`: stack depth limit (0 = no checks)
- `JS_SetGCThreshold(rt, bytes)`: trigger GC when allocation exceeds threshold

All limits apply per-runtime (shared across all contexts in that runtime).

### Comparison with Lua's C API

QuickJS's API is similar to Lua's in philosophy (C-function-based, stack-passing), but
differs in key ways:

| Aspect | QuickJS | Lua |
|---|---|---|
| Value passing | By value (JSValue is 128-bit struct) | Via stack indices |
| Memory management | Explicit DupValue/FreeValue | GC handles everything |
| Contexts | Multiple per runtime | Multiple lua_State (independent) |
| Type system | Tagged union (JSValue) | Tagged union (TValue) |
| Error handling | Exception-based (JS_IsException) | longjmp-based (lua_pcall) |

QuickJS requires more manual memory management (the `DupValue`/`FreeValue` discipline)
but gives more predictable performance. Lua's API is simpler for the embedder but relies
on the GC for cleanup.

---

## 13. Closures and Scope Chains

### How Closures Work at the VM Level

When a function is created that references variables from an enclosing scope, the VM must
capture those variables so they survive after the enclosing function returns.

### V8's Approach: Context Objects

V8 allocates a **Context** object (heap-allocated environment) for any scope that has
variables captured by inner functions. Variables that are never captured stay in registers.

```
function outer() {
    let x = 1;       // captured by inner -> goes into Context
    let y = 2;       // not captured -> stays in register
    return function inner() {
        return x;    // accesses x via Context chain
    };
}
```

The Context contains the captured variables and a pointer to the parent Context, forming a
scope chain. Property access on closured variables requires dereferencing the chain:
current Context -> parent Context -> ... -> variable slot.

V8 optimizes this by analyzing which variables are actually used by inner functions.
Variables not referenced by any closure stay in registers. The engine tries to prove
captured variables dead to avoid allocating Context objects.

### QuickJS's Approach: JSClosureVar and JSVarRef

QuickJS tracks closure variables explicitly during compilation. Each function's bytecode
includes a `JSClosureVar` list describing its captured variables:

```c
typedef struct JSClosureVar {
    uint8_t is_local;     // from parent's local scope?
    uint8_t is_arg;       // from parent's arguments?
    uint8_t is_const;     // immutable binding?
    uint8_t is_lexical;   // let/const vs var?
    uint16_t var_idx;     // index in parent's variable space
} JSClosureVar;
```

At runtime, when a closure is created, QuickJS creates `JSVarRef` objects for each
captured variable:

- While the parent function is still executing, the JSVarRef points directly into the
  parent's stack frame (a "live" reference).
- When the parent returns, all live JSVarRefs are "detached": the value is copied out of
  the stack frame into the JSVarRef's own storage.

Accessing a closure variable uses `get_var_ref` / `put_var_ref` opcodes. The documentation
states that "access to closure variables is optimized and is almost as fast as local
variables." This is because:

1. The function object stores a direct array of JSVarRef pointers
2. Each JSVarRef is either a direct pointer into the parent's stack or a self-contained
   value
3. No hash lookup, no chain traversal -- just `function->var_refs[index]->value`

This is a flat array lookup, much faster than V8's Context chain traversal for deeply
nested closures.

### Optimization: Dead Closure Elimination

Both V8 and QuickJS analyze variable usage to avoid unnecessary closure allocation. If a
variable is provably never captured, it stays on the stack. QuickJS's `resolve_variables`
pass handles this during compilation.

---

## 14. Async/Await and Promises at VM Level

### Promise Representation

A Promise is an object with internal state:

- **Pending**: no result yet, has a list of reaction callbacks
- **Fulfilled**: has a result value
- **Rejected**: has a reason value

Two internal job types manage promises:

- **PromiseResolveThenableJob**: chains promises together (deferred to next microtask)
- **PromiseReactionJob**: calls `.then`/`.catch` handlers when a promise settles

### Async Function Compilation

An async function is compiled as a **resumable function** with a state machine. Each
`await` is a suspend point:

```
async function f() {
    let a = await fetch(url);   // suspend point 1
    let b = await process(a);   // suspend point 2
    return b;
}

// Compiles to something like:
function f() {
    let state = 0, a, b;
    let implicit_promise = new Promise();

    function resume(value) {
        switch (state) {
            case 0:
                state = 1;
                return fetch(url).then(resume);
            case 1:
                a = value;
                state = 2;
                return process(a).then(resume);
            case 2:
                b = value;
                implicit_promise.resolve(b);
        }
    }
    resume();
    return implicit_promise;
}
```

V8 uses dedicated bytecodes (`SuspendGenerator`, `ResumeGenerator`) and an internal
`JSAsyncFunctionObject` with states: kSuspendedStart, kSuspendedYield, kExecuting,
kCompleted.

### Await Mechanics

When `await expr` executes:

1. If `expr` is not a Promise, wrap it in a resolved Promise
2. Attach resume handlers to the promise
3. Suspend the async function, saving its state
4. Return control to the caller (the microtask that invoked the function)
5. When the promise settles, queue a microtask to resume the function
6. The microtask runs, restoring function state and continuing from after the await

### V8 Optimization

V8 optimized await to avoid unnecessary promise allocations:

- If the awaited value is already a promise, skip wrapping (saves one Promise allocation)
- Eliminated the internal "throwaway" promise in most cases
- Reduced microtask ticks from 3 to 1 for the common case

Result: "async/await outperforms hand-written promise code" in modern V8.

### QuickJS Implementation

QuickJS uses dedicated opcodes (`await`, `yield`, `initial_yield`, `return_async`) and
the `JS_ExecutePendingJob()` loop to drain the job queue. The embedder must call this
function after JS_Eval to process async operations:

```c
int ret;
do {
    ret = JS_ExecutePendingJob(rt, &ctx);
} while (ret > 0);
```

Generators and async functions share the suspension machinery. The function's stack frame
is saved on suspend and restored on resume.

---

## 15. Transferable Lessons for deval

### From V8: What Makes It Fast

**Feedback-driven specialization**: The most impactful optimization in V8 is not any single
optimization pass but the feedback loop between Ignition (collecting type information) and
TurboFan (specializing based on it). Even without a JIT, deval could use type feedback to
select specialized bytecode handlers at runtime (e.g., an "add_int" fast path when the IC
says both operands have always been integers).

**Hidden classes / shapes**: The core idea of sharing structural metadata between objects
with the same layout is universally applicable. deval could implement shapes for Dart
classes to enable fixed-offset property access instead of hash lookups.

**Pointer tagging for Smis**: Encoding small integers directly in the value representation
(no heap allocation) is a massive win for loop counters, array indices, and arithmetic.
deval should ensure its value representation supports unboxed integers.

**Accumulator register**: V8's accumulator reduces bytecode size without the complexity of
full register allocation. deval could adopt this for a register-based design with an
implicit accumulator.

**Feedback vector monotonicity**: The one-way lattice for type feedback prevents
deoptimization loops. If deval implements any form of type-specialized dispatch, the
feedback should only ever generalize, never specialize again.

### From QuickJS: What Makes It Good for Embedding

**Reference counting + cycle detection**: This is the most directly transferable GC
strategy for deval. Dart has its own GC, but for an embedded interpreter, refcounting gives
predictable latency, no stop-the-world pauses, and simple integration with the host. The
cycle detector runs infrequently and only on objects that could form cycles.

**Runtime/Context separation**: Clean separation between engine-global state (memory,
atoms, GC) and execution-local state (global object, prototypes). deval should have a
similar two-tier architecture.

**Atom interning**: All property names as interned 32-bit integers. deval should intern
Dart identifiers and use integer comparison for field/method lookup.

**Single-pass compilation**: Skip the AST, emit bytecode directly from the parser. For an
embedded interpreter that prioritizes startup time and memory, this is the right tradeoff.
deval's current approach of compiling from Dart's AST could be simplified.

**Short opcodes**: The Pareto principle for bytecode -- specialized 1-byte encodings for
the 20-30 most common operations. deval should profile its bytecode distribution and add
short opcodes for the hot ones.

**Computed goto dispatch**: 10-20% faster than switch dispatch with no added complexity.
deval should use this on platforms that support it (though Dart's VM doesn't expose
computed goto -- this is more relevant if deval ever has a native backend).

**Pre-computed stack sizes**: Computing max stack depth at compile time eliminates
per-opcode overflow checks. deval can do this for its stack-based operations.

**Flat closure variable access**: QuickJS's `var_refs[index]->value` is faster than V8's
Context chain traversal. For an interpreter without JIT to optimize away the chain walk,
flat arrays are the right choice. deval's closure representation should use indexed arrays
rather than linked environments.

**Interrupt handler pattern**: A counter-based interrupt check (decrement on backward
branches, check on zero) provides timeout/cancellation without per-opcode overhead. This
is essential for embedding -- the host needs to be able to kill runaway scripts.

**Deterministic memory management**: Refcounting means the embedder knows exactly when
objects die. No surprise GC pauses. For a game engine embedding a scripting language
(deval's use case), this is important for frame timing.

### Architecture Recommendations for deval

Based on this research, the recommended architecture for deval draws primarily from
QuickJS's design, with selective V8 ideas:

```
From QuickJS (core architecture):
  - Stack-based bytecode (compact, simple)
  - Short opcodes for common patterns
  - Atom interning for identifiers
  - Shape-based object layout
  - Reference counting + cycle detection
  - Runtime/Context two-tier embedding API
  - Pre-computed stack sizes
  - Flat closure variable arrays
  - Counter-based interrupt handling
  - Single-pass or minimal-pass compilation

From V8 (selective optimizations):
  - Accumulator register (hybrid stack+accumulator)
  - Integer fast paths in arithmetic opcodes
  - Type feedback collection (even without JIT, for specialized handlers)
  - Elements kind tracking for arrays (packed int vs mixed)
  - Inline cache concept for property access (shape + offset cache)
```

The key principle: QuickJS proves you can build a compliant, performant JS engine in
~50 KLOC with no JIT, no external dependencies, and 210 KiB binary size. deval should
target a similar profile: small, predictable, embedding-friendly, with careful attention
to the hot paths (integer arithmetic, property access, function calls).

---

## Sources

### V8
- [Firing up the Ignition interpreter](https://v8.dev/blog/ignition-interpreter)
- [Fast properties in V8](https://v8.dev/blog/fast-properties)
- [Maps (Hidden Classes) in V8](https://v8.dev/docs/hidden-classes)
- [Elements kinds in V8](https://v8.dev/blog/elements-kinds)
- [Trash talk: the Orinoco garbage collector](https://v8.dev/blog/trash-talk)
- [Orinoco: young generation garbage collection](https://v8.dev/blog/orinoco-parallel-scavenger)
- [Faster async functions and promises](https://v8.dev/blog/fast-async)
- [Land ahoy: leaving the Sea of Nodes](https://v8.dev/blog/leaving-the-sea-of-nodes)
- [Digging into the TurboFan JIT](https://v8.dev/blog/turbofan-jit)
- [Sparkplug: a non-optimizing JavaScript compiler](https://v8.dev/blog/sparkplug)
- [Maglev: V8's Fastest Optimizing JIT](https://v8.dev/blog/maglev)
- [Pointer Compression in V8](https://v8.dev/blog/pointer-compression)
- [An Introduction to Speculative Optimization in V8](https://benediktmeurer.de/2017/12/13/an-introduction-to-speculative-optimization-in-v8/)
- [JavaScript engine fundamentals: Shapes and Inline Caches](https://mathiasbynens.be/notes/shapes-ics)
- [Ignition and TurboFan Compiler Pipeline (thlorenz)](https://github.com/thlorenz/v8-perf/blob/master/compiler.md)
- [Understanding V8's Bytecode](https://medium.com/dailyjs/understanding-v8s-bytecode-317d46c94775)
- [Chrome Browser Exploitation Part 2: Ignition, Sparkplug, TurboFan](https://jhalon.github.io/chrome-browser-exploitation-2/)
- [V8 Internals (browser.training)](https://browser.training.ret2.systems/content/module_1/7_v8_internals/v8_objects)
- [A tour of V8: object representation](https://jayconrod.com/posts/52/a-tour-of-v8-object-representation)
- [Polymorphic Inline Caches explained](https://jayconrod.com/posts/44/polymorphic-inline-caches-explained)

### QuickJS
- [QuickJS official documentation](https://bellard.org/quickjs/quickjs.html)
- [QuickJS Internals (carl-vbn)](https://carl-vbn.dev/misc/quickjs-docs/internals)
- [QuickJS-NG Internals](https://quickjs-ng.github.io/quickjs/developer-guide/internals/)
- [QuickJS: An Overview and Guide (Igalia)](https://blogs.igalia.com/compilers/2023/06/12/quickjs-an-overview-and-guide-to-adding-a-new-feature/)
- [QuickJS Bytecode Interpreter (DeepWiki)](https://deepwiki.com/bellard/quickjs/2.4-bytecode-interpreter)
- [QuickJS Runtime and Context API (DeepWiki)](https://deepwiki.com/quickjs-ng/quickjs/5.1-runtime-and-context-api)
- [Anatomy of QuickJS GC algorithm](https://medium.com/@landerlyoung/anatomy-of-quickjs-garbage-collection-algorithm-fc02f6813ba1)
- [QuickJS Atoms (naddiseo.ca)](https://naddiseo.ca/blog/20201224-quickjs-atoms.html)
- [OpenQuickJS Internals](https://openquickjs.org/developer/internals)
- [MicroQuickJS (bellard)](https://github.com/bellard/mquickjs)

### General
- [Threaded code (Wikipedia)](https://en.wikipedia.org/wiki/Threaded_code)
- [3 Dispatch Techniques (U of Toronto)](https://www.cs.toronto.edu/~matz/dissertation/matzDissertation-latex2html/node6.html)
- [Understanding VM Dispatch through Duality](https://noelwelsh.com/posts/understanding-vm-dispatch/)
- [Value representation in JavaScript implementations (wingolog)](https://wingolog.org/archives/2011/05/18/value-representation-in-javascript-implementations)
