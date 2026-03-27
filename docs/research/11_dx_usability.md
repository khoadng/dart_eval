# deval v2 Developer Experience Design
Phase: 5 | Status: COMPLETE


## 1. Design Philosophy

Three principles drive the deval v2 API:

1. **One-liner to value.** The most common operations (run code, register a
   function, read a result) must each be expressible in a single statement.
2. **No ceremony.** No two-phase registration, no metadata declarations, no
   wrapper classes for simple types. The API discovers what it needs from
   Dart's type system.
3. **Errors are features.** Every error message tells you what happened, what
   was expected, and where to look. No opaque stack traces or raw bytecode
   offsets.

Lua has ~120 C API functions. QuickJS has ~180. Wren has ~50. deval v2 targets
**under 40 public API methods** across two classes: `Deval` and `DevalContext`.


## 2. Core Embedding API

### 2.1 The two-tier model

QuickJS separates `JSRuntime` (memory, GC, atoms) from `JSContext` (execution
environment, global object). This is the right split for game engines where
you want multiple independent script contexts sharing one runtime.

```
  Deval (runtime)
    |-- owns the compiler, bytecode cache, interned strings, resource limits
    |-- one per application (or per "world" in a game)
    |
    +-- DevalContext (execution environment)
          |-- owns the global scope, loaded modules, permissions
          |-- one per script sandbox (e.g., per NPC, per mod, per level)
          |-- lightweight to create and destroy
```

### 2.2 Complete API surface

```dart
// ---- Deval (runtime) ----

class Deval {
  Deval({DevalConfig? config});

  // Create execution contexts
  DevalContext createContext({String name, List<Permission> permissions});

  // Register native functions (available to all contexts)
  void register(String name, Function fn);

  // Register native classes
  void registerClass<T>(DevalClass<T> binding);

  // Resource limits
  void setMemoryLimit(int bytes);
  void setExecutionLimit(Duration timeout);
  void setStackDepth(int maxFrames);

  // Lifecycle
  void dispose();
}

// ---- DevalContext (execution environment) ----

class DevalContext {
  // Evaluate source code, return result
  dynamic eval(String source);

  // Load and run a file
  dynamic run(String path);

  // Load bytecode
  void load(Uint8List bytecode);

  // Call a function defined in this context
  dynamic call(String function, [List<dynamic> args]);

  // Get/set global variables
  dynamic operator [](String name);
  void operator []=(String name, dynamic value);

  // Compile without executing (for caching)
  Uint8List compile(String source);

  // Error handling
  Stream<DevalError> get onError;

  // Lifecycle
  void dispose();
}

// ---- DevalConfig ----

class DevalConfig {
  const DevalConfig({
    this.memoryLimit,
    this.executionLimit,
    this.stackDepth = 256,
    this.enableDebug = false,
    this.stdout,
    this.stderr,
  });

  final int? memoryLimit;
  final Duration? executionLimit;
  final int stackDepth;
  final bool enableDebug;
  final void Function(String)? stdout;
  final void Function(String)? stderr;
}
```

That is **21 public methods** across the two main classes. Under half the target.

### 2.3 Hello world

```dart
final deval = Deval();
final ctx = deval.createContext();

// Evaluate an expression
print(ctx.eval('2 + 2')); // 4

// Evaluate a block
ctx.eval('''
  String greet(String name) => 'Hello, \$name!';
''');
print(ctx.call('greet', ['world'])); // Hello, world!

// Clean up
ctx.dispose();
deval.dispose();
```

Compare with current deval:

```dart
// Current: 8 lines of ceremony for the same result
final compiler = Compiler();
final program = compiler.compile({
  'default': {'main.dart': 'String greet(String name) => "Hello, \$name!";'},
});
final runtime = Runtime.ofProgram(program);
runtime.args = ['world'];
final result = runtime.executeLib('package:default/main.dart', 'greet');
print((result as $Value).$reified); // Hello, world!
```

### 2.4 One-shot eval (zero setup)

For the simplest possible use case, a static method bypasses all setup:

```dart
// Absolute minimum -- one line
print(Deval.eval('2 + 2')); // 4

// With a function call
print(Deval.eval('''
  int fib(int n) => n <= 1 ? n : fib(n - 1) + fib(n - 2);
  fib(10)
''')); // 55
```

Implementation: `Deval.eval` creates a temporary runtime + context, compiles,
executes, disposes, returns. No state leaks, no cleanup needed.


## 3. Plugin/Bridge System

### 3.1 The problem today

Exposing a Dart class to current deval requires:

1. A `BridgeClassDef` with full type metadata for every constructor, method,
   getter, setter, and field (~50-100 lines per class)
2. A `$ClassName` wrapper class implementing `$Instance` with:
   - `$getProperty` switch on string identifiers
   - Static `$Function` constants for every method
   - Static implementation functions with signature
     `$Value? fn(Runtime, $Value?, List<$Value?>)`
   - Box/unbox on every argument and return value
3. Two-phase plugin registration (compile-time + runtime)
4. Runtime function registration with magic string keys like
   `'package:mylib/src/my_class.dart#MyClass.myMethod'`

A simple class with 3 methods easily reaches 200+ lines of bridge code.

### 3.2 Registering a native function

**deval v2:**

