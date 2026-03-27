/// Benchmark: virtual dispatch vs switch dispatch for interpreter loops.
///
/// Simulates deval's core dispatch loop with a simple program:
///   sum = 0; for i in 0..N: sum += i
///
/// Run AOT (the only mode that matters for real perf):
///   fvm dart compile exe bin/bench_dispatch.dart -o /tmp/bench_dispatch
///   /tmp/bench_dispatch
///
/// Run JIT (for quick sanity check, numbers will differ):
///   fvm dart run bin/bench_dispatch.dart

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Opcodes
// ---------------------------------------------------------------------------

const int OP_LOAD_INT = 0;
const int OP_ADD = 1;
const int OP_LT = 2;
const int OP_JUMP_FALSE = 3;
const int OP_JUMP = 4;
const int OP_HALT = 5;
const int OP_INC = 6;
const int OP_MOVE = 7;

// ---------------------------------------------------------------------------
// Approach 1: Virtual dispatch (what deval does today)
// ---------------------------------------------------------------------------

abstract class Op {
  void run(VirtualMachine vm);
}

class OpLoadInt extends Op {
  final int reg;
  final int value;
  OpLoadInt(this.reg, this.value);

  @override
  void run(VirtualMachine vm) {
    vm.regs[reg] = value;
  }
}

class OpAdd extends Op {
  final int dst, a, b;
  OpAdd(this.dst, this.a, this.b);

  @override
  void run(VirtualMachine vm) {
    vm.regs[dst] = (vm.regs[a] as int) + (vm.regs[b] as int);
  }
}

class OpLt extends Op {
  final int dst, a, b;
  OpLt(this.dst, this.a, this.b);

  @override
  void run(VirtualMachine vm) {
    vm.regs[dst] = (vm.regs[a] as int) < (vm.regs[b] as int);
  }
}

class OpJumpFalse extends Op {
  final int reg;
  final int target;
  OpJumpFalse(this.reg, this.target);

  @override
  void run(VirtualMachine vm) {
    if (vm.regs[reg] == false) vm.pc = target - 1; // -1 because loop increments
  }
}

class OpJump extends Op {
  final int target;
  OpJump(this.target);

  @override
  void run(VirtualMachine vm) {
    vm.pc = target - 1;
  }
}

class OpHalt extends Op {
  @override
  void run(VirtualMachine vm) {
    vm.halted = true;
  }
}

class OpInc extends Op {
  final int reg;
  OpInc(this.reg);

  @override
  void run(VirtualMachine vm) {
    vm.regs[reg] = (vm.regs[reg] as int) + 1;
  }
}

class OpMove extends Op {
  final int dst, src;
  OpMove(this.dst, this.src);

  @override
  void run(VirtualMachine vm) {
    vm.regs[dst] = vm.regs[src];
  }
}

// 70 more Op subclasses to make the call site truly megamorphic (like deval's 74+)
class OpNop10 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop11 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop12 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop13 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop14 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop15 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop16 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop17 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop18 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop19 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop20 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop21 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop22 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop23 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop24 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop25 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop26 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop27 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop28 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop29 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop30 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop31 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop32 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop33 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop34 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop35 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop36 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop37 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop38 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop39 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop40 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop41 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop42 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop43 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop44 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop45 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop46 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop47 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop48 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop49 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop50 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop51 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop52 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop53 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop54 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop55 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop56 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop57 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop58 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop59 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop60 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop61 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop62 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop63 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop64 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop65 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop66 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop67 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop68 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop69 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop70 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop71 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop72 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop73 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop74 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop75 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop76 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop77 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop78 extends Op { @override void run(VirtualMachine vm) {} }
class OpNop79 extends Op { @override void run(VirtualMachine vm) {} }

// Force all Op subclasses to be alive so AOT sees the full polymorphism.
// Without this, tree shaking removes the nop classes and dispatch stays monomorphic.
final _allOps = <Op>[
  OpNop10(), OpNop11(), OpNop12(), OpNop13(), OpNop14(),
  OpNop15(), OpNop16(), OpNop17(), OpNop18(), OpNop19(),
  OpNop20(), OpNop21(), OpNop22(), OpNop23(), OpNop24(),
  OpNop25(), OpNop26(), OpNop27(), OpNop28(), OpNop29(),
  OpNop30(), OpNop31(), OpNop32(), OpNop33(), OpNop34(),
  OpNop35(), OpNop36(), OpNop37(), OpNop38(), OpNop39(),
  OpNop40(), OpNop41(), OpNop42(), OpNop43(), OpNop44(),
  OpNop45(), OpNop46(), OpNop47(), OpNop48(), OpNop49(),
  OpNop50(), OpNop51(), OpNop52(), OpNop53(), OpNop54(),
  OpNop55(), OpNop56(), OpNop57(), OpNop58(), OpNop59(),
  OpNop60(), OpNop61(), OpNop62(), OpNop63(), OpNop64(),
  OpNop65(), OpNop66(), OpNop67(), OpNop68(), OpNop69(),
  OpNop70(), OpNop71(), OpNop72(), OpNop73(), OpNop74(),
  OpNop75(), OpNop76(), OpNop77(), OpNop78(), OpNop79(),
];

