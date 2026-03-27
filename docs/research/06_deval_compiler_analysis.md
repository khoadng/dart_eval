# deval Compiler Deep Analysis
Phase: 1 | Status: COMPLETE

## 1. Full Compilation Pipeline

The compiler transforms Dart source to EVC bytecode through these stages:

```
  Source Strings/Files
       |
  [1] Dart Analyzer parseString()
       |
  DartCompilationUnit (AST)
       |
  [2] Library Construction (_buildLibraries)
       |  - SCC graph of compilation units (part/part-of merging)
       |  - Merge bridge declarations with matching URIs
       |
  [3] Reachability Analysis (_discoverReachableLibraries)
       |  - Walk import/export graph from entrypoints
       |  - Libraries not reachable from entrypoints are dropped
       |
  [4] Tree Shake (identifier-level)
       |  - TreeShakeVisitor collects all referenced identifiers per declaration
       |  - Used during import/export resolution to prune unused names
       |
  [5] Import/Export Resolution (_resolveImportsAndExports)
       |  - Compute visible declarations per library
       |  - Handle show/hide combinators, prefixed imports
       |
  [6] Lookup Table Population (_populateLookupTablesForDeclaration)
       |  - _topLevelDeclarationsMap: library -> name -> DeclarationOrBridge
       |  - _instanceDeclarationsMap: library -> class -> member -> Declaration
       |  - _topLevelGlobalIndices: library -> name -> global slot
       |  - TypeRef caching via TypeRef.cache()
       |
  [7] Type Registration
       |  - Cache TypeRefs for all class/enum declarations
       |  - Resolve bridge type refs
       |  - Build visibleTypesByIndex
       |
  [8] Bridge Function Index Assignment
       |  - Assign sequential integer IDs to all bridge constructors,
       |    static methods, getters, setters, fields
       |
  [9] Static Compilation Pass
       |  - Compile top-level variables and static fields first
       |  - Allows type inference for later declarations
       |  - ctx.resetStack() between each
       |
  [10] Main Compilation Pass
       |  - Compile classes, enums, functions (skipping already-compiled statics)
       |  - Each declaration: AST node -> direct bytecode emission
       |  - No intermediate representation
       |
  [11] Offset Resolution (OffsetTracker.apply)
       |  - Patch deferred Call/PushObjectPropertyImpl offsets
       |  - Forward references to functions not yet compiled get resolved
       |
  [12] Program Assembly
       |  - Collect ops, constant pool, type tables, global initializers
       |  - Build Program object
       |
  [13] Serialization (Program.write)
       |  - EVC\0 magic + version code
       |  - JSON-encoded metadata blocks (declarations, types, constants)
       |  - Raw opcode bytes
```

### Key insight: There is NO separate IR.
The compiler goes directly from Dart analyzer AST nodes to EVC bytecode
opcodes in a single pass. Each `compileExpression`, `compileStatement`,
and `compileDeclaration` call directly emits opcodes via `ctx.pushOp()`.


## 2. Dart Analyzer Integration

The compiler uses `package:analyzer` in two distinct ways:

**Compiler (parsing only):** Uses `parseString()` from
`package:analyzer/dart/analysis/utilities.dart` for syntactic parsing only.
No type resolution, no element model, no semantic analysis.
(`lib/src/eval/compiler/model/source.dart` line 117)

**Bindgen (full analysis):** Uses `AnalysisContextCollection` for full
semantic analysis including resolved types and element model.
(`lib/src/eval/bindgen/bindgen.dart` line 1)

The compiler walks AST nodes using a manual dispatch pattern (not the
visitor pattern). Each `compileExpression` uses an if/else chain on
runtime type (`lib/src/eval/compiler/expression/expression.dart` lines 35-83).
Same for `compileStatement` and `compileDeclaration`.

The only AST visitor is `PrescanVisitor` (for closure analysis) and
`TreeShakeVisitor` (for identifier collection).


## 3. Register Allocation (Stack Machine)

deval uses a **stack machine** model, not a register machine. There is no
register allocator. Variables are assigned **stack frame offsets** sequentially.

### Allocation mechanism

`Variable.alloc()` increments both `ctx.scopeFrameOffset` and
`ctx.allocNest.last`, returning a `Variable` with the next available
stack slot. (`lib/src/eval/compiler/variable.dart` lines 41-60)

### Scope management

`ScopeContext` maintains:
- `locals`: `List<Map<String, Variable>>` - nested scope frames
- `allocNest`: `List<int>` - count of allocations per scope level
- `scopeFrameOffset`: current stack top

