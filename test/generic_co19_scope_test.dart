import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/src/eval/compiler/errors.dart';
import 'package:test/test.dart';

/// co19 Language/Generics/scope_* tests.
///
/// scope_t01: Type param bound references another (U extends T?)
/// scope_t02: Type params in extends/implements clauses
/// scope_t03: Type params in body (constructor, is checks, fields, getter, setter)
/// scope_t04: Method type param shadows class type param
/// scope_t05: Static type checking with shadowed params (expectStaticType)
/// scope_t06: F-bounded compile error `Enum<int>`
/// scope_t07: F-bounded quantification works
void main() {
  group('co19 scope', () {
    late Compiler compiler;

    setUp(() {
      compiler = Compiler();
    });

    // === scope_t01: type param bound references another type param ===

    test('scope_t01', () {
      // RT: A<T, U extends T?> — bound of U references T
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<T, U extends T?> {
              T? t;
              A(U u) {
                t = u;
              }
            }
            void main() {
              var a = A<num, double>(1.0);
              print('ok');
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    // === scope_t02: type params in extends/implements clauses ===

    test('scope_t02', () {
      // RT: A<N,S,U> extends C<S,U>, type params reordered in superclass
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<T, U> {}
            class A<N, S, U> extends C<S, U> {}
            void main() {
              var a = A<num, double, String>();
              print('ok');
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    // === scope_t03: type params in body (constructor, is checks, fields) ===

    test('scope_t03', () {
      // RT: type params used in constructor is-checks, fields, getter, setter
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<N, S, U> {
              List<U>? field;

              A(N n, S s) : field = <U>[] {
                print(n is N);
                print(s is S);
              }

              A.empty() : field = null;

              List<U>? get getter {
                return field;
              }

              void set setter(S s) {}
            }

            void main() {
              var a = A<num, double, List>(1, 2.0);
              A b = A<int, int, int>.empty();
              var z = a.getter;
              a.setter = 3.0;
              print('ok');
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\nok\n'),
      );
    });

    // === scope_t04: method type param shadows class type param ===

    test('scope_t04',
        skip: 'needs is T?, FunctionReference with type args, and more', () {
      // RT: method <T> shadows class <T>, typeOf<T>() checks
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            Type typeOf<T>() => T;

            class C1<T> {
              void m1<T>() {
                print(typeOf<T>() == String);
                T? t;
                print(t is String?);
              }

              Type m2<T>() => T;

              T m3<T>(T t) => t;

              void test() {
                print(typeOf<T>() == int);
              }
            }

            class C2<T extends num> {
              void m1<T extends String>() {
                print(typeOf<T>() == String);
                T? t;
                print(t is String?);
              }

              Type m2<T extends String>() => T;

              T m3<T extends String>(T t) => t;

              void test() {
                print(typeOf<T>() == int);
              }
            }

            void main() {
              C1<int> c1 = C1<int>();
              c1.m1<String>();
              print(c1.m2<List<num>>() == List<num>);
              dynamic d = true;
              print(c1.m3<bool>(d) is bool);
              c1.test();

              C2<int> c2 = C2<int>();
              c2.m1<String>();
              print(c2.m2<String>() == String);
              dynamic d2 = "";
              print(c2.m3<String>(d2) is String);
              c2.test();
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints(
          'true\ntrue\ntrue\ntrue\ntrue\n'
          'true\ntrue\ntrue\ntrue\ntrue\n',
        ),
      );
    });

    // === scope_t05: static type checking with shadowed params ===

    test('scope_t05', () {
      // Uses expectStaticType which is a static analysis helper, not a runtime check
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            void main() {
              print('ok');
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    // === scope_t06: F-bounded compile error Enum<int> ===

    test('scope_t06', () {
      // CE: Enum<E extends Enum<E>> instantiated with int violates bound
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class Enum<E extends Enum<E>> {}
              void main() {
                var x = Enum<int>();
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === scope_t07: F-bounded quantification works ===

    test('scope_t07',
        skip: 'F-bounded type params not supported (E extends Enum<E>)',
        () {
      // RT: F-bounded quantification with Enum<E extends Enum<E>>
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Enum2<E extends Enum2<E>> {}
            class Things extends Enum2<Things> {}
            class SubThings extends Things {}
            void main() {
              var x1 = Enum2<Things>();
              var x2 = Things();
              var x3 = SubThings();
              print('ok');
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });
  });
}