class VirtualMachine {
  final List<Object?> regs = List.filled(8, null);
  int pc = 0;
  bool halted = false;
}

int runVirtual(List<Op> program, int n) {
  final vm = VirtualMachine();
  vm.regs[2] = n; // R2 = limit
  vm.pc = 0;
  vm.halted = false;

  while (!vm.halted) {
    final op = program[vm.pc];
    op.run(vm);
    vm.pc++;
  }

  return vm.regs[0] as int;
}

// ---------------------------------------------------------------------------
// Approach 2: Switch dispatch (proposed)
// ---------------------------------------------------------------------------

// Bytecode: [opcode, arg1, arg2, arg3] per instruction, packed in Int32List
// Each instruction is 4 ints wide for simplicity.

Int32List buildSwitchProgram() {
  final ops = <int>[];

  void emit(int op, [int a = 0, int b = 0, int c = 0]) {
    ops.addAll([op, a, b, c]);
  }

  // R0 = sum = 0
  emit(OP_LOAD_INT, 0, 0); // 0
  // R1 = i = 0
  emit(OP_LOAD_INT, 1, 0); // 1
  // R2 = n (set externally)
  // Loop start (instruction 2):
  // R3 = i < n
  emit(OP_LT, 3, 1, 2); // 2
  // if !R3 goto end
  emit(OP_JUMP_FALSE, 3, 7); // 3 -> jump to instruction 7
  // R0 = R0 + R1
  emit(OP_ADD, 0, 0, 1); // 4
  // R1 = R1 + 1
  emit(OP_INC, 1); // 5
  // goto loop start
  emit(OP_JUMP, 2); // 6
  // halt
  emit(OP_HALT); // 7

  return Int32List.fromList(ops);
}

