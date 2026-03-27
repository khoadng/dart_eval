# deval Runtime Deep Analysis
Phase: 1 | Status: COMPLETE


## 1. Architecture Overview

The deval runtime is a stack-based bytecode interpreter. Code is compiled to an
intermediate representation (EVC bytecode), then decoded into op objects stored
in a `List<EvcOp>`. Execution is a simple fetch-decode-execute loop.

Key files:
- `lib/src/eval/runtime/runtime.dart` - Runtime class, dispatch loop, state
- `lib/src/eval/runtime/ops/all_ops.dart` - Op constants, op loader table
- `lib/src/eval/runtime/ops/primitives.dart` - Boxing, unboxing, arithmetic
- `lib/src/eval/runtime/ops/flow.dart` - Call, return, jumps, try/catch
- `lib/src/eval/runtime/ops/memory.dart` - Args, stack, globals
- `lib/src/eval/runtime/ops/objects.dart` - Property access, dynamic dispatch
- `lib/src/eval/runtime/ops/bridge.dart` - Bridge instantiation, external calls
- `lib/src/eval/runtime/class.dart` - $Value, $Instance, $InstanceImpl
- `lib/src/eval/runtime/function.dart` - EvalFunction, $Function, $Closure


## 2. The Dispatch Loop

Location: `runtime.dart` lines 858-861

```dart
while (true) {
  final op = pr[_prOffset++];
  op.run(this);
}
```

This is a **virtual method dispatch loop**. Each op is an object implementing
`EvcOp.run(Runtime)`. The VM fetches the next op from `List<EvcOp> pr` by index,
then calls `op.run(this)` which is a virtual (polymorphic) call.

There is also `bridgeCall` (lines 875-895) which creates a nested dispatch loop
for calling back into eval'd code from bridge code. It saves/restores `_prOffset`
and pushes sentinel values onto callStack/catchStack.

### Dispatch mechanism analysis

The dispatch is neither a switch/case nor a computed goto. It is a polymorphic
virtual call on ~74 different concrete classes. This is the **worst possible
dispatch strategy for an interpreter** in Dart because:

1. The Dart VM cannot inline the virtual call - it sees 74+ different receiver
   types at the same call site, defeating megamorphic inline caching.
2. Each op is a heap-allocated object with its own vtable pointer.
3. There is no way for the CPU branch predictor to predict the next op.
4. A switch/case on an int opcode would be significantly faster because the
   Dart AOT compiler can generate a jump table.

### Bottleneck severity: CRITICAL

Every single bytecode instruction pays the cost of a megamorphic virtual call.
In a tight loop (e.g., `for (int i = 0; i < 1000000; i++) { sum += i; }`),
this dominates execution time.


## 3. Value Representation and Boxing

### The $Value hierarchy

```
$Value (abstract)
  |-- $null
  |-- $Instance (abstract)
        |-- $bool
        |-- $String
        |-- $num<T>
        |     |-- $int
        |     |-- $double
        |-- $InstanceImpl (eval'd classes)
        |-- $List
        |-- $Map
        |-- $Set
        |-- $Record
        |-- EvalFunction (abstract)
        |     |-- $Function
        |     |-- $Closure
        |     |-- EvalFunctionPtr
        |     |-- EvalStaticFunctionPtr
        |-- $Object
        |-- ... (all bridge wrappers)
```

Every value in the interpreter is either a raw Dart value (unboxed) on the
frame, or wrapped in a `$Value` subclass (boxed). The frame itself is
`List<Object?>` so even unboxed ints are boxed at the Dart level (Object? box).

### Boxing operations

Boxing is explicit via dedicated opcodes:
- `BoxInt` (op 7): `runtime.frame[reg] = $int(runtime.frame[reg] as int)`
- `BoxDouble` (op 42): `runtime.frame[reg] = $double(runtime.frame[reg] as double)`
- `BoxString` (op 36): `runtime.frame[reg] = $String(runtime.frame[reg] as String)`
- `BoxBool` (op 54): `runtime.frame[reg] = $bool(runtime.frame[reg] as bool)`
- `BoxNull` (op 56): `runtime.frame[reg] = $null()`
- `BoxNum` (op 41): `runtime.frame[reg] = $num(runtime.frame[reg] as num)`
- `BoxList` (op 37): creates `$List.wrap(<$Value>[...(runtime.frame[reg] as List)])`
- `BoxMap` (op 51): creates `$Map.wrap(<$Value, $Value>{...(runtime.frame[reg] as Map)})`

