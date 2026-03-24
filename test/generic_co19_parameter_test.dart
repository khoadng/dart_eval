import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/src/eval/compiler/errors.dart';
import 'package:test/test.dart';

/// co19 Language/Generics/parameter_* tests.
///
/// parameter_A01: Extends clause enforces upper bound (compile error)
/// parameter_A02: Default upper bound is Object
/// parameter_A03: Circular type parameter bounds (compile error)
/// parameter_A04: Type params in scope of other type param bounds
/// parameter_A05: Type params in scope of extends/implements/body
/// parameter_A06: Type param malformed in static context
/// parameter_A07: Type param cannot be used as constructor (compile error)
/// parameter_A08: Type param cannot be superclass/interface (compile error)
/// parameter_A09: Type param cannot be parameterized (compile error)
void main() {
  group('co19 parameter', () {
    late Compiler compiler;

    setUp(() {
      compiler = Compiler();
    });

    // === A01: Extends clause enforces upper bound ===

    test('parameter_A01_t01',
        skip: 'constructor instantiation bound validation not yet working', () {
      // CE: class type arg violates extends bound (e.g. C2<A>() where T extends B)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              class B extends A {}
              class C2<T extends B> {}
              void main() { C2<A>(); }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A01_t02',
        skip: 'GenericTypeAlias not supported', () {
      // CE: typedef function alias bound violation
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              class B extends A {}
              typedef Alias2<T extends B> = void Function(T);
              void main() { Alias2<A> a; }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A01_t03',
        skip: 'GenericTypeAlias not supported', () {
      // CE: typedef non-function alias bound violation
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              class B extends A {}
              class D<T> {}
              typedef Alias2<T extends B> = D<T>;
              void main() { D d = Alias2<A>(); }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A01_t04',
        skip: 'GenericTypeAlias not supported', () {
      // CE: old-style typedef bound violation
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              class B extends A {}
              typedef Alias2<T extends B>(T t);
              testme(a) {}
              void main() { Alias2<A> a = testme; }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A01_t05', () {
      // CE: function type arg violates extends bound
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              class B extends A {}
              void func2<T extends B>() {}
              void main() { func2<A>(); }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === A02: Default upper bound is Object ===

    test('parameter_A02_t01', () {
      // Unbounded type param accepts any type (class)
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C1<T> {}
            void main() {
              C1();
              C1<int>();
              C1<String>();
              C1<Object>();
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

    test('parameter_A02_t02',
        skip: 'GenericTypeAlias not supported', () {
      // RT: typedef function alias with unbounded T
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            typedef Alias<T> = void Function(T);
            void main() { print('ok'); }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    test('parameter_A02_t03',
        skip: 'GenericTypeAlias not supported', () {
      // RT: typedef non-function alias with unbounded T
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            class D<T> {}
            typedef Alias<T> = D<T>;
            void main() { D d = Alias<A>(); print('ok'); }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    test('parameter_A02_t04',
        skip: 'GenericTypeAlias not supported', () {
      // RT: old-style typedef with unbounded T
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            typedef Alias<T>(T t);
            testme(a) {}
            void main() { Alias<A> a = testme; print('ok'); }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    test('parameter_A02_t05', () {
      // Unbounded type param accepts any type (function)
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            void func<T>() {}
            void main() {
              func();
              func<int>();
              func<String>();
              func<Object>();
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

    test('parameter_A02_t06', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class G<T> {}
            void main() {
              G<int>();
              G<num>();
              G<Object>();
              G<String>();
              G<List>();
              G<G>();
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

    // === A03: Circular type parameter bounds ===

    test('parameter_A03_t01',
        () {
      // CE: class X extends X
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': 'class G1<X extends X> {} void main() {}',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A03_t02',
        skip: 'GenericTypeAlias not supported', () {
      // CE: typedef function alias X extends X
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef Alias1<X extends X> = void Function(X);
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A03_t03',
        skip: 'GenericTypeAlias not supported', () {
      // CE: typedef non-function alias X extends X
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T1> {}
              typedef G1<X extends X> = A<X>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A03_t04',
        skip: 'GenericTypeAlias not supported', () {
      // CE: old-style typedef X extends X
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef void Alias1<X extends X>(X);
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A03_t05',
        () {
      // CE: function X extends X
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': 'void func1<X extends X>(X x) {} void main() {}',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === A04: Type params in scope of other type param bounds ===

    test('parameter_A04_t01', () {
      // RT: class <X extends A, Y extends X> with Expect.equals(exp, X)
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            class B extends A {}
            class C<X extends A, Y extends X> {
              final X x;
              final Y y;
              C(this.x, this.y);
            }
            void main() {
              final c = C<A, B>(A(), B());
              print(c.x is A);
              print(c.y is B);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('parameter_A04_t02',
        skip: 'GenericTypeAlias not supported', () {
      // RT: typedef with inter-dependent bounds, Expect.equals on reified types
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            typedef Test<X1 extends A, X2 extends X1> = X1 Function(X2);
            void main() { print('ok'); }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    test('parameter_A04_t03',
        skip: 'GenericTypeAlias not supported', () {
      // RT: non-function typedef alias with inter-dependent bounds
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            class B extends A {}
            class C<X, Y> {}
            typedef Alias<X extends A, Y extends X> = C<X, Y>;
            void main() { print('ok'); }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    test('parameter_A04_t04',
        skip: 'GenericTypeAlias not supported', () {
      // RT: old-style typedef with inter-dependent bounds, is check
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            class B extends A {}
            typedef void Test<X1 extends A, X2 extends X1>(X1 exp1, X2 exp2);
            void testme1(A x, A y) {}
            void main() { print('ok'); }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('ok\n'),
      );
    });

    test('parameter_A04_t05', () {
      // RT: function <X extends A, Y extends X> with Expect.equals(exp, X)
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            class B extends A {}
            String check<X extends A, Y extends X>(X x, Y y) {
              return '\${x is A}-\${y is B}';
            }
            void main() { print(check<A, B>(A(), B())); }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true-true\n'),
      );
    });

    // === A05: Type params in extends/implements/body ===

    test('parameter_A05_t01', () {
      // RT: type arg propagates through extends clause
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<X> {
              final X value;
              C(this.value);
            }
            class D<X> extends C<X> {
              D(X value) : super(value);
            }
            void main() {
              final d = D<int>(42);
              print(d.value);
              print(d is C);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('42\ntrue\n'),
      );
    });

    test('parameter_A05_t02', () {
      // RT: is check through implements clause
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            class B extends A {}
            class C<X> {}
            class D<X extends A> implements C<X> {}
            void main() {
              print(D<A>() is C<A>);
              print(D<A>() is C<B>);
              print(D<B>() is C<A>);
              print(D<B>() is C<B>);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\nfalse\ntrue\ntrue\n'),
      );
    });

    test('parameter_A05_t03',
        skip: 'runtime type enforcement on field assignment not yet supported',
        () {
      // RT: X? field in body, wrong type assignment should throw
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            class B extends A {}
            class D<X extends A> { X? value; }
            void main() {
              dynamic a = A();
              final d = D<B>();
              try { d.value = a; print('no error'); }
              catch (e) { print('error'); }
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('error\n'),
      );
    });

    // === A06: Type param in instance vs static context ===

    test('parameter_A06_t01',
        skip: 'static member type param validation not implemented', () {
      // CE: type param T used in is-check inside static method
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T> {
                static bool f() { return null is T; }
              }
              void main() { C.f(); }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A06_t02',
        skip: 'static member type param validation not implemented', () {
      // CE: type param T used as static field type annotation
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T> { static T? t; }
              void main() { C.t = Object(); }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A06_t03', () {
      // RT: type param T in instance context (is T check, constructor init)
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<T> {
              bool check(Object v) => v is T;
            }
            void main() {
              final c = C<int>();
              print(c.check(1));
              print(c.check('hello'));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\nfalse\n'),
      );
    });

    // === A07: Type param cannot be constructor ===

    test('parameter_A07_t01',
        () {
      // CE: T() inside generic class method
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T> {
                test() { T(); }
              }
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A07_t02',
        () {
      // CE: new X() inside generic function
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              void func<X>() { X(); }
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === A08: Type param cannot be superclass/interface ===

    test('parameter_A08_t01',
        () {
      // CE: class extends T
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': 'class A<T> extends T {} void main() {}',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A08_t02',
        () {
      // CE: class implements T
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': 'class A<T> implements T {} void main() {}',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === A09: Type param cannot be parameterized ===

    test('parameter_A09_t01',
        () {
      // CE: T<int> inside class method
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T> {}
              class B<T extends A> {
                testme() { T<int> t; }
              }
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A09_t02',
        () {
      // CE: X<int> inside generic function
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T> {}
              void func<X extends A>(dynamic d) { X<int> x = d; }
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A09_t03',
        skip: 'GenericTypeAlias not supported', () {
      // CE: non-function typedef alias T<int> in bound
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T> {}
              class B<T1, T2> {}
              typedef Alias<T1 extends A, T2 extends T1<int>> = B<T1, T2>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A09_t04',
        skip: 'GenericTypeAlias not supported', () {
      // CE: old-style typedef T<int> in bound
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T> {}
              typedef void Alias<T extends A, T1 extends T<int>>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('parameter_A09_t05',
        skip: 'GenericTypeAlias not supported', () {
      // CE: function typedef alias T<int> in bound
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T> {}
              typedef B1<T extends A, T1 extends T<int>> = void Function();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });
  });
}
