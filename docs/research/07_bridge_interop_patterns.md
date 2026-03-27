# Bridge and Interop Patterns Research
Phase: 1 | Status: COMPLETE


## 1. Deval's Current Bridge System

Deval's bridge uses a wrapper/boxing pattern where every value crossing the
host-guest boundary must be wrapped in a `$Value` object.

### Core interfaces

```dart
abstract class $Value {
  int $getRuntimeType(Runtime runtime);
  dynamic get $value;    // unwrap to Dart value
  dynamic get $reified;  // deep unwrap (recurse into collections)
}

abstract class $Instance implements $Value {
  $Value? $getProperty(Runtime runtime, String identifier);
  void $setProperty(Runtime runtime, String identifier, $Value value);
}
```

Every Dart type exposed to the VM needs a wrapper class. `$int` wraps `int`,
`$String` wraps `String`, `$bool` wraps `bool`, etc. Each wrapper must:

1. Declare a `static const $declaration = BridgeClassDef(...)` with full
   type metadata (constructors, methods, getters, setters, fields).
2. Implement `$getProperty` with a string-dispatched switch statement
   returning `$Function` constants for every method.
3. Implement every method as a static function with signature
   `$Value? fn(Runtime runtime, $Value? target, List<$Value?> args)`.
4. Box/unbox every argument and return value on every call.

### Cost breakdown for `a + b` where both are `$int`

```
1. $getProperty(runtime, '+')     // string lookup, returns $Function
2. $Function._plus(runtime, target, args)
3. target!.$value                  // unbox left operand
4. args[0]!.$value                 // unbox right operand
5. target!.$value + other!.$value  // actual Dart addition
6. $int(evalResult)                // box result (allocation)
```

Six steps and one allocation for a single integer addition. The string
dispatch in `$getProperty` is a linear switch over operator names.

### Bridge classes ($Bridge mixin)

For host classes that can be subclassed inside the VM, deval uses the
`$Bridge` mixin backed by a static `Map<Object, BridgeData>` on `Runtime`:

```dart
mixin $Bridge<T> on Object implements $Value, $Instance {
  $Value? $getProperty(Runtime runtime, String identifier) {
    try {
      return Runtime.bridgeData[this]!.subclass!.$getProperty(runtime, identifier);
    } on UnimplementedError catch (_) {
      return $bridgeGet(identifier);
    }
  }
}
```

This uses exception-driven control flow (try/catch `UnimplementedError`) for
every property access to decide whether to delegate to the VM subclass or the
host implementation.

### Plugin system

```dart
abstract class EvalPlugin {
  String get identifier;
  void configureForCompile(BridgeDeclarationRegistry registry);
  void configureForRuntime(Runtime runtime);
}
```

Plugins must register bridge declarations at compile time (full
`BridgeClassDef` metadata) and bridge functions at runtime
(`runtime.registerBridgeFunc`). This is a two-phase registration.

### What makes this expensive

1. **Boxing every value.** `$int(42)` allocates a heap object for every
   integer. Primitives become indirect.
2. **String-based dispatch.** Property and method lookup goes through
   string comparison in switch statements.
3. **Uniform function signature.** Every bridge function takes
   `(Runtime, $Value?, List<$Value?>)` -- the `List` is allocated per call.
4. **Redundant metadata.** `BridgeClassDef` duplicates the Dart type system
   in a parallel data structure (BridgeTypeRef, BridgeParameter, etc.).
5. **Exception-driven bridging.** `$Bridge.$getProperty` catches
   `UnimplementedError` on every access to determine dispatch path.
6. **No specialization.** `int + int` and `String + String` go through the
   same generic path with dynamic type checks on the result.


## 2. Lua C API: Stack-Based Value Passing

### Design

Lua chose a stack-based API to solve the impedance mismatch between Lua's
dynamic types and C's static types. Rather than exposing a union type or a
handle system, all values pass through an abstract stack.

The stack solves two problems:
- **Language portability**: no complex union types that would be hard to
  represent in Java, Fortran, etc.
- **GC safety**: the stack is a GC root, so any value on it is protected
  from collection.

### Value passing pattern

```c
// Push values onto the stack
lua_pushinteger(L, 42);
lua_pushstring(L, "hello");

// Read values from the stack
int n = lua_tointeger(L, -2);    // second from top
const char* s = lua_tostring(L, -1);  // top

// Call a Lua function: push func, push args, call
lua_getglobal(L, "myFunc");
lua_pushinteger(L, 10);
lua_pushinteger(L, 20);
lua_call(L, 2, 1);  // 2 args, 1 result
int result = lua_tointeger(L, -1);
lua_pop(L, 1);
```