Unboxing: `Unbox` (op 2): `runtime.frame[_reg] = (runtime.frame[_reg] as $Value).$value`

### Allocation cost per boxing op

Each box operation allocates:
- `$int(v)` -> 1 object (the $int itself) + 1 $Object superclass in $num constructor
- `$num(v)` -> constructor: `$num(this.$value) : _superclass = $Object($value)` -
  allocates both a $num and a $Object
- `$double(v)` -> same as $int, inherits $num constructor
- `$bool(v)` -> constructor: `$bool(this.$value) : _superclass = $Object($value)` -
  allocates both a $bool and a $Object
- `$String(v)` -> constructor: `$String(this.$value) : _superclass = $Pattern.wrap($value)` -
  allocates a $String and a $Pattern wrapper
- `$null()` -> allocates a new $null every time (not const in BoxNull op, though
  MaybeBoxNull uses `const $null()`)

### Bottleneck severity: HIGH

For numeric-heavy code (`i + 1`), the sequence is:
1. PushConstantInt -> raw int on frame
2. NumAdd -> raw num result on frame
3. BoxInt -> allocates $int + $Object(!) just to store in a variable

The $num superclass allocating a `$Object` is particularly wasteful - every
$int, $double creation allocates TWO objects. This means `a + b` where a,b are
int creates at minimum 1 $int for the result = 2 heap allocations.


## 4. Stack and Frame System

### Frame layout

Each function call gets a new frame: `List<Object?>.filled(255, null)`
(PushScope, flow.dart line 45).

Frames are stored on `runtime.stack` (a `List<List<Object?>>`). The current
frame is cached in `runtime.frame`. Frame slots are addressed by index
(int16 offsets in bytecode).

`frameOffset` tracks the next free slot. Arguments are copied into the frame
at the start (PushScope lines 50-54).

### Problems

1. **Fixed 255-slot frames**: Every function call allocates a 255-element list
   regardless of how many locals it needs. A function with 2 locals wastes 253
   slots. (PushScope, flow.dart line 45)

2. **New list per call**: `List<Object?>.filled(255, null)` is called on every
   function entry. For recursive code or tight loops calling functions, this is
   a major source of GC pressure.

3. **Args passing via mutable list**: `runtime.args` is a `List<Object?>` that
   gets rebuilt on every call. PushArg appends to it, then PushScope copies from
   it, then clears it with `runtime.args = []` (new allocation).

4. **No frame recycling**: Frames are created and discarded. There is no frame
   pool or stack-allocated frame.

### Bottleneck severity: HIGH

A simple function call like `f(x)` requires:
- PushArg: `runtime.args.add(...)` (list append, possible grow)
- Call: push to callStack, push empty list to catchStack
- PushScope: allocate 255-element list, copy args, allocate new empty args list
- (function body)
- Return: pop stacks, restore frame
- PopScope or Return: removeLast from multiple lists


## 5. Method Calls End-to-End

### Static calls (Call op)

For known function offsets:
1. `PushArg` ops push arguments to `runtime.args`
2. `Call` op: pushes current offset to `callStack`, pushes `[]` to `catchStack`,
   sets `_prOffset` to target
3. Target function's `PushScope` creates new frame, copies args
4. `Return` op: stores return value, pops frame, pops callStack/catchStack,
   jumps back

### Dynamic dispatch (InvokeDynamic op)

objects.dart lines 5-116. This is complex:

1. Look up method name from constant pool: `runtime.constantPool[_methodIdx] as String`
2. **While loop** walking the superclass chain:
   - If `$InstanceImpl`: look up method in `evalClass.methods` map (HashMap lookup!)
   - If not found, walk to `evalSuperclass` and repeat
   - If `EvalFunctionPtr` with method "call": elaborate argument marshaling
   - Otherwise: call `$getProperty` on the $Instance, then `.call()` on result

The method lookup is a **HashMap string lookup per call**. For eval'd classes,
this goes through `Map<String, int>.[]` which hashes the method name string.

### Property access (PushObjectProperty op)

objects.dart lines 247-303. Similar pattern:
1. Look up property name from constant pool
2. Walk superclass chain checking `evalClass.getters[property]` (HashMap)
3. If getter found: push to args, do a bridgeCall to the getter offset
4. If method found: create `EvalStaticFunctionPtr` (heap allocation)
5. If neither: fall through to `$getProperty` virtual call on bridge objects

### Bottleneck severity: HIGH

