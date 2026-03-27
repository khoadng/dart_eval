# Lua VM Architecture Research
Phase: 1 | Status: COMPLETE

## Overview

Lua is widely regarded as the gold standard for embeddable virtual machines.
Its complete source code and documentation fit in 1.3 MB. The interpreter with
all standard libraries compiles to ~278K. Despite this minimal footprint, Lua
delivers performance that rivals much larger runtimes, largely due to a handful
of carefully chosen architectural decisions.

This report covers the Lua 5.4 reference VM and LuaJIT 2.1 in detail, with
focus on what matters for deval's bytecode interpreter and embedding story.

---

## 1. Instruction Format

### Register-Based VM

Lua 5.0 switched from a stack-based to a register-based VM. The key insight:
register bytecode generates fewer total instructions than stack bytecode. While
individual instructions are larger (4 bytes vs 1-2 bytes), programs compile to
significantly fewer instructions overall. The paper "The Implementation of Lua
5.0" reported roughly 37% fewer instructions for common programs.

Each instruction fits in a single 32-bit machine word. On most architectures
this means a single, predictable, branch-predictor-friendly memory fetch per
dispatch cycle. Registers are simply slots in the Lua stack array, and local
variables are allocated directly into registers. Access to locals requires no
indirection -- just an offset from the frame base pointer.

The dispatch loop is a simple while-switch:

    while (true) {
      Instruction i = *pc++;
      switch (GET_OPCODE(i)) {
        case OP_MOVE: ...
        case OP_ADD: ...
        ...
      }
    }

### 32-Bit Instruction Encoding (Lua 5.4)

Lua 5.4 uses 7 bits for the opcode (up from 6 in 5.3), supporting up to 128
opcodes. Five instruction formats exist:

    iABC:  | C (8) | B (8) | k (1) | A (8) | Op (7) |
    iABx:  |      Bx (17)          | A (8) | Op (7) |
    iAsBx: |     sBx (17, signed)  | A (8) | Op (7) |
    iAx:   |          Ax (25)             | Op (7) |
    isJ:   |          sJ (25, signed)     | Op (7) |

Field sizes and limits:

    Field   Bits   Max Value
    Op      7      127
    A       8      255 (MAXARG_A)
    B       8      255 (MAXARG_B)
    C       8      255 (MAXARG_C)
    k       1      1
    Bx      17     131071 (MAXARG_Bx)
    Ax      25     33554431 (MAXARG_Ax)
    sJ      25     33554431 (MAXARG_sJ)

Signed arguments use "excess K" encoding: the stored unsigned value minus K,
where K = MAXARG >> 1. For sBx, OFFSET_sBx = 65535.

### Format Usage

- iABC: Most instructions. Three-operand (e.g., ADD R[A] = R[B] + R[C]).
- iABx: Instructions needing a large unsigned operand (LOADK, CLOSURE).
- iAsBx: Signed offsets for loops (FORLOOP, FORPREP).
- iAx: Extra-large argument space (EXTRAARG, extends the previous instruction).
- isJ: Unconditional jumps (JMP pc += sJ).

### Operand Conventions

Every instruction has A as the destination register. This uniformity enables
elegant optimizations -- a single instruction like ADD C A B covers what would
require separate PUSH/PUSH/ADD/POP sequences in a stack VM.

Comparison instructions (EQ, LT, LE) use a skip-next-instruction pattern:

    EQ A B k    -- if ((R[A] == R[B]) ~= k) then skip next
    JMP offset  -- the jump to skip

The k bit inverts the condition, eliminating the need for separate "not-equal"
opcodes.

### Notable Lua 5.4 Opcodes (82 total)

Arithmetic with immediate/constant operands (ADDI, ADDK, SUBK, MULK, etc.)
avoid loading constants into registers first. Integer-specific comparisons
(EQI, LTI, LEI, GTI, GEI) similarly operate against small immediate values.

GETTABUP and SETTABUP combine upvalue access with table indexing in a single
instruction -- the common pattern for accessing module-level globals.

RETURN0 and RETURN1 are specialized fast-path return instructions that avoid
the overhead of general RETURN.

---

## 2. Value Representation

### Tagged Union (Standard Lua 5.4)