### Exposing C functions to Lua

```c
static int l_add(lua_State *L) {
    double a = luaL_checknumber(L, 1);
    double b = luaL_checknumber(L, 2);
    lua_pushnumber(L, a + b);
    return 1;  // number of results
}

// Register
lua_pushcfunction(L, l_add);
lua_setglobal(L, "add");
```

### Type extension via metatables

Metatables attach behavior to userdata (opaque C pointers stored in Lua):

```c
// Create userdata
MyStruct* obj = lua_newuserdata(L, sizeof(MyStruct));
luaL_setmetatable(L, "MyStruct");

// Define metamethods
luaL_newmetatable(L, "MyStruct");
lua_pushvalue(L, -1);
lua_setfield(L, -2, "__index");  // self-indexing
lua_pushcfunction(L, mymethod);
lua_setfield(L, -2, "doSomething");
```

### Overhead per call

- Stack manipulation (push/pop) for every argument and return value
- Type checking per argument (`lua_tointeger`, `luaL_checknumber`)
- No allocations for primitives (numbers are stored directly on the stack)
- Userdata requires one allocation for the C data block
- String lookup for named metamethods

### Strengths and weaknesses

Strengths: simple mental model, GC-safe by default, no handle management,
works from any language that can call C.

Weaknesses: stack indices are error-prone, verbose for complex calls,
every boundary crossing requires explicit push/pop choreography.


## 3. LuaJIT FFI: Eliminating the C API

### Design

LuaJIT's FFI lets Lua code declare C types and call C functions directly,
bypassing the Lua C API entirely. The JIT compiler generates native code
for FFI calls that is on par with what a C compiler would produce.

### Declaring C types from Lua

```lua
local ffi = require("ffi")

ffi.cdef[[
  typedef struct { double x, y; } Point;
  int printf(const char *fmt, ...);
  double sqrt(double x);
]]
```

### Calling C functions

```lua
local point = ffi.new("Point", {3.0, 4.0})
local dist = ffi.C.sqrt(point.x * point.x + point.y * point.y)
ffi.C.printf("distance: %g\n", dist)
```

### Why it is fast

- The JIT compiler inlines FFI calls. No stack manipulation, no type
  marshalling functions, no intermediate Lua C API layer.
- C struct field access compiles to direct memory loads at known offsets.
- Function calls through `ffi.C.funcname` are resolved once and the
  lookup overhead is eliminated by the JIT.
- The key rule: "cache namespaces, not functions" -- the JIT optimizes
  namespace-based resolution but cannot optimize cached function pointers.

### Metamethods on C types

```lua
local Point
local mt = {
  __add = function(a, b) return Point(a.x+b.x, a.y+b.y) end,
  __tostring = function(p) return "("..p.x..","..p.y..")" end,
}
Point = ffi.metatype("Point", mt)
```

### Overhead per call

For JIT-compiled code: effectively zero. The generated machine code is
equivalent to a direct C function call. For interpreted code: slightly
higher than the C API due to type parsing, but still lower than going
through the stack.

### Key insight for deval

LuaJIT proves that the fastest interop avoids the interop layer entirely.
If the VM can understand host type layouts directly, it can generate code
that accesses host data without boxing or marshalling.


## 4. Python C Extension API

### Design

Python's C API centers on `PyObject*`, a pointer to a reference-counted
struct. Every Python value is a `PyObject*` in C code.

```c
typedef struct {
    Py_ssize_t ob_refcnt;
    PyTypeObject *ob_type;
} PyObject;
```

### Reference counting

```c
PyObject* result = PyLong_FromLong(42);  // refcnt = 1
Py_INCREF(result);                        // refcnt = 2
Py_DECREF(result);                        // refcnt = 1
// return result to Python -- caller takes ownership
```

Three ownership conventions:
- **New reference**: caller owns, must DECREF when done
- **Borrowed reference**: caller must not DECREF
- **Stolen reference**: callee takes ownership (e.g., `PyList_SetItem`)

### Defining a C function for Python