// Pad the switch with many cases to simulate deval's 74+ opcodes.
// This prevents the AOT compiler from simplifying to a small range check.
int runSwitch(Int32List code, int n) {
  final regs = List<Object?>.filled(8, null);
  regs[2] = n;
  int pc = 0;

  while (true) {
    final base = pc * 4;
    final op = code[base];
    switch (op) {
      case OP_LOAD_INT:
        regs[code[base + 1]] = code[base + 2];
      case OP_ADD:
        regs[code[base + 1]] =
            (regs[code[base + 2]] as int) + (regs[code[base + 3]] as int);
      case OP_LT:
        regs[code[base + 1]] =
            (regs[code[base + 2]] as int) < (regs[code[base + 3]] as int);
      case OP_JUMP_FALSE:
        if (regs[code[base + 1]] == false) {
          pc = code[base + 2];
          continue;
        }
      case OP_JUMP:
        pc = code[base + 1];
        continue;
      case OP_HALT:
        return regs[0] as int;
      case OP_INC:
        regs[code[base + 1]] = (regs[code[base + 1]] as int) + 1;
      case OP_MOVE:
        regs[code[base + 1]] = regs[code[base + 2]];
      // Pad with 70 more cases to simulate deval's ~80 opcodes
      case 10: regs[0] = regs[0];
      case 11: regs[0] = regs[0];
      case 12: regs[0] = regs[0];
      case 13: regs[0] = regs[0];
      case 14: regs[0] = regs[0];
      case 15: regs[0] = regs[0];
      case 16: regs[0] = regs[0];
      case 17: regs[0] = regs[0];
      case 18: regs[0] = regs[0];
      case 19: regs[0] = regs[0];
      case 20: regs[0] = regs[0];
      case 21: regs[0] = regs[0];
      case 22: regs[0] = regs[0];
      case 23: regs[0] = regs[0];
      case 24: regs[0] = regs[0];
      case 25: regs[0] = regs[0];
      case 26: regs[0] = regs[0];
      case 27: regs[0] = regs[0];
      case 28: regs[0] = regs[0];
      case 29: regs[0] = regs[0];
      case 30: regs[0] = regs[0];
      case 31: regs[0] = regs[0];
      case 32: regs[0] = regs[0];
      case 33: regs[0] = regs[0];
      case 34: regs[0] = regs[0];
      case 35: regs[0] = regs[0];
      case 36: regs[0] = regs[0];
      case 37: regs[0] = regs[0];
      case 38: regs[0] = regs[0];
      case 39: regs[0] = regs[0];
      case 40: regs[0] = regs[0];
      case 41: regs[0] = regs[0];
      case 42: regs[0] = regs[0];
      case 43: regs[0] = regs[0];
      case 44: regs[0] = regs[0];
      case 45: regs[0] = regs[0];
      case 46: regs[0] = regs[0];
      case 47: regs[0] = regs[0];
      case 48: regs[0] = regs[0];
      case 49: regs[0] = regs[0];
      case 50: regs[0] = regs[0];
      case 51: regs[0] = regs[0];
      case 52: regs[0] = regs[0];
      case 53: regs[0] = regs[0];
      case 54: regs[0] = regs[0];
      case 55: regs[0] = regs[0];
      case 56: regs[0] = regs[0];
      case 57: regs[0] = regs[0];
      case 58: regs[0] = regs[0];
      case 59: regs[0] = regs[0];
      case 60: regs[0] = regs[0];
      case 61: regs[0] = regs[0];
      case 62: regs[0] = regs[0];
      case 63: regs[0] = regs[0];
      case 64: regs[0] = regs[0];
      case 65: regs[0] = regs[0];
      case 66: regs[0] = regs[0];
      case 67: regs[0] = regs[0];
      case 68: regs[0] = regs[0];
      case 69: regs[0] = regs[0];
      case 70: regs[0] = regs[0];
      case 71: regs[0] = regs[0];
      case 72: regs[0] = regs[0];
      case 73: regs[0] = regs[0];
      case 74: regs[0] = regs[0];
      case 75: regs[0] = regs[0];
      case 76: regs[0] = regs[0];
      case 77: regs[0] = regs[0];
      case 78: regs[0] = regs[0];
      case 79: regs[0] = regs[0];
    }
    pc++;
  }
}

// ---------------------------------------------------------------------------
// Approach 3: Switch dispatch with unboxed int registers
// ---------------------------------------------------------------------------

int runSwitchUnboxed(Int32List code, int n) {
  // Dedicated int register file -- no Object? boxing
  final regs = Int64List(8);
  regs[2] = n;
  int pc = 0;

  while (true) {
    final base = pc * 4;
    final op = code[base];
    switch (op) {
      case OP_LOAD_INT:
        regs[code[base + 1]] = code[base + 2];
      case OP_ADD:
        regs[code[base + 1]] = regs[code[base + 2]] + regs[code[base + 3]];
      case OP_LT:
        regs[code[base + 1]] =
            regs[code[base + 2]] < regs[code[base + 3]] ? 1 : 0;
      case OP_JUMP_FALSE:
        if (regs[code[base + 1]] == 0) {
          pc = code[base + 2];
          continue;
        }
      case OP_JUMP:
        pc = code[base + 1];
        continue;
      case OP_HALT:
        return regs[0];
      case OP_INC:
        regs[code[base + 1]] = regs[code[base + 1]] + 1;
      case OP_MOVE:
        regs[code[base + 1]] = regs[code[base + 2]];
      // Pad to match the 80-case switch
      case 10: regs[0] = regs[0];
      case 11: regs[0] = regs[0];
      case 12: regs[0] = regs[0];
      case 13: regs[0] = regs[0];
      case 14: regs[0] = regs[0];
      case 15: regs[0] = regs[0];
      case 16: regs[0] = regs[0];
      case 17: regs[0] = regs[0];
      case 18: regs[0] = regs[0];
      case 19: regs[0] = regs[0];
      case 20: regs[0] = regs[0];
      case 21: regs[0] = regs[0];
      case 22: regs[0] = regs[0];
      case 23: regs[0] = regs[0];
      case 24: regs[0] = regs[0];
      case 25: regs[0] = regs[0];
      case 26: regs[0] = regs[0];
      case 27: regs[0] = regs[0];
      case 28: regs[0] = regs[0];
      case 29: regs[0] = regs[0];
      case 30: regs[0] = regs[0];
      case 31: regs[0] = regs[0];
      case 32: regs[0] = regs[0];
      case 33: regs[0] = regs[0];
      case 34: regs[0] = regs[0];
      case 35: regs[0] = regs[0];
      case 36: regs[0] = regs[0];
      case 37: regs[0] = regs[0];
      case 38: regs[0] = regs[0];
      case 39: regs[0] = regs[0];
      case 40: regs[0] = regs[0];
      case 41: regs[0] = regs[0];
      case 42: regs[0] = regs[0];
      case 43: regs[0] = regs[0];
      case 44: regs[0] = regs[0];
      case 45: regs[0] = regs[0];
      case 46: regs[0] = regs[0];
      case 47: regs[0] = regs[0];
      case 48: regs[0] = regs[0];
      case 49: regs[0] = regs[0];
      case 50: regs[0] = regs[0];
      case 51: regs[0] = regs[0];
      case 52: regs[0] = regs[0];
      case 53: regs[0] = regs[0];
      case 54: regs[0] = regs[0];
      case 55: regs[0] = regs[0];
      case 56: regs[0] = regs[0];
      case 57: regs[0] = regs[0];
      case 58: regs[0] = regs[0];
      case 59: regs[0] = regs[0];
      case 60: regs[0] = regs[0];
      case 61: regs[0] = regs[0];
      case 62: regs[0] = regs[0];
      case 63: regs[0] = regs[0];
      case 64: regs[0] = regs[0];
      case 65: regs[0] = regs[0];
      case 66: regs[0] = regs[0];
      case 67: regs[0] = regs[0];
      case 68: regs[0] = regs[0];
      case 69: regs[0] = regs[0];
      case 70: regs[0] = regs[0];
      case 71: regs[0] = regs[0];
      case 72: regs[0] = regs[0];
      case 73: regs[0] = regs[0];
      case 74: regs[0] = regs[0];
      case 75: regs[0] = regs[0];
      case 76: regs[0] = regs[0];
      case 77: regs[0] = regs[0];
      case 78: regs[0] = regs[0];
      case 79: regs[0] = regs[0];
    }
    pc++;
  }
}