`beginAllocScope()` pushes a new scope. `endAllocScope()` emits `Pop`
to reclaim stack slots and decrements `scopeFrameOffset`.

### No reuse of dead slots

Once a variable goes out of scope, its slot is `Pop`'d. There is no
analysis to reuse stack slots of dead variables within the same scope.
Every intermediate expression result allocates a new slot. Example:
`a + b + c` allocates separate slots for `a+b` result and `(a+b)+c`
result, even though the first is dead after the second is computed.


## 4. Type Tracking

Types are tracked through `TypeRef` objects attached to every `Variable`.
(`lib/src/eval/compiler/type.dart`)

### TypeRef structure
- `file`: library ID (integer)
- `name`: type name string
- `extendsType`, `implementsType`, `withType`: inheritance chain
- `specifiedTypeArgs`: concrete generic arguments
- `boxed`: whether the value is boxed (heap-allocated wrapper)
- `nullable`: nullability
- `resolved`: whether the full type chain has been resolved
- `functionType`: for function types (`EvalFunctionType`)

### Type resolution
Types are created initially with just `(file, name)` via `TypeRef.cache()`.
Full resolution (filling in extends/implements/with chains) happens lazily
via `resolveTypeChain()`. A static `_cache` map deduplicates TypeRefs.

### Known methods/fields
`getKnownMethods()` and `getKnownFields()` in `builtins.dart` provide
compile-time type information for built-in types (int, double, bool,
String, List, Map, etc.), enabling the compiler to determine return types
without semantic analysis.

### Boxing model
Core primitive types (int, double, bool, List) can be "unboxed" - stored
as raw values on the stack. All other types are always boxed. The set
`unboxedAcrossFunctionBoundaries` determines which types stay unboxed
when passed between functions. Method arguments are always boxed for
bridge interop consistency (see `declaration/method.dart` line 46-52).


## 5. Generics Compilation

Generics are handled at the type level only - there is no monomorphization
or specialization.

### Type parameters
`TypeRef.loadTemporaryTypes()` registers generic type parameters as
temporary types in the context, mapping parameter names to their bounds
(or `dynamic` if unbounded). These are stored in
`ctx.temporaryTypes[library]` and cleared after compilation of the
generic declaration.

### Type argument propagation
When a generic type is instantiated with concrete arguments, the
`specifiedTypeArgs` field carries them. During method invocation, the
compiler resolves generic return types by matching type parameter names
against the `resolveGenerics` map built from the call site's type arguments.
(`lib/src/eval/compiler/expression/method_invocation.dart` lines 190-222)

### Erasure
At runtime, generics are effectively erased. The constant pool and
runtime type system track type IDs, but there is no generic specialization
of bytecode. A `List<int>` and `List<String>` execute identical bytecode.


## 6. Closure Compilation

### Prescan phase
`PrescanVisitor` (`lib/src/eval/compiler/optimizer/prescan.dart`) walks
function bodies before compilation to detect closures. It identifies:
- `localsReferencedFromClosure`: variables accessed by inner functions
- `closedFrames`: scope frame indices that need to be captured

The prescan mirrors the compiler's scope structure (matching
beginAllocScope/endAllocScope) and tracks which identifiers inside
`FunctionExpression` nodes reference variables from outer scopes.

### Capture mechanism
When a scope is detected as closed (referenced from a closure), the
compiler emits `PushScope`/`PopScope` ops to create a heap-allocated
scope frame. The closure captures a reference to the parent scope via
a special `#prev` local variable.

Access to captured variables goes through an `IndexList` chain:
the closure holds `#prev` (a list), and each access indexes into
the correct frame level. Multiple levels of nesting produce chained
IndexList operations. (`lib/src/eval/compiler/context.dart` lines 253-308)

### Function expression compilation
`compileFunctionExpression()` (`lib/src/eval/compiler/expression/function.dart`):
1. Emit `JumpConstant` to skip over the function body
2. Emit function body with `beginMethod`
3. Save/restore compiler state around the body
4. Emit `PushFunctionPtr` to create a closure value
5. Function signature metadata (arg counts, types) pushed to constant pool

### Calling conventions
Two calling conventions: `static` (direct Call opcode) and `dynamic`
(closure call with runtime type checking). Closures always use dynamic
convention, which has significant overhead due to argument type
validation via runtime type lists.


## 7. Control Flow Compilation