Every method call on an eval'd object does a HashMap lookup. Every property
access on an eval'd object does a HashMap lookup. The string-keyed HashMap
is the dispatch mechanism for instance members, which is orders of magnitude
slower than a vtable dispatch.

Additionally, property access through `$getProperty` on bridge types uses a
giant switch/case on string identifiers (see $String, $num, $int). While this
is faster than HashMap, it still involves string comparison.


## 6. Bridge Call Overhead

### InvokeExternal (bridge.dart lines 90-123)

Calling a native Dart function from eval'd code:
1. Copy args from `runtime.args` to a new `List<$Value?>.filled(argsLen, null)`
   (heap allocation)
2. Clear args: `runtime.args = []` (heap allocation)
3. Call `runtime._bridgeFunctions[_function](runtime, null, mappedArgs)`
4. Store result in `runtime.returnValue`

The bridge function receives `(Runtime runtime, $Value? target, List<$Value?> args)`.
Every argument must be boxed as `$Value`. The result must also be a `$Value`.

### BridgeInstantiate (bridge.dart lines 5-49)

Creating a bridge class instance:
1. Same arg copying pattern (new List allocation)
2. Calls bridge constructor function
3. Creates `BridgeData` and stores it in an `Expando` (global weak map):
   `Runtime.bridgeData[instance] = BridgeData(...)`

### $Bridge mixin (runtime_bridge.dart)

The bridge property access pattern (lines 13-21):
```dart
$Value? $getProperty(Runtime runtime, String identifier) {
  try {
    return Runtime.bridgeData[this]!.subclass!.$getProperty(runtime, identifier);
  } on UnimplementedError catch (_) {
    return $bridgeGet(identifier);
  }
}
```

This uses **exception-based control flow** for the common case where the
property is not overridden in eval'd code. Every property access on a bridge
object that is NOT overridden throws and catches an UnimplementedError. This is
extremely expensive.

### Bottleneck severity: CRITICAL (for bridge-heavy code)

The try/catch pattern in $Bridge means that accessing native properties on a
bridge class (the common case when a Dart class is used from eval'd code without
overriding) throws an exception every time. Exception handling is one of the
slowest operations in Dart.


## 7. Closure Variable Capture

### PushCaptureScope (flow.dart lines 64-78)

Closures capture the **entire parent frame** by reference:
```dart
exec.frame[exec.frameOffset++] = exec.stack[exec.stack.length - 2];
```

This stores a reference to the parent's 255-element list. When the closure is
invoked, this captured frame is passed as `$prev` in `EvalFunctionPtr`.

### EvalFunctionPtr.call (function.dart lines 65-69)

```dart
$Value? call(Runtime runtime, $Value? target, List<$Value?> args) {
  runtime.args = [if ($prev != null) $prev, ...args];
  runtime.bridgeCall(offset);
  return runtime.returnValue as $Value?;
}
```

The spread operator `...args` creates a new list every call.

### PushFunctionPtrCopyCapture (flow.dart lines 343-379)

For closures in loops, the entire frame is **copied**:
```dart
[...runtime.frame]
```
This copies all 255 elements of the frame for each closure created in a loop
iteration.

### Bottleneck severity: MEDIUM

Closure capture is coarse-grained (whole frame, not individual variables).
The copy-on-loop-iteration pattern copies 255 elements regardless of how many
are actually captured. For code creating closures in tight loops (e.g.,
`.map((e) => ...)` on large lists), this is expensive.


## 8. Exception Handling

### Try op (flow.dart lines 381-401)

Pushes catch offset to `catchStack.last`, saves frameOffset.

### Throw op / $throw method (runtime.dart lines 899-931)

Stack unwinding is a while loop:
1. Walk catchStack looking for a non-empty catch frame
2. For each empty frame: pop stack, frame, frameOffsetStack, catchStack, callStack
3. If callStack entry is -1 (entry point), throw WrappedException to escape
4. Otherwise set _prOffset to catch offset and continue

The catch mechanism uses negative offsets for finally blocks (line 920).

### Performance note

The unwinding loop itself is not terrible. The main cost is that every `Call` op
pushes an empty list `[]` to `catchStack` (flow.dart line 18), even when there
is no try/catch in the called function. This means every function call allocates
an empty list for catchStack.

### Bottleneck severity: LOW-MEDIUM

The empty list allocation on every Call is wasteful but not dominant. The real
cost is when bridge code uses try/catch for control flow ($Bridge mixin).


## 9. Globals

### LoadGlobal (memory.dart lines 98-121)

