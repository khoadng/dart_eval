# deval v2 Architecture Design
Phase: 4 | Status: COMPLETE


## 1. Bytecode Format (EVC v2)

### 1.1 Instruction Encoding

Fixed 32-bit words stored in an `Int32List`. Every instruction is exactly one
word. No variable-length encoding, no byte streams, no strings in the bytecode
stream.

```
  31       24 23       16 15        8 7         0
  +---------+-----------+-----------+-----------+
  | opcode  |     A     |     B     |     C     |   ABC format
  +---------+-----------+-----------+-----------+
  | opcode  |     A     |         Bx            |   ABx format
  +---------+-----------+-----------+-----------+
  | opcode  |     A     |         sBx           |   AsBx format (signed)
  +---------+-----------+-----------+-----------+
  | opcode  |              Ax                   |   Ax format
  +---------+-----------+-----------+-----------+
  | opcode  |             sAx                   |   sAx format (signed)
  +---------+-----------+-----------+-----------+
```

- **Opcode**: 8 bits (256 opcodes max, ~90 used initially)
- **A**: 8 bits (register index 0-255)
- **B, C**: 8 bits each (register or small constant)
- **Bx**: 16 bits unsigned (constant pool index, jump offset)
- **sBx**: 16 bits signed (relative jump -32768..+32767)

This is Lua's proven encoding. Eight bits per register is enough (256 locals
per function). Sixteen bits for constant pool indices handles up to 65536
constants per function; larger programs use a wide-constant opcode.

### 1.2 Opcode Table

Current deval has **74 opcodes** as heap-allocated op objects. v2 targets
**~90 opcodes** as integer cases in a switch, organized by category.

```
  Category            Opcodes  Current Equivalent
  -----------------------------------------------
  Load/Store          ~15      PushConstantInt, PushNull, CopyValue, etc.
  Arithmetic/Logic    ~15      NumAdd, NumSub, NumLt (+ new: Mul, Div, Mod, etc.)
  Comparison/Test     ~8       CheckEq, IsType, LogicalNot, etc.
  Control Flow        ~10      Jump, Call, Return, etc.
  Object/Property     ~10      CreateClass, GetProp, SetProp, etc.
  Bridge/External     ~6       InvokeExternal, BridgeInstantiate, etc.
  Collection          ~8       NewList, ListAppend, IndexList, etc.
  Closure/Capture     ~4       Closure, GetUpvalue, SetUpvalue, CloseUpvalue
  Async               ~4       Await, ReturnAsync, Complete, Suspend
  Type                ~4       IsType, CastType, PushRuntimeType, PushConstType
  Misc                ~6       Nop, WideCons, Assert, Try, Throw, PopCatch
```

#### Load/Store

```
  Op              Fmt    Semantics
  -----------------------------------------------
  LoadConst       ABx    R[A] = K[Bx]
  LoadConstW      Ax     R[prev_A] = K[wide_index]  (for >65535 constants)
  LoadInt         AsBx   R[A] = sBx                  (small int literal)
  LoadTrue        A--    R[A] = true
  LoadFalse       A--    R[A] = false
  LoadNull        A--    R[A] = null
  Move            AB-    R[A] = R[B]
  LoadGlobal      ABx    R[A] = globals[Bx]
  StoreGlobal     ABx    globals[Bx] = R[A]
  GetUpvalue      AB-    R[A] = upvalues[B]
  SetUpvalue      AB-    upvalues[B] = R[A]
  LoadRetval      A--    R[A] = accumulator
  StoreRetval     A--    accumulator = R[A]
  Pop             A--    frameOffset -= A
```

#### Arithmetic/Logic

```
  Op              Fmt    Semantics
  -----------------------------------------------
  AddRR           ABC    R[A] = R[B] + R[C]          (unboxed num)
  SubRR           ABC    R[A] = R[B] - R[C]
  MulRR           ABC    R[A] = R[B] * R[C]
  DivRR           ABC    R[A] = R[B] / R[C]
  ModRR           ABC    R[A] = R[B] % R[C]
  IntDivRR        ABC    R[A] = R[B] ~/ R[C]
  NegR            AB-    R[A] = -R[B]
  ShlRR           ABC    R[A] = R[B] << R[C]
  ShrRR           ABC    R[A] = R[B] >> R[C]
  BitAndRR        ABC    R[A] = R[B] & R[C]
  BitOrRR         ABC    R[A] = R[B] | R[C]
  BitXorRR        ABC    R[A] = R[B] ^ R[C]
  BitNotR         AB-    R[A] = ~R[B]
  NotR            AB-    R[A] = !R[B]                (bool)
  ConcatRR        ABC    R[A] = R[B] + R[C]          (String)
```

#### Comparison/Test

```
  Op              Fmt    Semantics
  -----------------------------------------------
  EqRR            ABC    R[A] = R[B] == R[C]
  LtRR            ABC    R[A] = R[B] < R[C]
  LeRR            ABC    R[A] = R[B] <= R[C]
  GtRR            ABC    R[A] = R[B] > R[C]
  GeRR            ABC    R[A] = R[B] >= R[C]
  IsTypeR         ABx    R[A] = R[A] is typeIds[Bx]
  IsNotTypeR      ABx    R[A] = R[A] is! typeIds[Bx]
  TestNull        AB-    R[A] = R[B] == null
```