### If/else (`macroBranch`)
`lib/src/eval/compiler/macros/branch.dart`:
1. Compile condition, emit `JumpIfFalse` with placeholder offset
2. Save state, compile then-branch
3. If else exists: emit `JumpConstant` (skip else), patch JumpIfFalse
4. Compile else-branch
5. Patch jump targets
6. `resolveBranchStateDiscontinuity` reconciles boxing state between branches

### Loops (`macroLoop`)
`lib/src/eval/compiler/macros/loop.dart`:
1. Compile initialization
2. Save boxing state
3. Compile condition, emit `JumpIfFalse`
4. Compile body, then update
5. Emit `JumpConstant` back to loop start
6. Patch JumpIfFalse to loop exit
7. `resolveBranchStateDiscontinuity` after loop for boxing consistency

For-each loops desugar into iterator pattern: `.iterator`, `.moveNext()`,
`.current`. (`lib/src/eval/compiler/statement/for.dart`)

### Switch
Switch compiles as a chain of if/else branches using `macroBranch`.
Each case emits an `==` comparison, with recursion to the next case
in the else branch. (`lib/src/eval/compiler/statement/switch.dart`)

No jump table optimization even for contiguous integer cases.

### Try/catch/finally
`lib/src/eval/compiler/statement/try.dart`:
1. Finally block (if any): emit `PushFinally` + finally body first, jump over
2. Emit `Try` op with placeholder catch offset
3. Compile try body
4. Emit `PopCatch` after try body
5. Catch clauses compiled as nested type-check branches (IsType + macroBranch)
6. Exception variable captured via `PushReturnValue` after Try handler fires

### Break/continue
Labels track loop boundaries. Break triggers `endAllocScopeQuiet` + jump
to after the loop. Continue jumps back to loop start.


## 8. Bridge Type Integration

Bridge types are Dart classes that exist in the host runtime, exposed
to the eval'd code. They integrate at multiple levels:

### Declaration level
`BridgeClassDef`, `BridgeEnumDef`, `BridgeFunctionDeclaration` are registered
via `defineBridgeClass`, etc. They merge with source declarations sharing
the same library URI.

### Compilation level
Bridge declarations get sequential `bridgeStaticFunctionIdx` assignments.
When compiled code calls a bridge method:
- Static calls emit `InvokeExternal` with the bridge function index
- Instance calls emit `InvokeDynamic` (string-based method lookup)
- Bridge constructors emit `BridgeInstantiate`

### Runtime level
At runtime, `registerBridgeFunc()` maps bridge indices to actual Dart
functions. The `$Value` / `$Instance` protocol allows bridge objects
to participate in the eval runtime.

### Type level
Bridge type refs can use `BridgeTypeRef.type(cacheId)` to reference
already-registered type IDs, or `BridgeTypeRef.spec(library, name)` for
deferred resolution. The compiler resolves these during type registration
(step 7 of the pipeline).


## 9. Bytecode Output Format

### Program.write() serialization
(`lib/src/eval/compiler/program.dart`)

```
  Bytes 0-3:   Magic "EVC\0" (0x45 0x56 0x43 0x00)
  Bytes 4-7:   Version code (i32, currently 81)

  Then 11 metadata blocks, each:
    4 bytes: JSON length (i32)
    N bytes: UTF-8 JSON payload

  Metadata blocks in order:
    1. topLevelDeclarations: Map<library_id, Map<name, offset>>
    2. instanceDeclarations: Map<library_id, Map<class, [getters, setters, methods, type_id]>>
    3. typeTypes: List<List<int>> (supertype sets per type ID)
    4. typeIds: Map<library_id, Map<name, type_id>>
    5. bridgeLibraryMappings: Map<uri, library_id>
    6. bridgeFunctionMappings: Map<library_id, Map<name, bridge_func_id>>
    7. constantPool: List<Object> (strings, lists, etc.)
    8. runtimeTypes: List<RuntimeTypeSet as JSON>
    9. globalInitializers: List<int> (offsets to initializer code)
   10. enumMappings: Map<library_id, Map<enum, Map<value, global_id>>>
   11. overrideMap: Map<name, [offset, version_constraint]>

  Remaining bytes: raw opcodes
```

All metadata is JSON-encoded, which is simple but not space-efficient.
Opcodes are binary-encoded via `Runtime.opcodeFrom()`.


## 10. Existing Optimizations

### What exists

1. **Numeric intrinsics** (`lib/src/eval/compiler/helpers/invoke.dart`
   lines 23-31, 181-280): `+`, `-`, `<`, `>`, `<=`, `>=` on num/int/double
   types compile to specialized `NumAdd`, `NumSub`, `NumLt`, `NumLtEq`
   ops instead of dynamic dispatch. These operate on unboxed values.