// ---------------------------------------------------------------------------
// Benchmark harness
// ---------------------------------------------------------------------------

List<Op> buildVirtualProgram() {
  return [
    OpLoadInt(0, 0), // 0: R0 = sum = 0
    OpLoadInt(1, 0), // 1: R1 = i = 0
    OpLt(3, 1, 2), // 2: R3 = i < n
    OpJumpFalse(3, 7), // 3: if !R3 goto 7
    OpAdd(0, 0, 1), // 4: sum += i
    OpInc(1), // 5: i++
    OpJump(2), // 6: goto 2
    OpHalt(), // 7: done
  ];
}

void bench(String name, int Function() fn, {int warmup = 3, int runs = 5}) {
  // Warmup
  for (var i = 0; i < warmup; i++) {
    fn();
  }

  // Timed runs
  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    final result = fn();
    sw.stop();
    times.add(sw.elapsedMicroseconds);
    // Prevent DCE
    if (result == -999) print('impossible');
  }

  times.sort();
  final median = times[times.length ~/ 2];
  final best = times.first;
  print('  $name: ${median / 1000.0} ms (median)  '
      '${best / 1000.0} ms (best)');
}

void main() {
  const n = 10000000; // 10M iterations

  final virtualProgram = buildVirtualProgram();
  final switchProgram = buildSwitchProgram();

  print('Dispatch benchmark: sum(0..$n)');
  print('Expected result: ${n * (n - 1) ~/ 2}\n');

  // Verify correctness
  final r1 = runVirtual(virtualProgram, n);
  final r2 = runSwitch(switchProgram, n);
  final r3 = runSwitchUnboxed(switchProgram, n);
  assert(r1 == r2 && r2 == r3, 'Results differ: $r1 vs $r2 vs $r3');
  print('All approaches produce: $r1\n');

  // Prevent tree-shaking of nop Op subclasses -- forces megamorphic dispatch
  if (n < 0) for (final op in _allOps) op.run(VirtualMachine());

  print('--- Results ---');
  bench('1. Virtual dispatch (current deval)', () => runVirtual(virtualProgram, n));
  bench('2. Switch dispatch (List<Object?>)', () => runSwitch(switchProgram, n));
  bench('3. Switch dispatch (Int64List regs)', () => runSwitchUnboxed(switchProgram, n));

  print('\nNote: AOT numbers are what matter. Compile with:');
  print('  fvm dart compile exe bin/bench_dispatch.dart -o /tmp/bench_dispatch');
  print('  /tmp/bench_dispatch');
}