```dart
final deval = Deval();

// Option A: direct lambda
deval.register('add', (int a, int b) => a + b);

// Option B: existing function reference
deval.register('sqrt', dart_math.sqrt);

// Option C: variadic / dynamic
deval.register('log', (List<dynamic> args) {
  print(args.join(' '));
});

final ctx = deval.createContext();
print(ctx.eval('add(3, 4)')); // 7
print(ctx.eval('sqrt(16.0)')); // 4.0
ctx.eval('log("score:", 42)'); // prints: score: 42
```

The runtime inspects the function's parameter types at registration time using
`Function.apply` metadata and the Dart type system. For `(int, int) => int`,
it knows: 2 params, both int, returns int. It generates a specialized bridge
that converts tagged values to Dart ints, calls the function, and converts
the result back. No `$Value` wrappers, no `List<$Value?>` allocation.

**Lua equivalent (for comparison):**

```c
static int l_add(lua_State *L) {
    int a = luaL_checkinteger(L, 1);
    int b = luaL_checkinteger(L, 2);
    lua_pushinteger(L, a + b);
    return 1;
}
lua_register(L, "add", l_add);
```

**QuickJS equivalent:**

```c
JSValue js_add(JSContext *ctx, JSValueConst this_val,
               int argc, JSValueConst *argv) {
    int a, b;
    JS_ToInt32(ctx, &a, argv[0]);
    JS_ToInt32(ctx, &b, argv[1]);
    return JS_NewInt32(ctx, a + b);
}
JS_SetPropertyStr(ctx, global, "add", JS_NewCFunction(ctx, js_add, "add", 2));
```

**Wren equivalent:**

```c
void mathAdd(WrenVM* vm) {
    double a = wrenGetSlotDouble(vm, 1);
    double b = wrenGetSlotDouble(vm, 2);
    wrenSetSlotDouble(vm, 0, a + b);
}
// Plus: bindForeignMethod callback with string matching
```

**Current deval:**

```dart
// 1. Compile-time registration
compiler.defineBridgeTopLevelFunction(BridgeFunctionDeclaration(
  'package:mylib/math.dart#add',
  BridgeFunctionDef(
    returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int)),
    params: [
      BridgeParameter('a', BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int)), false),
      BridgeParameter('b', BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int)), false),
    ],
  ),
));

// 2. Runtime registration
runtime.registerBridgeFunc(
  'package:mylib/math.dart',
  'add',
  (Runtime rt, $Value? target, List<$Value?> args) {
    final a = args[0]!.$value as int;
    final b = args[1]!.$value as int;
    return $int(a + b);
  },
);
```

deval v2 is **1 line** vs current deval's **18 lines across 2 registration phases**.

### 3.3 Exposing a native class

**deval v2:**

```dart
final deval = Deval();

deval.registerClass(DevalClass<Vec3>(
  name: 'Vec3',
  constructor: (double x, double y, double z) => Vec3(x, y, z),
  getters: {
    'x': (Vec3 self) => self.x,
    'y': (Vec3 self) => self.y,
    'z': (Vec3 self) => self.z,
    'length': (Vec3 self) => self.length,
  },
  methods: {
    'dot': (Vec3 self, Vec3 other) => self.dot(other),
    'cross': (Vec3 self, Vec3 other) => self.cross(other),
    'normalized': (Vec3 self) => self.normalized(),
  },
  operators: {
    '+': (Vec3 self, Vec3 other) => self + other,
    '-': (Vec3 self, Vec3 other) => self - other,
    '*': (Vec3 self, double s) => self * s,
  },
));

final ctx = deval.createContext();
ctx.eval('''
  var a = Vec3(1, 0, 0);
  var b = Vec3(0, 1, 0);
  var c = a.cross(b);
  print(c.z); // 1.0
''');
```

The `DevalClass<T>` declaration is pure Dart. No metadata DSL, no string-keyed
type references, no BridgeTypeAnnotation trees. The runtime extracts type
information from the closures themselves.

**DevalClass API:**

```dart
class DevalClass<T> {
  const DevalClass({
    required this.name,
    this.constructor,
    this.namedConstructors,
    this.getters = const {},
    this.setters = const {},
    this.methods = const {},
    this.operators = const {},
    this.staticMethods = const {},
    this.superclass,
  });

  final String name;
  final Function? constructor;
  final Map<String, Function>? namedConstructors;
  final Map<String, Function> getters;
  final Map<String, Function> setters;
  final Map<String, Function> methods;
  final Map<String, Function> operators;
  final Map<String, Function> staticMethods;
  final Type? superclass;
}
```

**Lua equivalent (metatable-based userdata):**

```c
// ~40 lines: newuserdata, setmetatable, pushcfunction for each method,
// __index table setup, __gc destructor. Each method reads userdata from
// stack, casts pointer, calls C function, pushes result.
```

**QuickJS equivalent:**

```c
// ~30 lines: JSClassDef, JS_NewClass, JS_NewObjectProtoClass for
// constructor, JS_SetPropertyStr for each method, each method is a
// C function that unpacks JSValue args.
```

**Wren equivalent:**

```c
// ~25 lines per class: foreign class declaration in Wren source,
// allocate/finalize callbacks in C, one C function per method
// reading/writing slots, bindForeignMethod callback with string matching.
```

**Current deval:**