Lazy initialization pattern:
```dart
var value = runtime.globals[_index];
if (value == null) {
  runtime.callStack.add(runtime._prOffset);
  runtime.catchStack.add([]);
  runtime._prOffset = runtime.globalInitializers[_index];
} else {
  runtime.returnValue = value;
}
```

Globals are stored in `List<Object?>.filled(20000, null)` (runtime.dart line 472).
That is a 20,000-element list allocated at runtime creation, mostly null.

### Bottleneck severity: LOW

The 20k global slots waste memory but have minimal runtime cost.


## 10. Hot Path Analysis

For a typical numeric loop like:
```dart
int sum = 0;
for (int i = 0; i < n; i++) {
  sum += i;
}
```

The per-iteration hot path is approximately:
1. `NumLt` (compare i < n) - reads two frame slots, writes bool
2. `JumpIfFalse` - reads frame slot, conditional branch
3. `NumAdd` (sum + i) - reads two frame slots, writes num result
4. `BoxInt` (box result) - **allocates $int + $Object** (2 objects)
5. `CopyValue` (store to sum slot)
6. `PushConstantInt` (literal 1)
7. `NumAdd` (i + 1) - reads two frame slots
8. `BoxInt` (box i) - **allocates $int + $Object** (2 objects)
9. `CopyValue` (store to i slot)
10. `JumpConstant` (back to loop start)

Per iteration: ~10 ops, 4 heap allocations, 10 virtual dispatch calls.

For method-heavy code (OOP patterns), add:
- HashMap lookups for method/property dispatch
- Additional frame allocations per call
- Bridge crossing costs if interacting with native types


## 11. Allocation Summary Per Operation

| Operation | Heap Allocations |
|-----------|-----------------|
| PushScope (function entry) | 1 List(255) + 1 empty List for args |
| Call | 1 empty List for catchStack |
| BoxInt | 1 $int + 1 $Object |
| BoxDouble | 1 $double + 1 $Object |
| BoxBool | 1 $bool + 1 $Object |
| BoxString | 1 $String + 1 $Pattern |
| BoxNull | 1 $null (not const in BoxNull) |
| BoxList | 1 $List + 1 new List (spread copy) |
| BoxMap | 1 $Map + 1 new Map (spread copy) |
| InvokeExternal | 1 List for mapped args + 1 empty List for args |
| PushFunctionPtr | 1 EvalFunctionPtr + 2 Lists (posArgTypes, sortedNamedArgTypes) |
| PushFunctionPtrCopyCapture | Same as above + 1 List(255) copy |
| CreateClass | 1 $InstanceImpl + 1 List(valuesLen) |
| EvalFunctionPtr.call | 1 new List (spread args) |
| PushObjectProperty (method) | 1 EvalStaticFunctionPtr |
| InvokeDynamic ($Instance path) | 1 new List for args.cast() |
| BridgeInstantiate | 1 List for mapped args + 1 empty List + 1 BridgeData |


## 12. Optimization Opportunities

### P0: Switch-based dispatch (replaces virtual dispatch)

Replace the polymorphic virtual call with a switch on opcode int. Store op
data in parallel arrays (or a flat bytecode buffer) instead of op objects.

Expected impact: 2-5x speedup on the dispatch loop itself.

```
// Current: virtual dispatch
final op = pr[_prOffset++];
op.run(this);

// Better: switch dispatch
final opcode = opcodes[_prOffset++];
switch (opcode) {
  case Evc.OP_ADDVV: _numAdd(); break;
  case Evc.OP_BOXINT: _boxInt(); break;
  ...
}
```

Even better: decode operands inline from a flat int array instead of storing
them in object fields.

### P0: Eliminate superclass allocation in $num/$bool/$String

`$num` constructor allocates `$Object($value)` for the `_superclass` field.
`$bool` does the same. `$String` allocates `$Pattern.wrap($value)`. These
superclass objects exist only to delegate `$getProperty` fallback.

Fix: merge the fallback properties (==, !=, toString, hashCode) into each
wrapper's switch statement directly. Eliminate the _superclass field entirely.

Expected impact: cuts boxing allocation in half for all primitives.

### P1: Sized frames instead of fixed 255

The compiler knows how many locals each function needs. Encode this in the
PushScope op and allocate `List<Object?>.filled(actualSize, null)`.

Expected impact: reduces frame allocation cost, especially for small functions.

### P1: Eliminate per-call catchStack allocation

Instead of pushing a new empty `List<int>` for every Call, use an index into a
shared catch stack or use a sentinel value.

### P1: Fix $Bridge try/catch control flow

