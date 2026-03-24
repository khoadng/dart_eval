import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/src/eval/compiler/errors.dart';
import 'package:test/test.dart';

/// co19 Language/Generics/class_* tests.
///
/// class_A01: Wrong number of type arguments (compile error)
/// class_A02: Recursive type arg must be well-bounded (compile error)
/// class_A03: Type argument reification
/// class_A04: Type args on non-generic class (compile error)
void main() {
  group('co19 class', () {
    late Compiler compiler;

    setUp(() {
      compiler = Compiler();
    });

    // === class_A01: Wrong number of type arguments ===

    test('class_A01_t01',
        () {
      // CE: too many type args for C<T> (e.g. C<int, int>)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T> {}
              void main() {
                C<int, int>? c7;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('class_A01_t02',
        () {
      // CE: wrong count + bound violation for C1<T extends num?>
      // e.g. C1<int, int> (too many), C1<List<num>> (bound violation)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C1<T extends num> {}
              void main() {
                C1<int, int>? c6;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('class_A01_t03',
        () {
      // CE: wrong count for 2-param and 4-param classes
      // e.g. C1<dynamic> for C1<T1, T2>, C2<int> for C2<T1, T2, T3, T4>
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C1<T1, T2> {}
              class C2<T1, T2, T3, T4> {}
              void main() {
                C1<dynamic>? c5;
                C2<int>? c13;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('class_A01_t04',
        () {
      // CE: wrong count for 102-param class (e.g. ManyParameters<int>)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class ManyParameters<T0, T1, T2, T3, T4> {}
              void main() {
                ManyParameters<int>? m;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === class_A02: Recursive type arg bounds ===

    test('class_A02_t01',
        () {
      // CE: recursive bound C<T extends C<T>>, C<C<int>> is invalid
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T extends C<T>> {}
              void main() {
                C<C<int>>? c1;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === class_A03: Reified type argument substitution ===

    test('class_A03_t01',
        () {
      // RT: T reified inside class body, checks T == int etc.
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<T> {
              Type get typeArg => T;
            }
            void main() {
              print(C<int>().typeArg == int);
              print(C<String>().typeArg == String);
              print(C<Object>().typeArg == Object);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\ntrue\n'),
      );
    });

    test('class_A03_t02',
        () {
      // RT: multiple T1, T2, T3 reified inside class body
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<T1, T2, T3> {
              Type get t1 => T1;
              Type get t2 => T2;
              Type get t3 => T3;
            }
            void main() {
              final c = C<int, String, double>();
              print(c.t1 == int);
              print(c.t2 == String);
              print(c.t3 == double);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\ntrue\n'),
      );
    });

    // === class_A04: Type args on non-generic class ===

    test('class_A04_t01',
        () {
      // CE: type args on non-generic class A
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              void main() {
                A<int>? a1;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });
  });
}
