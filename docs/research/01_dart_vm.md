# Dart VM Architecture Research
Phase: 1 | Status: COMPLETE

## 1. Compilation Pipeline

### 1.1 Source to Kernel

Dart source never reaches the VM directly. The Common Frontend (CFE), written
in Dart, parses source into a Kernel AST and serializes it as a `.dill` file
(kernel binary). The standalone `dart` executable hosts a helper "kernel
service" isolate that handles this transparently.

Kernel is not bytecode. It is a serialized, high-level AST derived from a
small intermediary language. Nodes map closely to Dart language constructs
(classes, procedures, expressions, statements, types). The VM consumes this
AST and compiles it further.

### 1.2 Kernel Loading and Lazy Deserialization

The VM parses the kernel binary lazily. On load, only top-level library and
class skeletons are created. Each entity retains a pointer back into the
binary so members and function bodies can be deserialized on demand. Function
bodies are only read when a function is first invoked or compiled.

### 1.3 Unoptimized Compilation (JIT First Tier)

Two passes:

1. **CFG construction.** Walk the serialized AST to build a control flow graph
   (CFG) of basic blocks. Each block is filled with intermediate language (IL)
   instructions resembling a stack machine: operands are pushed/popped, results
   pushed back.

2. **Direct lowering.** Each IL instruction expands one-to-many into native
   machine code. No optimization passes are applied. All calls compile as
   fully dynamic (inline-cached) regardless of static type information.

The purpose of the unoptimized tier is to start executing quickly while
collecting type feedback for later optimization.

### 1.4 Optimizing Compilation (JIT Second Tier)

Functions whose execution counters exceed a threshold are submitted to the
background optimizing compiler. The pipeline:

1. Rebuild unoptimized IL from the Kernel AST.
2. Convert to SSA (static single assignment) form.
3. Speculative specialization using collected type feedback from inline caches.
4. Optimization passes (in rough order):
   - Inlining (heuristic based on caller/callee size, call count, loop depth)
   - Type propagation on the dominator tree
   - Range analysis
   - Representation selection (choose unboxed representations for numerics)
   - Store-to-load and load-to-load forwarding
   - Global value numbering
   - Allocation sinking (escape analysis eliminates heap allocations)
   - Constant folding and propagation
5. Linear scan register allocation.
6. Machine code generation (one-to-many lowering of optimized IL).

The `@pragma("vm:prefer-inline")` annotation overrides the inlining heuristic
and forces inlining when possible.

### 1.5 AOT Compilation

AOT replaces speculative optimization with global static analysis:

- **Type Flow Analysis (TFA)** traces the entire program to determine
  reachable code, allocated classes, and type flows. All analysis is
  conservative (errs toward correctness).
- Whole-program compilation. No speculative guards needed because TFA results
  are sound. No deoptimization infrastructure.
- Produces an AOT snapshot containing precompiled machine code for all
  reachable functions. Executed by a stripped "precompiled runtime" that lacks
  the compiler and dynamic code loading.

AOT code reaches near-peak performance immediately with no warmup.

### 1.6 Snapshots

The VM serializes heap object graphs into snapshots for fast startup. The
format is low-level: a list of objects to create and instructions on how to
connect them.

**Clustered serialization.** Objects are grouped by class (cluster). Type
information is written once per cluster instead of once per object.
Serialization has three stages: Trace (BFS to discover reachable objects and
assign them to clusters), Alloc (write allocation counts per cluster), Fill
(write field values). Deserialization reverses this: allocate all objects by
cluster counts, then fill fields. Reference IDs are assigned sequentially
during alloc, used during fill.

Three snapshot kinds:

- **Kernel snapshot.** Serialized Kernel AST (the .dill file itself).
- **AppJIT snapshot.** Captures JIT-compiled code after a training run.
  Amortizes compilation cost; JIT remains available at runtime for divergent
  profiles.
- **AppAOT snapshot.** Pre-compiled machine code, no JIT at runtime.


## 2. Kernel Binary Format (Dill)

### 2.1 Encoding

- Magic number: `0x90ABCDEF`
- Variable-length unsigned integers:
  - UInt7: 1 byte, high bit 0 (values 0-127)
  - UInt14: 2 bytes, prefix `10` (discard high bit)
  - UInt30: 4 bytes, prefix `11` (discard two high bits)
  - UInt32: big-endian fixed 32-bit