#### Control Flow

```
  Op              Fmt    Semantics
  -----------------------------------------------
  Jump            sAx    pc += sAx
  JumpTrue        AsBx   if R[A] == true: pc += sBx
  JumpFalse       AsBx   if R[A] == false: pc += sBx
  JumpNull        AsBx   if R[A] == null: pc += sBx
  JumpNotNull     AsBx   if R[A] != null: pc += sBx
  Call            ABx    call func at codeOffset Bx, A = arg count
  TailCall        ABx    (same as Call but reuses frame)
  Return          A--    return R[A]  (-1 = void)
  ReturnAsync     AB-    complete R[B] with R[A], return future
```

#### Object/Property

```
  Op              Fmt    Semantics
  -----------------------------------------------
  NewObject       ABx    R[A] = new instance of classId Bx
  GetField        ABC    R[A] = R[B].fields[C]       (eval'd, by index)
  SetField        ABC    R[A].fields[C] = R[B]       (eval'd, by index)
  GetPropDyn      ABx    R[A] = R[A].prop(K[Bx])     (dynamic, string)
  SetPropDyn      ABx    R[A].prop(K[Bx]) = R[prev]  (dynamic, string)
  InvokeDyn       ABx    R[A].method(K[Bx])(args)    (vtable or bridge)
  GetPropIC       ABC    R[A] = R[B].prop  (inline-cached, C = cache slot)
  InvokeIC        ABC    R[A].method(args) (inline-cached, C = cache slot)
```

#### Bridge/External

```
  Op              Fmt    Semantics
  -----------------------------------------------
  CallExternal    ABx    R[A] = externFuncs[Bx](args)
  BridgeNew       ABx    R[A] = bridge_construct(Bx, args)
  WrapValue       AB-    R[A] = box(R[B])             (to $Value)
  UnwrapValue     AB-    R[A] = unbox(R[B])            (from $Value)
  AutoWrap        AB-    R[A] = smartWrap(R[B])        (type-aware)
```

#### Collection

```
  Op              Fmt    Semantics
  -----------------------------------------------
  NewList         A--    R[A] = []
  NewMap          A--    R[A] = {}
  NewSet          A--    R[A] = Set()
  ListAppend      AB-    R[A].add(R[B])
  ListGet         ABC    R[A] = R[B][R[C]]
  ListSet         ABC    R[A][R[B]] = R[C]
  MapSet          ABC    R[A][R[B]] = R[C]
  MapGet          ABC    R[A] = R[B][R[C]]
  Length          AB-    R[A] = R[B].length
```

#### Closure/Capture

```
  Op              Fmt    Semantics
  -----------------------------------------------
  Closure         ABx    R[A] = new closure(proto Bx, upvalues from desc)
  GetUpvalue      AB-    R[A] = upvalues[B]
  SetUpvalue      AB-    upvalues[B] = R[A]
  CloseUpvalue    A--    close open upvalues from R[A] upward
```

#### Async

```
  Op              Fmt    Semantics
  -----------------------------------------------
  Await           AB-    suspend, resume when R[B] completes, result in R[A]
  Suspend         ---    serialize frame state for async gap
  ReturnAsync     AB-    complete completer R[B] with R[A]
```

#### Exception

```
  Op              Fmt    Semantics
  -----------------------------------------------
  Try             ABx    push catch handler at pc + Bx
  PopCatch        ---    pop top catch handler
  Throw           A--    throw R[A]
  PushFinally     ABx    push finally block, jump to try body at pc + Bx
```

### 1.3 Constant Pool

Each function prototype has its own constant pool (like Lua), stored as a
`List<Object>`. Entries are indexed by the Bx field in instructions.

Types of constants:
- Integers too large for sBx (outside -32768..32767)
- All doubles
- All strings
- Type descriptors
- Function prototypes (nested closures)

### 1.4 Function Prototypes

Functions are not delimited in the bytecode stream. Instead, each function
is a **FunctionProto** object assembled at compile time:

```dart
class FunctionProto {
  final String name;
  final Int32List code;           // bytecode instructions
  final List<Object> constants;   // constant pool
  final int numParams;            // positional param count
  final int numLocals;            // total register slots needed
  final int stackSize;            // max stack usage
  final List<UpvalueDesc> upvalues;  // upvalue descriptors
  final List<FunctionProto> children; // nested function protos
  final int sourceFile;           // for debug info
  final Int32List lineMap;        // pc -> source line (debug)
}

class UpvalueDesc {
  final bool isLocal;    // true = captures from immediate parent
  final int index;       // register index (if local) or upvalue index (if not)
}
```

### 1.5 Binary Format (EVC v2)

Section-based format for streaming and lazy loading:

