# deval v2 Research: Master Report
Phase: 6 | Status: COMPLETE

This is the consolidated summary of 11 research reports spanning VM architecture
analysis (Dart VM, Lua, V8/QuickJS, WASM), deval internals (runtime + compiler +
bridge), cross-referencing, deep dives on Dart-specific constraints, architecture
design, and developer experience.

---

## Executive Summary

deval is 50-1000x slower than native Dart, depending on workload. The bottlenecks
are architectural, not algorithmic. Every production VM we studied avoids the
patterns deval uses. The fix is not incremental optimization -- it's a redesign
of the interpreter core.

The good news: Dart's AOT compiler gives us the tools we need (jump-table switch,
Smi tagging of ints in List<Object?>, sealed class optimization). We just need
to use them.

---

## If You Only Do 3 Things

### 1. Switch-based dispatch (report 05, 08)
Replace `op.run(this)` virtual call with `switch (opcodes[pc++])`.
- Current: megamorphic virtual dispatch on 74+ classes = worst possible strategy
- Every other VM uses switch/computed-goto/handler-table
- Dart AOT compiles dense int switches to jump tables
- Expected: 2-5x speedup on the dispatch loop
- Effort: MEDIUM (mechanical refactor, convert each EvcOp to a switch case)

### 2. Eliminate double-allocation in boxing (report 05, 07)
`$int(v)` allocates both a `$int` AND a `$Object` superclass.
`$bool(v)` and `$String(v)` have the same problem.
- Merge fallback properties (==, toString, hashCode) into each wrapper's switch
- Eliminate the `_superclass` field entirely
- Expected: 2x reduction in boxing allocations (4M -> 2M allocs for 1M iterations)
- Effort: LOW (remove _superclass, copy ~5 methods into each wrapper's $getProperty)

### 3. Fix $Bridge try/catch (report 05, 07)
Every bridge property access that isn't overridden throws/catches UnimplementedError.
- Replace with null check: `if (subclass?.$getProperty(...) case final v?) return v;`
- Expected: 10-100x speedup on bridge property access
- Effort: LOW (change ~5 lines in runtime_bridge.dart)

**These three changes alone could make deval 5-20x faster with 1-2 days of work.**

---

## The Full Picture: What's Wrong and Why

### Current deval vs Production VMs

```
Feature               Production VMs    deval          Impact
--------------------------------------------------------------------
Op dispatch           switch/goto       virtual call   CRITICAL (every op)
Primitive boxing      unboxed/tagged    2 heap allocs  CRITICAL (every int op)
Bridge dispatch       direct/cached     try/catch      CRITICAL (every bridge access)
Frame allocation      sized per func    fixed 255      HIGH (every call)
Method dispatch       vtable/IC         HashMap        HIGH (every method call)
Arg passing           buffer/reuse      new List       HIGH (every call)
Bytecode storage      flat int array    List<Object>   MEDIUM (cache, memory)
Closures              flat upvalues     whole frame    MEDIUM (closures in loops)
String dispatch       interned/int ID   raw strcmp      MEDIUM (property access)
Constant folding      yes               no             MEDIUM (constant exprs)
Numeric intrinsics    full set          only +,-,<,>   MEDIUM (math-heavy code)
```

### Root Cause: No Intermediate Representation

The compiler goes directly from Dart AST to bytecode with no IR. This makes
optimization passes structurally impossible. Every missed optimization in the
compiler becomes a runtime cost.

---

## Recommended Architecture: deval v2

Based on studying Dart VM, Lua, V8/QuickJS, and WASM, the recommended model is:

### Primary inspiration: QuickJS
- Small, embeddable, no JIT, predictable performance
- 210 KiB binary, full spec compliance
- Single-pass compilation with bytecode cleanup passes
- Reference counting (we inherit Dart's GC instead)
- Atom interning for identifiers

### Key design decisions:

**1. Bytecode: Fixed 32-bit words in Int32List** (report 09, 10)
- Lua-style encoding: 8-bit opcode + ABC/ABx/AsBx operands
- ~90 opcodes (up from 74), including all missing arithmetic intrinsics
- Decode is pure bit arithmetic, zero allocation
- Cache-friendly: sequential int reads, no pointer chasing

**2. Value representation: Object? with type tags** (report 09)
- Store values as raw Dart values in `List<Object?>` (the frame)
- Dart VM already Smi-tags ints in List<Object?> = zero allocation for ints
- `is int` check compiles to a single bit test in AOT (Smi tag check)
- Heap objects (String, List, instances) stored directly as Dart objects
- No $Value wrapping for internal operations -- only at bridge boundary
- Separate `Uint8List` type tag array for polymorphic slots (optional)

**3. Switch-on-int dispatch from Int32List** (report 09, 10)
- Dense opcode numbering starting from 0
- Dart AOT generates jump tables for this pattern
- Operands decoded inline from the instruction word

**4. Sized frames per function** (report 10)
- Compiler computes exact register count per function
- `List<Object?>.filled(actualSize, null)` instead of fixed 255

**5. Integer-indexed method dispatch** (report 07, 10)
- Assign member IDs at compile time (like atoms)
- EvalObject stores methods in `List<Function?>` indexed by member ID
- Array lookup instead of HashMap<String, int>

**6. Flat closures** (report 09, 10)
- QuickJS/Lua upvalue model: closure captures specific cells, not whole frame
- Shared cells enable mutation visibility
- ~42x memory improvement for typical captures

**7. Reusable argument buffer** (report 07, 10)
- Pre-allocated args buffer, reset between calls
- Zero List allocation per function call

**8. Linear IR between AST and bytecode** (report 06, 10)
- Enables: constant folding, DCE, register allocation, peephole optimization
- Simple three-address code, single pass to emit bytecode

---

## Developer Experience Vision (report 11)

### API Surface: 21 methods (vs current ~50+)

```dart
// Hello world
final deval = Deval();
final ctx = deval.createContext();
print(ctx.eval('2 + 2')); // 4

// One-liner
print(Deval.eval('2 + 2')); // 4
```

### Registering native functions: 1 line (vs 15+ lines today)

```dart
// v2
deval.register('add', (int a, int b) => a + b);

// Current: BridgeClassDef + $Function + static impl + registerBridgeFunc
```

### Registering native classes: ~15 lines (vs 200+ lines today)

```dart
// v2
deval.registerClass(DevalClass<Vec3>(
  name: 'Vec3',
  constructor: (args) => Vec3(args[0], args[1], args[2]),
  getters: {'x': (v) => v.x, 'y': (v) => v.y, 'z': (v) => v.z},
  methods: {'length': (v, args) => v.length},
));
```

### Two-tier model (QuickJS-inspired)
- `Deval`: runtime (compiler, string table, resource limits)
- `DevalContext`: execution environment (globals, modules, permissions)
- Multiple contexts per runtime (e.g., per NPC, per mod)

### Capability-based security
- Contexts start with zero permissions
- Explicitly grant: filesystem, network, process, etc.
- QuickJS-style interrupt counter for execution limits

---

## Migration Path (report 10)

### Phase A: Quick wins on current codebase (1-2 days)
1. Fix $Bridge try/catch -> null check
2. Eliminate _superclass allocation in $num/$bool/$String
3. Use const $null() and cached $bool singletons
4. Add missing numeric intrinsics (*, /, %, <<, >>)
5. Add PushFalse opcode
6. Compute frame sizes, encode in PushScope

### Phase B: Switch dispatch (3-5 days)
1. Encode ops as int opcodes + operand arrays
2. Replace dispatch loop with switch on int
3. Decode operands inline
4. (Existing tests must still pass)

### Phase C: New runtime (parallel development)
1. Build v2 runtime alongside v1
2. New bytecode format, new dispatch, new value representation
3. New bridge API with backward-compatible adapter
4. Swap runtime behind the same Compiler front end
5. Eventually: new compiler with IR and optimization passes

### Backward compatibility
- v1 .evc files are NOT compatible with v2 (different bytecode format)
- Existing plugins work through LegacyBridgeAdapter
- Source-level compatibility: Dart code compiled for v1 recompiles for v2

---

## Performance Targets

```
Workload               Current         Target v2       Improvement
------------------------------------------------------------------
Numeric loop           50-200x native  5-15x native    10-40x faster
Method-heavy OOP       100-500x        10-30x          10-50x faster
Bridge-crossing        200-1000x       15-50x          15-60x faster
Compilation speed      ~same           ~same           (not a bottleneck)
Memory per value       32-64 bytes     8-16 bytes      2-8x less
Frame allocation       255 * 8 bytes   actual * 8      varies, much less
```

These targets are based on what QuickJS achieves (5-20x native for JS) adapted
for Dart's constraints (no computed goto, no NaN boxing).

---

## Report Index

```
docs/research/
  00_master_report.md        This file -- consolidated summary
  01_dart_vm.md              Dart VM architecture (compilation, objects, GC, async)
  02_lua_vm.md               Lua VM (instructions, values, tables, coroutines, C API)
  03_v8_quickjs.md           V8 Ignition + QuickJS (dispatch, shapes, ICs, embedding)
  04_wasm.md                 WASM (binary format, validation, wasm3, security)
  05_deval_runtime_analysis.md  Current runtime bottlenecks (dispatch, boxing, bridge)
  06_deval_compiler_analysis.md Current compiler gaps (no IR, no optimizations, bugs)
  07_bridge_interop_patterns.md Comparative FFI/bridge analysis (10 VMs)
  08_cross_reference.md      Cross-reference of all findings
  09_deep_dives.md           Value repr in Dart, string interning, bytecode encoding
  10_deval_v2_design.md      Full architecture design for v2
  11_dx_usability.md         Developer experience and API design
```

---

## Decision Points for the User

1. **Incremental vs rewrite?** Phase A+B (quick wins + switch dispatch) can land
   on the current codebase. Phase C (full v2) is a parallel runtime. Both can
   happen on experiment branches.

2. **When to break .evc compatibility?** The new bytecode format is fundamentally
   different (Int32List vs JSON metadata + object-based ops). A clean break is
   recommended, with a version check in the magic header.

3. **How much bridge compat?** A LegacyBridgeAdapter can wrap existing $Value-based
   plugins. But new plugins should use the v2 API (register + DevalClass).

4. **IR or no IR?** An IR enables optimization passes but adds compilation time.
   For game scripting (short scripts, fast iteration), QuickJS's approach (minimal
   bytecode cleanup passes, no full IR) may be the right tradeoff. The IR can
   always be added later.

5. **Priority: performance vs DX?** Phase A+B improve performance 5-20x without
   changing the public API. The DX improvements (new embedding API, codegen bridge)
   are Phase C. Both are important, but performance unblocks use cases that the
   current speed makes impractical.
