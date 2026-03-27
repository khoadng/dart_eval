# Cross-Reference Analysis
Phase: 2 | Status: COMPLETE

## 1. Universal Patterns Across All VMs

Every high-performance VM we studied shares these architectural choices:

### 1.1 Unboxed Primitives
- **Dart VM**: Smi (tag 0, upper bits = int value). Zero allocation for integers.
- **Lua**: TValue tagged union. Numbers stored inline, no allocation.
- **LuaJIT**: NaN boxing. 8 bytes per value, doubles stored as-is.
- **V8**: Smi (LSB=0, upper 31/32 bits = int). Zero allocation.
- **QuickJS**: JSValue with int32 fast path. No allocation for integers.
- **WASM**: Fixed-width types (i32, i64, f32, f64). No boxing at all.
- **deval**: `$int(v)` allocates TWO objects ($int + $Object). WORST of all systems.

**Verdict**: Unboxed primitives are non-negotiable. deval is the only system that
heap-allocates for every integer operation.

### 1.2 Integer/Switch-Based Dispatch
- **Dart VM**: Inline caching + megamorphic hash table (JIT), global dispatch table (AOT)
- **Lua**: `switch (GET_OPCODE(i))` on 7-bit opcode from 32-bit instruction
- **V8 Ignition**: Indirect threaded dispatch via handler table
- **QuickJS**: Computed goto (`goto *dispatch_table[opcode]`) or switch fallback
- **WASM (wasm3)**: Chain of function pointers with tail-call
- **WASM (WAMR)**: Labels-as-values computed goto
- **deval**: Polymorphic virtual method call `op.run(this)` on 74+ classes. WORST.

**Verdict**: Switch or computed-goto dispatch is the universal standard. Virtual
method dispatch is the worst possible strategy for an interpreter's inner loop.

### 1.3 Register/Stack Machine with Compact Instructions
- **Dart VM**: SSA IR compiled to native registers
- **Lua**: Register-based, 32-bit fixed-width instructions, 82 opcodes
- **V8 Ignition**: Register-based with accumulator, variable-length bytecodes
- **QuickJS**: Stack-based with short opcodes for hot paths
- **WASM**: Stack-based with locals (hybrid)
- **deval**: Stack machine, ops stored as heap objects in a List<EvcOp>

**Verdict**: Either register-based (Lua model) or stack+accumulator (V8 model) works.
The key is compact encoding -- deval's ops-as-objects is unique and wasteful.

### 1.4 Pre-Computed Frame Sizes
- **Lua**: Compiler knows exact register count per function
- **V8 Ignition**: Frame size determined at compile time
- **QuickJS**: Max stack depth computed at compile time, no per-op checks
- **WASM**: Locals declared in function header
- **deval**: Fixed 255-slot frames for ALL functions

**Verdict**: Every VM computes frame sizes at compile time. deval's 255-slot fixed
frames are uniquely wasteful.

### 1.5 Integer-Based Method Dispatch
- **Dart VM**: CID-based vtable (AOT) or inline cache (JIT)
- **V8**: Hidden classes + inline caches (shape + offset)
- **QuickJS**: Atom (interned int) + shape property hash
- **Lua**: Tables with string-interned keys + metatables
- **deval**: HashMap<String, int> lookup per call

**Verdict**: Even Lua, the simplest VM, uses interned strings for O(1) equality.
deval's raw string HashMap is the most expensive dispatch mechanism studied.


## 2. Key Insight: The Dart Constraint

Unlike C-based VMs, deval runs inside the Dart VM. This constrains options:

### What We CAN'T Do in Dart
- NaN boxing (no raw memory manipulation)
- Computed goto (no label addresses)
- Tagged pointers (no pointer arithmetic)
- Tail-call optimization (not guaranteed by Dart)
- Union types (no C-style unions)
- Inline assembly (no machine-level control)

### What We CAN Do in Dart
- Switch on int (compiles to jump table in AOT)
- Sealed class hierarchies (compiler can optimize pattern matching)
- Typed lists (Int32List, Float64List) for flat bytecode buffers
- Extension types (zero-cost abstractions over ints)
- Records (lightweight tuples, potentially stack-allocated)
- const constructors (compile-time constants)
- Expando / WeakReference for soft references