A Vec3 bridge class would be 300-500 lines across:
- `BridgeClassDef` with full type metadata (~80 lines)
- `$Vec3` wrapper class with `$getProperty` switch, static functions,
  box/unbox for every argument (~200+ lines)
- Plugin with two-phase registration (~40 lines)

deval v2: **~25 lines**, all in one place, all plain Dart.

### 3.4 Annotation-based binding (zero boilerplate)

For classes you own (or can annotate), deval v2 supports codegen:

```dart
@devalExpose
class Vec3 {
  final double x, y, z;

  Vec3(this.x, this.y, this.z);

  double get length => math.sqrt(x * x + y * y + z * z);

  Vec3 normalized() {
    final l = length;
    return Vec3(x / l, y / l, z / l);
  }

  double dot(Vec3 other) => x * other.x + y * other.y + z * other.z;
  Vec3 cross(Vec3 other) => Vec3(
    y * other.z - z * other.y,
    z * other.x - x * other.z,
    x * other.y - y * other.x,
  );

  Vec3 operator +(Vec3 other) => Vec3(x + other.x, y + other.y, z + other.z);
  Vec3 operator -(Vec3 other) => Vec3(x - other.x, y - other.y, z - other.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
}
```

A build_runner generator produces the `DevalClass<Vec3>` binding automatically.
The annotation `@devalExpose` marks which classes to generate bindings for.
Fine-grained control is available:

```dart
@devalExpose
class Player {
  @devalHide  // not exposed to scripts
  final String _internalId;

  final String name;
  int health;

  @devalReadOnly  // getter only, no setter
  int get score => _calculateScore();
}
```

### 3.5 Inheritance (native subclass in eval'd code)

A script can extend a native class if the binding declares it extensible:

```dart
deval.registerClass(DevalClass<Entity>(
  name: 'Entity',
  constructor: (String name) => Entity(name),
  getters: {
    'name': (Entity self) => self.name,
    'position': (Entity self) => self.position,
  },
  methods: {
    'update': (Entity self, double dt) => self.update(dt),
    'onCollision': (Entity self, Entity other) => self.onCollision(other),
  },
));
```

```dart
// In deval script:
class Enemy extends Entity {
  int health = 100;

  Enemy(String name) : super(name);

  @override
  void update(double dt) {
    // Custom behavior
    if (health <= 0) {
      print('$name defeated');
    }
  }

  @override
  void onCollision(Entity other) {
    health -= 10;
  }
}
```

The host can call `onCollision` on what it sees as an `Entity`, and deval's
vtable routes it to the script's override. The mechanism:

1. At registration, `Entity` gets a class ID and vtable slots for overridable
   methods.
2. When the script creates `Enemy extends Entity`, deval allocates an
   `Entity` instance via the native constructor and attaches a script-side
   vtable overlay.
3. When the host calls `entity.onCollision(other)`, the bridge checks the
   vtable overlay first. If the method is overridden in script, it calls into
   deval. Otherwise it falls through to the native implementation.

No try/catch control flow. No `UnimplementedError`. A simple null check on
the vtable slot.

### 3.6 Bidirectional callbacks

Script code can receive and call native callbacks, and native code can receive
and call script callbacks. Both directions use plain Dart `Function`.

**Native passes a callback to script:**

```dart
deval.register('addEventListener', (String event, Function callback) {
  eventBus.on(event, callback);
});

ctx.eval('''
  addEventListener('hit', (int damage) {
    print('Took \$damage damage');
  });
''');

// Later, from native code:
eventBus.emit('hit', [25]); // Script prints: Took 25 damage
```

When the script defines a closure and passes it to a native function, deval
wraps it in a thin `DevalFunction` that implements Dart's `Function` interface.
The native code receives a real Dart `Function` it can call normally.

**Script receives a native callback:**

```dart
deval.register('map', (List<dynamic> items, Function transform) {
  return items.map((e) => transform(e)).toList();
});

ctx.eval('''
  var result = map([1, 2, 3], (x) => x * 2);
  print(result); // [2, 4, 6]
''');
```

Here `transform` is a deval closure, but the native `map` function calls it
through normal Dart function call syntax. No `bridgeCall`, no manual
argument marshalling.


## 4. Error Messages and Debugging

### 4.1 Design principles

Elm and Rust set the standard for error messages. Every deval error must
answer three questions:

1. **What happened?** (the error itself)
2. **Where?** (source file, line, column, with code snippet)
3. **Why?** (context: what was being called, what types were involved)

### 4.2 Type errors

```
TypeError: Expected 'int' but got 'String'

  score.dart:12:18
    |
 12 |   var total = count + name;
    |                      ^^^^
    = 'count' is int (declared at line 3)
    = 'name' is String (declared at line 4)
    = operator '+' on int expects int, not String

  Did you mean: count + name.length?
```

### 4.3 Undefined member errors

```
NoSuchMethod: 'Vec3' has no method 'normalize'

  enemy.dart:8:14
    |
  8 |   var dir = velocity.normalize();
    |                      ^^^^^^^^^
    = 'velocity' is Vec3 (declared at line 5)
    = Similar: Vec3.normalized() -> Vec3

  Did you mean: velocity.normalized()?
```

### 4.4 Stack traces with source mapping