2. **Boolean intrinsic**: `!` on bool compiles to `LogicalNot`.

3. **Equality optimization**: `==` and `!=` always compile to `CheckEq`
   (reference equality) instead of dynamic dispatch, since the result
   is guaranteed to be `bool`.

4. **Static dispatch** (`lib/src/eval/compiler/reference.dart` lines 500-554):
   When the concrete type of a receiver is known (single entry in
   `concreteTypes`), method calls compile to `Call` (direct jump) instead
   of `InvokeDynamic` (string-based dispatch).

5. **Property access optimization** (`lib/src/eval/compiler/variable.dart`
   lines 242-261): When concrete type is known, field access uses
   `PushObjectPropertyImpl` (index-based) instead of `PushObjectProperty`
   (string-based lookup).

6. **Short-circuit evaluation**: `&&`, `||`, `??` properly short-circuit
   using `macroBranch`. The right operand is only evaluated if needed.

7. **Unboxed primitives**: int, double, bool, List can be stored unboxed
   on the stack, avoiding heap allocation for local computations.

8. **Library-level tree shaking**: Unreachable libraries (not imported
   from entrypoints) are excluded from compilation.

9. **Identifier-level tree shaking**: `TreeShakeVisitor` collects
   referenced identifiers; unused declarations within reachable
   libraries can potentially be pruned during import resolution.

10. **Closure prescan**: Identifies which scopes need heap allocation
    for closure capture, avoiding unnecessary PushScope/PopScope for
    scopes that are never captured.

### What does NOT exist (missing optimizations)

1. **No constant folding.** `2 + 3` compiles to `PushConstantInt(2)`,
   `PushConstantInt(3)`, `NumAdd` instead of `PushConstantInt(5)`.
   Every constant expression evaluates at runtime.

2. **No dead code elimination within functions.** Code after unconditional
   `return` or `throw` is still compiled (the `willAlwaysReturn`/
   `willAlwaysThrow` flags only prevent emitting an extra trailing Return).
   Unreachable branches in if/else are still compiled.

3. **No common subexpression elimination (CSE).** Repeated property
   accesses like `obj.x + obj.x` emit duplicate PushObjectProperty ops.

4. **No copy propagation.** Variable assignments that are simple copies
   still go through CopyValue ops. No analysis to reuse the source
   directly.

5. **No strength reduction.** `x * 2` is not converted to `x + x` or
   a shift. `x / 1` is not eliminated.

6. **No loop-invariant code motion.** Expressions inside loops that
   don't change between iterations are recomputed every iteration.

7. **No inlining.** Small functions are never inlined. Every function
   call has full Call/Return overhead including PushScope/PopScope.

8. **No tail call optimization.** Recursive functions always grow the
   call stack.

9. **No peephole optimization.** The opcode list is never post-processed
   to find reducible patterns like `PushNull; Pop` or `Box; Unbox`.

10. **No register allocation.** The stack machine model means every
    intermediate result occupies a distinct stack slot. A register
    allocator on top of an IR could dramatically reduce stack traffic.

11. **No escape analysis.** All objects are heap-allocated. An escape
    analysis pass could stack-allocate short-lived objects.

12. **No specialization of generic code.** `List<int>` and `List<dynamic>`
    execute identical bytecode. Specialized paths for common generic
    instantiations would avoid boxing.

13. **No switch jump tables.** Switch statements compile as linear
    if/else chains, O(n) per case instead of O(1) with a jump table.

14. **No redundant box/unbox elimination.** The `resolveBranchState
    Discontinuity` mechanism ensures boxing state is consistent across
    branches, but it does not eliminate cases where a value is boxed
    then immediately unboxed (or vice versa).

15. **No method devirtualization.** Even when the full class hierarchy
    is known at compile time and a method is never overridden, instance
    method calls still use dynamic dispatch unless `concreteTypes` is
    populated (which only happens for constructor results and certain
    literal types).

16. **No declaration-level DCE within libraries.** The tree shaker
    collects identifiers but the actual pruning of unused functions/
    classes within a reachable library is limited to import visibility.
    Private unused functions within a library are still compiled.


## 11. Code Quality Issues

### Architectural issues

1. **No IR means no optimization pipeline.** The direct AST-to-bytecode
   architecture makes it structurally impossible to add most optimizations
   without a major refactor. A proper compiler would have at least one IR
   between AST and bytecode.