### 2.2 Top-Level Structure (ComponentFile)

- 10-byte SDK hash
- Problem/diagnostic list (JSON strings)
- Array of Library definitions
- UriSource (source map with file references)
- List of Constants (constant pool)
- Reverse list of constant mappings
- List of CanonicalName entries (hierarchical name tree)
- Metadata payloads and mappings
- StringTable (WTF-8 encoded, indexed by end-offsets)
- ComponentIndex (fixed-size UInt32 offsets for random access)

### 2.3 Canonical Names

Tree-structured references. Each entry stores a parent index (biased: 0 for
null, N+1 for parent at index N). This encodes the full qualified name
hierarchy (library -> class -> member) without repeating prefixes.

### 2.4 Libraries

Each library contains flags (synthetic, NNBD mode, unsupported), language
version (major/minor), canonical name, URI, dependencies, parts, typedefs,
classes, extensions. Libraries include index tables with byte offsets for
classes and procedures, enabling selective parsing.

### 2.5 Classes

Tag byte 2. Contains: canonical name, file URI, offsets, flags (abstract,
enum, mixin, sealed, base, interface, final), type parameters, superclass,
mixins, implemented interfaces, fields, constructors, procedures. Each with
indexed byte offsets.

### 2.6 Procedures

Tag byte 6. Kind enum: method, getter, setter, operator, factory. Includes
stub kind, function signature, body, flags (static, abstract, external,
synthetic).

### 2.7 Expressions

Specialized tags for common patterns:

- Integer literals have tags 240-247 for values -3 to 4 (single byte encoding)
- Variable get/set, tear-off
- Static/instance/dynamic/super/constructor invocations
- Collection literals (list, set, map, record) with const variants
- Control: conditional, logical, null-coalescing, await
- Function expressions, block expressions, pattern matching

### 2.8 Statements

Expression statements, blocks, if/while/do-while/for/for-in/async-for-in,
switch (with pattern support), try-catch-finally, return/break/continue,
variable/function declarations, assert.

### 2.9 Types

DartType variants: dynamic, void, null, never, interface types (with
nullability: nullable=0, nonNullable=1, neither=2), function types (with
positional/named parameters), type parameter references (index-based),
intersection types, extension types, record types, FutureOr.

### 2.10 Constants

Null, bool, int, double, string, symbol, type literal, list, set, map,
record, instance constants (with field values), static/constructor tear-offs,
instantiation constants, unevaluated expressions.

### 2.11 Metadata

Backend-specific metadata sections. Tools attach arbitrary payloads to AST
nodes through tag-based mappings (node offset -> metadata offset in payload
array).


## 3. Object Model

### 3.1 Tagged Pointers

Every value in the Dart VM is either an immediate (unboxed) value or a pointer
to a heap object. The low bit of the machine word distinguishes them:

- **Tag 0 (LSB = 0): Smi.** The upper bits are the integer value. No heap
  allocation. A tag of 0 means many arithmetic operations work directly on
  the tagged representation without untagging.
- **Tag 1 (LSB = 1): Heap object pointer.** The upper bits are the address
  (aligned, so LSB is naturally 0; the tag replaces it). A tag of 1 has no
  access penalty because the offset in load/store instructions absorbs the
  -1 adjustment.

On 64-bit platforms, Smi holds a 63-bit signed integer. On 32-bit, 31-bit.

### 3.2 Heap Object Layout

All heap objects are allocated in double-word increments. The layout:

- **Header (1 machine word).** Contains:
  - ClassIdTag: index into the class table identifying the object's Dart class
  - Size information
  - GC status flags (mark bit, remembered bit, etc.)
  - On 64-bit: 32-bit identity hash embedded in the header
  - On 32-bit: identity hash stored in a separate hash table

- **Fields.** Zero or more slots following the header. Each slot is a tagged
  pointer (Smi or heap object reference).

### 3.3 Alignment for GC Age Detection

- Old-space objects: address % (2 * word_size) == 0
- New-space objects: address % (2 * word_size) == word_size

This lets the GC check an object's generation by examining alignment alone,
without comparing against heap boundary addresses.

### 3.4 Class Hierarchy and Class IDs