```
Unhandled exception: RangeError: Index out of bounds: index 5, length 3

  inventory.dart:22:16  getItem
    |
 22 |   return items[index];
    |                ^^^^^

  quest.dart:45:20  completeQuest
    |
 45 |   var reward = inventory.getItem(slotIndex);
    |                          ^^^^^^^

  main.dart:12:3  main
    |
 12 |   completeQuest(player, 5);
    |   ^^^^^^^^^^^^^
```

Every bytecode instruction carries a source position. The compiled bytecode
includes a source map section (file paths + line/column table, delta-encoded
for compactness). When an error occurs, the runtime walks the call stack and
maps each frame's bytecode offset back to source coordinates.

### 4.5 Source maps for compiled bytecode

The bytecode format includes a debug info section:

```
[header]
[constant pool]
[bytecode]
[source map]     <-- file table + position table
[debug symbols]  <-- optional: local variable names, scopes
```

Source maps are always included (they add ~10-15% to bytecode size). Debug
symbols are opt-in via `DevalConfig(enableDebug: true)` and add variable
names, scope boundaries, and type annotations for the debugger.

### 4.6 Debug hooks

```dart
final deval = Deval(config: DevalConfig(enableDebug: true));
final ctx = deval.createContext();

// Breakpoint
ctx.debug.setBreakpoint('enemy.dart', line: 12);

// Step control
ctx.debug.onBreakpoint.listen((frame) {
  print('Paused at ${frame.file}:${frame.line}');
  print('Locals: ${frame.locals}');
  // frame.locals is Map<String, dynamic>

  frame.stepOver(); // or stepInto(), stepOut(), resume()
});

// Watch expressions
ctx.debug.watch('player.health', (value) {
  print('Health changed: $value');
});

ctx.run('game_logic.dart');
```

The debug API is a separate optional interface (`ctx.debug`) that is only
available when `enableDebug: true`. In production mode, there is zero debug
overhead -- no per-instruction callbacks, no breakpoint checks.

Implementation: when debug mode is on, the dispatch loop checks a breakpoint
bitmap (one bit per bytecode offset) before each instruction. The bitmap
check is a single array lookup + bitwise AND, costing ~1-2ns per instruction.
When no breakpoints are set, the bitmap is all zeros and branch prediction
eliminates the cost.


## 5. Scripting Experience

### 5.1 What makes Lua/JS feel "easy"

- No visible compilation step. You write code, it runs.
- Immediate feedback. `eval("2+2")` returns 4.
- Small standard library that covers the basics (print, math, string ops).
- Types get out of your way. You focus on logic, not declarations.
- Good error messages when things go wrong.
- Seamless interop with the host (this is the real differentiator).

deval runs Dart syntax, which means we inherit Dart's type system. But we
can make it feel lightweight:

- Type inference handles most declarations (`var x = 42;` not `int x = 42;`)
- The `dynamic` type is available for flexible scripting
- Null safety is enforced but error messages guide the fix
- No imports needed for standard library (it is in scope by default)

### 5.2 Standard library (out of the box)

Every `DevalContext` has these available without imports:

```
  dart:core       int, double, String, bool, List, Map, Set, RegExp,
                  Duration, DateTime, print, Object, Iterable,
                  num, Comparable, Pattern, StringBuffer, Symbol,
                  Enum, Record, Type, Uri, Exception, Error,
                  StackTrace, Function, Null, Never

  dart:math       sin, cos, sqrt, pow, min, max, pi, e, Random, Point

  dart:convert    json (JsonCodec), utf8, base64, ascii

  dart:typed_data Int32List, Float64List, Uint8List, ByteData,
                  Float32List, Int64List
```

Additional libraries require explicit opt-in via permissions:

```
  dart:io         File, Directory, HttpClient, Socket, Process
                  (requires FilesystemPermission, NetworkPermission, etc.)

  dart:async      Future, Stream, Timer, Completer, StreamController, Zone
                  (always available, listed separately for clarity)
```

### 5.3 End-to-end: `Deval.eval("print('hello')")`

```
  1. Deval.eval() creates a temporary Deval + DevalContext
  2. Source is wrapped: "void __eval__() { print('hello'); }"
  3. Compiler parses -> AST -> bytecode in one pass
     - "print" resolves to a builtin function ID (no string lookup at runtime)
     - "'hello'" becomes a constant pool entry
     - The call compiles to: LOAD_CONST 0, CALL_BUILTIN print, 1
  4. Runtime executes the bytecode
     - LOAD_CONST: pushes string constant onto the value stack
     - CALL_BUILTIN: reads the stdout handler from config, calls it
     - Default stdout handler: Dart's print()
  5. Function returns void, Deval.eval returns null
  6. Temporary runtime + context are disposed
```

Total overhead: one compilation (microseconds for small expressions), one
dispatch loop iteration per instruction (~5-6 instructions for this example).

### 5.4 Loading and running a .dart file

```dart
final deval = Deval();
final ctx = deval.createContext();

// Load from string (as if it were a file)
ctx.eval('''
  class Enemy {
    String name;
    int health;

    Enemy(this.name, this.health);

    String status() => '\$name: \$health HP';
  }

  Enemy boss = Enemy('Dragon', 500);
''');

// Access from host
var bossStatus = ctx.call('boss.status');
print(bossStatus); // Dragon: 500 HP

// Or access the variable directly
var boss = ctx['boss']; // returns an opaque DevalObject
print(ctx.call('boss.status')); // Dragon: 500 HP
```