```c
static PyObject* my_add(PyObject* self, PyObject* args) {
    int a, b;
    if (!PyArg_ParseTuple(args, "ii", &a, &b))
        return NULL;  // exception already set
    return PyLong_FromLong(a + b);
}

static PyMethodDef methods[] = {
    {"add", my_add, METH_VARARGS, "Add two integers"},
    {NULL, NULL, 0, NULL}
};
```

### Type slots

New-style types define behavior through slot functions:

```c
static PyType_Slot MyType_slots[] = {
    {Py_tp_init, my_init},
    {Py_tp_dealloc, my_dealloc},
    {Py_nb_add, my_add},
    {0, NULL}
};
```

Slots replace the old monolithic `PyTypeObject` struct with a sparse array
of function pointers, reducing boilerplate and improving ABI stability.

### Buffer protocol

Allows zero-copy sharing of memory between objects:

```c
static int my_getbuffer(PyObject *self, Py_buffer *view, int flags) {
    MyObj *obj = (MyObj*)self;
    view->buf = obj->data;
    view->len = obj->size;
    // ...
    return 0;
}
```

### Overhead

- Every value is heap-allocated and reference-counted
- `PyArg_ParseTuple` parses a format string at runtime
- Every C function call crosses through the interpreter dispatch
- Reference counting errors are the #1 source of extension bugs

### Python ctypes and cffi

**ctypes** (stdlib): runtime FFI, declares C types from Python, no
compilation needed. Higher call overhead due to runtime type resolution.

**cffi**: two modes.
- ABI mode: like ctypes but cleaner API, moderate overhead
- API mode: compiles a C extension at build time, lower overhead

Performance hierarchy: C extension > cffi API > cffi ABI > ctypes.

cffi's API mode generates compiled wrappers, approaching hand-written
C extension performance. The key insight: a compilation step that knows
both sides of the type mapping at build time produces faster code.


## 5. GraalVM Polyglot Interop (Truffle)

### Design

GraalVM solves cross-language interop through a shared interoperability
protocol. Languages implement a standard set of "messages" (hasMembers,
readMember, execute, etc.) and the Truffle framework handles dispatch.

### Embedding API

```java
try (Context context = Context.create()) {
    Value result = context.eval("js", "40 + 2");
    int answer = result.asInt();  // 42
}
```

### Exposing host functions to guest

```java
// Host class
public class MathHelper {
    @HostAccess.Export
    public int add(int a, int b) { return a + b; }
}

// Bind to guest
context.getBindings("js").putMember("math", new MathHelper());

// Use from JavaScript
context.eval("js", "math.add(3, 4)");
```

### ProxyObject for dynamic types

```java
ProxyObject proxy = ProxyObject.fromMap(Map.of(
    "name", "test",
    "compute", (ProxyExecutable) args -> args[0].asInt() * 2
));
```

### Type mapping

The `Value` class provides capability-based type queries:
- `canExecute()`, `hasMembers()`, `hasArrayElements()`
- `asInt()`, `asString()`, `asDouble()` for conversion
- `getMember(name)`, `execute(args...)` for invocation

This is fundamentally different from deval's approach. Instead of wrapping
every value in a type-specific box, GraalVM uses a single `Value` type with
capability queries. The Truffle framework optimizes through partial evaluation
and speculative compilation.

### Cross-language call overhead

Within GraalVM, the Truffle compiler can inline across language boundaries
through partial evaluation. A JavaScript function calling a Ruby method can
be compiled into a single optimized machine code unit. This is the gold
standard for cross-language interop performance.

### Key insight for deval

The capability-based `Value` type (canExecute, hasMembers) is a cleaner
abstraction than type-specific wrapper classes. It separates "what can I
do with this value" from "what concrete type is it."


## 6. V8 Embedding API

### Design

V8 uses a handle-based system where JavaScript values are referenced through
typed handles rather than raw pointers or a stack.

### Core concepts

```cpp
// Create an isolate (VM instance with its own heap)
v8::Isolate* isolate = v8::Isolate::New(params);

{
    // HandleScope manages handle lifetimes (RAII)
    v8::HandleScope handle_scope(isolate);

    // Context is an execution environment
    v8::Local<v8::Context> context = v8::Context::New(isolate);
    v8::Context::Scope context_scope(context);

    // Compile and run
    v8::Local<v8::String> source = v8::String::NewFromUtf8Literal(isolate, "40+2");
    v8::Local<v8::Script> script = v8::Script::Compile(context, source).ToLocalChecked();
    v8::Local<v8::Value> result = script->Run(context).ToLocalChecked();
    int answer = result->Int32Value(context).FromJust();
}
```