Every loaded Dart class gets a numeric class ID (CID). The CID is stored in
every instance's header. The VM maintains a class table indexed by CID.

For AOT, class IDs are assigned via depth-first traversal of the class
hierarchy. This makes subtype ranges contiguous: checking if an object is an
instance of class C or any subclass reduces to a range check on the CID
(cid >= C_first && cid <= C_last).

### 3.5 Internal VM Object Split

The VM splits object definitions:

- `class Xyz` in `runtime/vm/object.h`: C++ methods (API for manipulating
  the object from C++ code)
- `class UntaggedXyz` in `runtime/vm/raw_object.h`: memory layout (field
  offsets, sizes, the actual shape in memory)

This separation keeps the C++ interface clean while the raw layout stays
cache-friendly and GC-traversable.


## 4. Dispatch Mechanisms

### 4.1 Inline Caching (JIT)

The VM does not use vtables or itable dispatch. Instead, every call site has
an associated `UntaggedICData` object. This cache maps receiver class ->
target method, along with invocation frequency counters.

On a call:
1. A shared lookup stub searches the ICData for a matching receiver class.
2. Cache hit: jump to the cached method.
3. Cache miss: runtime resolution adds the new (class, method) entry and
   invokes it.

The ICData accumulates type feedback. When the optimizing compiler processes
the function, it reads the ICData to speculate about receiver types and
devirtualize calls.

ICData states by polymorphism:
- Monomorphic: single receiver class. Fastest path.
- Polymorphic: small number of classes. Checked linearly.
- Megamorphic: too many classes. Falls back to hash-based lookup.

### 4.2 Global Dispatch Table (AOT)

For non-dynamic calls in AOT, the compiler builds a global dispatch table
(GDT). Each selector (method name + arity) gets an offset into the table.
Table rows are indexed by CID. Selector rows interleave to compress the table
and reuse holes.

Call instruction sequence (x64):
```
movzx cid, word ptr [obj + 15]       ; load CID from object header
call [GDT + cid * 8 + (selectorOffset - 16) * 8]
```

The GDT pointer is biased so small selector offsets use compact instruction
encoding.

### 4.3 Switchable Calls (AOT Dynamic Dispatch)

For calls with dynamic receivers in AOT, call sites are "switchable" --
they transition through states as execution patterns emerge:

1. **Unlinked.** Initial state. Calls SwitchableCallMissStub for resolution.
2. **Monomorphic.** Direct call to single observed class with CID verification
   at entry.
3. **Single target.** If the method applies to a contiguous CID range (from
   depth-first numbering), a range check replaces class-id equality.
4. **Linear inline cache.** Small number of (class, method) pairs, checked
   iteratively.
5. **Megamorphic.** Hash-based dictionary for highly polymorphic sites.

Each transition happens automatically as new receiver classes appear.


## 5. Deoptimization

### 5.1 Eager Deoptimization

Guard instructions (CheckSmi, CheckClass) inserted before speculative code
verify assumptions at runtime. If the check fails, execution transfers
immediately to the corresponding point in the unoptimized version of the
function.

### 5.2 Lazy Deoptimization

When the VM detects that a global assumption is invalidated (e.g., a new
subclass is loaded that breaks class hierarchy assumptions), it marks affected
optimized frames on the stack for deoptimization. When execution returns to
those frames, they deoptimize lazily.

### 5.3 Deoptimization Infrastructure

Deoptimization instructions describe how to reconstruct the unoptimized
function's state (locals, stack, PC) from the optimized function's state.
A mini-interpreter executes these instructions during the transition.

After deoptimization, the VM usually discards the optimized code and later
reoptimizes with updated type feedback.


## 6. Generics and Type Reification

### 6.1 Reification Strategy

Dart reifies generic types: type arguments are preserved at runtime and
available for `is`/`as` checks. This contrasts with Java's type erasure.

### 6.2 TypeArguments Vectors

Each generic instance stores a `type_arguments` field at a known offset. This
field points to a `TypeArguments` object -- a vector of `AbstractType` values.

### 6.3 Flattening

The VM flattens type argument vectors across the class hierarchy. For a class
`C<T>` extending `B<List<T>>`, instances of C store `[List<T>, T]` rather
than just `[T]`. This way the same vector works correctly when the object is
viewed as a B or as a C. Each type parameter is assigned an index into this
flat vector.

