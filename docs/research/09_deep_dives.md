# Deep Dives on Key Transferable Insights
Phase: 3 | Status: COMPLETE


## 1. Value Representation in Dart

This is the hardest problem in the redesign. Unlike C-based VMs that can use
NaN boxing, tagged pointers, or union types, we must work within Dart's type
system. Every value in the interpreter must be representable as a Dart object
that the Dart VM itself manages.

### Background: How Dart VM Handles Values Internally

The Dart VM uses Smi (Small Integer) tagging internally: on 64-bit platforms,
integers up to 63 bits are stored as tagged immediates with the low bit = 0.
All other objects have low bit = 1 (pointer tag). This means the VM never
heap-allocates small integers. Doubles, however, are always boxed on the heap
unless the compiler can prove they stay in registers (unboxed representation).

Key insight: when our interpreter stores a value in a `List<Object?>` slot,
the Dart VM already Smi-tags ints that fit in 63 bits. So raw `int` values in
a `List<Object?>` are already "free" from the Dart VM's perspective -- no heap
allocation. The problem is that we also need to track the TYPE of each value
(is it an int? a double? a string? an instance?) and that's where the cost
comes in.

### Current deval Cost

`$int(42)` allocates: 1 `$int` object + 1 `$Object` superclass = 2 heap objects.
Per boxing operation: ~32-64 bytes of heap, plus GC pressure.

### Approach A: Extension Type on int (Tag + Payload in 64-bit int)

```dart
extension type const DVal(int _bits) {
  // Tag in low 3 bits, payload in upper 61 bits
  static const _tagBits = 3;
  static const _tagMask = (1 << _tagBits) - 1; // 0x7

  // Tags
  static const tagInt    = 0; // 000
  static const tagDouble = 1; // 001
  static const tagBool   = 2; // 010
  static const tagNull   = 3; // 011
  static const tagString = 4; // 100
  static const tagObject = 5; // 101

  int get tag => _bits & _tagMask;
  int get payload => _bits >> _tagBits;

  // Constructors
  static DVal fromInt(int v) => DVal((v << _tagBits) | tagInt);
  static DVal fromBool(bool v) => DVal(((v ? 1 : 0) << _tagBits) | tagBool);
  static DVal get nil => const DVal(tagNull);

  // Fast extraction
  int get asInt => _bits >> _tagBits; // arithmetic shift preserves sign
  bool get asBool => (_bits >> _tagBits) == 1;
}
```

Analysis:

- Memory per value: 8 bytes (one int). Zero heap allocation.
- Allocation cost: None. Extension types compile away -- `DVal` IS an `int`.
- Dispatch cost: `switch (v.tag)` is a switch on `v & 7`, extremely fast.
- Int payload: 61-bit signed integers (more than enough for most uses).
- Double payload: CANNOT fit a 64-bit double in 61 bits. Two options:
  (a) Store an INDEX into a separate Float64List. The "payload" is a slot
      number, not the actual double value. This adds an indirection for doubles.
  (b) Use a separate representation for doubles entirely.
- String/Object payload: Store an INDEX into an object table (`List<Object>`).
  The payload is a handle/index, not the actual object.

```dart
// The interpreter state holds side tables for non-int values
class ValueStore {
  final Float64List doubles = Float64List(4096);
  int _doubleCount = 0;
  final List<Object> objects = []; // strings, instances, functions, etc.

  DVal boxDouble(double v) {
    final idx = _doubleCount++;
    doubles[idx] = v;
    return DVal((idx << 3) | DVal.tagDouble);
  }

  double unboxDouble(DVal v) => doubles[v.payload];

  DVal boxObject(Object obj) {
    final idx = objects.length;
    objects.add(obj);
    return DVal((idx << 3) | DVal.tagObject);
  }

  Object unboxObject(DVal v) => objects[v.payload];
}
```

Verdict on Approach A:

```
Strengths                          Weaknesses
+----------------------------------+----------------------------------+
| Zero allocation for int/bool/null| Doubles require indirection      |
| 8 bytes per value, flat in list  | Object handles need a side table |
| Switch on tag is ~1 instruction  | 61-bit int limit (not 64-bit)   |
| Extension type = zero overhead   | GC for object table is manual   |
| Cache-friendly (all ints inline) | Losing a double value = stale   |
+----------------------------------+----------------------------------+
```

The double indirection is the main weakness. For numeric-heavy code (the
primary bottleneck), doubles would go through `doubles[idx]` on every access.
This is still far better than allocating 2 objects per boxing operation.

The object table creates a GC problem: when does an entry get freed? Options:
(a) Never free -- acceptable for short-lived scripts, bad for long-running.
(b) Generation-based: reset the table between major GC points.
(c) Reference counting on handles (complex).

For a game scripting VM with frame-bounded lifetimes, option (a) or (b)
is likely sufficient. Scripts run for a frame, then state resets.


### Approach B: (int, int) Record -- Tag + Payload

```dart
typedef DVal = (int, int); // ($1 = tag, $2 = payload)

const tagInt    = 0;
const tagDouble = 1;
const tagBool   = 2;
const tagNull   = 3;
const tagObject = 4;

DVal valInt(int v)  => (tagInt, v);
DVal valBool(bool v) => (tagBool, v ? 1 : 0);
DVal valNull()       => (tagNull, 0);
```

Analysis:

- Memory per value: 16 bytes (two ints) if stored as a record object on the
  heap. Potentially 0 bytes if the compiler can scalar-replace.