```
  Offset   Size    Content
  -----------------------------------------------
  0        4       Magic: "EV2\0"
  4        4       Version (int32)
  8        4       Section count (int32)
  12       ...     Section directory (type:u8, offset:u32, size:u32 per entry)
  ...      ...     Section data

  Section types:
    0x01  TYPE_TABLE     Type IDs, type hierarchy sets
    0x02  STRING_TABLE   All interned strings (names, identifiers)
    0x03  GLOBAL_TABLE   Global variable descriptors
    0x04  CLASS_TABLE    Class descriptors (vtable layouts, field counts)
    0x05  FUNC_TABLE     Function prototypes (code + constants)
    0x06  BRIDGE_MAP     Bridge library/function index mappings
    0x07  ENTRY_POINTS   Library -> function name -> func index
    0x08  DEBUG_INFO     Source maps, names (optional, strippable)
```

All metadata is binary-encoded (no JSON). Strings are length-prefixed UTF-8.
Integer arrays are raw typed data. This eliminates the current JSON parsing
overhead during loading.


## 2. Value Representation

### 2.1 The Problem

Dart has no union types, no pointer tagging, no NaN boxing. But we need to
store int, double, bool, null, and heap objects in the same register file
without allocating a wrapper object for every primitive.

### 2.2 Dual-Track Registers

The register file uses two parallel arrays:

```
  Register file for one frame (n = numLocals from FunctionProto):

  ┌──────────────────────────────────────────────────────────┐
  │  Int64List  iRegs    [n]   integer/tag track              │
  │  List<Object?>  oRegs  [n]   object track                 │
  └──────────────────────────────────────────────────────────┘

  Tag encoding (stored in iRegs when the value is a primitive):
    bits 63..60 = type tag
    bits 59..0  = payload

  Tag values:
    0x0  = int         payload = the integer value (60-bit signed)
    0x1  = double      payload = unused, actual value in oRegs as boxed double
    0x2  = bool        payload = 0 or 1
    0x3  = null        payload = 0
    0x4  = object      payload = unused, actual object in oRegs
```

Wait -- this is overengineered for Dart. The Dart VM already boxes int/double
as Object? on `List<Object?>`. We cannot avoid that boxing. The real question is:
can we avoid allocating **$Value wrappers** on top of Dart's own boxing?

### 2.3 Practical Design: Object? Registers with Tag Byte Array

```dart
class Frame {
  final List<Object?> regs;     // values (int, double, bool, String, $Value, etc.)
  final Uint8List tags;         // type tags for fast dispatch
  final int size;

  Frame(this.size)
    : regs = List<Object?>.filled(size, null),
      tags = Uint8List(size);
}
```

Tag values:

```
  Tag   Meaning                  regs[i] contains
  ---   -------                  ----------------
  0     null                     null
  1     int (unboxed)            Dart int
  2     double (unboxed)         Dart double
  3     bool (unboxed)           Dart bool
  4     String (unboxed)         Dart String
  5     EvalObject               $EvalObject (eval'd class instance)
  6     BridgeObject             native Dart object (no $Value wrapper)
  7     Function                 EvalFunctionPtr or Dart Function
  8     List (unboxed)           Dart List
  9     Map (unboxed)            Dart Map
  10    Set (unboxed)            Dart Set
  255   boxed ($Value)           legacy $Value (migration path)
```

The tag byte tells the VM what type is in the register **without calling
$getRuntimeType or doing `is` checks**. Arithmetic ops read tags to confirm
operands are int/double and operate directly on raw Dart values.

### 2.4 Why This Works

In current deval, `a + b` where both are ints requires:

```
  Current:  frame[reg] = $int(frame[loc1] as int + frame[loc2] as int)
            Two $int allocations (operands), one $int allocation (result)
            Plus the virtual dispatch to reach this code

  v2:       regs[A] = (regs[B] as int) + (regs[C] as int)
            tags[A] = TAG_INT
            Zero allocations. One `as int` cast (which Dart AOT removes
            when preceded by a tag check).
```

The `as int` cast is needed for Dart's type system since regs is
`List<Object?>`, but the Dart AOT compiler can elide the check when it can
prove the value is an int (which follows from the tag check in the opcode
implementation).

### 2.5 Bridge Boundary Crossing

When eval'd code calls a bridge function, values must become `$Value`.
When bridge code calls back, `$Value` must become tagged register values.

```
  Eval -> Bridge:
    Tag 1 (int)     -> $int(regs[i] as int)        // allocate wrapper
    Tag 2 (double)  -> $double(regs[i] as double)
    Tag 3 (bool)    -> $bool(regs[i] as bool)
    Tag 4 (String)  -> $String(regs[i] as String)
    Tag 5 (EvalObj) -> regs[i] as $EvalObject       // already $Value
    Tag 6 (Bridge)  -> wrap via bridge descriptor
    Tag 0 (null)    -> $null()

  Bridge -> Eval:
    $int            -> regs[i] = value.$value, tags[i] = TAG_INT
    $double         -> regs[i] = value.$value, tags[i] = TAG_DOUBLE
    $Value          -> regs[i] = value, tags[i] = TAG_BOXED
```

Boxing only happens at the bridge boundary, not on every arithmetic op.
In a tight numeric loop with no bridge calls, zero $Value allocations occur.


## 3. Runtime Architecture

### 3.1 Dispatch Loop

The core of the VM. Switch on int read from Int32List:

```dart
class VM {
  void execute(FunctionProto proto, Frame frame) {
    final code = proto.code;
    var pc = 0;

    while (true) {
      final instr = code[pc++];
      final op = instr >>> 24;           // top 8 bits
      final a  = (instr >>> 16) & 0xFF;  // bits 23..16
      final b  = (instr >>> 8) & 0xFF;   // bits 15..8
      final c  = instr & 0xFF;           // bits 7..0
      final bx = instr & 0xFFFF;         // bits 15..0 unsigned
      final sbx = bx - 32768;            // bits 15..0 signed

      switch (op) {
        case OP_MOVE:
          frame.regs[a] = frame.regs[b];
          frame.tags[a] = frame.tags[b];

        case OP_LOAD_INT:
          frame.regs[a] = sbx;
          frame.tags[a] = TAG_INT;

        case OP_ADD_RR:
          frame.regs[a] = (frame.regs[b] as int) + (frame.regs[c] as int);
          frame.tags[a] = TAG_INT;

        case OP_CALL:
          _call(frame, a, bx, pc);
          // after return, result is in frame.regs[a]

        case OP_RETURN:
          _return(frame, a);
          return;

        case OP_JUMP:
          pc += (instr & 0xFFFFFF) - 0x800000; // 24-bit signed

        // ... ~90 cases total
      }
    }
  }
}
```

The switch on int compiles to a jump table in Dart AOT. This is the fastest
dispatch available in Dart, equivalent to QuickJS's `switch(opcode)` fallback
(which is what QuickJS uses when computed goto is unavailable).

### 3.2 Frame Layout

```
  Frame for function foo(a, b) with 3 locals and 2 temps:
  ┌─────────────────────────────────────────────────┐
  │  regs:  [a] [b] [local0] [local1] [local2] [t0] [t1]  │
  │  tags:  [1] [1] [0]      [0]      [0]      [0]  [0]   │
  │         ^^params  ^^locals          ^^temporaries       │
  └─────────────────────────────────────────────────┘
  size = numParams + numLocals  (known at compile time)
```

No more fixed 255-slot frames. The compiler computes exact register counts
per function. Frame allocation:

```dart
class Frame {
  factory Frame.forProto(FunctionProto proto) {
    final size = proto.numLocals;
    return Frame._(
      List<Object?>.filled(size, null),
      Uint8List(size),
      size,
    );
  }
}
```

### 3.3 Call Convention

Arguments are passed via a shared argument buffer, not a newly-allocated list:

```dart
class VM {
  // Reusable argument buffer, grown as needed, never shrunk
  final _argBuf = List<Object?>.filled(32, null);
  final _argTagBuf = Uint8List(32);
  int _argCount = 0;

  void _pushArg(Object? value, int tag) {
    if (_argCount >= _argBuf.length) _growArgBuf();
    _argBuf[_argCount] = value;
    _argTagBuf[_argCount] = tag;
    _argCount++;
  }
}
```

On `OP_CALL`:
1. Save current frame, pc to the call stack
2. Create new Frame (from a frame pool if available)
3. Copy args from _argBuf into new frame's registers 0..N-1
4. Copy tags from _argTagBuf
5. Reset _argCount
6. Set pc = target function's code offset
7. Continue dispatch loop

On `OP_RETURN`:
1. Store return value in caller's designated register
2. Restore frame and pc from call stack
3. Return frame to pool

### 3.4 Call Stack

```dart
class CallStack {
  // Parallel arrays for cache locality
  final frames = <Frame>[];
  final pcs = <int>[];
  final protos = <FunctionProto>[];
  final catchStacks = <List<CatchEntry>>[];
  int depth = 0;

  void push(Frame frame, int pc, FunctionProto proto) {
    if (depth >= frames.length) {
      frames.add(frame);
      pcs.add(pc);
      protos.add(proto);
      catchStacks.add([]);
    } else {
      frames[depth] = frame;
      pcs[depth] = pc;
      protos[depth] = proto;
      catchStacks[depth] = [];
    }
    depth++;
  }

  (Frame, int, FunctionProto) pop() {
    depth--;
    return (frames[depth], pcs[depth], protos[depth]);
  }
}
```

### 3.5 Exception Handling

Structured exception handling without Dart try/catch in the hot path:

```dart
class CatchEntry {
  final int handlerPc;       // bytecode offset of catch block
  final int frameDepth;      // call stack depth when try was entered
  final int frameOffset;     // register offset to restore
  final bool isFinally;
}
```

On `OP_TRY`: push a CatchEntry onto the current frame's catch stack.

On `OP_THROW`:
1. Walk catch stacks from current frame upward
2. Find the nearest CatchEntry
3. Unwind call stack to that depth
4. Set pc = handlerPc
5. Store exception in designated register
6. Continue dispatch

No Dart `try/catch` wrapping each bridge call. The VM's `$throw` method
does structured unwinding entirely within the interpreter's own data
structures, only throwing a real Dart exception when unwinding reaches
the VM boundary (no catch handler found).

### 3.6 Globals