### Handle types

- **Local<T>**: short-lived, tied to a HandleScope, stack-allocated
- **Persistent<T>**: survives across HandleScopes, must be explicitly Reset
- **UniquePersistent<T>**: RAII wrapper around Persistent
- **EscapableHandleScope**: allows returning a Local from a nested scope

### Exposing C++ functions

```cpp
void Add(const v8::FunctionCallbackInfo<v8::Value>& info) {
    v8::Isolate* isolate = info.GetIsolate();
    double a = info[0]->NumberValue(isolate->GetCurrentContext()).FromJust();
    double b = info[1]->NumberValue(isolate->GetCurrentContext()).FromJust();
    info.GetReturnValue().Set(v8::Number::New(isolate, a + b));
}

// Register via FunctionTemplate
v8::Local<v8::FunctionTemplate> fn = v8::FunctionTemplate::New(isolate, Add);
global->Set(isolate, "add", fn);
```

### Property accessors

```cpp
void GetX(v8::Local<v8::Name> property,
          const v8::PropertyCallbackInfo<v8::Value>& info) {
    v8::Local<v8::Object> self = info.Holder();
    v8::Local<v8::External> wrap = v8::Local<v8::External>::Cast(
        self->GetInternalField(0));
    MyObj* obj = static_cast<MyObj*>(wrap->Value());
    info.GetReturnValue().Set(v8::Number::New(info.GetIsolate(), obj->x));
}
```

### Overhead

- Handle creation is cheap (stack pointer bump in HandleScope)
- No boxing for numbers (V8 uses SMI / NaN-boxing internally)
- Function calls go through the FunctionCallbackInfo abstraction
- Template instantiation has upfront cost but cached afterward
- The SetReturnValue pattern avoids allocating a return handle

### Key insight for deval

V8's `FunctionCallbackInfo` is a single struct providing access to
arguments, return value, and isolate. No `List<$Value?>` allocation
per call. The return value is set in-place rather than returned.


## 7. QuickJS Embedding

### Design

QuickJS uses direct parameter passing (no implicit stack) with reference-
counted JSValues. Functions receive their arguments as normal C parameters.

### JSValue representation

JSValue is a tagged union (64-bit on 64-bit platforms) that can hold:
- int32 (small integers, no allocation)
- float64 (doubles, no allocation)
- pointers to reference-counted objects (strings, objects, etc.)

```c
// Create values -- no allocation for integers
JSValue num = JS_NewInt32(ctx, 42);
JSValue str = JS_NewString(ctx, "hello");

// Extract values
int32_t n = 0;
JS_ToInt32(ctx, &n, num);
const char* s = JS_ToCString(ctx, str);
JS_FreeCString(ctx, s);

// Reference counting
JS_FreeValue(ctx, str);  // decrement refcount
```

### Registering C functions

```c
JSValue js_add(JSContext *ctx, JSValueConst this_val,
               int argc, JSValueConst *argv) {
    int32_t a, b;
    JS_ToInt32(ctx, &a, argv[0]);
    JS_ToInt32(ctx, &b, argv[1]);
    return JS_NewInt32(ctx, a + b);
}

// Register
JSValue global = JS_GetGlobalObject(ctx);
JS_SetPropertyStr(ctx, global, "add",
    JS_NewCFunction(ctx, js_add, "add", 2));
JS_FreeValue(ctx, global);
```

### Key design choice: no implicit stack

"There is no implicit stack, so C functions get their parameters as
normal C parameters." This eliminates stack index errors and makes the
API feel more natural to C programmers.

### Error handling

```c
JSValue result = JS_Call(ctx, func, this_val, argc, argv);
if (JS_IsException(result)) {
    JSValue exception = JS_GetException(ctx);
    // handle error
    JS_FreeValue(ctx, exception);
}
```

### Overhead

- Small integers (int32) and booleans are unboxed in JSValue tags
- Strings and objects are reference-counted (no tracing GC needed for
  simple cases, cycle collector handles cycles)
- Function calls pass a C array of JSValues -- no List allocation
- The tagged-value representation means no heap allocation for primitives

### Key insight for deval

QuickJS proves that a tagged-value representation can eliminate boxing for
primitives while still supporting dynamic typing. The `JSValueConst*`
parameter pattern (pointer to array of tagged values) is far cheaper than
`List<$Value?>`.


