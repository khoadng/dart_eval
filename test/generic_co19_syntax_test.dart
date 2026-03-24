import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/src/eval/compiler/errors.dart';
import 'package:test/test.dart';

/// co19 Language/Generics/syntax_t01..t34 tests.
///
/// Runtime tests: syntax_t01-t04, t15-t16, t18, t20, t22-t27
/// Compile-error tests: syntax_t05-t14, t17, t19, t21, t28-t31, t34
/// Syntax-error multitest: syntax_t32-t33 (skipped, multitest format)
void main() {
  group('co19 syntax', () {
    late Compiler compiler;

    setUp(() {
      compiler = Compiler();
    });

    // ---- syntax_t01: Generic class with fields and constructor (RT) ----

    test('syntax_t01', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<T> {
              A(this.val);
              T val;
            }

            class B<T1, T2> {
              B(this.x, this.y);
              T1 x;
              T2 y;
            }

            void main() {
              A<int> a = A<int>(5);
              print(a.val);

              A<String> a2 = A<String>("s");
              print(a2.val);

              B<String, int> b = B<String, int>("1", 2);
              print(b.x);
              print(b.y);

              B<int, String> b2 = B<int, String>(2, "1");
              print(b2.x);
              print(b2.y);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('5\ns\n1\n2\n2\n1\n'),
      );
    });

    // ---- syntax_t02: Various correct generic class declarations (RT) ----

    test('syntax_t02', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C1<T> {}
            class C2<A, B, C> {}
            class C3<T extends num> {}

            void main() {
              C1<int>();
              C2<int, int, int>();
              C3<int>();
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

    // ---- syntax_t03: Generic abstract class with implementors (RT) ----

    test('syntax_t03', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            abstract class I {}
            abstract class I1<T> {}
            abstract class I2<A, B, C> {}

            class C1 implements I1 {}
            class C2 implements I2 {}
            class C4 implements I {}

            void main() {
              C1();
              C2();
              C4();
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

    // ---- syntax_t04: Generic typedef declarations (RT) ----

    test('syntax_t04', skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef f1<T>();
            typedef f2<A, B, C>();

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

    // ---- syntax_t05: Empty type parameter list is CE ----

    test('syntax_t05', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<>{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t06: Missing closing bracket in type params (CE) ----

    test('syntax_t06', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t07: Missing opening bracket in type params (CE) ----

    test('syntax_t07', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C T>{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t08: Trailing comma in type params (CE) ----

    test('syntax_t08', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T, >{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t09: Type parameter with type arguments (CE) ----

    test('syntax_t09', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T> {}
              class C<T, A<T>>{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t10: Parameterized type parameter (CE) ----

    test('syntax_t10', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T<T>>{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t11: extends not followed by type (CE) ----

    test('syntax_t11', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T extends >{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t12: Incomplete type parameter declaration (CE) ----

    test('syntax_t12', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T
              class C<T extends Function>{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t13: Misspelled extends keyword (CE) ----

    test('syntax_t13', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T extend Function>{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t14: Misspelled extends without type (CE) ----

    test('syntax_t14', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T extend >{}
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t15: Generic vs relational operator disambiguation (RT) ----

    test('syntax_t15', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<B, C, D, E> {
              void foo(bool p1, int p2, int p3, bool p4) {
                print(p1);
                print(p2);
                print(p3);
                print(p4);
              }

              void test() {
                var a = 1;
                var b = 2;
                var c = 3;
                var d = 4;
                var e = 5;
                var f = 6;
                foo(a < b, c, d, e > f);
              }
            }

            void main() {
              A().test();
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\n3\n4\nfalse\n'),
      );
    });

    // ---- syntax_t16: Metadata on type parameters (RT) ----

    test('syntax_t16',
        skip: 'metadata on type params not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            const constant = 0;

            class Foo {
              const Foo.bar(x);
            }

            class C<@Foo.bar(0) @constant T, @Foo.bar(1) TT extends List<T>> {}

            void main() {
              C();
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

    // ---- syntax_t17: Empty type params in typedef (CE) ----

    test('syntax_t17', skip: 'GenericTypeAlias not supported', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef f1<>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t18: Generic methods on classes (RT) ----

    test('syntax_t18', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Test<X> {
              T func1<T>(T value) {
                return value;
              }

              void fManyParameters<
                T0,T1,T2,T3,T4,T5,T6,T7,T8,T9,T10,
                T11,T12,T13,T14,T15,T16,T17,T18,T19,T20>() {}
            }

            void main() {
              Test test = Test();
              print(test.func1<int>(42));
              print(test.func1<String>("hello"));
              print('ok');
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('42\nhello\nok\n'),
      );
    });

    // ---- syntax_t19: Empty type params in function declaration (CE) ----

    test('syntax_t19', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class Test {
                void function<>() {}
              }
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t20: Type alias = class (RT) ----

    test('syntax_t20', skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<T> {
              A(this.val);
              T val;
            }

            typedef AAlias<T> = A<T>;

            void main() {
              AAlias<int> a2 = A<int>(14);
              print(a2.val);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('14\n'),
      );
    });

    // ---- syntax_t21: Empty type params in type alias (CE) ----

    test('syntax_t21', skip: 'GenericTypeAlias not supported', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class Test<T> {}
              typedef TAlias1<> = Test<int>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t22: Type alias with two type params (RT) ----

    test('syntax_t22', skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class B<T1, T2> {
              B(this.x, this.y);
              T1 x;
              T2 y;
            }

            typedef BAlias<T1, T2> = B<T1, T2>;

            void main() {
              BAlias<int, String> b2 = B<int, String>(0, "testme");
              print(b2.x);
              print(b2.y);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('0\ntestme\n'),
      );
    });

    // ---- syntax_t23: Type alias maps one param to two positions (RT) ----

    test('syntax_t23', skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class B<T1, T2> {
              T1? x;
              T2? y;
              B(T1 x, T2 y) {
                this.x = x;
                this.y = y;
              }
            }

            typedef BAlias<T> = B<T, T>;

            void main() {
              BAlias<int> b2 = B<int, int>(0, 100);
              print(b2.x);
              print(b2.y);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('0\n100\n'),
      );
    });

    // ---- syntax_t24: Type alias with bounded type params (RT) ----

    test('syntax_t24', skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class B<T1, T2> {
              B(this.x, this.y);
              T1 x;
              T2 y;
            }

            typedef BAlias<T1 extends num, T2 extends String> = B<T1, T2>;

            void main() {
              BAlias<int, String> b2 = B<int, String>(0, "testme");
              print(b2.x);
              print(b2.y);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('0\ntestme\n'),
      );
    });

    // ---- syntax_t25: Type alias with inter-dependent bounds (RT) ----

    test('syntax_t25', skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class B<T1, T2> {
              B(this.x, this.y);
              T1 x;
              T2 y;
            }

            typedef BAlias<T1, T2 extends T1> = B<T1, T2>;

            void main() {
              BAlias<num, int> b2 = B<num, int>(0, 149);
              print(b2.x);
              print(b2.y);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('0\n149\n'),
      );
    });

    // ---- syntax_t26: Metadata on type alias with const constructor (RT) ----

    test('syntax_t26', skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<T> { const C(); }

            @C() typedef G = void Function();
            @C<int>() typedef K = void Function();

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

    // ---- syntax_t27: Metadata on type alias with alias-typed annotation (RT) ----

    test('syntax_t27', skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<X> { const A(); }
            class C<T> { const C(); }

            typedef CAlias<X> = C<X>;

            @CAlias() typedef G = void Function();
            @CAlias<int>() typedef K = void Function();

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

    // ---- syntax_t28: class = alias form without mixin (CE) ----

    test('syntax_t28', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X> {}
              class test<X> = A<X>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t29: class = alias form with bound, without mixin (CE) ----

    test('syntax_t29', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X> {}
              class test<X extends num> = A<X>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t30: class = alias with extends in type arg position (CE) ----

    test('syntax_t30', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X> {}
              class test<X extends A> = A<X extends A<X>>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t31: Non-generic type used with type args (CE) ----

    test('syntax_t31',
        () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              void main() {
                A<int>();
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t32: Multitest syntax errors ----

    test('syntax_t32', skip: 'multitest format not supported', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef WAlias1<T> = int Function(T);
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t33: Multitest syntax errors ----

    test('syntax_t33', skip: 'multitest format not supported', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef W2<T> = int;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // ---- syntax_t34: Invalid typedef form with @dart=2.12 restriction (CE) ----

    test('syntax_t34', skip: 'GenericTypeAlias not supported', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class C<T> { const C(); }

              @C<int>() typedef K = void Function();

              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });
  });
}