Every Lua value is a TValue: a Value union plus a type tag byte (tt_).

    typedef union Value {
      struct GCObject *gc;    // collectable objects
      void *p;                // light userdata
      lua_CFunction f;        // light C functions
      lua_Integer i;          // integer numbers
      lua_Number n;           // float numbers
    } Value;

    typedef struct TValue {
      Value value_;
      lu_byte tt_;
    } TValue;

The tt_ field encodes type information in 7 bits:

    Bits 0-3: primary type tag (LUA_TNIL, LUA_TBOOLEAN, etc.)
    Bits 4-5: variant bits (subtypes within a primary type)
    Bit 6:    collectable flag (BIT_ISCOLLECTABLE)

Key macros:

    makevariant(t, v)  = t | (v << 4)
    novariant(t)       = t & 0x0F
    withvariant(t)     = t & 0x3F
    ctb(t)             = t | BIT_ISCOLLECTABLE

Type variants allow fine-grained discrimination:

    Nil:      LUA_VNIL, LUA_VEMPTY, LUA_VABSTKEY
    Boolean:  LUA_VFALSE, LUA_VTRUE
    Number:   LUA_VNUMINT (integer), LUA_VNUMFLT (float)
    String:   LUA_VSHRSTR (short), LUA_VLNGSTR (long)
    Function: LUA_VLCL (Lua closure), LUA_VLCF (C function), LUA_VCCL (C closure)
    Other:    LUA_VTABLE, LUA_VTHREAD, LUA_VUSERDATA, LUA_VLIGHTUSERDATA

The boolean split into VFALSE/VTRUE means truthiness checks are a single
tag comparison with no value inspection.

### NaN Boxing (LuaJIT)

LuaJIT packs type information into the NaN space of IEEE 754 doubles. Every
TValue is exactly 8 bytes (vs 12-16 bytes in standard Lua).

IEEE 754 defines NaN as: all exponent bits set + non-zero fraction. This
leaves 51 bits in the fraction field available for encoding non-number types.

#### Non-GC64 Mode (32-bit pointers)

    Bits 63-32 (MSW): internal type tag (it)
    Bits 31-0  (LSW): GCRef, int32_t, or double's low word

    Valid double: MSW < 0xfff80000
    Tagged value: MSW >= 0xfff80000

Type tags are small negative numbers, enabling efficient comparison as
sign-extended 8-bit immediates on most architectures.

#### GC64 Mode (64-bit pointers)

    Bits 63-51: NaN marker (13 bits, all 1s = 0xfff8...)
    Bits 50-47: internal type tag (itype, 4 bits)
    Bits 46-0:  value payload (47 bits)

Payload encoding by type:
- GC objects: 64-bit pointer masked to lower 47 bits
- Integers: zero-extended 32-bit value
- Primitives: all 47 bits set to 1
- Light userdata: 8-bit segment + 39-bit offset

GC64 raises the memory limit from 2 GB to 128 TB (the low 47-bit address
space).

#### LuaJIT Type Tag Values

    LJ_TNIL      = ~0u    (0xFFFFFFFF)
    LJ_TFALSE    = ~1u
    LJ_TTRUE     = ~2u
    LJ_TLIGHTUD  = ~3u
    LJ_TSTR      = ~4u
    LJ_TFUNC     = ~8u
    LJ_TTAB      = ~11u
    LJ_TUDATA    = ~12u
    LJ_TNUMX     = ~13u

The ordering enables efficient range checks:
- itype == LJ_TISNUM for integers
- itype < LJ_TISNUM for doubles
- itype >= LJ_TISPRI for primitives (nil, false, true)

### Implications for deval

Dart has no union types and no raw memory tricks like NaN boxing. The closest
analog is a sealed class hierarchy with pattern matching, which the Dart
compiler can optimize into tag checks. The key lesson is that value
representation width directly determines cache efficiency -- every byte added
to TValue multiplies cache pressure across the entire VM.

---

## 3. Register Allocation and Stack Frame Layout

### Registers Are Stack Slots

Lua registers are not separate from the stack. They ARE the stack. Each
function call gets a contiguous slice of the stack array as its activation
record. The base pointer (ci->func + 1) marks R[0], and all register
addressing is offset from base.

    Stack layout for a call f(a, b):

    [ ... | f | a | b | local1 | local2 | temp1 | temp2 | ... ]
      ^       ^                                            ^
      ci->func ci->base (= R[0])                         ci->top