### The Critical Realization
Dart's switch-on-int compiles to an efficient jump table in AOT mode. This is
our best available dispatch mechanism -- roughly equivalent to computed goto
in C VMs. Combined with flat typed arrays (Int32List) for bytecode storage,
we can achieve a dispatch loop competitive with QuickJS's switch fallback mode.

The value representation problem is harder. We can't do NaN boxing or tagged
pointers. But we CAN use:
1. Extension types on int (zero-cost tag + payload encoding)
2. Unboxed int/double on typed lists (no Object? boxing)
3. Sealed class hierarchy for heap objects (compiler-optimized dispatch)


## 3. deval-Specific Bottleneck Ranking (Cross-Referenced)

Combining the runtime analysis with VM research, here are the bottlenecks
ranked by impact and feasibility of fix:

### Tier 1: Must Fix (5-50x improvement potential each)

**A. Virtual dispatch loop -> switch on int**
- Impact: Every op pays megamorphic call overhead. At 50-200x slower than
  native for numeric code, dispatch overhead is ~30-50% of that.
- Evidence: All VMs use switch/computed-goto. None use virtual dispatch.
- Feasibility: HIGH. Switch on int is idiomatic Dart. The refactor is
  mechanical: convert each EvcOp subclass to a case in the switch.

**B. $int/$double double-allocation -> unboxed/tagged values**
- Impact: Every integer operation allocates 2 objects. For a numeric loop
  doing 1M iterations, that's 4M allocations per loop just for boxing.
- Evidence: Every VM avoids this. Lua/V8/QuickJS all store ints inline.
- Feasibility: MEDIUM. Requires rethinking the value representation.
  Extension types on int could provide zero-cost tagging.

**C. $Bridge try/catch -> explicit check**
- Impact: Every property access on a bridge object that isn't overridden
  throws and catches an exception. Exception handling is 100-1000x slower
  than a conditional check.
- Evidence: No other VM uses exceptions for normal dispatch.
- Feasibility: HIGH. Replace with a null check or flag check.

### Tier 2: Should Fix (2-10x improvement each)

**D. Fixed 255-slot frames -> sized frames**
- Compiler already knows local count. Encode in PushScope.

**E. HashMap method dispatch -> integer-indexed vtables**
- Assign member IDs at compile time. Array lookup instead of hash.

**F. Per-call List allocation for args -> reusable buffer**
- Pre-allocate an args buffer, reset between calls.

**G. $num superclass allocation -> merge properties into wrapper**
- Eliminate the $Object/$Pattern superclass objects in $num/$bool/$String.

### Tier 3: Nice to Have (10-50% improvement each)

**H. Missing numeric intrinsics (*, /, %, <<, >>)**
- Common operations fall through to dynamic dispatch.

**I. No constant folding**
- `2 + 3` runs at runtime instead of compile time.

**J. Flat bytecode buffer instead of List<EvcOp>**
- Int32List or Uint8List for ops + operands.

**K. Closure captures whole frame -> capture specific variables**
- QuickJS's flat var_refs approach is the model.


## 4. Architectural Model Recommendation

Based on cross-referencing all VMs against Dart's constraints:

### Primary model: QuickJS
- Small, embeddable, no JIT, predictable performance
- 210 KiB binary, full JS compliance
- Reference counting (fits Dart's GC model -- we inherit Dart's GC)
- Atom interning for identifiers
- Short opcodes for hot paths
- Pre-computed stack sizes
- Single-pass or minimal-pass compilation

### Selective additions from other VMs:

**From Lua:**
- 32-bit fixed-width instruction encoding (register-based)
- Dual register+stack model (registers for locals, stack for temps)
- The "embedding API IS the product" philosophy
- ~120 function API surface area target

**From V8:**
- Accumulator register (reduces bytecode size)
- Feedback vector concept (even without JIT -- for specializing hot paths)
- Inline cache concept for property access (monomorphic cache per call site)

**From WASM:**
- Structured control flow (block/loop/br instead of byte-offset jumps)
- Validation-first design (type-check at load time, skip checks at runtime)
- Section-based binary format for streaming/lazy loading
- Capability-based sandboxing