- Allocation cost: THIS IS THE CRITICAL QUESTION. Dart records are immutable
  value types. The Dart VM's allocation sinking can eliminate heap allocation
  for objects that don't escape the current scope. However, allocation sinking
  currently only handles `AllocateObject` and `AllocateUninitializedContext` --
  it does NOT handle array types, and records may or may not be covered.

The Dart VM's optimizer can scalar-replace records when:
1. The record doesn't escape the function (stored only in local variables).
2. All field accesses are statically resolved.
3. The record is not stored in a `List<Object?>` (which forces boxing).

Problem: in an interpreter, values are stored in a frame which is a
`List<Object?>`. Storing a `(int, int)` record into `List<Object?>` FORCES
heap allocation of the record because it must be boxed as an `Object?`.

```dart
// This forces heap allocation -- the record escapes into the list
frame[slot] = (tagInt, 42); // heap-allocates a _Record2 object
```

This means records in a `List<Object?>` frame are no better than a small
class. They might even be WORSE because the record overhead includes type
descriptors for the field types.

Verdict on Approach B:

```
Strengths                          Weaknesses
+----------------------------------+----------------------------------+
| Clean syntax                     | Heap-allocated when stored in    |
| Immutable (safe)                 | List<Object?> (the frame)        |
| Destructuring is ergonomic       | 16+ bytes per value on heap      |
| Compiler knows field types       | No evidence of stack allocation  |
|                                  | for records in containers        |
+----------------------------------+----------------------------------+
```

Records are WORSE than extension-type-on-int for interpreter values.
They offer no advantage over a small class when they must live in a list.


### Approach C: Sealed Class Hierarchy

```dart
sealed class DVal {}

final class DInt implements DVal {
  final int value;
  DInt(this.value);
}

final class DDouble implements DVal {
  final double value;
  DDouble(this.value);
}

final class DBool implements DVal {
  final bool value;
  DBool(this.value);
}

final class DNull implements DVal {
  const DNull();
}

final class DString implements DVal {
  final String value;
  DString(this.value);
}

final class DObject implements DVal {
  final Object value;
  DObject(this.value);
}
```

Dispatch via pattern matching:

```dart
switch (val) {
  case DInt(:final value): return value + 1;
  case DDouble(:final value): return value + 1.0;
  case DBool(:final value): return !value;
  // ...
}
```

Analysis:

- Memory per value: 16 bytes minimum (object header 8 bytes + field 8 bytes)
  on 64-bit. `DInt` = 16 bytes. `DDouble` = 24 bytes (8 header + 8 double,
  possibly 8 padding). `DNull` = 8 bytes if const singleton.
- Allocation cost: Every `DInt(42)` allocates a heap object. The Dart VM
  CAN potentially allocation-sink these, but only if the value doesn't escape
  into a List (which it must, for the frame).
- Dispatch cost: The Dart AOT compiler knows all subtypes of a sealed class
  (they must be in the same library). Pattern matching on sealed classes
  compiles to class-ID (cid) range checks. The Dart VM assigns class IDs
  using depth-first numbering, so `is DInt` compiles to something like:
  `cid >= DInt_cid_start && cid <= DInt_cid_end` -- typically 1-2 comparisons.
  For a sealed class with 6 subtypes, this is a chain of cid range checks,
  similar to a binary search. NOT a jump table.

Important nuance from Dart SDK issue #53594: a class holding an int can
sometimes be MORE efficient than a plain int in AOT, because the compiler
can avoid the Smi tagging/untagging overhead when the value is stored in a
typed field. The class's `int` field is stored unboxed within the object.

However, each `DInt` still requires a heap allocation. For a numeric loop
doing 1M iterations, that's 1M allocations (better than deval's current
2M, but still 1M too many).

Verdict on Approach C:

```
Strengths                          Weaknesses
+----------------------------------+----------------------------------+
| Idiomatic Dart                   | 1 heap alloc per value           |
| Exhaustive pattern matching      | 16-24 bytes per value            |
| Compiler knows all subtypes      | cid range check, not jump table  |
| final classes = no subclassing   | GC pressure in tight loops       |
| Can add methods to subtypes      | Can't avoid alloc when in a List |
+----------------------------------+----------------------------------+
```


### Approach D: Object? with Runtime Type Checks

```dart
// Frame is List<Object?>, values are raw Dart types
// int stored as int, double as double, String as String
// Instances stored as actual instance objects

Object? frame = List<Object?>.filled(frameSize, null);

// Dispatch
void addOp(List<Object?> frame, int dst, int a, int b) {
  final va = frame[a];
  final vb = frame[b];
  if (va is int && vb is int) {
    frame[dst] = va + vb;
  } else if (va is double || vb is double) {
    frame[dst] = (va as num) + (vb as num);
  }
}
```

Analysis:

- Memory per value: Same as the raw Dart value. `int` in `List<Object?>` is
  Smi-tagged by the VM (0 bytes extra for small ints). `double` is boxed by
  the VM (~16 bytes). `String` is the String object itself.
- Allocation cost: Zero for ints (Smi). One box for doubles. Zero extra for
  strings/objects (they already exist).
- Dispatch cost: `if (v is int)` compiles to a Smi tag check in native code:
  test if the low bit is 0. This is ONE INSTRUCTION on x86/ARM. It's the
  cheapest possible type check. `if (v is double)` checks the cid against
  the Double class ID range -- slightly more expensive but still a couple
  of comparisons.