### CallInfo Structure

Each active function call has a CallInfo record:

    struct CallInfo {
      StkId func;           // function position on stack
      StkId top;            // stack ceiling for this frame
      CallInfo *previous;   // doubly-linked list
      CallInfo *next;
      union {
        struct {            // for Lua functions:
          const Instruction *savedpc;
          // ...
        } l;
        struct {            // for C functions:
          lua_KFunction k;  // continuation function
          int ctx;          // continuation context
          // ...
        } c;
      } u;
      int callstatus;       // status flags
    };

CallInfo records form a doubly-linked list, reused across calls to avoid
allocation overhead.

### Register Window Mechanism

Function calls use register windows: arguments are evaluated into successive
registers starting from the first unused register. These registers then become
the beginning of the called function's activation record. No copying is needed
for arguments -- the caller's temporaries become the callee's parameters.

    Caller's frame:
    [ ... | locals | temp | f | arg1 | arg2 | ??? ]
                           ^
                           new ci->func

    Callee's frame:
    [ ... | locals | temp | f | param1 | param2 | local1 | ... ]
                               ^
                               new ci->base = R[0]

### Local Variable to Register Mapping

The compiler assigns local variables to registers in declaration order. Since
Lua is a single-pass compiler, it tracks register allocation with a simple
counter (freereg). When a local goes out of scope, its register is freed and
can be reused by later locals. The compiler maintains that variables in scope
always occupy the lowest registers.

---

## 4. Table Implementation

### Dual Array + Hash Structure

Lua tables are the sole data structuring mechanism in the language. They serve
as arrays, dictionaries, objects, modules, and namespaces. The implementation
splits storage into two parts:

    struct Table {
      TValue *array;         // array part
      int sizearray;         // size of array part
      Node *node;            // hash part
      lu_byte lsizenode;     // log2 of hash node count
      Node *lastfree;        // pointer to last free slot
      struct Table *metatable;
      lu_byte flags;         // absent metamethod cache
      GCObject *gclist;
    };

### Array Part

Integer keys starting from 1 are candidates for the array part. Access is
O(1) by direct indexing -- no hashing required. The array part size is the
largest N such that:

1. More than half the slots between 1 and N are in use.
2. There is at least one used slot in the range (N/2+1, N].

This ensures at least 50% utilization while keeping the array as large as
possible. The algorithm counts keys in power-of-two intervals using a nums[]
array where nums[i] counts keys k satisfying 2^(i-1) < k <= 2^i, then finds
the optimal cutoff.

### Hash Part

The hash part uses an internal chained scatter table with Brent's variation.
Each Node contains:

    struct Node {
      TValue i_val;    // value
      TKey i_key;      // key (includes link to next node in chain)
    };

The main invariant: if an element is not in its main position (the slot its
hash maps to), then the element occupying that slot IS in its own main
position. This means:

- On lookup: hash the key, check main position, follow chain.
- On insert: if main position is occupied by a "squatter" (element whose main
  position is elsewhere), move the squatter and insert at the main position.

Brent's variation: when a collision occurs, the algorithm checks whether the
existing occupant can be moved to a better position, reducing average chain
length.

The lastfree pointer starts at the end of the node array and scans backward
to find free slots during insertion. This avoids a full scan of the hash part.

### Rehashing

When the hash part has no free slots, a rehash occurs:

1. Count all integer keys in both array and hash parts.
2. Compute the optimal array size using the 50% utilization rule.
3. Reallocate both parts: array part grows/shrinks, remaining keys go to hash.

Rehashing is O(n) but occurs infrequently -- the table typically doubles in
size, amortizing the cost.

### Why This Matters

The dual structure means `t[1], t[2], t[3]` is nearly as fast as a C array,
while `t["name"]` uses an efficient hash table. No other dynamic language gets
this right in a single unified data structure. Lua tables work well as arrays,
dictionaries, sparse arrays, and objects without the user needing to choose
the right container type.

---

## 5. String Interning

### Short vs Long Strings

Lua 5.3+ distinguishes two string types based on LUAI_MAXSHORTLEN (default 40):

    struct TString {
      CommonHeader;
      lu_byte extra;      // reserved words / hash state
      lu_byte shrlen;     // length for short strings
      unsigned int hash;  // hash value
      union {
        size_t lnglen;    // length for long strings
        TString *hnext;   // linked list for short string hash table
      } u;
      // string body follows immediately in memory
    };