Replace the exception-based dispatch in $Bridge.$getProperty with an explicit
check. The BridgeDelegatingShim could return a sentinel value instead of
throwing UnimplementedError.

### P2: Constant $null / $bool singletons

`BoxNull` allocates `$null()` on every invocation. It should use `const $null()`.
There are only two possible $bool values; they could be cached as constants.

### P2: EvalFunctionPtr.call avoids list spread

```dart
runtime.args = [if ($prev != null) $prev, ...args];
```
This creates a new list every call. Could pre-allocate or use a different
args-passing strategy.

### P2: Cache method/property lookups

Replace HashMap string lookups in `InvokeDynamic` and `PushObjectProperty` with
integer-indexed method tables. The compiler already knows the method set of each
class; it could assign integer indices at compile time.

### P3: Frame pooling

Maintain a pool of reusable frames to avoid repeated allocation/GC of 255-
element lists.

### P3: Flat bytecode buffer

Instead of `List<EvcOp>` (list of objects), encode the program as a flat
`Int32List` or `Uint8List`. Operands are read inline during dispatch. This
eliminates all op object allocations at load time and improves cache locality.


## 13. Architecture Issues

### 13.1 Mutable runtime state everywhere

The Runtime class has ~30 mutable fields: `frame`, `args`, `returnValue`,
`frameOffset`, `_prOffset`, `inCatch`, `catchControlFlowOutcome`,
`rethrowException`, `returnFromCatch`, etc. This makes the execution model
hard to reason about and impossible to parallelize.

### 13.2 args as shared mutable state

`runtime.args` is used both as a parameter-passing mechanism and as temporary
storage during op execution (e.g., PushFunctionPtr reads from args at lines
320-333 of flow.dart). This dual use is fragile and requires careful ordering
of ops.

### 13.3 bridgeCall re-entrancy

`bridgeCall` creates a nested dispatch loop. This means eval'd code can call
bridge code which calls back into eval'd code, creating nested native stack
frames. Deep nesting can overflow the native stack. Each re-entry also
duplicates the try/catch overhead.

### 13.4 Global mutable state

`Runtime.bridgeData` is a static Expando (runtime_bridge.dart line 746 of
runtime.dart). This means bridge data is global, not per-runtime. The $Bridge
mixin reads `Runtime.bridgeData[this]` in `$_get`, `$_set`, `$_invoke`,
`$getProperty`, `$setProperty`, and `$getRuntimeType`. An Expando lookup is
effectively a weak map lookup on every bridge property access.

### 13.5 Constant pool accessed by index with dynamic casts

`runtime.constantPool[_methodIdx] as String` (objects.dart line 21) - no type
safety, relies on compiler producing correct indices.

### 13.6 String-keyed dispatch in $getProperty

Every bridge wrapper has a giant switch on string identifiers. $String has ~25
cases, $num has ~30 cases, $int has ~12 more. These string comparisons happen
on every property access.

### 13.7 Duplicated return logic

The Return op (flow.dart lines 175-225) has complex logic around catch/finally
state, duplicated in ReturnAsync. The special values of `_location` (-1, -2, -3)
are magic numbers with implicit semantics.


## 14. Summary of Bottleneck Severity

| Bottleneck | Severity | Impact |
|-----------|----------|--------|
| Virtual dispatch loop | CRITICAL | Every op pays ~5-10ns overhead |
| $num/$bool/$String superclass alloc | HIGH | 2x allocations per box |
| Fixed 255-slot frames | HIGH | Wasted memory + GC pressure |
| HashMap method dispatch | HIGH | O(n) string hash per call |
| $Bridge try/catch control flow | CRITICAL | Exception per bridge prop access |
| Per-call catchStack allocation | MEDIUM | 1 list alloc per function call |
| Closure captures whole frame | MEDIUM | 255-element copy in loops |
| EvalFunctionPtr spread args | MEDIUM | 1 list alloc per closure call |
| No $null/$bool constants | LOW | Easy fix, minor impact |
| 20k global slots | LOW | Memory waste at startup |

### Estimated overall interpreter overhead vs native Dart

For numeric-heavy code: **50-200x slower** (dominated by boxing + dispatch)
For OOP/method-heavy code: **100-500x slower** (HashMap dispatch + bridge costs)
For bridge-crossing code: **200-1000x slower** (exception-based control flow)

These are rough estimates based on the allocation and dispatch patterns observed.
The two highest-leverage fixes are switching to int-based dispatch and eliminating
superclass allocations in primitive wrappers.