- Type ambiguity: There's no way to distinguish between "interpreter int"
  and "interpreter bool" since Dart `bool` IS a distinct type. But what about
  distinguishing "interpreter null" from "Dart null in the frame"? Since
  frame slots are initialized to null, we'd need a sentinel for "unset".

The critical insight from the Dart VM internals: `is int` on an `Object?`
compiles to a SINGLE BIT TEST (check if low bit is 0 = Smi). This is
the cheapest possible dispatch for integers, faster than any tag scheme
we could build ourselves.

```
// Pseudo-assembly for `if (v is int)` in Dart AOT:
test rax, 1      // check low bit
jnz  not_int     // if set, not a Smi -> not int
// ... int path, value = rax >> 1
```

For doubles:
```
// Pseudo-assembly for `if (v is double)` in Dart AOT:
test rax, 1      // check if Smi first
jz   not_double  // Smi is not double
movzx ecx, [rax + kClassIdOffset]  // load class ID
cmp   ecx, kDoubleCid
jne   not_double
// ... double path
```

Verdict on Approach D:

```
Strengths                          Weaknesses
+----------------------------------+----------------------------------+
| Zero alloc for ints (Smi!)       | Can't distinguish custom types   |
| Leverages VM's own optimizations | double still boxed by VM         |
| is-int = 1 instruction           | No tag for "interpreter type"    |
| No wrapper overhead at all       | Need separate type tracking for  |
| Frame stores raw values          | objects (instance vs function)   |
| Simplest code                    | Bool is separate from int        |
+----------------------------------+----------------------------------+
```


### Approach E: Parallel Typed Arrays (Split Representation)

```dart
class TypedFrame {
  final Uint8List tags;      // type tag per slot
  final Int64List ints;      // int values (also bool as 0/1)
  final Float64List doubles; // double values
  final List<Object?> refs;  // strings, instances, functions

  TypedFrame(int size)
      : tags = Uint8List(size),
        ints = Int64List(size),
        doubles = Float64List(size),
        refs = List<Object?>.filled(size, null);

  // Tags
  static const tInt    = 0;
  static const tDouble = 1;
  static const tBool   = 2;
  static const tNull   = 3;
  static const tRef    = 4;

  void setInt(int slot, int value) {
    tags[slot] = tInt;
    ints[slot] = value;
  }

  int getInt(int slot) => ints[slot];

  void setDouble(int slot, double value) {
    tags[slot] = tDouble;
    doubles[slot] = value;
  }

  double getDouble(int slot) => doubles[slot];

  void setRef(int slot, Object obj) {
    tags[slot] = tRef;
    refs[slot] = obj;
  }
}
```

Analysis:

- Memory per value: 1 byte (tag) + 8 bytes (int OR double) + 8 bytes (ref
  slot, always allocated). Total per slot: ~25 bytes with all arrays, BUT
  only the relevant array is "active". Memory efficiency depends on sparsity.
- Allocation cost: ZERO for primitives. `ints[slot] = 42` writes directly
  into a typed array with no boxing. `doubles[slot] = 3.14` also zero
  boxing -- Float64List stores raw IEEE 754 doubles.
- Dispatch cost: `switch (tags[slot])` on a Uint8List element. This is a
  byte load + switch on small int -- very fast.
- GC interaction: Typed arrays (Int64List, Float64List) are opaque to GC --
  the GC doesn't scan them for pointers. Only `List<Object?>` refs is scanned.
  This REDUCES GC work compared to a single `List<Object?>` frame.

The key advantage: Int64List and Float64List store values UNBOXED. No Smi
tagging, no double boxing. Reading `ints[slot]` returns a raw 64-bit int.
Reading `doubles[slot]` returns a raw 64-bit double. This is as close to
C-level value storage as Dart allows.

However, note Dart SDK issue #53513: typed data access can sometimes be
slower than expected in AOT due to bounds checking and lack of certain
optimizations. The VM team is aware of this and has been improving it.

Frame allocation cost: creating a TypedFrame allocates 4 arrays. For
compiler-known frame sizes (e.g., 8 slots), this is:
- Uint8List(8): 8 bytes + header
- Int64List(8): 64 bytes + header
- Float64List(8): 64 bytes + header
- List<Object?>(8): 64 bytes + header
Total: ~200 bytes + headers for 8 slots. Compare to current deval:
`List<Object?>.filled(255, null)` = 2040 bytes.

With sized frames, the typed array approach uses LESS memory despite having
4 arrays, because frame sizes are much smaller.

Optimization: if the compiler tracks types, most frames won't need ALL
four arrays. A function that only uses ints and refs doesn't need the
doubles array. The compiler could encode which arrays to allocate.

Further optimization: for a register-based VM where the compiler assigns
int-typed locals to int slots and double-typed locals to double slots, we
could use just TWO arrays: Int64List for ints+bools and a List<Object?> for
everything else (doubles boxed, strings, objects). This trades some double
performance for simpler frame allocation.

Verdict on Approach E:

```
Strengths                          Weaknesses
+----------------------------------+----------------------------------+
| ZERO boxing for int AND double   | 4 arrays per frame               |
| True unboxed storage             | Memory overhead if frame sparse  |
| GC only scans refs array         | Index into wrong array = silent  |
| Tag check is byte load + switch  | More complex frame management    |
| Cache-friendly per-type access   | Copy-on-capture more complex     |
| 64-bit int (not 61-bit)          | 4x allocation on function entry  |
+----------------------------------+----------------------------------+
```


### Recommended Hybrid: Approach D + E

The strongest design combines approaches D and E:

**Hot path (local variables in registers):** Use parallel typed arrays
(Approach E). The compiler assigns each local a typed slot. Int locals go
in Int64List, double locals in Float64List, reference locals in List<Object?>.
No boxing, no type tags needed -- the compiler statically knows the type.

**Cold path (dynamic values, polymorphic slots):** Use `Object?` with
runtime type checks (Approach D). When a value's type isn't statically
known, store it in `List<Object?>` and use `is int` / `is double` checks.
The Dart VM's Smi optimization means ints are still free.

**Bridge boundary:** Values crossing into/out of bridge code use `Object?`
representation (Approach D). Bridge functions receive raw Dart values, not
wrapped `$Value` objects. The bridge layer does type conversion only when
necessary.

```dart
class Frame {
  // Statically-typed slots (compiler-assigned)
  final Int64List iRegs;    // int registers
  final Float64List dRegs;  // double registers
  final List<Object?> rRegs; // reference registers (String, instances)

  // Operand stack for temporaries (polymorphic)
  final List<Object?> stack;
  int sp = 0;

  Frame(int intCount, int doubleCount, int refCount, int stackDepth)
      : iRegs = Int64List(intCount),
        dRegs = Float64List(doubleCount),
        rRegs = List<Object?>.filled(refCount, null),
        stack = List<Object?>.filled(stackDepth, null);
}
```

The compiler knows at compile time how many int, double, and ref locals
each function needs. It encodes this in the function header:

```
FUNC_HEADER: iRegCount(u8) dRegCount(u8) rRegCount(u8) stackDepth(u8)
```

Opcodes are type-specialized:

```dart
switch (opcode) {
  case OP_IADD: // int add: iRegs[A] = iRegs[B] + iRegs[C]
    frame.iRegs[a] = frame.iRegs[b] + frame.iRegs[c];
  case OP_DADD: // double add: dRegs[A] = dRegs[B] + dRegs[C]
    frame.dRegs[a] = frame.dRegs[b] + frame.dRegs[c];
  case OP_ADD:  // polymorphic add (cold path)
    final va = frame.stack[a], vb = frame.stack[b];
    if (va is int && vb is int) {
      frame.stack[dst] = va + vb;
    } else {
      frame.stack[dst] = (va as num) + (vb as num);
    }
}
```

This gives us the best of both worlds: zero-boxing for statically-typed
code, and reasonable performance for dynamic code.


### Value Representation Summary

```
Approach     Bytes/int  Bytes/dbl  Alloc  Dispatch     Recommendation
-----------  ---------  ---------  -----  -----------  ---------------
A ext-int    8          8+indir    0      bit mask     Good for simple VM
B record     16+        16+        heap   destruct     REJECT
C sealed     16         24         heap   cid range    OK but allocates
D Object?    8(Smi)     16(box)    0/1    is-check     Good for cold path
E parallel   8          8          0      tag byte     Best for hot path
D+E hybrid   8          8          0      static type  RECOMMENDED
```


## 2. String Interning in Dart

### Does Dart Already Intern Strings?

Yes, partially. The Dart VM interns string LITERALS and const strings:

- `identical("hello", "hello")` returns `true`. String literals with the
  same content share the same object in memory.
- `identical(const String.fromEnvironment("X"), const String.fromEnvironment("X"))`
  returns `true`. Const expressions are canonicalized.
- `identical("hel" + "lo", "hello")` -- this depends on whether the compiler
  evaluates the concatenation at compile time. If both sides are const, yes.

However, dynamically created strings are NOT interned:

```dart
final a = "hello";
final b = String.fromCharCodes([104, 101, 108, 108, 111]);
print(identical(a, b)); // false -- same content, different objects
print(a == b);          // true -- value equality still works
```

### Implications for an Interpreter

In deval, identifiers (variable names, method names, property names) are
strings that appear repeatedly. Currently, method dispatch does
`runtime.constantPool[idx] as String` followed by HashMap lookup using
that string.

Since constant pool strings are set once at compile time, they are likely
already deduplicated within the constant pool. But the HashMap lookup still
does VALUE equality (`==`), which compares characters.

### Custom Intern Table Design

For maximum performance, we should use integer IDs (atoms) instead of strings:

```dart
class AtomTable {
  final Map<String, int> _stringToId = {};
  final List<String> _idToString = [];

  int intern(String s) {
    return _stringToId.putIfAbsent(s, () {
      final id = _idToString.length;
      _idToString.add(s);
      return id;
    });
  }

  String lookup(int id) => _idToString[id];
}
```

Usage in the compiler:

```dart
// At compile time, intern all identifiers
final methodAtom = atomTable.intern("toString"); // returns e.g. 42
// Emit bytecode with atom ID, not string
emit(OP_INVOKE, receiverReg, methodAtom, argCount);
```

Usage in the runtime:

```dart
// Method table uses int keys instead of String keys
class EvalClass {
  final List<int?> methods; // indexed by atom ID -> bytecode offset
  // OR for sparse tables:
  final Map<int, int> methodMap; // atom ID -> bytecode offset
}
```

Int-keyed lookup is much faster than string-keyed:
- `Map<int, int>` uses int hash (identity-based, no character comparison)
- `List<int?>` with direct indexing is even faster (O(1), no hashing at all)

For classes with known method sets, the compiler can assign sequential atom
IDs per class, enabling array-indexed dispatch:

```dart
// If class Foo has methods [bar=0, baz=1, toString=2]
// Then method lookup is just:
final offset = fooClass.methods[atomId];
// One array access, no hashing
```