2. **Global mutable state.** `CompilerContext` is a massive mutable state
   bag with 30+ fields. It accumulates data across the entire compilation,
   making it hard to reason about what state is valid at any point.

3. **Late-bound global `unboxedAcrossFunctionBoundaries`**
   (`builtins.dart` line 375). A `late` global variable initialized
   during compilation. Fragile; depends on compilation order.

4. **Late-bound global `dartCoreFile`** (`builtins.dart` line 8).
   Set as a side effect during type registration. Used everywhere.

5. **Static TypeRef cache** (`type.dart` lines 33-36). Global mutable
   static state that persists across compiler invocations. The `_cache`
   and `_inverseCache` are never cleared, causing potential stale data
   if the compiler is reused.

### Code duplication

1. **Bridge function index assignment** has identical null-check +
   initialize patterns repeated 5 times in `_assignBridgeStaticFunction
   IndicesForClass` (`compiler.dart` lines 809-860).

2. **Method invocation** logic is split across `compileMethodInvocation`,
   `_invokeWithTarget`, the `Invoke` extension on `Variable`, and
   `invokeClosure`. These four entry points have overlapping concerns
   and duplicated argument handling.

3. **Variable resolution** (local -> instance -> static -> global)
   is implemented separately in `IdentifierReference.getValue()`,
   `IdentifierReference.setValue()`, and `IdentifierReference.resolveType()`.
   The three-way duplication of the lookup chain is error-prone.

4. **Boxing reconciliation** is done by three similar methods:
   `resolveBranchStateDiscontinuity`, `restoreBoxingState`, and parts
   of `resolveNonlinearity`. These all iterate over locals comparing
   boxing state and emitting box/unbox ops, with subtle differences.

### Unnecessary complexity

1. **ConstantPool hash collision risk** (`constant_pool.dart`). Uses
   `DeepCollectionEquality().hash(p) + p.runtimeType.hashCode` with an
   XOR of list length. This is a custom hash scheme that does not handle
   collisions - if two different objects hash to the same value, the
   pool returns the wrong index. No collision detection exists.

2. **OffsetTracker patching** is a workaround for the lack of a proper
   two-pass compilation or link phase. Forward references to functions
   emit placeholder `-1` offsets and rely on post-compilation patching.
   This would be unnecessary with an IR.

3. **Type inference save/restore** (`enterTypeInferenceContext` /
   `inferTypes` / `uninferTypes`) creates full snapshots of all locals
   to temporarily narrow types in branches. This is expensive and complex;
   a proper SSA form would handle this naturally.

4. **The `#prev` variable trick** for closures. Captured variables are
   accessed through a chain of `IndexList` operations on a synthetic
   `#prev` list variable. Each level of closure nesting adds another
   indirection. This is correct but slow; a flat closure representation
   (capturing specific variables into a fixed-size record) would be
   more efficient.

### Potential bugs

1. **`ConstantPool.addOrGet` hash collision** as noted above can cause
   silent corruption if two different constant values collide.

2. **Switch _switchAlwaysReturns** (`statement/switch.dart` lines 219-232)
   always returns false - the loop logic is broken (it `continue`s
   instead of tracking state, then returns false unconditionally).

3. **`bool false` encoding** (`builtins.dart` lines 48-52): `false` is
   compiled as `PushTrue` followed by `LogicalNot`, which allocates an
   extra stack slot. A `PushFalse` opcode would be more efficient.

4. **Prescan is disabled** for methods. `compileMethodDeclaration` has
   `///ctx.runPrescan(d);` commented out (line 21), meaning closure
   detection for methods relies on the default behavior rather than
   prescanning. `compileFunctionDeclaration` also has prescan commented
   out (line 19 `//ctx.runPrescan(d);`).

5. **endAllocScope called twice** in some method compilation paths -
   once inside the if/else for function body type, once after. The
   double-pop potential exists if `willAlwaysReturn` is false.


## 12. Numeric Intrinsic Coverage Gaps

The numeric intrinsics only cover `+`, `-`, `<`, `>`, `<=`, `>=`.
Missing intrinsics that would avoid dynamic dispatch:

- `*` (multiply) - very common in game/math code
- `/` (divide)
- `~/` (integer divide)
- `%` (modulo)
- `<<`, `>>` (shifts)
- `&`, `|`, `^` (bitwise ops)
- `unary -` (negation)
- `.toInt()`, `.toDouble()`, `.toString()`
- `.abs()`, `.round()`, `.floor()`, `.ceil()`