For file-based loading:

```dart
// Load a .dart file from the filesystem
ctx.run('/scripts/enemy_ai.dart');

// Or from a string with a virtual path (for source maps)
ctx.eval(source, path: 'scripts/enemy_ai.dart');
```

### 5.5 REPL experience

```dart
final deval = Deval();
final ctx = deval.createContext();
final repl = DevalRepl(ctx);

// Each line is evaluated, state persists
repl.execute('var x = 10;');       // null (statement)
repl.execute('x + 5');             // 15 (expression, auto-printed)
repl.execute('x = x * 2;');       // null (assignment)
repl.execute('x');                 // 20

// Errors don't crash the session
repl.execute('x / 0');             // IntegerDivisionByZeroException
repl.execute('x');                 // 20 (state preserved)

// Multi-line support
repl.execute('int fib(int n) {');  // ... (incomplete, waits for more)
repl.execute('  if (n <= 1) return n;');
repl.execute('  return fib(n-1) + fib(n-2);');
repl.execute('}');                 // null (function defined)
repl.execute('fib(10)');           // 55
```

The `DevalRepl` class handles:
- Expression vs statement detection (auto-return for expressions)
- Incomplete input detection (unmatched braces/parens)
- Error recovery (catch, report, continue)
- History and state persistence across lines


## 6. API Ergonomics Comparison

Five tasks compared across deval v2, current deval, Lua, QuickJS, and Wren.

### 6.1 Hello world embedding

**deval v2:**
```dart
print(Deval.eval('print("Hello from deval!")')); // one line
```

**Current deval:**
```dart
eval('print("Hello from deval!")'); // one line (but hides 8 lines of setup)
```

**Lua:**
```c
lua_State *L = luaL_newstate();
luaL_openlibs(L);
luaL_dostring(L, "print('Hello from Lua!')");
lua_close(L);
```

**QuickJS:**
```c
JSRuntime *rt = JS_NewRuntime();
JSContext *ctx = JS_NewContext(rt);
JS_Eval(ctx, "console.log('Hello from QuickJS!')", ...);
JS_FreeContext(ctx);
JS_FreeRuntime(rt);
```

**Wren:**
```c
WrenVM* vm = wrenNewVM(&config);
wrenInterpret(vm, "main", "System.print(\"Hello from Wren!\")");
wrenFreeVM(vm);
```

deval v2 matches the best here. The one-shot `Deval.eval` has less ceremony
than any C-based API because Dart handles memory management.

### 6.2 Exposing a native function

**deval v2:**
```dart
final deval = Deval();
deval.register('clamp', (num value, num min, num max) {
  return value.clamp(min, max);
});
final ctx = deval.createContext();
print(ctx.eval('clamp(15, 0, 10)')); // 10
```

**Current deval:**
```dart
// Requires: BridgeFunctionDeclaration + BridgeFunctionDef + BridgeParameter
// metadata at compile time, plus a separate runtime.registerBridgeFunc call
// with manual $Value boxing/unboxing. ~20 lines across 2 phases.
```

**Lua:**
```c
static int l_clamp(lua_State *L) {
    double v = luaL_checknumber(L, 1);
    double lo = luaL_checknumber(L, 2);
    double hi = luaL_checknumber(L, 3);
    lua_pushnumber(L, v < lo ? lo : v > hi ? hi : v);
    return 1;
}
lua_register(L, "clamp", l_clamp);
```

**QuickJS:**
```c
JSValue js_clamp(JSContext *ctx, JSValueConst this_val,
                 int argc, JSValueConst *argv) {
    double v, lo, hi;
    JS_ToFloat64(ctx, &v, argv[0]);
    JS_ToFloat64(ctx, &lo, argv[1]);
    JS_ToFloat64(ctx, &hi, argv[2]);
    return JS_NewFloat64(ctx, v < lo ? lo : v > hi ? hi : v);
}
```

**Wren:**
```c
void clampFn(WrenVM* vm) {
    double v = wrenGetSlotDouble(vm, 1);
    double lo = wrenGetSlotDouble(vm, 2);
    double hi = wrenGetSlotDouble(vm, 3);
    wrenSetSlotDouble(vm, 0, v < lo ? lo : v > hi ? hi : v);
}
// Plus: bindForeignMethod callback
```

deval v2 wins here. The Dart lambda IS the bridge function. No marshalling
code visible to the user.

### 6.3 Exposing a native class with methods

**deval v2:**
```dart
deval.registerClass(DevalClass<Timer>(
  name: 'Timer',
  constructor: (double duration) => Timer(duration),
  getters: {
    'elapsed': (Timer self) => self.elapsed,
    'isRunning': (Timer self) => self.isRunning,
    'remaining': (Timer self) => self.remaining,
  },
  methods: {
    'start': (Timer self) => self.start(),
    'stop': (Timer self) => self.stop(),
    'reset': (Timer self) => self.reset(),
  },
));
// ~15 lines
```

**Current deval:**
```dart
// BridgeClassDef: ~50 lines of BridgeMethodDef/BridgeFunctionDef/BridgeParameter
// $Timer wrapper class: ~150 lines ($getProperty switch, static functions,
//   box/unbox, $declaration)
// Plugin registration: ~20 lines (configureForCompile + configureForRuntime)
// Total: ~220 lines
```