### 6.4 Overlapping Optimization

When type arguments repeat (e.g., `C<T> extends B<T>`), the vector can be
collapsed: `[T, T]` becomes `[T]` with both parameters sharing index 0.

### 6.5 Null Vector Optimization

A null type_arguments pointer implies a vector of `dynamic` of the correct
length. This was common in Dart 1 and the optimization persists.

### 6.6 Function Type Arguments

For generic functions, type arguments are concatenated from outermost to
innermost enclosing generic function. An `InstantiateFrom` method takes both
instantiator type arguments (from the receiver) and function type arguments
to substitute type parameters.

### 6.7 Type Representation Hierarchy

- `AbstractType` (base)
  - `Type`: simple types with class_id, arguments, nullability, hash, state
  - `FunctionType`: full function signatures (type params, bounds, result,
    positional/named params)
  - `TypeParameter`: index-based reference to a declared type parameter
  - `TypeRef`: breaks cycles in recursive type graphs

### 6.8 Canonicalization

Types are hash-consed (canonicalized). A global table maps hash codes to
canonical type instances. Once canonicalized, type equality reduces to pointer
comparison. TypeRef nodes use only local information for hashing to avoid
infinite recursion on cyclic type graphs.

### 6.9 Cached Instantiations

Repeated instantiations of the same TypeArguments vector from the same
instantiator are cached as 3-tuples in the TypeArguments object. When
instantiation produces one of the input vectors unchanged, the VM skips
instantiation entirely.


## 7. Closures

### 7.1 Representation

A closure in the Dart VM is an instance of the `Closure` class. It contains:
- A pointer to the function (code) it wraps
- A context object holding captured variables
- Type arguments for generic closures

When the instance's class is `Closure`, the runtime type is not `Closure`
but the function type representing the signature.

### 7.2 Context Objects

A `Context` is a variable-sized heap object containing:
- A pointer to the enclosing (parent) context
- An array of captured variable slots

Closures defined in the same scope share the same context. Nested scopes
create a chain of context objects linked through parent pointers.

### 7.3 Overcapturing

The VM currently shares a single context per scope, which means closures may
capture variables they do not actually reference (overcapturing). This is a
known trade-off: simpler implementation at the cost of potentially keeping
objects alive longer than necessary.

### 7.4 Non-Capturing Closures

Closures that capture no variables still allocate a Closure object but can
avoid context allocation entirely. There have been ongoing optimizations to
reduce allocation overhead for non-capturing closures.


## 8. Async/Await

### 8.1 Suspension Mechanism

Suspendable functions (async, async*, sync*) use a `SuspendState` heap
object to save and restore execution state across suspension points.

SuspendState is a variable-size allocation containing:
- Fixed header
- The complete stack frame (locals, spill slots, expression stack)
- The program counter where execution was suspended
- GC metadata (the stored PC lets GC locate pointers in the saved frame)

A single SuspendState is allocated on first suspension and reused for
subsequent suspensions in the same function invocation.

### 8.2 Frame Management

Key constraints:
- Suspendable functions are never inlined into other functions (prevents
  state mixing with callers).
- Parameters are copied into the local frame in the prologue to create a
  contiguous region for save/restore.
- An artificial `:suspend_state` variable lives at a fixed frame offset.

During suspension, the region between FP and SP is copied into the
SuspendState payload. During resumption, it is copied back.

### 8.3 Stub Architecture

Four specialized machine code stubs:

1. **InitSuspendableFunction.** Runs in the prologue. Calls a Dart helper
   to initialize function-specific data (e.g., creates a `_Future<T>` for
   async functions). Stores result in `:suspend_state`.

2. **Suspend.** At each await/yield point:
   - Allocates or reuses SuspendState
   - Saves return address as resumption PC
   - Copies active frame into SuspendState payload
   - Triggers write barriers if crossing generational boundaries
   - Calls a customization Dart method (e.g., `_SuspendState._await`)
   - Returns the method's result to the caller

3. **Resume.** Tail-called from `_SuspendState._resume`:
   - Allocates a new frame using stored frame_size
   - Restores frame contents from SuspendState
   - Checks for exception resumption, deoptimization, or debugger breakpoints
   - Jumps to stored PC to continue execution