Each of these currently falls through to `InvokeDynamic`, which:
1. Boxes both operands
2. Does a string-based method lookup
3. Calls through the dynamic dispatch mechanism
4. Unboxes the result

For numeric-heavy code (games), this is a major performance bottleneck.


## 13. Summary of Optimization Opportunities by Impact

```
  HIGH IMPACT
  +-------------------------------------------------+
  | Constant folding for arithmetic/boolean          |
  | * intrinsics (mul, div, mod, bitwise, negation)  |
  | Redundant box/unbox elimination (peephole)       |
  | PushFalse opcode (avoid PushTrue + LogicalNot)   |
  | Switch jump tables for integer/enum cases        |
  | Method devirtualization (sealed/final classes)   |
  +-------------------------------------------------+

  MEDIUM IMPACT
  +-------------------------------------------------+
  | Dead code elimination after return/throw         |
  | Common subexpression elimination                 |
  | Stack slot reuse for dead intermediates          |
  | Loop-invariant code motion                       |
  | Flat closure representation                      |
  | Unbox method args when not crossing bridge       |
  +-------------------------------------------------+

  LOW IMPACT (high effort, moderate payoff)
  +-------------------------------------------------+
  | Full SSA-based IR                                |
  | Register allocation                              |
  | Function inlining                                |
  | Escape analysis                                  |
  | Generic specialization                           |
  | Tail call optimization                           |
  +-------------------------------------------------+
```


## 14. File Reference Index

```
  Pipeline entry:     lib/src/eval/compiler/compiler.dart
  Context/state:      lib/src/eval/compiler/context.dart
  Variables:          lib/src/eval/compiler/variable.dart
  Type system:        lib/src/eval/compiler/type.dart
  References:         lib/src/eval/compiler/reference.dart
  Offset patching:    lib/src/eval/compiler/offset_tracker.dart
  Constant pool:      lib/src/eval/compiler/constant_pool.dart
  Program output:     lib/src/eval/compiler/program.dart
  Scope/method:       lib/src/eval/compiler/scope.dart
  Source loading:     lib/src/eval/compiler/model/source.dart

  Expressions:        lib/src/eval/compiler/expression/expression.dart
  Binary ops:         lib/src/eval/compiler/expression/binary.dart
  Literals:           lib/src/eval/compiler/expression/literal.dart
  Functions/closures: lib/src/eval/compiler/expression/function.dart
  Method calls:       lib/src/eval/compiler/expression/method_invocation.dart
  Identifiers:        lib/src/eval/compiler/expression/identifier.dart
  Instance creation:  lib/src/eval/compiler/expression/instance_creation.dart

  Statements:         lib/src/eval/compiler/statement/statement.dart
  If:                 lib/src/eval/compiler/statement/if.dart
  For/for-each:       lib/src/eval/compiler/statement/for.dart
  While/do-while:     lib/src/eval/compiler/statement/while.dart, do.dart
  Switch:             lib/src/eval/compiler/statement/switch.dart
  Try/catch:          lib/src/eval/compiler/statement/try.dart
  Var declarations:   lib/src/eval/compiler/statement/variable_declaration.dart

  Declarations:       lib/src/eval/compiler/declaration/declaration.dart
  Classes:            lib/src/eval/compiler/declaration/class.dart
  Constructors:       lib/src/eval/compiler/declaration/constructor.dart
  Methods:            lib/src/eval/compiler/declaration/method.dart
  Functions:          lib/src/eval/compiler/declaration/function.dart
  Fields:             lib/src/eval/compiler/declaration/field.dart

  Macros:             lib/src/eval/compiler/macros/branch.dart
                      lib/src/eval/compiler/macros/loop.dart

  Helpers:            lib/src/eval/compiler/helpers/invoke.dart
                      lib/src/eval/compiler/helpers/closure.dart
                      lib/src/eval/compiler/helpers/argument_list.dart

  Optimizer:          lib/src/eval/compiler/optimizer/prescan.dart (only one)

  Tree shaking:       lib/src/eval/compiler/util/tree_shake.dart
  Graph utils:        lib/src/eval/compiler/util/graph.dart
  Library graph:      lib/src/eval/compiler/util/library_graph.dart

  Builtins:           lib/src/eval/compiler/builtins.dart

  Runtime:            lib/src/eval/runtime/runtime.dart
  Opcodes:            lib/src/eval/runtime/ops/all_ops.dart

  Bindgen:            lib/src/eval/bindgen/bindgen.dart
```