**Lua:**
```c
// luaL_newmetatable + lua_pushcfunction for each method + __index setup
// ~50-60 lines for 3 getters + 3 methods
```

**QuickJS:**
```c
// JSClassDef + JS_NewClass + property list + one C function per member
// ~40-50 lines
```

**Wren:**
```c
// Foreign class in Wren source + allocate callback + one C function per method
// + bindForeignMethod switch
// ~35-45 lines
```

### 6.4 Calling an eval'd function from native

**deval v2:**
```dart
final ctx = deval.createContext();
ctx.eval('''
  int square(int x) => x * x;
  String greet(String name, int age) => '\$name is \$age years old';
''');

// Direct call with natural Dart types
int result = ctx.call('square', [7]) as int; // 49
String msg = ctx.call('greet', ['Alice', 30]) as String;
```

**Current deval:**
```dart
runtime.args = [7];
final result = runtime.executeLib('package:default/main.dart', 'square');
final value = (result as $Value).$reified; // 49
```

**Lua:**
```c
lua_getglobal(L, "square");
lua_pushinteger(L, 7);
lua_call(L, 1, 1);
int result = lua_tointeger(L, -1);
lua_pop(L, 1);
```

**QuickJS:**
```c
JSValue global = JS_GetGlobalObject(ctx);
JSValue func = JS_GetPropertyStr(ctx, global, "square");
JSValue arg = JS_NewInt32(ctx, 7);
JSValue result = JS_Call(ctx, func, JS_UNDEFINED, 1, &arg);
int32_t val;
JS_ToInt32(ctx, &val, result);
JS_FreeValue(ctx, result);
JS_FreeValue(ctx, func);
JS_FreeValue(ctx, global);
```

**Wren:**
```c
wrenEnsureSlots(vm, 2);
wrenGetVariable(vm, "main", "square", 0);
WrenHandle* method = wrenMakeCallHandle(vm, "call(_)");
wrenSetSlotDouble(vm, 1, 7);
wrenCall(vm, method);
double result = wrenGetSlotDouble(vm, 0);
wrenReleaseHandle(vm, method);
```

deval v2 is the simplest: one line, natural Dart types, no handle management.

### 6.5 Bidirectional callbacks

**deval v2:**
```dart
// Native defines a function that accepts a callback
deval.register('onTick', (Function callback) {
  gameLoop.onTick = (double dt) => callback(dt);
});

// Script registers its callback
ctx.eval('''
  onTick((double dt) {
    print('Frame: \${dt}ms');
  });
''');

// Game loop runs, calling back into script each frame
gameLoop.tick(16.6); // prints: Frame: 16.6ms
```

**Current deval:**
```dart
// Requires:
// 1. Bridge function for onTick that receives an EvalFunctionPtr
// 2. Manual bridgeCall() to invoke the callback
// 3. Boxing dt as $double before passing
// 4. Creating a List<$Value?> for the arguments
// ~25 lines of bridge machinery
```

**Lua:**
```c
// Store callback as registry reference
lua_pushvalue(L, 1);
int ref = luaL_ref(L, LUA_REGISTRYINDEX);

// Later, call it back
lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
lua_pushnumber(L, dt);
lua_call(L, 1, 0);
luaL_unref(L, LUA_REGISTRYINDEX, ref);
```

**QuickJS:**
```c
// Store callback with JS_DupValue, call with JS_Call, free with JS_FreeValue
// Reference counting makes this manual but straightforward
```


## 7. Safety Without Friction

### 7.1 Capability-based access

deval v2 uses a permission system inspired by WASM's capability model and
Deno's permission flags. By default, a context has NO access to:
- Filesystem
- Network
- Process spawning
- System clock (wall time)
- Random (deterministic by default for replays)

Capabilities are granted at context creation:

```dart
final ctx = deval.createContext(
  permissions: [
    Permission.fileRead('/scripts/'),   // read-only, scoped to directory
    Permission.network('api.game.com'), // single host
    Permission.random(),                // non-deterministic random
  ],
);
```

When a script attempts an unpermitted operation:

```
PermissionDenied: Filesystem write access not granted

  save.dart:5:3
    |
  5 |   File('save.dat').writeAsStringSync(data);
    |   ^^^^
    = This context has fileRead('/scripts/') but not fileWrite
    = Grant with: Permission.fileWrite('/saves/')
```

### 7.2 Resource limits

**Memory limit:**

```dart
final deval = Deval(config: DevalConfig(memoryLimit: 16 * 1024 * 1024)); // 16 MB
```

The runtime tracks allocations in the value heap (object count * average size).
When the limit is reached, it throws `MemoryLimitExceeded` which the host can
catch. This is a soft limit -- Dart's actual GC handles real memory management.
The limit prevents runaway scripts from consuming the host's memory budget.

Implementation: an allocation counter incremented on every object creation
(new instance, new list, new string concat). No per-byte tracking -- just
object-granularity accounting. Cost: one integer increment per allocation.

**Execution timeout:**

```dart
final deval = Deval(config: DevalConfig(executionLimit: Duration(seconds: 5)));
```