### Dart Symbol vs Custom Atoms

Dart's `Symbol` class canonicalizes via `Symbol('name')`, but:
- `Symbol` doesn't expose an integer ID
- `Symbol` equality still does string comparison internally
- `Symbol` instances are heap objects with overhead

A custom atom table is strictly better for our use case. It gives us:
- Integer identity (comparison is `==` on ints)
- Direct array indexing capability
- Zero per-lookup allocation
- Compact serialization (atom IDs in bytecode)

### String Interning Recommendation

1. Build a custom AtomTable during compilation
2. All identifiers (methods, properties, variables, types) get atom IDs
3. Constant pool stores atom IDs, not raw strings
4. Method/property dispatch uses int-keyed lookup
5. The atom table is serialized with the bytecode (string list + ID mapping)
6. At runtime, string<->atom conversion only happens at bridge boundaries


## 3. Bytecode Encoding for Dart

### Design Constraints

- Must be stored in Dart typed arrays (Int32List or Uint8List)
- Must be efficiently decodable in a Dart switch dispatch loop
- Must encode opcodes, register indices, constants, and jump targets
- Must support ~100-150 opcodes

### Option 1: Fixed 32-bit Instructions (Lua Model)

Store in Int32List. Every instruction is exactly one 32-bit word.

```
31              24 23          16 15           8 7            0
+----------------+--------------+--------------+--------------+
|       C        |      B       |      A       |    opcode    |
+----------------+--------------+--------------+--------------+
  8 bits (0-255)   8 bits (0-255)  8 bits (0-255)  8 bits (0-255)

Alternative wide format (for jumps, large constants):
+----------------+-------------------------------+-----------+
|    (unused)    |          Bx (16 bits)         |  opcode   |
+----------------+-------------------------------+-----------+

Or signed jump:
+----------------+-------------------------------+-----------+
|                      sBx (24 bits)             |  opcode   |
+----------------+-------------------------------+-----------+
```

Decoding in Dart:

```dart
final bytecode = Int32List(...);
int pc = 0;

while (true) {
  final inst = bytecode[pc++];
  final op = inst & 0xFF;
  final a = (inst >> 8) & 0xFF;
  final b = (inst >> 16) & 0xFF;
  final c = (inst >> 24) & 0xFF;

  switch (op) {
    case OP_IADD: frame.iRegs[a] = frame.iRegs[b] + frame.iRegs[c];
    case OP_ISUB: frame.iRegs[a] = frame.iRegs[b] - frame.iRegs[c];
    case OP_LOADK: frame.rRegs[a] = constants[(inst >> 8) & 0xFFFFFF];
    case OP_JMP:  pc += ((inst >> 8) << 8) >> 8; // sign-extend 24-bit
    // ...
  }
}
```

Analysis:
- 8-bit opcode = 256 opcodes max (plenty)
- 8-bit register fields = 256 registers max per function (plenty)
- Fixed width = pc arithmetic is trivial (`pc++`, `pc += offset`)
- Int32List access = direct memory read, no bounds-check overhead if
  the compiler can prove bounds (or we use `@pragma('vm:unsafe:no-bounds-check')`)
- Decoding = bit shifts + masks, all in registers, zero allocation

Limitations:
- 8-bit constant index (field C) limits inline constants to 256
  - Mitigated: use Bx format (16-bit) or sBx (24-bit) for large indices
- No variable-length encoding = some wasted space for simple ops
- Jump range limited to 24-bit signed (+/- 8M instructions)

### Option 2: Variable-Length with LEB128 (WASM Model)

Store in Uint8List. Instructions are 1-5 bytes.

```
Single-byte: [opcode]
Two-byte:    [opcode] [operand]
Multi-byte:  [opcode] [LEB128 operand...]
```

Decoding:

```dart
final bytecode = Uint8List(...);
int pc = 0;

while (true) {
  final op = bytecode[pc++];
  switch (op) {
    case OP_IADD:
      final a = bytecode[pc++];
      final b = bytecode[pc++];
      final c = bytecode[pc++];
      frame.iRegs[a] = frame.iRegs[b] + frame.iRegs[c];
    case OP_LOADK:
      final a = bytecode[pc++];
      final k = readLEB128(bytecode, pc); // variable length
      pc += leb128Size(k);
      frame.rRegs[a] = constants[k];
    // ...
  }
}
```