```dart
class GlobalTable {
  final regs = List<Object?>.filled(8192, null);
  final tags = Uint8List(8192);
  final initializers = Int32List(8192); // func index, -1 = no initializer
  final initialized = Uint8List(8192);  // 0 = not yet, 1 = done

  Object? load(int index, VM vm) {
    if (initialized[index] == 0) {
      vm.callInitializer(initializers[index]);
      initialized[index] = 1;
    }
    return regs[index];
  }
}
```

Lazy initialization on first access, same as current deval but with typed
storage instead of `List<Object?>.filled(20000, null)`.

### 3.7 Async/Await

Dart VM's SuspendState model adapted for the interpreter. On `OP_AWAIT`:

```dart
case OP_AWAIT:
  final future = frame.regs[b];
  // Serialize current state
  final suspension = AsyncSuspension(
    frame: frame,
    pc: pc,
    callDepth: callStack.depth,
    proto: currentProto,
  );
  // Schedule resumption
  (future as Future).then((result) {
    frame.regs[a] = result;
    frame.tags[a] = _tagFor(result);
    _resume(suspension);
  }, onError: (error) {
    _resumeWithThrow(suspension, error);
  });
  // Return the completer's future to the caller
  _returnAsync(frame, completerReg);
  return;
```

The key insight: the frame and its register arrays are heap objects that
survive the async gap. We don't need to serialize to a flat buffer -- we
just hold a reference to the frame. This matches Dart VM's approach where
SuspendState holds a reference to the suspended frame.


## 4. Object Model

### 4.1 Eval'd Class Instances

```dart
class EvalObject {
  final ClassDesc classDesc;       // shared metadata (vtable, field count)
  final List<Object?> fields;      // field values by index
  final Uint8List fieldTags;       // type tags per field

  EvalObject(this.classDesc)
    : fields = List<Object?>.filled(classDesc.fieldCount, null),
      fieldTags = Uint8List(classDesc.fieldCount);
}
```

No more `$InstanceImpl` extending `$Value`. The `EvalObject` is a plain Dart
object. It only gets wrapped in a `$Value` at the bridge boundary.

### 4.2 Class Descriptors with Vtables

```dart
class ClassDesc {
  final int typeId;
  final int fieldCount;
  final ClassDesc? superclass;

  // Vtable: integer-indexed arrays instead of HashMap<String, int>
  final Int32List getterOffsets;    // index -> bytecode offset (-1 = not defined)
  final Int32List setterOffsets;    // index -> bytecode offset (-1 = not defined)
  final Int32List methodOffsets;    // index -> bytecode offset (-1 = not defined)

  // For dynamic dispatch (string-based, used by bridge and toString/== etc.)
  final Map<int, int> memberNameToIndex;  // string_id -> vtable index
}
```

Member IDs are assigned at compile time. A global `StringTable` maps
identifiers to integer IDs. The compiler emits vtable indices directly in
bytecode, so `obj.foo()` compiles to `InvokeIC R[a], vtableIndex` rather than
`InvokeDynamic R[a], "foo"`.

### 4.3 Vtable Dispatch (Eval'd Classes)

```
  obj.someMethod(x, y)

  Current deval:
    1. constantPool[methodIdx] -> "someMethod"      (string lookup)
    2. object.evalClass.methods["someMethod"]        (HashMap lookup)
    3. if null, walk superclass chain                (repeated HashMap lookups)
    4. jump to offset

  v2:
    1. object.classDesc.methodOffsets[vtableIdx]     (array index)
    2. if -1, check superclass.methodOffsets[vtableIdx]
    3. jump to offset
```

Array index is O(1) and cache-friendly. The vtable index is a compile-time
constant baked into the instruction.

### 4.4 Bridge Class Instances

Native Dart objects are stored directly in registers with tag TAG_BRIDGE (6).
A `BridgeClassDesc` provides the dispatch table:

```dart
class BridgeClassDesc {
  final int typeId;

  // Bridge dispatch: member_id -> native handler function
  final List<BridgeHandler?> handlers;  // indexed by member_id

  // Each handler knows how to get/set/invoke
  // No more string-based $getProperty switch statements
}

typedef BridgeHandler = Object? Function(VM vm, Object target, List<Object?> args);
```

When eval'd code accesses a property on a bridge object:

```
  OP_GET_PROP_IC  A, B, cache_slot
    1. Read type tag of R[B]
    2. If TAG_BRIDGE:
       a. Look up BridgeClassDesc from type registry
       b. Call handlers[memberId](vm, regs[B], args)
    3. If TAG_EVAL_OBJECT:
       a. Use vtable dispatch
```

### 4.5 Inline Caches

Each call site has a small inline cache (1-2 entries) that remembers the
last type seen and its dispatch target:

```dart
class InlineCache {
  int cachedTypeId = -1;
  int cachedOffset = -1;   // for eval'd: bytecode offset
                            // for bridge: handler index

  int lookup(int typeId, ClassDesc desc, int memberId) {
    if (typeId == cachedTypeId) return cachedOffset;
    // cache miss: do full lookup, update cache
    final offset = desc.methodOffsets[memberId];
    cachedTypeId = typeId;
    cachedOffset = offset;
    return offset;
  }
}
```

The IC array is per-FunctionProto, allocated at load time. The `C` operand
in `GetPropIC`/`InvokeIC` instructions indexes into this array.