4. **Return.** Handles cleanup (e.g., completing a Future):
   - Removes the function frame
   - Calls a type-specific Dart method
   - Returns the result

### 8.4 Future Wiring

For async functions:
- `InitAsync` creates a `_Future<T>` as the return value.
- `_SuspendState._await` lazily creates then/error callbacks on first await.
- If the awaited value is a Future, callbacks attach to it.
- If not a Future, a microtask schedules continuation.
- When the Future completes, callbacks invoke the Resume stub.
- `_returnAsync` completes the original Future when the body finishes.

### 8.5 Optimizations

- Callback closures created lazily (only on first await, not at init).
- `ReturnAsyncNotFuture` fast path when compiler proves the return value
  is not a Future.
- x64/ia32 maintain call/return stack balance with an epilogue after Suspend.

### 8.6 Exception Handling

Async functions set a `has_async_handler` bit on their ExceptionHandlers.
The `AsyncExceptionHandler` stub intercepts uncaught exceptions and routes
them through `_SuspendState._handleException` to propagate errors via the
Future mechanism.


## 9. Garbage Collection

### 9.1 Generational Architecture

Two generations:
- **New space.** Collected by a parallel, stop-the-world semispace scavenger.
- **Old space.** Collected by concurrent-mark-concurrent-sweep or
  concurrent-mark-parallel-compact.

### 9.2 Scavenger (New Space)

Implements Cheney's algorithm with parallel workers (default 2 threads).

- Two semispaces: from-space and to-space.
- Workers process roots in parallel, copying live objects to to-space using
  worker-local bump allocation.
- Forwarding pointers installed via compare-and-swap in the from-space header.
  If a worker loses the CAS race, it un-allocates its copy and uses the
  winner's pointer.
- Promoted objects (survived enough scavenges) go to old space via
  worker-local freelist allocation. Promoted objects added to a work-stealing
  list for load balancing.

### 9.3 Mark-Sweep (Old Space)

**Marking.** If target is old-space and mark bit is clear, set mark bit and
add to marking stack (grey set). All new-space objects are treated as roots
(not marked), making the two spaces independent.

**Sweeping.** Walk old-space objects. Unmarked objects are added to a free
list. Marked objects have their mark bit cleared. Pages where every object
is unreachable are released to the OS.

### 9.4 Concurrent Marking

The marker runs concurrently with mutators. Synchronization:
- Marking starts with acquire-release fence so all prior mutator writes are
  visible.
- Objects allocated during marking are allocated "black" (pre-marked) so the
  marker won't visit them.
- Write barriers prevent the marker from missing newly-stored references.

### 9.5 Mark-Compact (Sliding Compactor)

Forwarding table is compact: heap divided into blocks, each block stores a
target address and a bitvector of surviving double-words. Heap pages are
kept aligned for constant-time table access. Objects slide toward lower
addresses to eliminate fragmentation.

### 9.6 Write Barriers

Combined generational + incremental barrier using bit manipulation on the
header:

```
Generational check:
  if (source.IsOldObject() && !source.IsRemembered() && target.IsNewObject())
    source.SetRemembered(); AddToRememberedSet(source);

Incremental marking check:
  if (source.IsOldObject() && target.IsOldObject() && !target.IsMarked())
    MarkTarget(target);
```

Header bits (kOldAndNotMarkedBit, kNewBit, kOldBit, kOldAndNotRememberedBit)
are combined with a shift-and-mask into a single check.

### 9.7 Write Barrier Elimination

Compiler eliminates barriers when provably unnecessary:
- Value is a constant, Smi, or bool
- Container is a self-reference
- Container was recently allocated (no GC possible between alloc and store)
- Container known to be in remembered set / already marked

### 9.8 Allocation

- New-space: bump allocation (fast path, no locking per thread).
- Old-space: free-list allocation. Large free blocks use bump allocation
  within the block. Workers use thread-local freelists.

### 9.9 Safepoints

A mutator at a safepoint must not hold raw heap pointers that the GC cannot
find. Safepoints are required for GC pauses, snapshot creation, and
installation of compiler results. A mutator can be at a safepoint without
being suspended (e.g., doing non-heap I/O).

### 9.10 Finalization