Analysis:
- More compact for simple ops (1-2 bytes vs 4 bytes)
- Variable-length constant indices (no 256 limit)
- LEB128 decoding adds overhead per operand (loop + branch)
- PC arithmetic is harder (can't do `pc + N` without knowing instruction sizes)
- Uint8List access per byte = more memory reads per instruction

### Option 3: Hybrid 32-bit with Extension Words

Store in Int32List. Most instructions are 1 word. Instructions needing
more data use an immediately-following extension word.

```
Standard:     [op(8) | A(8) | B(8) | C(8)]
Extended:     [op(8) | A(8) | FLAGS(16)]  [extension_word(32)]
Wide const:   [OP_LOADK_W(8) | A(8) | unused(16)]  [const_index(32)]
Wide jump:    [OP_JMP_W(8) | unused(24)]  [offset(32)]
```

```dart
case OP_LOADK_W:
  final a = (inst >> 8) & 0xFF;
  final k = bytecode[pc++]; // read extension word
  frame.rRegs[a] = constants[k];
```

Analysis:
- Same benefits as Option 1 for common instructions
- Extension word handles arbitrary-size operands
- PC arithmetic still simple (each instruction is 1 or 2 words)
- Slight overhead for checking/reading extension words

### Bytecode Encoding Recommendation

**Option 1 (fixed 32-bit) is the best fit for Dart.**

Rationale:
1. Int32List gives the best read performance in Dart (4-byte aligned reads)
2. Fixed width makes PC arithmetic trivial (critical for jump targets)
3. 8-bit opcode field supports 256 opcodes (we need ~120)
4. 8-bit register fields support 256 registers (more than enough per function)
5. The Bx/sBx formats handle the rare cases needing larger operands
6. Decoding is pure bit arithmetic -- no allocation, no branching
7. Matches Lua's proven design exactly

For the rare case where 8-bit constant indices aren't enough, use a
LOADK_WIDE opcode that reads the next word as a full 32-bit index.

### Concrete Instruction Encoding

```
Format ABC:  [op:8 | A:8 | B:8 | C:8]     -- 3-register ops
Format ABx:  [op:8 | A:8 | Bx:16]          -- register + unsigned 16-bit
Format AsBx: [op:8 | A:8 | sBx:16]         -- register + signed 16-bit
Format sBx:  [op:8 | sBx:24]               -- signed 24-bit (jumps)
Format Ax:   [op:8 | Ax:24]                -- unsigned 24-bit (wide const)
```

Example opcode assignments:

```
OP_IADD    = 0x01  // iRegs[A] = iRegs[B] + iRegs[C]    (ABC)
OP_ISUB    = 0x02  // iRegs[A] = iRegs[B] - iRegs[C]    (ABC)
OP_IMUL    = 0x03  // iRegs[A] = iRegs[B] * iRegs[C]    (ABC)
OP_DADD    = 0x04  // dRegs[A] = dRegs[B] + dRegs[C]    (ABC)
OP_DSUB    = 0x05  // dRegs[A] = dRegs[B] - dRegs[C]    (ABC)
OP_DMUL    = 0x06  // dRegs[A] = dRegs[B] * dRegs[C]    (ABC)
OP_ILT     = 0x10  // if iRegs[A] < iRegs[B] then pc++   (ABC)
OP_ILE     = 0x11  // if iRegs[A] <= iRegs[B] then pc++  (ABC)
OP_LOADK   = 0x20  // rRegs[A] = constants[Bx]           (ABx)
OP_LOADI   = 0x21  // iRegs[A] = sign_extend(sBx)        (AsBx)
OP_MOVE_IR = 0x30  // rRegs[A] = box(iRegs[B])           (ABC)
OP_MOVE_RI = 0x31  // iRegs[A] = unbox_int(rRegs[B])     (ABC)
OP_JMP     = 0x40  // pc += sBx                           (sBx)
OP_CALL    = 0x50  // call func at constants[Bx], A args  (ABx)
OP_RET     = 0x51  // return rRegs[A]                     (ABC)
OP_INVOKE  = 0x60  // rRegs[A].method[B](C args)          (ABC)
OP_GETPROP = 0x61  // rRegs[A] = rRegs[B].prop[C]         (ABC)
OP_SETPROP = 0x62  // rRegs[A].prop[B] = rRegs[C]         (ABC)
```

The B and C fields in INVOKE/GETPROP/SETPROP are atom IDs (interned method
name indices), not register numbers.


## 4. Switch Dispatch Performance in Dart AOT

### Current State

Dart SDK issue #17690 (opened 2014) requested jump table generation for
switch statements. Issue #49585 (2022) reported that switch dispatch consumed
~50% of runtime in an experimental expression evaluator. Issue #49807
confirmed that switch optimizations are AOT-only (JIT skips them to preserve
hot-reload).

### How Dart AOT Compiles Switch Statements

The Dart AOT compiler handles switch on int/enum in several ways depending
on the case distribution:

1. **Dense integer range (consecutive or near-consecutive values):**
   Generates a JUMP TABLE. The opcode value becomes a direct index into an
   array of code addresses. This is O(1) dispatch -- the ideal case.
   Condition: the range of case values is small relative to the number of
   cases (low "sparseness ratio").

2. **Sparse integer values:**
   Generates a BINARY SEARCH tree of comparisons. O(log n) dispatch.
   For 128 cases, this is ~7 comparisons.

3. **Very sparse or mixed types:**
   Falls back to LINEAR if-else chain. O(n) dispatch.

### Optimizing for Jump Table Generation

To ensure the compiler generates a jump table for our dispatch loop:

1. Use consecutive int opcodes starting from 0 (or a small offset)
2. Avoid gaps in the opcode numbering (or fill gaps with unreachable cases)
3. Use `switch` on a local `int` variable, not a field or expression
4. Mark the dispatch function with `@pragma('vm:prefer-inline')` to prevent
   the switch from being split across function calls

```dart
// GOOD: dense range starting from 0
@pragma('vm:prefer-inline')
void dispatch(Int32List bytecode, int pc) {
  final inst = bytecode[pc];
  final op = inst & 0xFF;
  switch (op) {
    case 0: /* NOP */ break;
    case 1: /* IADD */ break;
    case 2: /* ISUB */ break;
    // ... no gaps ...
    case 127: /* LAST_OP */ break;
  }
}
```

```dart
// BAD: sparse values, gaps
switch (op) {
  case 0: break;
  case 100: break;  // gap of 99!
  case 200: break;  // gap of 100!
}
```

### Expected Performance

For ~128 densely-packed opcodes in AOT mode:

- Jump table dispatch: ~3-5 ns per instruction (load + indirect jump)
- Binary search fallback: ~10-15 ns per instruction (7 comparisons)
- Current deval virtual dispatch: ~20-50 ns per instruction (megamorphic call)

The jump table path gives us a 4-10x speedup over current virtual dispatch,
bringing us close to C switch dispatch performance. The remaining overhead
vs C is:
- Dart's bounds checking on array access (can be disabled with pragma)
- No computed goto (Dart has no `goto *table[op]` equivalent)
- Function call overhead if the dispatch loop isn't fully inlined

### Dispatch Loop Structure

```dart
void execute(Program program) {
  final bytecode = program.bytecode; // Int32List
  var pc = 0;
  final frame = Frame(...);

  for (;;) {
    final inst = bytecode[pc++];
    switch (inst & 0xFF) {
      case OP_IADD:
        final a = (inst >> 8) & 0xFF;
        final b = (inst >> 16) & 0xFF;
        final c = (inst >> 24) & 0xFF;
        frame.iRegs[a] = frame.iRegs[b] + frame.iRegs[c];
      case OP_JMP:
        pc += (inst >> 8) << 8 >> 8; // sign-extend 24-bit offset
      case OP_RET:
        return;
      // ... ~120 more cases ...
    }
  }
}
```

### Key Optimization: Keep the Loop Tight

The dispatch loop should be ONE function with ONE switch. Do not:
- Extract each opcode into a separate method (defeats jump table)
- Use async/await in the dispatch loop (adds state machine overhead)
- Store pc as a field (keep it as a local variable for register allocation)
- Access bytecode through an abstraction layer (use Int32List directly)

The Dart AOT compiler is most effective when:
- All variables are local (register-allocatable)
- The switch is on a local int
- Case bodies are short (inline-friendly)
- No exception handling in the hot loop


## 5. Flat Closure Representation in Dart

### Current deval Problem

Closures capture the ENTIRE parent frame (all 255 slots) by reference.
When a closure is created in a loop, the entire frame is COPIED (255 elements).
This is wasteful -- most closures use only 1-3 variables from the parent scope.

### QuickJS Model: JSVarRef

QuickJS uses a flat variable reference model:

1. Each closure has an array of `JSClosureVar` records (compile-time metadata)
   that describe which outer variables it captures: index, name, is_local flag.

2. At runtime, each captured variable becomes a `JSVarRef` -- a heap-allocated
   cell holding the variable's value, with a reference count.

3. While the outer function is still active, the JSVarRef points directly
   into the stack frame ("open" upvalue). When the outer function returns,
   the value is copied from the stack into the JSVarRef's own storage
   ("closed" upvalue).

4. Multiple closures sharing the same variable share the same JSVarRef.

### Lua Model: Upvalues

Lua's upvalue system is almost identical to QuickJS's JSVarRef:

1. Each closure has an upvalue array sized to exactly the number of captured
   variables.

2. Open upvalues point into the stack. Closed upvalues contain the value
   directly.

3. The VM maintains a linked list of open upvalues per stack frame, sorted
   by stack index. When creating a closure, it searches this list to reuse
   existing upvalues for the same variable.

4. When a function returns, all open upvalues pointing into its frame are
   "closed" -- the value is moved from the stack into the upvalue cell.

### Dart-Native Closure Design

We can implement flat closures efficiently in Dart:

```dart
// Compile-time: the compiler knows exactly which variables each
// closure captures and from which scope depth.
class ClosureMeta {
  final int funcOffset;       // bytecode offset of the function body
  final int iRegCount;        // int registers needed
  final int dRegCount;        // double registers needed
  final int rRegCount;        // ref registers needed
  final int stackDepth;       // max operand stack depth
  final List<CaptureInfo> captures; // what to capture
}

class CaptureInfo {
  final int sourceSlot;   // slot in the enclosing frame
  final int targetSlot;   // slot in the closure's capture array
  final SlotKind kind;    // int, double, or ref
  final bool isDirect;    // true = capture from immediate parent
                          // false = capture from parent's capture array
}

enum SlotKind { intSlot, doubleSlot, refSlot }
```

The upvalue cell in Dart:

```dart
// A mutable cell that can be shared between closures
class UpvalueCell {
  Object? value; // the captured value (int, double, String, etc.)
}

// A closure at runtime
class EvalClosure {
  final int funcOffset;
  final List<UpvalueCell> upvalues;

  EvalClosure(this.funcOffset, this.upvalues);
}
```

### Open vs Closed Upvalue Optimization

In Dart, we can't point an upvalue directly into a typed array (Int64List
slot) because there's no way to create a reference to an array element.
Instead, we use an indirection approach:

While the enclosing function is active, locals live in the frame's typed
arrays. When a closure captures a variable, we have two strategies:

**Strategy 1: Always copy into cells (simpler)**

When creating a closure, immediately copy the captured values into
UpvalueCell objects. The enclosing function then reads/writes through
the cell too (the compiler rewrites accesses to captured variables).

```dart
// When a local is captured by a closure:
// Before: frame.iRegs[slot] = value
// After:  capturedCells[cellIdx].value = value

case OP_CLOSURE:
  final meta = closureMetas[closureIdx];
  final cells = <UpvalueCell>[];
  for (final cap in meta.captures) {
    if (cap.isDirect) {
      // Get or create the cell for this variable
      cells.add(frame.getOrCreateCell(cap.sourceSlot, cap.kind));
    } else {
      // Re-capture from parent closure's upvalue array
      cells.add(parentClosure.upvalues[cap.sourceSlot]);
    }
  }
  frame.rRegs[dstReg] = EvalClosure(meta.funcOffset, cells);
```

**Strategy 2: Copy-on-close (Lua-style, more complex)**

Locals stay in typed arrays until the enclosing function returns. On return,
any open cells are "closed" by copying the value out of the frame.

This is faster when closures are rarely created but would add complexity
to the return path. For a Dart implementation, Strategy 1 is likely
better because:
- No need to track open/closed state
- No "close upvalues" pass on every function return
- The cell allocation (one small object per captured variable) is cheap
  compared to deval's current 255-element frame copy