### 4.6 Generics at Runtime

Same as current deval: effectively erased. The type system tracks type IDs
for `is` checks using the type hierarchy sets (same typeTypes structure).
No monomorphization, no runtime type argument threading.

Future optimization: for hot paths where the generic type is known, the
compiler could emit specialized opcodes (e.g., `ListGetInt` that skips
type checking). This is a v2.1 concern.

### 4.7 Closures

Flat upvalue capture (QuickJS model), not whole-frame capture:

```dart
class EvalClosure {
  final FunctionProto proto;
  final List<Upvalue> upvalues;  // captured variables only
}

class Upvalue {
  Object? value;
  int tag;
  bool isOpen;          // true = still on parent's frame
  int registerIndex;    // which register in parent frame (while open)
  Frame? parentFrame;   // reference to parent frame (while open)

  Object? get() => isOpen ? parentFrame!.regs[registerIndex] : value;

  void set(Object? v, int t) {
    if (isOpen) {
      parentFrame!.regs[registerIndex] = v;
      parentFrame!.tags[registerIndex] = t;
    } else {
      value = v;
      tag = t;
    }
  }

  void close() {
    value = parentFrame!.regs[registerIndex];
    tag = parentFrame!.tags[registerIndex];
    isOpen = false;
    parentFrame = null;
  }
}
```

`OP_CLOSURE` creates an EvalClosure and populates its upvalue array using
the UpvalueDesc from the FunctionProto. Open upvalues share a reference
to the parent frame. `OP_CLOSE_UPVALUE` (emitted when a scope exits that
contains captured variables) copies the value out of the frame.

This replaces the current design where closures capture a reference to the
entire parent frame (`[...runtime.frame]`).


## 5. Bridge System v2

### 5.1 Design Goals

1. Zero allocation for numeric operations (no $Value wrappers in hot paths)
2. Integer-indexed dispatch instead of string-based
3. No exception-driven control flow
4. Codegen for bridge wrappers (not hand-written)
5. Minimal public API surface

### 5.2 Plugin API

```dart
abstract class DevalPlugin {
  void register(DevalRegistry registry);
}

class DevalRegistry {
  void declareClass(ClassSpec spec);
  void declareFunction(String library, String name, NativeHandler handler);
  void declareEnum(String library, String name, Map<String, Object> values);
}

class ClassSpec {
  final String library;
  final String name;
  final List<MemberSpec> members;
  final NativeConstructor? constructor;
  final int? superTypeId;
}

class MemberSpec {
  final String name;
  final MemberKind kind;     // getter, setter, method, field
  final NativeHandler handler;
}

typedef NativeHandler = Object? Function(VM vm, Object? target, ArgReader args);
typedef NativeConstructor = Object Function(VM vm, ArgReader args);
```

### 5.3 ArgReader (Zero-Allocation Argument Passing)

```dart
class ArgReader {
  final VM _vm;

  int get length => _vm._argCount;

  int intAt(int i) => _vm._argBuf[i] as int;
  double doubleAt(int i) => _vm._argBuf[i] as double;
  String stringAt(int i) => _vm._argBuf[i] as String;
  bool boolAt(int i) => _vm._argBuf[i] as bool;
  Object? objectAt(int i) => _vm._argBuf[i];
  int tagAt(int i) => _vm._argTagBuf[i];

  // For bridge compatibility during migration
  $Value? valueAt(int i) {
    final tag = tagAt(i);
    return switch (tag) {
      TAG_INT    => $int(intAt(i)),
      TAG_DOUBLE => $double(doubleAt(i)),
      TAG_BOOL   => $bool(boolAt(i)),
      TAG_STRING => $String(stringAt(i)),
      TAG_NULL   => const $null(),
      _          => objectAt(i) as $Value?,
    };
  }
}
```

No List<$Value?> allocation per call. The ArgReader reads directly from the
VM's reusable argument buffer.

### 5.4 How Native Dart Types Are Exposed

Codegen (invoked at build time or via CLI) reads Dart source and generates
bridge descriptors and handlers:

```dart
// INPUT (user's Dart class):
class Vector2 {
  double x, y;
  Vector2(this.x, this.y);
  double get length => sqrt(x * x + y * y);
  Vector2 operator +(Vector2 other) => Vector2(x + other.x, y + other.y);
}

// GENERATED (by deval bridge codegen):
class Vector2Bridge extends DevalPlugin {
  @override
  void register(DevalRegistry registry) {
    registry.declareClass(ClassSpec(
      library: 'package:game/vector2.dart',
      name: 'Vector2',
      members: [
        MemberSpec('x', MemberKind.getter, _getX),
        MemberSpec('x', MemberKind.setter, _setX),
        MemberSpec('y', MemberKind.getter, _getY),
        MemberSpec('y', MemberKind.setter, _setY),
        MemberSpec('length', MemberKind.getter, _getLength),
        MemberSpec('+', MemberKind.method, _opPlus),
      ],
      constructor: _construct,
    ));
  }

  static Object _construct(VM vm, ArgReader args) {
    return Vector2(args.doubleAt(0), args.doubleAt(1));
  }
  static Object? _getX(VM vm, Object? target, ArgReader args) =>
    (target as Vector2).x;
  static Object? _setX(VM vm, Object? target, ArgReader args) {
    (target as Vector2).x = args.doubleAt(0); return null;
  }
  // ... etc
}
```