`FinalizerEntry` holds weak references to value, detach key, and finalizer.
When the value is collected, the entry is added to a collected list. Parallel
tasks use atomic exchange on the list head. For native finalizers, the
callback is invoked immediately during GC.


## 10. Isolates

### 10.1 Structure

- `dart::Isolate`: represents a single isolate.
- `dart::IsolateGroup`: groups isolates sharing a managed heap.
- `dart::Heap`: the isolate group's heap.

### 10.2 Memory Model

Isolates within a group share the same GC-managed heap. Despite this, they
cannot share mutable state directly. Communication is exclusively through
message passing via ports. Immutable objects can be shared by reference.

### 10.3 Threading

An OS thread can enter only one isolate at a time. Each isolate has one
mutator thread executing Dart code, plus helper threads for background
compilation, GC, and concurrent marking.

The default event loop does not spawn a dedicated thread. Instead, a
`dart::MessageHandlerTask` is posted to a thread pool when a new message
arrives.

### 10.4 Isolate Group Benefits

Isolates in the same group share code, class tables, and other read-only
data. Creating a new isolate within an existing group is fast and
memory-efficient.


## 11. Performance Tricks

### 11.1 Smi Fast Paths

Arithmetic on Smis (tag 0) often works without untagging. Addition of two
Smis is a single machine add (the tag bits cancel out). Overflow checks
detect when the result exceeds the Smi range.

CheckSmi guards inline a fast path for tagged integers with a slow path for
boxed values, null, or operator overrides.

### 11.2 Unboxing

TFA can prove that numeric variables are non-nullable, enabling unboxed
inline representation. The compiler's representation selection pass chooses
between tagged (Smi), unboxed int64, or unboxed double for each SSA value.
Unboxing avoids heap allocation for intermediate numeric computations.

Current heuristics are conservative: integer variables unbox only when all
reaching values are boxing operations or constants.

### 11.3 Inlining Heuristics

The compiler decides whether to inline based on:
- Caller and callee size (instruction count)
- Number of call sites in the callee
- Loop nesting depth in the caller
- Invocation frequency from type feedback

`@pragma("vm:prefer-inline")` forces inlining.

### 11.4 Allocation Sinking

Escape analysis determines if an object's reference escapes the allocating
function. If it does not escape, the allocation is sunk (eliminated) and
fields are replaced with local variables. This is critical for value types
like points or vectors that are transiently constructed.

### 11.5 Global Object Pool

The VM uses a single global object pool (GOP) rather than per-function pools.
This reduces calling convention overhead and simplifies constant access.

### 11.6 Depth-First CID Numbering

Class IDs are assigned via depth-first traversal of the class hierarchy. This
makes subclass ranges contiguous, enabling subtype checks with a single range
comparison rather than a table lookup.

### 11.7 Selector Row Interleaving (AOT)

In the global dispatch table, selector rows are interleaved to fill holes,
compressing the table. The GDT pointer is biased so frequently-used selectors
with small offsets get compact instruction encoding.


## 12. Key Source Files

All paths relative to the dart-lang/sdk repository:

| Path | Purpose |
|------|---------|
| `runtime/vm/object.h` | C++ methods for VM objects |
| `runtime/vm/raw_object.h` | Memory layout of VM objects |
| `runtime/vm/object.cc` | Object implementation |
| `runtime/vm/dart.cc` | Core VM initialization |
| `runtime/vm/isolate.h/cc` | Isolate and IsolateGroup |
| `runtime/vm/heap/` | GC, scavenger, marker, compactor |
| `runtime/vm/compiler/` | Compiler pipeline (frontend, backend, JIT, AOT) |
| `runtime/vm/compiler/frontend/` | Kernel-to-IL translation |
| `runtime/vm/compiler/backend/` | Optimization passes, codegen |
| `runtime/vm/compiler/jit/` | JIT-specific passes |
| `runtime/vm/compiler/aot/` | AOT-specific passes (TFA, dispatch table) |
| `runtime/vm/app_snapshot.cc` | Snapshot serialization/deserialization |
| `runtime/vm/clustered_snapshot.h/cc` | Clustered snapshot format |
| `runtime/vm/class_id.h` | Class ID definitions |
| `runtime/vm/stub_code_*.cc` | Architecture-specific stubs |
| `runtime/vm/megamorphic_cache_table.cc` | Megamorphic dispatch cache |
| `pkg/kernel/binary.md` | Kernel binary format specification |
| `pkg/kernel/` | Kernel AST definitions (Dart) |
| `runtime/docs/gc.md` | GC documentation |
| `runtime/docs/async.md` | Async/await implementation docs |
| `runtime/docs/types.md` | Type representation docs |


