/// Benchmark: $Value boxing overhead vs raw values in List<Object?>
///
/// Simulates deval's actual hot path: sum loop where every iteration
/// boxes the result as $int (allocating 2 objects per box).
///
/// Run AOT:
///   fvm dart compile exe bin/bench_boxing.dart -o /tmp/bench_boxing
///   /tmp/bench_boxing

// ---------------------------------------------------------------------------
// Minimal $Value hierarchy (mirrors deval's actual classes)
// ---------------------------------------------------------------------------

abstract class $Value {
  dynamic get $value;
}

abstract class $Instance implements $Value {}

class $Object implements $Instance {
  final dynamic _value;
  $Object(this._value);

  @override
  dynamic get $value => _value;
}

class $num<T extends num> implements $Instance {
  final T $value;
  final $Object _superclass; // deval allocates this on every $num!

  $num(this.$value) : _superclass = $Object($value);
}

class $int extends $num<int> {
  $int(super.$value);
}

class $double extends $num<double> {
  $double(super.$value);
}

// ---------------------------------------------------------------------------
// Approach 1: Current deval pattern (box every result)
// ---------------------------------------------------------------------------

int runBoxed(int n) {
  final frame = List<Object?>.filled(8, null);

  // R0 = sum (boxed as $int)
  frame[0] = $int(0);
  // R1 = i (boxed as $int)
  frame[1] = $int(0);
  // R2 = n (boxed as $int)
  frame[2] = $int(n);

  while (true) {
    // NumLt: unbox, compare, store bool
    final i = (frame[1] as $int).$value;
    final limit = (frame[2] as $int).$value;
    frame[3] = i < limit;

    // JumpIfFalse
    if (frame[3] == false) break;

    // NumAdd: unbox both, add, store raw
    final sum = (frame[0] as $int).$value;
    final rawResult = sum + i;

    // BoxInt: THIS IS THE BOTTLENECK -- allocates $int + $Object
    frame[0] = $int(rawResult);

    // Inc i: unbox, add 1, rebox
    frame[1] = $int(i + 1);
  }

  return (frame[0] as $int).$value;
}

// ---------------------------------------------------------------------------
// Approach 2: No $Value -- store raw Dart values in List<Object?>
// ---------------------------------------------------------------------------

int runRaw(int n) {
  final frame = List<Object?>.filled(8, null);

  frame[0] = 0; // sum (raw int)
  frame[1] = 0; // i (raw int)
  frame[2] = n; // limit (raw int)

  while (true) {
    final i = frame[1] as int;
    final limit = frame[2] as int;
    frame[3] = i < limit;

    if (frame[3] == false) break;

    final sum = frame[0] as int;
    frame[0] = sum + i; // raw int, NO allocation

    frame[1] = i + 1; // raw int, NO allocation
  }

  return frame[0] as int;
}

// ---------------------------------------------------------------------------
// Approach 3: No $Value, eliminate superclass alloc only
// (what if we just fix $num to not allocate $Object?)
// ---------------------------------------------------------------------------

class $intLite implements $Value {
  final int $value;
  const $intLite(this.$value);
}

int runLiteBox(int n) {
  final frame = List<Object?>.filled(8, null);

  frame[0] = $intLite(0);
  frame[1] = $intLite(0);
  frame[2] = $intLite(n);

  while (true) {
    final i = (frame[1] as $intLite).$value;
    final limit = (frame[2] as $intLite).$value;
    frame[3] = i < limit;

    if (frame[3] == false) break;

    final sum = (frame[0] as $intLite).$value;
    // Only 1 allocation instead of 2
    frame[0] = $intLite(sum + i);
    frame[1] = $intLite(i + 1);
  }

  return (frame[0] as $intLite).$value;
}

// ---------------------------------------------------------------------------
// Approach 4: Hybrid -- box only at boundaries, unboxed internally
// (compiler knows when boxing is needed)
// ---------------------------------------------------------------------------

int runHybrid(int n) {
  // Imagine the compiler knows R0, R1, R2 are always int in this scope.
  // It skips Box/Unbox ops entirely for internal arithmetic.
  // Boxing only happens when crossing a function boundary or bridge call.
  final frame = List<Object?>.filled(8, null);

  frame[0] = 0;
  frame[1] = 0;
  frame[2] = n;

  while (true) {
    // Direct int operations, no cast needed if compiler tracks types
    // (in practice we still need `as int` but the Dart VM optimizes this
    // to a Smi tag check which is essentially free)
    final i = frame[1] as int;
    if (i >= (frame[2] as int)) break;
    frame[0] = (frame[0] as int) + i;
    frame[1] = i + 1;
  }

  return frame[0] as int;
}

// ---------------------------------------------------------------------------
// Approach 5: Baseline -- pure Dart, no frame at all
// ---------------------------------------------------------------------------

int runNative(int n) {
  int sum = 0;
  for (int i = 0; i < n; i++) {
    sum += i;
  }
  return sum;
}

// ---------------------------------------------------------------------------
// Benchmark harness
// ---------------------------------------------------------------------------

void bench(String name, int Function() fn, {int warmup = 3, int runs = 7}) {
  for (var i = 0; i < warmup; i++) {
    fn();
  }

  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    final result = fn();
    sw.stop();
    times.add(sw.elapsedMicroseconds);
    if (result == -999) print('impossible');
  }

  times.sort();
  final median = times[times.length ~/ 2];
  final best = times.first;
  print('  $name');
  print('    ${median / 1000.0} ms (median)  ${best / 1000.0} ms (best)');
}

void main() {
  const n = 10000000;

  // Verify all produce same result
  final expected = n * (n - 1) ~/ 2;
  assert(runBoxed(n) == expected);
  assert(runRaw(n) == expected);
  assert(runLiteBox(n) == expected);
  assert(runHybrid(n) == expected);
  assert(runNative(n) == expected);
  print('Boxing benchmark: sum(0..$n) = $expected\n');

  print('--- Results ---\n');
  bench('1. Current deval ($int + $Object, 2 allocs/box)', () => runBoxed(n));
  bench('2. Lite boxing (1 alloc/box, no superclass)', () => runLiteBox(n));
  bench('3. Raw values in List<Object?> (0 allocs)', () => runRaw(n));
  bench('4. Hybrid (raw + simplified loop)', () => runHybrid(n));
  bench('5. Native Dart (no interpreter)', () => runNative(n));

  print('\n--- Analysis ---');
  print('Compare 1 vs 3: cost of boxing');
  print('Compare 1 vs 2: cost of $Object superclass alloc alone');
  print('Compare 3 vs 5: cost of List<Object?> frame overhead');
}