## 8. Dart FFI (dart:ffi)

### Design

Dart FFI uses static type information to generate specialized marshalling
code at compile time, avoiding runtime reflection entirely.

```dart
// Declare the native function signature
typedef NativeAdd = Int32 Function(Int32, Int32);
typedef DartAdd = int Function(int, int);

// Look up and bind
final dylib = DynamicLibrary.open('libmath.so');
final add = dylib.lookupFunction<NativeAdd, DartAdd>('add');

// Call -- no boxing, no marshalling visible to the user
int result = add(3, 4);
```

### Struct mapping

```dart
final class Point extends Struct {
  @Double()
  external double x;

  @Double()
  external double y;
}

// Access struct fields through a pointer -- direct memory read
Pointer<Point> ptr = calloc<Point>();
ptr.ref.x = 3.0;  // writes directly to native memory
```

### Leaf functions

```dart
final sqrt = dylib.lookupFunction<
    Double Function(Double),
    double Function(double)
>('sqrt', isLeaf: true);
```

Leaf functions cannot call back into Dart, which allows:
- Skipping the exit frame setup
- Direct pointer passing without GC protection
- Cross-function optimization by the compiler

### Overhead

- Near zero for leaf functions (direct native call)
- Small fixed cost for non-leaf (save/restore Dart stack frame)
- No boxing for primitives (Dart int/double map directly to native types)
- Struct access is direct memory read/write at computed offsets
- All type information is resolved at compile time

### Key insight for deval

Dart FFI's power comes from static type knowledge. When both sides of the
boundary have known types at compile time, the compiler generates specialized
code with no runtime dispatch. Deval's `$Value` interface forces everything
through a single dynamic dispatch path.


## 9. Java JNI vs Panama FFM API

### JNI (old approach)

```c
JNIEXPORT jint JNICALL Java_Math_add(JNIEnv *env, jobject obj,
                                      jint a, jint b) {
    return a + b;
}
```

Problems:
- Requires C header generation from Java (javah/javac -h)
- Three artifacts to maintain (Java class, C header, C implementation)
- Aggregate data must be laboriously unpacked field-by-field
- No type safety at the C boundary
- JNI calls have significant overhead (thread state transitions, handle
  table management)

### Panama FFM (new approach)

```java
Linker linker = Linker.nativeLinker();
SymbolLookup stdlib = linker.defaultLookup();

FunctionDescriptor desc = FunctionDescriptor.of(
    ValueLayout.JAVA_INT,    // return type
    ValueLayout.ADDRESS       // parameter: const char*
);

MethodHandle strlen = linker.downcallHandle(
    stdlib.find("strlen").orElseThrow(),
    desc
);

try (Arena arena = Arena.ofConfined()) {
    MemorySegment cStr = arena.allocateUtf8String("hello");
    int len = (int) strlen.invoke(cStr);  // 5
}
```

### Key improvements

- Pure Java (no C code to write or compile)
- Type-safe memory access through MemorySegment
- Arena-based memory management (no manual free)
- `jextract` tool auto-generates bindings from C headers
- Performance comparable to JNI for most workloads

### Key insight for deval

The evolution from JNI to Panama mirrors what deval needs: moving from
hand-written boilerplate (wrapper classes) to declarative descriptions
(type descriptors) that a tool can process automatically.


## 10. Wren VM Embedding

### Design