### GC Interaction

UpvalueCell objects are regular Dart objects managed by Dart's GC. When
no closure references a cell, it's garbage collected. No manual memory
management needed -- this is a natural advantage of implementing in Dart.

Shared cells (multiple closures capturing the same variable) work correctly:
both closures hold a reference to the same UpvalueCell, so mutations through
one closure are visible to the other.

### Memory Comparison

```
                        Current deval         New design
Closure creation:       Copy 255-element list Create N cells (N = captured vars)
Typical capture (3 vars): 2040 bytes copied   3 UpvalueCell objects (~48 bytes)
Loop closure (1000 iter): 2040 * 1000 = 2MB   48 * 1000 = 48KB (if not shared)
Shared variable:        N/A (copy semantics)  Same cell object (0 extra bytes)
```

For a closure that captures 3 variables from its parent, the new design
uses ~42x less memory than the current frame-copy approach.

### Flat Capture Across Multiple Scopes

When a closure captures a variable from a grandparent scope, the intermediate
function must also "thread through" the capture. The compiler handles this:

```dart
void outer() {
  int x = 1;          // captured by inner2
  void middle() {
    void inner() {
      print(x);        // uses x from outer
    }
    inner();
  }
  middle();
}
```

Compile-time resolution:
1. `inner` captures `x` from `middle`'s scope
2. But `middle` doesn't USE `x` -- it only passes it through
3. Compiler adds `x` to `middle`'s capture list as a "pass-through"
4. At runtime: `outer` creates cell for `x`, `middle` receives it in its
   upvalues, `inner` receives the same cell from `middle`'s upvalues
5. All three functions share ONE UpvalueCell for `x`


## 6. Combined Architecture Sketch

Putting it all together, here is how the pieces fit:

```
COMPILATION PHASE
=================
Source -> AST -> Bytecode

During compilation:
  1. AtomTable interns all identifiers
  2. Type inference determines slot types (int, double, ref)
  3. Compiler assigns typed registers per function
  4. Closure analysis determines capture lists
  5. Frame sizes computed (iRegCount, dRegCount, rRegCount, stackDepth)
  6. Bytecode emitted to Int32List (fixed 32-bit Lua-style encoding)

Output: Program = {
  bytecode: Int32List,
  constants: List<Object>,   // strings, large ints, doubles
  atomTable: AtomTable,      // interned identifier strings
  closureMetas: List<ClosureMeta>,
  funcHeaders: List<FuncHeader>,
  classMetas: List<ClassMeta>,
}


RUNTIME PHASE
=============
Program -> Execution

Frame = {
  iRegs: Int64List(n),       // unboxed int registers
  dRegs: Float64List(n),     // unboxed double registers
  rRegs: List<Object?>(n),   // reference registers
  stack: List<Object?>(n),   // operand stack for polymorphic ops
  cells: List<UpvalueCell?>, // upvalue cells for captured variables
}

Dispatch loop:
  for (;;) {
    final inst = bytecode[pc++];
    switch (inst & 0xFF) { /* ~120 cases */ }
  }

Value representation:
  - Int locals: raw int in Int64List (zero boxing)
  - Double locals: raw double in Float64List (zero boxing)
  - Ref locals: Object? in List<Object?> (Smi-tagged ints are still free)
  - Polymorphic values: Object? with `is int`/`is double` runtime checks
  - Bridge boundary: raw Dart values, no $Value wrappers

Method dispatch:
  - Atom-indexed lookup: class.methods[atomId] -> bytecode offset
  - No string hashing at runtime
  - Property access: class.props[atomId] -> getter/setter offset

Closures:
  - Flat capture: List<UpvalueCell> sized to captured variable count
  - Shared cells for same-variable captures across closures
  - No frame copying
```

### Expected Performance Gains

```
Bottleneck              Current Cost        New Cost            Speedup
--------------------    ----------------    ----------------    -------
Dispatch loop           Virtual call ~30ns  Switch ~5ns         6x
Int boxing              2 objects/op        0 objects/op        inf (no alloc)
Double boxing           2 objects/op        0 objects/op        inf (no alloc)
Frame allocation        255-element list    4 small typed arrays 5-10x
Method dispatch         HashMap<String>     Array[atomId]       10-20x
Property access         String switch       Array[atomId]       5-10x
Closure capture         Copy 255 elements   N cells (N~1-5)     50x
Bridge property         try/catch           null check          100-1000x
Function call overhead  3 list allocs       1 frame alloc       3x

Overall for numeric loops:     ~20-50x improvement
Overall for OOP-heavy code:    ~30-100x improvement
Overall for bridge-heavy code: ~50-200x improvement
```

These estimates are conservative. The compounding effect of fixing all
bottlenecks simultaneously (fewer allocations = less GC = even faster)
means the real improvement could be larger.