The generated code is compact. Each handler is a one-liner. No $Value
wrappers, no BridgeClassDef metadata trees, no string-switch dispatch.

### 5.5 How Eval'd Code Calls Native Methods

```
  eval:  myVector.length

  1. OP_GET_PROP_IC  R[dest], R[vec], cache_slot=3
  2. VM checks tag: TAG_BRIDGE
  3. IC hit? -> call cached handler directly
  4. IC miss:
     a. Look up BridgeClassDesc by typeId
     b. Find handler for member "length" (by member_id)
     c. Update IC: cachedTypeId = typeId, cachedHandler = handler
     d. Call handler
  5. handler returns double -> store in R[dest], tags[dest] = TAG_DOUBLE
```

### 5.6 How Native Code Calls Eval'd Methods

```dart
// From native Dart code, call an eval'd function:
final result = vm.callFunction('package:game/main.dart', 'update', [
  deltaTime,  // raw double, no wrapping needed
]);
// result is a raw Dart value, not a $Value
```

Internally, `vm.callFunction` pushes args to the arg buffer with appropriate
tags, looks up the function offset, and enters the dispatch loop.

### 5.7 Backward-Compatible $Value Bridge

During migration, existing plugins that use the `$Value` API continue to
work through a compatibility layer:

```dart
class LegacyBridgeAdapter extends DevalPlugin {
  final EvalPlugin legacy;

  @override
  void register(DevalRegistry registry) {
    // Wrap each legacy bridge function to box/unbox at the boundary
    for (final func in legacy.functions) {
      registry.declareFunction(func.library, func.name, (vm, target, args) {
        final boxedArgs = List<$Value?>.generate(
          args.length, (i) => args.valueAt(i),
        );
        final boxedTarget = target != null ? vm.wrapValue(target) : null;
        final result = func.handler(vm.legacyRuntime, boxedTarget, boxedArgs);
        return result?.$value;
      });
    }
  }
}
```

This is intentionally slower than native v2 bridges. It exists only to
avoid a flag-day migration.


## 6. Compiler Changes

### 6.1 Intermediate Representation

v2 adds a lightweight IR between AST and bytecode:

```
  Source
    |
  [Dart Analyzer parseString()]
    |
  AST
    |
  [Lowering pass]
    |
  IR (list of IR nodes per function)
    |
  [Register allocation]
    |
  [Bytecode emission]
    |
  FunctionProto (Int32List code + constants)
```

The IR is a simple linear list of operations, close to bytecode but with
virtual registers (not yet assigned to physical register slots):

```dart
sealed class IRNode {}
class IRLoadInt extends IRNode { final int dest; final int value; }
class IRAdd extends IRNode { final int dest, left, right; }
class IRCall extends IRNode { final int dest; final int funcId; final List<int> args; }
class IRJump extends IRNode { final IRLabel target; }
class IRJumpFalse extends IRNode { final int cond; final IRLabel target; }
class IRReturn extends IRNode { final int src; }
class IRGetField extends IRNode { final int dest, obj, fieldIdx; }
// ... etc
```

### 6.2 Why an IR?

The current compiler emits bytecode directly from AST, which means:
- No dead code elimination (if/else branches that always go one way)
- No constant folding (`2 + 3` runs at runtime)
- No register reuse (every expression gets a new slot)
- No peephole optimization (redundant move elimination)

The IR enables optimization passes without the complexity of SSA:

### 6.3 Optimization Passes

**Pass 1: Constant folding**
Evaluate constant expressions at compile time. `2 + 3` becomes `LoadInt 5`.
String concatenation of literals, boolean logic on constants.

**Pass 2: Dead code elimination**
Remove unreachable code after unconditional jumps or returns. Remove
assignments to variables that are never read.

**Pass 3: Register allocation**
Linear scan over the IR to assign virtual registers to physical slots.
Reuse slots when variables are dead. This replaces the current sequential
allocation that never reclaims slots.

```dart
class RegisterAllocator {
  int allocate(IRNode node, Set<int> liveOut) {
    // Find a free register not in liveOut
    // Reuse registers from dead variables
    // Return the physical register index
  }
}
```

**Pass 4: Peephole optimization (on bytecode)**
After emission, scan the Int32List for patterns:
- `Move R[a], R[b]` followed by `Move R[b], R[a]` -> remove second
- `LoadInt R[a], 0` followed by `AddRR R[a], R[a], R[b]` -> `Move R[a], R[b]`
- Redundant tag updates when type is known

### 6.4 Compile-Time Information for Runtime

The compiler feeds dispatch information into the bytecode:

- **Member IDs**: every field/method/getter/setter gets a global integer ID.
  The instruction operand is this ID, not a string constant pool index.
- **Type IDs**: classes get depth-first IDs for fast subtype range checks.
- **Vtable layouts**: class descriptors include pre-built vtable arrays.
- **Frame sizes**: each FunctionProto declares exact register count.
- **Inline cache slots**: the compiler counts IC sites per function and
  allocates the IC array size.