## 13. Implications for deval

Key lessons from the Dart VM architecture relevant to building an interpreter:

1. **Kernel is the input format.** If deval consumes .dill files, it gets the
   same input the VM uses. The binary format is well-documented and stable.
   Lazy deserialization is essential for startup performance.

2. **Tagged pointers are non-negotiable for perf.** The Smi optimization
   (tag 0 = integer, tag 1 = heap pointer) eliminates allocation for the
   most common value type. Any interpreter should consider a similar scheme.

3. **Inline caching is the standard dispatch strategy.** The VM avoids
   vtables entirely in JIT mode. For an interpreter, even a simple
   monomorphic inline cache (last-seen class + method) at each call site
   dramatically reduces dispatch overhead.

4. **Type argument flattening simplifies generic access.** Rather than
   walking the class hierarchy to find type arguments, a flat vector at a
   fixed offset gives O(1) access at any hierarchy level.

5. **Async/await is frame serialization.** The SuspendState approach (copy
   frame to heap, copy back on resume) is clean and avoids CPS
   transformation of the AST. An interpreter can implement this with a
   similar save/restore of its virtual frame.

6. **Context chains for closures.** The VM's per-scope context with parent
   pointers is simple to implement. Overcapturing is an accepted trade-off
   for implementation simplicity.

7. **Generational GC pays off.** Most objects are short-lived. A simple
   two-space scavenger for young objects with promotion to an old space
   is the minimum viable GC strategy.

8. **Constant pool is per-component, not per-function.** The kernel binary
   stores constants at the component level. An interpreter's constant pool
   should mirror this structure.


## Sources

- [Dart VM (mrale.ph)](https://mrale.ph/dartvm/)
- [Dart VM Types (mrale.ph)](https://mrale.ph/dartvm/types.html)
- [Dart VM GC (mrale.ph)](https://mrale.ph/dartvm/gc.html)
- [Dart VM Async (mrale.ph)](https://mrale.ph/dartvm/async.html)
- [Introduction to Dart VM (googlesource)](https://dart.googlesource.com/sdk/+/refs/tags/2.16.0-91.0.dev/runtime/docs/index.md)
- [GC Documentation (googlesource)](https://dart.googlesource.com/sdk/+/refs/tags/2.15.0-99.0.dev/runtime/docs/gc.md)
- [Type Representation (googlesource)](https://dart.googlesource.com/sdk/+/9076b6a76a5c4e7a933002c2e6b8e3d3f8fdf03f/runtime/docs/types.md)
- [Kernel Binary Format (github)](https://github.com/dart-lang/sdk/blob/main/pkg/kernel/binary.md)
- [Dart SDK Runtime (github)](https://github.com/dart-lang/sdk/tree/main/runtime)
- [10 Years of Dart (mrale.ph)](https://mrale.ph/talks/vmil2020/)
- [Rebuilding Optimizing Compiler for Dart](https://devblogs.sh/posts/rebuilding-optimizing-compiler-for-dart-by-vyacheslav-egorov)
- [Building Optimising Compiler for Dart (2013)](https://devblogs.sh/posts/building-optimising-compiler-for-dart-by-vyacheslav-egorov-2013)
- [Dart VM Closure Issue #36983](https://github.com/dart-lang/sdk/issues/36983)
- [Dart VM Async Docs (github)](https://github.com/dart-lang/sdk/blob/main/runtime/docs/async.md)
- [Plugfox GC Overview](https://plugfox.dev/garbage-collection/)
- [Plugfox Dart VM Introduction](https://plugfox.dev/introduction-to-dart-vm/)
- [Reversing Dart AOT Snapshots (Phrack)](https://phrack.org/issues/71/11)
- [Anatomy of a Snapshot](https://recipes.tst.sh/docs/reverse-engineering/anatomy-of-a-snapshot.html)