Wren's API is purpose-built for game engine embedding. It uses numbered
slots (like Lua's stack but indexed rather than LIFO) plus persistent
handles for object references.

### Slot-based value passing

```c
// Foreign method implementation
void mathAdd(WrenVM* vm) {
    double a = wrenGetSlotDouble(vm, 1);  // arg 1
    double b = wrenGetSlotDouble(vm, 2);  // arg 2
    wrenSetSlotDouble(vm, 0, a + b);      // return via slot 0
}
```

### Foreign method binding

```c
WrenForeignMethodFn bindForeignMethod(WrenVM* vm,
    const char* module, const char* className,
    bool isStatic, const char* signature) {

    if (strcmp(className, "Math") == 0 &&
        isStatic &&
        strcmp(signature, "add(_,_)") == 0) {
        return mathAdd;
    }
    return NULL;
}
```

The VM calls this once during class definition and caches the function
pointer. Subsequent calls go directly to the C function.

### Foreign classes

```wren
foreign class Vec3 {
    construct new(x, y, z) {}
    foreign x
    foreign y
    foreign z
    foreign +(other)
}
```

```c
// Allocate: called when construct is invoked
void vec3Allocate(WrenVM* vm) {
    Vec3* v = (Vec3*)wrenSetSlotNewForeign(vm, 0, 0, sizeof(Vec3));
    v->x = wrenGetSlotDouble(vm, 1);
    v->y = wrenGetSlotDouble(vm, 2);
    v->z = wrenGetSlotDouble(vm, 3);
}
```

### Handles for persistent references

```c
// Get a handle to keep a reference alive across calls
wrenEnsureSlots(vm, 1);
wrenGetVariable(vm, "main", "MyClass", 0);
WrenHandle* classHandle = wrenGetSlotHandle(vm, 0);

// Later: call a method
WrenHandle* callHandle = wrenMakeCallHandle(vm, "doThing(_)");
wrenSetSlotHandle(vm, 0, classHandle);
wrenSetSlotString(vm, 1, "arg");
wrenCall(vm, callHandle);

// Cleanup
wrenReleaseHandle(vm, classHandle);
wrenReleaseHandle(vm, callHandle);
```

### Overhead

- Slots are an array -- indexed access, no stack manipulation
- No boxing for primitives (doubles stored directly in slots)
- Foreign data is allocated inline with the Wren object (one allocation)
- Binding resolution happens once at class load, cached as function pointer
- No string dispatch at call time

### Key insight for deval

Wren's design is lean and game-focused. The "bind once, call fast" pattern
(resolve the function pointer at class definition, then direct-call forever
after) is applicable to deval's bridge system.


## 11. Comparative Analysis

### Value passing strategies

```
  System          Strategy         Primitive Cost    Object Cost
  ---------------------------------------------------------------
  Lua C API       Stack-based      Push/pop (cheap)  Push/pop + userdata alloc
  LuaJIT FFI      Direct           Zero (JIT)        Direct memory access
  Python C API    PyObject*        Heap alloc + RC    Heap alloc + RC
  GraalVM         Value handles    Truffle opt        Truffle opt
  V8              Typed handles    SMI (no alloc)     Handle (stack bump)
  QuickJS         Tagged values    No alloc (tagged)  Refcounted alloc
  Dart FFI        Direct native    No alloc           Struct at offset
  Panama FFM      MethodHandle     No alloc           MemorySegment
  Wren            Indexed slots    Slot write (cheap)  Foreign alloc
  Deval           $Value boxing    Heap alloc          Heap alloc + wrapper
```

Deval is the only system that heap-allocates for every primitive crossing
the boundary. Every other system either uses tagged values, stack/slot
storage, or direct native representation to avoid this.

### Type mapping strategies

```
  System          Approach                     Boilerplate per type
  -------------------------------------------------------------------
  Lua             Metatables on userdata        ~20 lines per method
  LuaJIT FFI      C header declarations         Near zero (parse C)
  Python C API    PyTypeObject + slot functions  ~50 lines per type
  Python cffi     C declarations in Python       Near zero (parse C)
  GraalVM         @HostAccess.Export annotation  1 annotation per method
  V8              FunctionTemplate + accessors   ~15 lines per method
  QuickJS         JS_NewCFunction + property set ~10 lines per method
  Dart FFI        typedef + lookupFunction       ~3 lines per function
  Panama FFM      FunctionDescriptor + jextract  Auto-generated
  Wren            Foreign method binding         ~10 lines per method
  Deval           $Value wrapper class           ~50-100 lines per type
```

Deval has the highest boilerplate cost. The `$num` wrapper alone is 628
lines for a single numeric type. The `$String` wrapper is 648 lines.

### Overhead per FFI call

```
  System              Minimum call overhead
  ------------------------------------------
  LuaJIT FFI (JIT)    ~0 ns (inlined)
  Dart FFI (leaf)     ~2-5 ns (direct call)
  Panama FFM          ~5-10 ns (MethodHandle)
  V8                  ~20-50 ns (handle scope + dispatch)
  Lua C API           ~30-50 ns (stack push/pop)
  QuickJS             ~30-50 ns (tagged value marshal)
  Wren                ~30-50 ns (slot read/write)
  Python C API        ~50-100 ns (refcount + tuple parse)
  GraalVM (cold)      ~100+ ns (interp), ~0 ns (compiled)
  Deval               ~200+ ns (box + string dispatch + unbox + list alloc)
```

These are rough estimates but the relative ordering is well-established
in benchmarks across these systems.

### Callback support (guest calling host vs host calling guest)

```
  System          Host -> Guest          Guest -> Host
  -----------------------------------------------------------
  Lua             lua_call/lua_pcall     lua_pushcfunction
  LuaJIT FFI      ffi.C.func()           callbacks via ffi.cast
  Python          PyObject_Call          C function registration
  GraalVM         Value.execute()        @HostAccess.Export
  V8              Function->Call()       FunctionTemplate::New
  QuickJS         JS_Call()              JS_NewCFunction()
  Dart FFI        N/A (host is native)   Pointer.fromFunction
  Wren            wrenCall()             foreign method binding
  Deval           bridgeCall()           registerBridgeFunc
```

Most systems have symmetric call patterns. The critical difference is
overhead: systems with tagged values or direct calling conventions
(LuaJIT, QuickJS) are cheapest for callbacks.

### Memory management across the boundary

```
  System          Ownership Model              Danger Level
  -----------------------------------------------------------
  Lua             GC owns Lua values           Low (stack protects)
  LuaJIT FFI      Manual for C, GC for Lua     Medium (C pointers)
  Python          Reference counting            High (leak/dangling)
  GraalVM         JVM GC for all                Low
  V8              GC + handle scopes            Medium (handle leaks)
  QuickJS         Reference counting            Medium (manual DECREF)
  Dart FFI        Manual for native memory      High (use-after-free)
  Panama FFM      Arena-scoped                  Low (arena auto-frees)
  Wren            GC + manual handle release    Low-Medium
  Deval           Dart GC owns $Value wrappers  Low (but wasteful)
```

Deval's memory model is safe (Dart GC handles everything) but wasteful
because every value is wrapped in a Dart object.

### Error handling across the boundary

```
  System          Pattern
  -----------------------------------------------------------
  Lua             lua_pcall returns error code, error on stack
  Python          Return NULL + PyErr_SetString
  V8              MaybeLocal<T> (empty = exception)
  QuickJS         JS_EXCEPTION sentinel value
  Wren            WrenInterpretResult enum
  Deval           Dart exceptions (try/catch UnimplementedError)
```

Deval's use of exception-driven control flow for normal dispatch
(`$Bridge.$getProperty` catches `UnimplementedError`) is the most
problematic pattern here. Exceptions should signal errors, not drive
normal method resolution.

### Ergonomics: boilerplate to expose `int.abs()`

**Deval (current)**:
```dart
// In BridgeClassDef (compile-time metadata):
'abs': BridgeMethodDef(
  BridgeFunctionDef(
    returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int)),
    params: [],
  ),
  isStatic: false,
),

// In $getProperty switch:
case 'abs':
  return __absInt;

// Static function + constant:
static const $Function __absInt = $Function(_absInt);
static $Value? _absInt(Runtime runtime, $Value? target, List<$Value?> args) {
  final evalResult = (target!.$value as int).abs();
  return $int(evalResult);
}

// Plus runtime registration in configureForRuntime
```

That is 15+ lines across 3-4 locations for a single zero-argument method.

**QuickJS equivalent**:
```c
JSValue js_int_abs(JSContext *ctx, JSValueConst this_val,
                   int argc, JSValueConst *argv) {
    int32_t val;
    JS_ToInt32(ctx, &val, this_val);
    return JS_NewInt32(ctx, abs(val));
}
```
5 lines in one location.

**Wren equivalent**:
```c
void intAbs(WrenVM* vm) {
    int val = (int)wrenGetSlotDouble(vm, 0);
    wrenSetSlotDouble(vm, 0, abs(val));
}
```
3 lines in one location.


## 12. What Would a Better Bridge Look Like for Deval

### Problem summary

Deval's bridge system has five fundamental costs:
1. Heap allocation for every primitive (boxing)
2. String-based method dispatch
3. List allocation for every call's arguments
4. Redundant type metadata declarations
5. Exception-driven control flow for bridge dispatch

### Design principles from the research

From LuaJIT: **eliminate the interop layer where possible.** If the VM
knows the host type layout, it can access data directly.

From QuickJS: **use tagged values to avoid boxing primitives.** A 64-bit
tagged value can hold int, double, bool, and null without allocation.

From V8: **use a callback info struct instead of allocating argument
lists.** `FunctionCallbackInfo` provides indexed access to arguments
without allocating a container.

From Wren: **resolve bindings once at class definition, then direct-call.**
The function pointer is cached; no string lookup on every call.

From Dart FFI: **leverage static type information.** When types are known
at compile time, generate specialized code.

From GraalVM: **capability-based value queries** instead of type-specific
wrapper hierarchies.

From Panama: **declarative descriptions + code generation** instead of
hand-written wrappers.

### Concrete proposals

**A. Tagged value representation**

Replace `$Value` boxing with a tagged value that can hold primitives inline:

```dart
// Conceptual -- actual representation depends on implementation
class EvalValue {
  // Tag + payload in two fields (Dart cannot do NaN-boxing)
  final int _tag;    // 0=null, 1=bool, 2=int, 3=double, 4=object
  final int _payload; // raw bits or object reference index

  // Fast accessors with no allocation
  int get asInt => _payload;  // when _tag == 2
  double get asDouble => _doubleFromBits(_payload);  // when _tag == 3
  bool get asBool => _payload != 0;  // when _tag == 1
}
```

This eliminates heap allocation for null, bool, int, and double. These
four types dominate runtime value traffic.

**B. Numeric dispatch table instead of string switch**

Replace string-based `$getProperty` with an integer-indexed dispatch:

```dart
// At compile time, assign numeric IDs to known members
const kAdd = 0, kSub = 1, kMul = 2, kDiv = 3, kAbs = 4; // ...

// At runtime, dispatch by ID (array lookup, not string comparison)
EvalValue getProperty(int memberId) => _vtable[memberId];
```

A vtable array lookup is O(1) with no string comparison.

**C. Args passed as a view, not an allocated List**

Instead of `List<$Value?>` per call, use a pre-allocated args buffer:

```dart
// Runtime maintains a reusable argument buffer
class CallFrame {
  final List<EvalValue> args = List.filled(maxArity, EvalValue.nil);
  int argCount = 0;

  void pushArg(EvalValue v) { args[argCount++] = v; }
  EvalValue arg(int i) => args[i];
  void reset() { argCount = 0; }
}
```

Zero allocations per call. The buffer is reused.

**D. Bind-once function resolution**

Like Wren, resolve bridge functions at class load time and cache as
direct function references:

```dart
typedef BridgeFn = EvalValue Function(CallFrame frame);

// Resolved once at setup
class ResolvedClass {
  final List<BridgeFn> methods;  // indexed by member ID
  final List<BridgeFn> getters;
  final List<BridgeFn> setters;
}
```

**E. Code generation for wrapper classes**

Instead of hand-writing 600+ line wrapper classes, generate them from
type declarations. Similar to how Panama's `jextract` generates Java
bindings from C headers, deval could generate bridge code from Dart
source analysis.

Deval already has a `bindgen` directory suggesting this direction.
The key is making the generated code use the optimized representations
above (tagged values, vtable dispatch, pre-allocated args) instead of
generating the same expensive patterns.

**F. Direct field access for known types**

For types with known layouts (like bridge classes with fixed fields),
allow direct indexed access instead of string-based property lookup:

```dart
// Instead of: instance.$getProperty(runtime, "x")
// Use:        instance.fields[0]  // field "x" is at index 0
```

This is what Lua userdata and Wren foreign classes do: the C code knows
the struct layout and reads fields at fixed offsets.


## 13. Priority ordering for deval

Based on impact vs effort:

```
  Change                          Impact    Effort    Priority
  ---------------------------------------------------------------
  Tagged values for primitives    High      Medium    1
  Pre-allocated arg buffer        High      Low       2
  Integer-based member dispatch   High      Medium    3
  Bind-once function caching      Medium    Low       4
  Remove exception-driven flow    Medium    Low       5
  Code generation for wrappers    High      High      6
  Direct field access             Medium    Medium    7
```

Changes 1-3 together would eliminate the majority of per-call overhead.
The pre-allocated arg buffer (#2) is the easiest win: replace
`List<$Value?>` with a reusable `CallFrame` that is reset between calls.

Tagged values (#1) eliminate the dominant allocation cost. Every `$int(x)`
and `$double(x)` becomes a tag + payload write instead of a heap
allocation.

Integer dispatch (#3) replaces O(n) string comparison with O(1) array
indexing for property access, which is the hottest path in the interpreter.