Implementation: QuickJS-style interrupt counter. Every N instructions
(e.g., 10,000), the dispatch loop checks `DateTime.now()` against the
deadline. The check frequency is tunable. At 10K instructions between checks,
the overhead is one clock read per ~50 microseconds of execution -- negligible.

```dart
// In the dispatch loop (simplified):
if (--interruptCounter <= 0) {
  interruptCounter = interruptInterval;
  if (DateTime.now().isAfter(deadline)) {
    throw ExecutionTimeout('Script exceeded ${config.executionLimit}');
  }
}
```

**Stack depth:**

```dart
final deval = Deval(config: DevalConfig(stackDepth: 256));
```

Prevents infinite recursion. Each function call increments a depth counter.
When it exceeds the limit: `StackOverflow: Maximum call depth (256) exceeded`.

### 7.3 Preventing infinite loops

The execution timeout (above) handles infinite loops. But for tighter control,
the host can set a step limit:

```dart
final ctx = deval.createContext();
ctx.setStepLimit(1000000); // max 1M bytecode instructions
ctx.eval('while (true) {}'); // throws StepLimitExceeded after 1M ops
```

Step limits are deterministic (unlike timeouts) and useful for:
- Fair scheduling between multiple script contexts
- Testing (ensure a script terminates)
- Replay systems (same steps = same result)

### 7.4 Cooperative yielding

For long-running scripts in a game loop, cooperative yielding prevents
frame drops:

```dart
final ctx = deval.createContext();

// Script uses yield to return control to the host
ctx.eval('''
  void processChunk(List<int> data) {
    for (var i = 0; i < data.length; i++) {
      process(data[i]);
      if (i % 100 == 0) yield;  // give the host a chance to run
    }
  }
''');

// Host calls with a time budget
final result = ctx.callWithBudget(
  'processChunk',
  [largeData],
  budget: Duration(milliseconds: 4), // 4ms per frame at 60fps
);

if (result.isComplete) {
  // Script finished within budget
} else {
  // Script yielded, resume next frame
  ctx.resume();
}
```

`yield` in a deval script suspends execution and returns control to the host.
The host can resume later. This is implemented as coroutine-style frame
serialization (save the value stack, frame pointer, and program counter).


## 8. Game Engine Integration Patterns

### 8.1 ECS scripted systems

The primary use case: game designers write systems in deval that the engine
runs each frame alongside native systems.

```dart
// Host: register ECS query API
deval.register('query', (List<Type> components) {
  return world.query(components);
});
deval.registerClass(DevalClass<Entity>(/* ... */));
deval.registerClass(DevalClass<Position>(/* ... */));
deval.registerClass(DevalClass<Velocity>(/* ... */));

// Script: a movement system
ctx.eval('''
  void movementSystem(double dt) {
    for (var entity in query([Position, Velocity])) {
      var pos = entity.get<Position>();
      var vel = entity.get<Velocity>();
      pos.x += vel.x * dt;
      pos.y += vel.y * dt;
    }
  }
''');

// Host: call each frame
gameLoop.onTick = (dt) {
  ctx.call('movementSystem', [dt]);
};
```

### 8.2 Hot reload

Scripts can be reloaded without restarting the game:

```dart
// Watch for file changes
watcher.onChange('scripts/enemy_ai.dart', (content) {
  try {
    ctx.eval(content); // re-evaluates, replacing old definitions
    print('Hot reloaded enemy_ai.dart');
  } on DevalError catch (e) {
    print('Reload failed: $e'); // old code still active
  }
});
```

Re-evaluation replaces function and class definitions in the context's global
scope. Existing object instances keep their data but pick up new method
implementations (because methods are resolved through the class vtable, not
baked into instances).

### 8.3 Mod system

Mods are isolated contexts with controlled access:

```dart
DevalContext loadMod(String modPath) {
  final source = File('$modPath/init.dart').readAsStringSync();
  final manifest = parseManifest('$modPath/manifest.yaml');

  final ctx = deval.createContext(
    name: manifest.name,
    permissions: [
      Permission.fileRead(modPath),  // can only read own files
      // No network, no process, no filesystem write
    ],
  );

  // Expose only the mod API, not engine internals
  ctx['modApi'] = modApi;
  ctx['registerItem'] = modApi.registerItem;
  ctx['registerEnemy'] = modApi.registerEnemy;

  ctx.setStepLimit(10000000);  // prevent abuse
  ctx.eval(source);
  return ctx;
}

// Load all mods
for (final modDir in Directory('mods').listSync()) {
  mods.add(loadMod(modDir.path));
}
```

Each mod runs in its own `DevalContext` with its own global scope. Mods cannot
see each other's state. The host controls exactly what API surface each mod
can access.


## 9. Internal Architecture (How It Works)

### 9.1 Value representation

All values crossing the host-guest boundary use a tagged representation:

```dart
// Internal -- not exposed to users
class DevalValue {
  static const int tagNull = 0;
  static const int tagBool = 1;
  static const int tagInt = 2;
  static const int tagDouble = 3;
  static const int tagObject = 4;

  final int tag;
  final int bits; // raw payload (int value, double bits, or object table index)
}
```

Primitives (null, bool, int, double) require zero heap allocation. They are
stored as two integers: a tag and a payload. Objects (strings, lists, instances)
are stored in an object table and referenced by index.

When a user calls `ctx.call('square', [7])`:

1. `7` is a Dart `int`. The bridge recognizes `int` and creates
   `DevalValue(tagInt, 7)` -- no allocation.
2. The dispatch loop runs `square` with this value on the stack.
3. The result `49` comes back as `DevalValue(tagInt, 49)`.
4. The bridge converts it back to Dart `int` -- no allocation.

For objects like `String` or user-defined classes, the bridge creates an entry
in the object table (one allocation) and returns the index. When the result
crosses back, it looks up the index and returns the Dart object.

### 9.2 Auto-marshalling

When `deval.register('clamp', (num value, num min, num max) => ...)` is called,
the runtime generates a specialized bridge at registration time:

```
  Input types:  [num, num, num]
  Output type:  num
  Bridge:       read 3 tagged values from stack
                assert tag == tagInt or tag == tagDouble for each
                convert to Dart num
                call the Dart function
                convert result to tagged value
                push to stack
```

This bridge is a concrete function, not a generic dispatch. For common type
patterns (all-int, all-double, mixed primitives), pre-built bridges exist.
For complex types (user classes), a generic bridge does the lookup.

### 9.3 Integer-indexed dispatch

Method calls on registered classes use integer IDs, not strings:

```
  Compile time:
    "velocity.x"  ->  LOAD_LOCAL 2, GET_FIELD 0  (field ID 0 = "x")

  Runtime:
    GET_FIELD looks up classId + fieldId in a flat array
    -> calls the getter function pointer directly
```

The compiler assigns integer IDs to every member of every known class. The
runtime stores vtables as flat arrays of function pointers indexed by member
ID. A property access is: `vtable[classId][memberId](self)` -- two array
lookups, no string hashing.


## 10. Migration Path

### 10.1 Compatibility layer

deval v2 provides a compatibility adapter for existing bridge code:

```dart
// Wrap an old-style EvalPlugin for use with deval v2
final deval = Deval();
deval.registerLegacyPlugin(MyOldPlugin());
```

`registerLegacyPlugin` accepts an `EvalPlugin` and translates its two-phase
registration into the new single-phase model. The `$Value` wrappers still
work (they are just slower). This allows incremental migration.

### 10.2 Migration priority

```
  Step 1: Replace eval()/Runtime/Compiler with Deval/DevalContext
          (API change only, same bytecode engine underneath)

  Step 2: Replace BridgeClassDef + $Wrapper classes with DevalClass<T>
          for new code. Legacy wrappers continue to work.

  Step 3: Migrate existing wrappers one at a time.
          Each migration: ~200 lines of wrapper -> ~15 lines of DevalClass.

  Step 4: Remove legacy compatibility layer once migration is complete.
```

### 10.3 What changes internally

The new API is a facade over a redesigned bridge layer:

```
  Old path:  User -> $Value wrapper -> string dispatch -> Runtime
  New path:  User -> auto-marshal -> integer dispatch -> Runtime

  The bytecode engine itself can be upgraded independently (Phase 3/4).
  The API layer (Phase 5) can ship first with the existing engine,
  then swap in the new engine transparently.
```

This means the DX improvements described in this document can land before
the bytecode engine is rewritten. Users get the new API immediately, and
performance improves later when the engine catches up.


## 11. Summary

### API method count

```
  Deval class:         6 methods (createContext, register, registerClass,
                       setMemoryLimit, setExecutionLimit, dispose)
                       + 1 static (eval)

  DevalContext class:   9 methods (eval, run, load, call, compile,
                       operator[], operator[]=, onError, dispose)

  DevalClass<T>:       1 constructor (all configuration via named params)

  DevalConfig:         1 constructor

  Permission:          5 factory constructors (fileRead, fileWrite,
                       network, process, random)

  Total public API:    ~22 methods
```

Compare: Lua ~120 functions, QuickJS ~180, current deval ~40+ across
Compiler/Runtime/EvalPlugin/BridgeDeclarationRegistry plus the entire
$Value/$Instance/BridgeClassDef hierarchy.

### Boilerplate comparison

```
  Task                      Current deval    deval v2     Reduction
  ---------------------------------------------------------------
  Hello world               8 lines          1 line       8x
  Register a function       18 lines         1 line       18x
  Register a class          220 lines        15 lines     15x
  Call eval'd function      4 lines          1 line       4x
  Bidirectional callback    25 lines         5 lines      5x
```

### Design decisions

```
  Decision                  Rationale
  ---------------------------------------------------------------
  Two-tier Runtime/Context  QuickJS model. Shared runtime, isolated contexts.
  Auto-marshalling          Dart has enough type info to eliminate manual
                            boxing. Lua/QuickJS/Wren can't do this in C.
  Integer dispatch          Universal across all production VMs. String
                            dispatch is unique to current deval and slow.
  Capability permissions    WASM/Deno model. Secure by default, opt-in access.
  Interrupt counter         QuickJS model. Amortized cost, deterministic.
  DevalClass<T> bindings    Wren's "bind once" + Dart's type inference.
                            No metadata DSL, no codegen required.
  Optional codegen          @devalExpose for zero-boilerplate on owned types.
                            DevalClass<T> for types you don't own.
  Source maps always on     10-15% size cost, but errors without source
                            locations are useless. Non-negotiable.
  API before engine         New API can ship on old engine. Performance
                            comes later without API changes.
```