Short strings (<= LUAI_MAXSHORTLEN):
- Interned in a global hash table (stringtable strt).
- Equality is pointer comparison -- O(1).
- Hash computed eagerly on creation via luaS_hash().
- Duplicates are detected and deduplicated.
- Dead strings in the hash table can be "resurrected" if the same string is
  created again before GC sweeps them.

Long strings (> LUAI_MAXSHORTLEN):
- NOT interned. Allocated directly.
- Hash computed lazily (only when needed, e.g., as table key).
- Equality requires memcmp -- O(n).
- This avoids the O(n) cost of hashing large strings on creation, which was a
  performance bottleneck in earlier Lua versions that interned everything.

### Hash Computation

luaS_hash() uses the string content and a global randomized seed. The seed
prevents hash-flooding attacks where an adversary crafts strings that all
collide in the hash table.

### String Cache

A recently-used string cache in the global state provides fast access to
strings that come through the C API (e.g., lua_pushstring), avoiding repeated
hash table lookups for the same string in a tight loop.

---

## 6. Closures and Upvalues

### Closure Types

    LClosure (Lua closure):
      - Proto* p          // function prototype (bytecode, constants, etc.)
      - UpVal* upvals[]   // array of upvalue pointers

    CClosure (C closure):
      - lua_CFunction f   // C function pointer
      - TValue upvalue[]  // array of upvalue values (not shared)

A Proto is a compiled function blueprint: bytecode, constants, nested protos,
debug info. One Proto can generate many closures, each with different upvalue
bindings.

### Upvalue States

An UpVal can be in two states:

Open: points to a slot on the Lua stack (the variable is still alive in its
declaring function's frame).

    struct UpVal {
      TValue *v;          // points to stack slot
      union {
        struct {
          UpVal *next;    // linked list of open upvalues
          // ...
        } open;
        TValue value;     // storage for closed upvalue
      } u;
    };

Closed: the variable has gone out of scope; its value is copied into the
UpVal's own storage and the pointer is redirected to point to it.

### Open Upvalue Linked List

All open upvalues for a thread are maintained in a linked list
(L->openupval), sorted by stack level (highest first). This enables efficient
closing: when a scope exits, luaF_close() walks the list from the top,
closing all upvalues at or above the exiting scope's stack level. The sorted
order means we can stop as soon as we hit an upvalue below the threshold.

### Upvalue Sharing

When multiple closures reference the same outer local, they share the same
UpVal object. luaF_findupval() searches the open upvalue list before creating
a new one. This ensures that if closure A modifies an upvalue, closure B sees
the change immediately.

### Flat Closure Optimization

If an outer function creates a closure and that closure only accesses the
outer function's own locals (not grandparent locals), the upvalue can be
resolved directly. For deeper nesting, intermediate functions create
"bridge" upvalues that pass through the reference chain.

### The CLOSE Instruction

Lua 5.4 added explicit CLOSE and TBC (to-be-closed) instructions. CLOSE
explicitly closes upvalues at a given stack level. TBC marks a variable
as "to be closed" (similar to defer/RAII), invoking its __close metamethod
when the variable goes out of scope.

---

## 7. Coroutines

### Implementation as lua_State

A Lua coroutine IS a lua_State -- the same structure used for the main thread.
Each coroutine has:

- Its own stack (TValue array)
- Its own CallInfo chain
- Its own savedpc and execution state
- Shared global_State with all other coroutines in the same Lua instance

Creating a coroutine (lua_newthread / coroutine.create) allocates a new
lua_State with a fresh stack, linked to the same global state.

### Asymmetric Model

Lua provides asymmetric coroutines: resume/yield pairs rather than symmetric
transfer. The caller resumes a coroutine, the coroutine yields back to the
caller. This is simpler to reason about and implement than symmetric
coroutines (which can be built on top of asymmetric ones).

### Yield and Resume Mechanics

Resume (lua_resume):
1. Validate the coroutine is in a resumable state (LUA_YIELD or new).
2. Transfer arguments from the resumer's stack to the coroutine's stack
   via lua_xmove.
3. For new coroutines: call luaD_precall + luaV_execute.
4. For suspended coroutines: restore the saved CallInfo and continue.

Yield (lua_yield):
1. Save the current execution state (pc, stack pointers).
2. Set the coroutine's status to LUA_YIELD.
3. Return control to the resumer.

Data transfer between coroutines uses lua_xmove, which copies TValues between
independent stack arrays.

### Status Codes

    LUA_OK     -- idle or completed successfully
    LUA_YIELD  -- suspended at a yield point
    LUA_ERRRUN -- runtime error (coroutine is dead)

### Cost

Coroutine creation is cheap -- just a stack allocation and lua_State init.
Context switching is cheap -- just saving/restoring a few pointers. No OS
threads, no kernel transitions, no heavy scheduling. This makes Lua coroutines
suitable for per-entity game AI, cooperative multitasking, and iterator
patterns.

---

## 8. Garbage Collection

### Tri-Color Incremental Mark-Sweep

Lua uses a tri-color marking scheme:

    White: not yet visited, potentially unreachable (candidates for collection)
    Gray:  reachable, but references not yet fully processed
    Black: reachable, all references processed

The critical invariant: a black object must never point to a white object.
Write barriers enforce this during incremental collection.

### Incremental Mode (default before 5.4)

Collection is divided into small steps interleaved with program execution,
avoiding long pauses. The GC state machine transitions through:

    GCSpause      -- waiting for next cycle
    GCSpropagate  -- marking reachable objects (gray -> black)
    GCSatomic     -- finalize marking (must complete atomically)
    GCSswpallgc   -- sweep all GC objects
    GCSswpfinobj  -- sweep finalizable objects
    GCSswptobefnz -- sweep to-be-finalized objects
    GCSswpend     -- finish sweeping
    GCScallfin    -- call finalizers (__gc metamethods)

Two parameters control pacing:
- gc_pause: how long to wait before starting a new cycle (ratio of memory).
- gc_stepmul: how much work to do per allocation step.

### Generational Mode (Lua 5.4)

New in 5.4, optimized for programs with many short-lived allocations (common
in games). Objects are segregated by age:

    G_NEW       -- created in current cycle
    G_SURVIVAL  -- survived one collection
    G_OLD0      -- caught by write barrier
    G_OLD1      -- persisted as old for one cycle
    G_OLD       -- permanently old, skipped in minor collections
    G_TOUCHED1  -- modified old object, needs revisiting
    G_TOUCHED2  -- second-generation touched

Objects must survive two GC cycles before becoming "old". This two-cycle
rule is more accurate than a single-cycle promotion and reduces false
retention.

Two collection types:
- Minor (young generation): only scans new and survival-age objects. Fast.
- Major (full): scans everything, like incremental mode. Triggered when minor
  collections don't reclaim enough memory.

### Write Barriers

Forward barrier (luaC_barrier): when a black object references a white object,
push the white object to gray. Prevents the invariant violation during
incremental marking.

Backward barrier (luaC_barrierback): when an old object references a young
object, mark the old object as "touched" so it gets revisited in the next
minor collection. Essential for generational correctness.

### Implications for deval

Dart has its own GC, so deval doesn't need to implement garbage collection.
But understanding Lua's GC design matters for two reasons: (1) write barrier
patterns affect how the VM structures object references, and (2) the
generational hypothesis (most objects die young) should inform deval's
allocation patterns.

---

## 9. LuaJIT Architecture

### Overview

LuaJIT is a trace-compiling JIT for Lua, created by Mike Pall. It achieves
performance competitive with statically-typed languages on many benchmarks.
The architecture has four main components:

1. Fast interpreter (hand-written assembly, not C)
2. Trace recorder (bytecode -> SSA IR)
3. Optimizer (on-the-fly optimizations on the IR)
4. Code generator (IR -> native machine code)

### Trace Recording

LuaJIT monitors bytecode execution and identifies "hot" loops and function
calls. When a loop back-edge or function entry exceeds a threshold, the
recorder starts capturing a trace:

1. Execute bytecode normally but emit corresponding IR instructions.
2. At branches, record the taken path (the other path becomes a "side exit").
3. A trace finishes when it: loops back to the start, returns to a lower
   call level, hits a NYI operation, or exceeds the length limit.
4. The recorded IR is then optimized and compiled to native code.

### SSA IR

The IR is in Static Single Assignment form, stored as a linear array of 64-bit
instructions. Each instruction has an opcode and at most two operands. The IR
is implicitly numbered by position (no explicit reference pointers).

The IR is unified -- it carries both high-level semantics and low-level
details. There is no separate HIR/MIR/LIR split. This reduces complexity and
compilation overhead.

Key IR characteristics:
- 2-operand-normalized form
- 23 output types (nil through u64, covering Lua types + low-level types)
- Per-opcode chaining for fast reverse searches (used by CSE, alias analysis)
- Constants grow downward in the array, other instructions grow upward

IR instruction categories:
- Constants: KPRI, KINT, KGC, KPTR, KNUM, KINT64, KSLOT
- Guards: LT, GE, LE, GT, EQ, NE, ABC, RETF
- Arithmetic: ADD, SUB, MUL, DIV, MOD, POW, NEG, ABS, FPMATH
- Memory: AREF, HREF, HREFK, NEWREF (references), ALOAD/HLOAD/ULOAD/FLOAD/
  SLOAD (loads), ASTORE/HSTORE/USTORE/FSTORE (stores)
- Allocations: SNEW, TNEW, TDUP, CNEW
- Control: PHI, RENAME, LOOP, USE

### Snapshots

Snapshots capture the bytecode-level execution state at specific points in a
trace. When a guard fails (side exit), the VM uses the most recent snapshot to
restore the interpreter state and fall back to bytecode execution.

Each snapshot records which IR instructions correspond to which stack slots.
Compression techniques minimize storage. Snapshots are the bridge between
JIT-compiled code and the interpreter -- they enable speculative optimization
with safe fallback.

### Optimization Passes

Most optimizations run on-the-fly during IR emission, not as separate passes:

- FOLD: constant folding and algebraic simplification during emission.
- CSE: common subexpression elimination via per-opcode hash chains.
- DSE: dead store elimination.
- ABC: array bounds check elimination using unsigned comparison semantics.
- SINK: allocation sinking -- defer or eliminate allocations entirely.
- LOOP: loop-specific optimizations, PHI insertion.

Eliminated instructions are either not emitted, ignored during code generation,
or tagged for removal.

### NYI (Not Yet Implemented)

Certain Lua features cannot be JIT-compiled and force a fallback to the
interpreter. Major NYI items include:

- string.dump, string.find with certain patterns
- unpack with large ranges
- Certain metamethod combinations
- next() (partially addressed in later versions)
- os.exit, io operations
- Coroutine operations in some contexts
- Table with __newindex metamethods in some patterns

LuaJIT 2.1 introduced "trace stitching" which can resume traces after a NYI
instruction executes in the interpreter, reducing the performance cliff.

### Lessons for deval

deval is an interpreter, not a JIT. But LuaJIT's architecture offers relevant
insights:
- The fast interpreter (written in assembly) shows that interpreter speed
  alone goes far. LuaJIT's interpreter is 2-5x faster than standard Lua.
- The snapshot mechanism is a clean abstraction for "bail out to safe state".
- The unified IR design (no HIR/MIR/LIR split) shows that simplicity wins.

---

## 10. C API Design

This section is the most critical for deval's plugin/embedding story.

### Core Philosophy

The Lua C API is stack-based: all communication between C and Lua happens
through a virtual stack. This design solves two impedance mismatches:

1. Lua has garbage collection, C has manual memory management. The stack
   roots all values visible to C code, so the GC knows not to collect them.
2. Lua has dynamic types, C has static types. The stack is a heterogeneous
   container that both sides can push to and pop from.

The API is minimalist. It does not validate arguments (for speed). Mistakes
cause segfaults, not error messages. This is a deliberate trade-off: the API
is small, fast, and predictable at the cost of being unforgiving.

### The Stack

    Positive indices:  1, 2, 3, ... (bottom to top)
    Negative indices: -1, -2, -3, ... (top to bottom)

    lua_gettop(L)       -- returns the index of the top element
    lua_settop(L, n)    -- sets the stack top to n (pops or pushes nils)
    lua_pushvalue(L, i) -- pushes a copy of element at index i
    lua_remove(L, i)    -- removes element at index i, shifts down
    lua_insert(L, i)    -- moves top to index i, shifts up
    lua_replace(L, i)   -- pops top and replaces element at index i

### Push/Query Protocol

C pushes values onto the Lua stack, then calls operations that consume them:

    // Set global "x" to 42
    lua_pushinteger(L, 42);
    lua_setglobal(L, "x");

    // Get t["key"]
    lua_getglobal(L, "t");    // push t
    lua_getfield(L, -1, "key"); // push t["key"]

    // Set t["key"] = "value"
    lua_getglobal(L, "t");
    lua_pushstring(L, "value");
    lua_setfield(L, -2, "key");

### Calling Lua from C

    lua_getglobal(L, "myfunction");  // push function
    lua_pushinteger(L, 10);          // push arg 1
    lua_pushstring(L, "hello");      // push arg 2
    lua_pcall(L, 2, 1, 0);          // call with 2 args, 1 result
    int result = lua_tointeger(L, -1); // get result
    lua_pop(L, 1);                   // clean up

lua_pcall is a protected call -- errors are caught and returned as status
codes rather than longjmp'ing. lua_call is unprotected (faster but unsafe).

### Calling C from Lua

C functions exposed to Lua have this signature:

    typedef int (*lua_CFunction)(lua_State *L);

The function receives arguments on the stack (index 1, 2, ...), pushes return
values, and returns the count of return values as the int return.

    static int l_add(lua_State *L) {
      double a = luaL_checknumber(L, 1);
      double b = luaL_checknumber(L, 2);
      lua_pushnumber(L, a + b);
      return 1;  // one return value
    }

Registration:

    lua_pushcfunction(L, l_add);
    lua_setglobal(L, "add");

### Pseudo-Indices

Special index values that don't correspond to stack positions:

- LUA_REGISTRYINDEX: the global registry table (shared across all C code).
- lua_upvalueindex(n): the n-th upvalue of the current C closure.

### The Registry

A regular Lua table accessible only from C, used for:
- Storing references that must survive across function calls.
- Sharing data between C libraries.
- Implementing the reference system.

Best practice: use the address of a C static variable as a light userdata key.
The C linker guarantees uniqueness across all libraries.

    static const char KEY = 'k';
    lua_pushlightuserdata(L, (void *)&KEY);
    lua_pushinteger(L, 42);
    lua_settable(L, LUA_REGISTRYINDEX);

### Reference System

luaL_ref(L, t) pops a value from the stack, stores it in table t, and returns
an integer reference. luaL_unref(L, t, ref) releases the reference. This is
the standard way to prevent GC from collecting a Lua object that C code holds.

### C Closures and Upvalues

C functions can have associated upvalues (like static variables per-closure):

    // Create a counter closure
    lua_pushinteger(L, 0);           // initial upvalue
    lua_pushcclosure(L, counter, 1); // 1 upvalue
    lua_setglobal(L, "counter");

    static int counter(lua_State *L) {
      int n = lua_tointeger(L, lua_upvalueindex(1));
      lua_pushinteger(L, ++n);
      lua_replace(L, lua_upvalueindex(1));
      lua_pushinteger(L, n);
      return 1;
    }

Unlike Lua closures, C closures do NOT share upvalues. Each closure gets
independent copies. Sharing requires using a table as the upvalue.

### Userdata

Full userdata: a block of memory managed by Lua's GC, with an associated
metatable. Created with lua_newuserdata(L, size). This is how C structures
are exposed to Lua as first-class objects with methods, metamethods, and
automatic cleanup (__gc).

Light userdata: a raw void* pointer. No GC, no metatable. Used for opaque
handles and registry keys.

### Error Handling

Lua errors use longjmp (setjmp/longjmp in C, exceptions in C++). This means:
- lua_pcall sets up a recovery point.
- luaL_error triggers a longjmp to the nearest pcall.
- C code between pcall and the error must not hold resources that need
  explicit cleanup (or must use to-be-closed variables in Lua 5.4).

### Why The Stack-Based Design Works

1. No reference counting. C code never owns Lua objects -- the stack roots
   them. When you pop a value, you release your hold on it. The GC handles
   the rest. Contrast with Python's API where every PyObject* needs manual
   incref/decref.

2. No type casting. Every value on the stack is a Lua value. C code queries
   it with type-checking functions. No unsafe casts, no generic void pointers
   for every operation.

3. Natural argument passing. Function arguments are just stack values.
   Variable arguments, multiple return values, and error objects all use the
   same stack mechanism.

4. Minimal surface area. The entire API is ~120 functions. Most operations
   are combinations of push + operation + pop. This makes the API easy to
   learn and hard to get fundamentally wrong.

5. No ABI fragility. The stack is an opaque abstraction. Internal TValue
   layout can change between versions without breaking C code. The API
   functions are the only interface.

### Implications for deval

deval's embedding interface should learn from Lua's C API:

- Stack-based value exchange eliminates ownership complexity. The host pushes
  values, deval processes them, results appear on the stack.
- Pseudo-indices are elegant: the registry, upvalues, and globals all use
  the same indexing abstraction.
- The reference system (luaL_ref) is a clean solution for preventing GC of
  objects held by the host.
- C closures with upvalues enable stateful callbacks without global state.
- Userdata with metatables is how Lua exposes host-side objects to scripts
  with full OOP support and automatic cleanup.
- The ~120 function surface area is achievable. Resist the temptation to
  add convenience wrappers to the core API.

---

## 11. Compiler Optimizations

### Single-Pass Compiler

Lua's compiler is single-pass: it generates bytecode directly during parsing,
with no AST intermediate. This makes compilation fast (important for a
language that compiles source at load time), but limits optimization
opportunities.

### Constant Folding

The compiler performs constant folding for arithmetic operators (+, -, *, /,
%, ^, unary -) and logical not. If both operands are constants, the result is
computed at compile time and emitted as a constant load.

    local x = 2 + 3        -- compiles to LOADI 5
    local y = math.pi * 2  -- NOT folded (math.pi is a table access)

### Dead Code After Return

Code after a return statement in the same block is not emitted. The compiler
tracks the "block follows return" state and skips code generation.

### Conditional Constant Propagation

The compiler can detect `if true then ... end` and `if false then ... end`
patterns, eliminating dead branches.

### What Lua Does NOT Do

- No global optimization passes (no SSA, no data flow analysis).
- No function inlining.
- No loop unrolling.
- No escape analysis.
- No register coalescing beyond scope-based reuse.

The philosophy is: keep the compiler simple and fast, let the programmer write
clear code, and if you need more performance, use LuaJIT.

### Luau Extensions

Roblox's Luau fork adds multi-pass compilation with three optimization levels:
- Level 0: minimal (debugging).
- Level 1 (default): constant folding, upvalue optimization, peephole.
- Level 2: function inlining, loop unrolling.

This shows what's possible when you add compilation passes while keeping the
language semantics identical.

---

## 12. Why Lua Is The Gold Standard

### Minimal Surface, Maximum Leverage

Lua has one data structure (tables), one scope mechanism (lexical closures),
one concurrency primitive (coroutines), and one extension mechanism
(metatables). Each is implemented excellently. The entire language spec fits
in a few dozen pages.

### Embeddability

- 278K compiled size. Fits on microcontrollers.
- Pure ANSI C. Compiles everywhere C compiles.
- The C API is the actual interface, not an afterthought bolted onto a
  standalone language. Lua was designed to be embedded from day one.
- No global state. Multiple independent Lua states can coexist in one process.
- Deterministic: no JIT warmup, no background threads, no hidden I/O.

### Performance Per Complexity

Lua achieves remarkable performance for its complexity budget:
- Register-based VM with 32-bit instructions.
- Efficient tagged values.
- Table implementation that adapts to usage patterns.
- Interned strings with O(1) equality.
- Cheap coroutines.
- Incremental GC with generational mode.

No single technique is novel. The achievement is getting ALL of them right
in a coherent, minimal design.

### Track Record

- Game industry standard (World of Warcraft, Roblox, LOVE2D, Defold).
- Embedded systems (OpenWrt, Redis, Nginx/OpenResty, Adobe Lightroom).
- Scientific computing (Torch, early days).
- 30+ years of production use, backward compatibility, and API stability.

### What deval Should Take From Lua

1. The embedding API is the product. Internal cleverness means nothing if the
   host integration is painful.
2. One data structure done well beats five done adequately.
3. 32-bit fixed-width instructions with register-based dispatch are the right
   default for a bytecode interpreter.
4. Value representation width is the single biggest performance lever.
5. The compiler should be fast and simple. Optimization belongs in the runtime
   (or a separate JIT pass), not the compiler.
6. Small is a feature. Every API function, every opcode, every type tag should
   earn its place.