### 6.5 String Interning

All identifiers (variable names, member names, library URIs) are interned
at compile time into a global StringTable. Runtime uses integer IDs
everywhere. String comparison only happens during initial loading.

```dart
class StringTable {
  final List<String> strings = [];
  final Map<String, int> index = {};

  int intern(String s) => index.putIfAbsent(s, () {
    strings.add(s);
    return strings.length - 1;
  });
}
```


## 7. Migration Path

### 7.1 Strategy: Parallel Runtime, Not Incremental Rewrite

The current runtime is too intertwined to refactor incrementally. The
dispatch loop, value representation, frame layout, and bridge system all
depend on each other. Changing one breaks the others.

The migration strategy:

```
  Phase   What                              Duration
  -----   ----                              --------
  M1      New bytecode format + IR          Foundation
          - Int32List bytecode encoding
          - FunctionProto structure
          - IR nodes and lowering pass
          - Register allocator
          - Bytecode emitter

  M2      New runtime core                  Core
          - Frame with tags
          - Switch-based dispatch loop
          - Call stack, call convention
          - Structured exception handling
          - Globals

  M3      Object model                      Objects
          - EvalObject + ClassDesc
          - Vtable dispatch
          - Upvalue-based closures
          - Inline caches

  M4      Bridge v2                         Bridge
          - New plugin API
          - ArgReader
          - Codegen tool
          - LegacyBridgeAdapter

  M5      Compiler integration              Connect
          - Replace direct bytecode emission with IR
          - Optimization passes
          - New bytecode output
          - Test parity with v1

  M6      Stdlib migration                  Stdlib
          - Migrate core/async/collection/io stdlib
          - Generate bridge code instead of hand-writing

  M7      Cleanup                           Ship
          - Remove v1 runtime
          - Update docs, examples
          - Performance benchmarks
```

### 7.2 Backward Compatibility

**EVC v1 files**: Not compatible with v2. The magic bytes change from
`EVC\0` to `EV2\0`. The Runtime can detect the version and give a clear
error message.

**Existing plugins**: Work through LegacyBridgeAdapter (section 5.7). This
wraps v1-style `EvalCallableFunc` functions to work with v2's ArgReader
pattern. Performance is worse than native v2 but functional.

**Public API**: `Runtime.executeLib()` remains the primary entry point.
`Runtime.ofProgram()` and `Runtime(evc)` constructors remain. The `Program`
class changes internally but the external contract is the same.

### 7.3 What Can Be Incremental

These changes can be merged to master independently before the full v2:

1. **String interning** in the compiler (member name -> int ID). This
   benefits v1 too by reducing constant pool string duplication.

2. **Frame size computation** in the compiler. Even if v1 still allocates
   255 slots, computing the actual size is useful data.

3. **IR introduction** as a compile target. The IR can emit v1 opcodes
   initially, then switch to v2 opcodes when the runtime is ready.

4. **Codegen tool** for bridge wrappers. Even generating v1-style wrappers
   saves manual effort and reduces bugs.

5. **Missing arithmetic opcodes** (mul, div, mod, shift, bitwise) in v1.
   These are independent additions to the current opcode set.

### 7.4 What Requires a Rewrite

1. **Dispatch loop**: must switch from virtual dispatch to switch-on-int.
   This is all-or-nothing -- there is no intermediate state.

2. **Value representation**: the Frame/tag system replaces List<Object?>.
   Every opcode implementation changes.

3. **Call convention**: arg buffer replaces `runtime.args = []`. Every
   call site and every bridge function signature changes.

4. **Exception handling**: structured unwinding replaces Dart try/catch
   per bridgeCall. The catch stack data structures change.

### 7.5 Testing Strategy

v1 has a test suite. The migration plan:

1. Keep v1 tests running throughout (never break master).
2. Build v2 runtime as a separate class (`VM` vs `Runtime`).
3. Port tests one-by-one to run against both v1 and v2.
4. When test parity is reached, deprecate v1.
5. After one release cycle, remove v1.


## Appendix: Size Comparison

```
  Aspect                    v1 (current)         v2 (proposed)
  ---------------------------------------------------------------
  Opcodes                   74                   ~90
  Dispatch                  virtual method       switch on int
  Instruction size          variable (1-N bytes) fixed 32 bits
  Instruction storage       List<EvcOp>          Int32List
  Frame size                255 (fixed)          computed per function
  Frame storage             List<Object?>        List<Object?> + Uint8List
  Value wrapper per int     2 objects ($int)      0 (raw Dart int)
  Method dispatch           HashMap<String,int>  Int32List vtable
  Bridge arg passing        List<$Value?> alloc   reusable buffer
  Bridge property access    try/catch             handler array lookup
  Closure capture           whole parent frame    flat upvalues
  Binary metadata           JSON strings          binary sections
  Constant pool             1 global              per function
  IR between AST/bytecode   none                  linear IR
  Optimization passes       none                  4 (fold, DCE, regalloc, peephole)
  Bridge codegen            none                  CLI tool
```