**From Dart VM:**
- Type argument flattening for efficient generic access
- Async/await as frame serialization (SuspendState model)
- Depth-first class ID numbering for subtype range checks


## 5. Gaps Requiring Deeper Investigation

### 5.1 Value Representation in Dart
The biggest open question. Dart has no union types or pointer tagging. Options:
- `(int tag, int payload)` record -- 2 ints, no allocation for primitives
- Extension type on int (tag in bits) -- 1 int, limited precision
- `Object?` with pattern matching -- relies on Dart AOT optimizations
- Sealed class with specialized subclasses -- Dart compiler can optimize

Need to benchmark these options to find the best representation.

### 5.2 Atom/String Interning in Dart
Dart's String is immutable and the VM may intern some strings already.
Need to determine if we need a separate interning layer or can leverage
Dart's existing string identity semantics.

### 5.3 Bytecode Format: Fixed vs Variable Width
Lua uses 32-bit fixed-width. V8/QuickJS use variable-width. WASM uses
variable-width. For a Dart interpreter using Int32List, fixed-width is
simpler. Need to evaluate the size/speed tradeoff.

### 5.4 Structured Control Flow Feasibility
WASM's block/loop/br model enables single-pass validation. Can we compile
Dart's control flow into structured form? The Dart analyzer's AST already
has structured control flow, so this should map naturally.

### 5.5 How Much Optimization Is Worth Adding?
QuickJS proves a capable interpreter needs minimal optimization (single-pass
compiler with a few bytecode cleanup passes). But deval's compiler already
has a multi-pass structure. The question is: add an IR for optimization, or
simplify to match QuickJS's approach?

Given deval's use case (game engine scripting), startup time matters more
than peak throughput. QuickJS's approach (fast compilation, decent execution)
is likely the right tradeoff.


## 6. Cross-Reference Matrix

```
Feature                 DartVM  Lua    V8/QJS  WASM   deval   Fix?
-----------------------------------------------------------------------
Unboxed ints            Y       Y      Y       Y      N       MUST
Switch/goto dispatch    Y       Y      Y       Y      N       MUST
Compact bytecode        Y       Y      Y       Y      N       MUST
Sized frames            Y       Y      Y       Y      N       MUST
Int method dispatch     Y       Y*     Y       N/A    N       MUST
Inline caches           Y       N      Y       N      N       SHOULD
Constant folding        Y       Y      Y       N/A    N       SHOULD
String interning        Y       Y      Y       N/A    N       SHOULD
Struct'd ctrl flow      N       N      N       Y      N       NICE
Validation-first        N       N      N       Y      N       NICE
Flat closures           N       Y*     Y**     N/A    N       SHOULD
Peephole opts           Y       N      Y       N/A    N       SHOULD
```
* Lua uses interned strings (O(1) equality) rather than integer IDs
** QuickJS uses flat var_refs, V8 uses context chains

The pattern is clear: deval is missing EVERY feature that's universal across
production VMs. The good news is that none of these are impossible in Dart.
The bad news is that there's a lot of ground to cover.


## 7. Key Takeaways for Phase 3+

1. **Value representation is THE problem.** It affects everything -- dispatch,
   boxing, memory, GC pressure. Solving this first unlocks all other optimizations.

2. **Switch-based dispatch is low-hanging fruit.** Mechanical refactor, huge payoff.
   Do this first because it's the easiest win with the most impact.

3. **The bridge system needs a ground-up redesign.** Exception-driven dispatch,
   string-based lookup, per-call allocation, 600-line wrappers -- every aspect
   is a bottleneck. The new bridge should follow QuickJS/Wren patterns.

4. **Start with QuickJS as the architectural model.** It's the closest match to
   deval's constraints (no JIT, embeddable, small footprint). Selectively add
   Lua patterns (register-based, fixed-width) and V8 patterns (inline caches,
   feedback) where they provide clear benefits.

5. **Compile-time information is underutilized.** The compiler knows types,
   frame sizes, method sets, and call patterns. This information should flow
   to the runtime as integer IDs, sized allocations, and specialized opcodes
   rather than being discarded and re-discovered through dynamic dispatch.
