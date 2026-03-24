import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/src/eval/compiler/errors.dart';
import 'package:test/test.dart';

/// co19 Language/Generics/typedef_* tests.
///
/// typedef_A01: Generic type alias declaration forms (metadata, T must be type)
/// typedef_A02: Old-style function typedef with generics + metadata
/// typedef_A03: Old-style function typedef with named args
/// typedef_A04: Typedef introduces mapping from type arg lists to types
/// typedef_A05: Old-style typedef mapping from type arg lists to types
/// typedef_A06: Well-boundedness of type in typedef body
/// typedef_A07: Parameterized type count must match (l != s)
/// typedef_A08: U must be well-bounded
/// typedef_A09: Bounds on typedef params must imply bounds in body
/// typedef_A10: Non-generic typedef with type parameter is error
void main() {
  group('co19 typedef', () {
    late Compiler compiler;

    setUp(() {
      compiler = Compiler();
    });

    // === typedef_A01: Generic type alias declaration forms ===

    test('typedef_A01_t01',
        skip: 'GenericTypeAlias not supported', () {
      // RT: non-function generic type alias with metadata, is-checks
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<T> {}
            class D<T1 extends num, T2 extends String> {}
            typedef CAlias<T extends num> = C<T>;
            typedef DAlias<T1 extends num, T2 extends String> = D<T1, T2>;
            void main() {
              CAlias ca1 = CAlias();
              print(ca1 is C<num>);
              CAlias<int> ca2 = CAlias<int>();
              print(ca2 is C<int>);
              DAlias da = DAlias();
              print(da is D<num, String>);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\ntrue\n'),
      );
    });

    test('typedef_A01_t02',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: non-const metadata on typedef (int i = 1; @i typedef ...)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              int i = 1;
              class C<T> {}
              @i typedef CAlias<T> = C<T>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A01_t03',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: class with invalid constructor syntax + non-const metadata
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A() {}
              class C<T> {}
              @A() typedef CAlias<T> = C<T>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A01_t04',
        skip: 'GenericTypeAlias not supported', () {
      // RT: function type alias with metadata, empty main
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef Alias1<T> = Function<T1 extends T>();
            typedef Alias2<T> = void Function<T1 extends T>(T);
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

    test('typedef_A01_t05',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: non-const metadata on function type aliases
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              int i = 1;
              @i typedef CAlias<T> = Function();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A01_t06',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: T must be a type, not a variable (typedef X1<T> = i)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              int i = 5;
              typedef W1<T> = i;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A01_t07',
        skip: 'GenericTypeAlias not supported', () {
      // RT: T can be another type alias
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<X> {}
            typedef X1<T> = A<T>;
            typedef X2<T> = X1<T>;
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

    test('typedef_A01_t08',
        skip: 'GenericTypeAlias not supported', () {
      // RT: T can be dynamic, Null, void, FutureOr
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef S1<T> = dynamic;
            typedef S2<T> = Null;
            typedef S3<T> = void;
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

    test('typedef_A01_t09',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: T must be a type, not a function call or constructor call
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              void my_function<T>() {}
              typedef Alias1<T> = my_function;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A01_t10',
        skip: 'GenericTypeAlias not supported', () {
      // RT: T can be another function type alias
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef Alias1<T> = T Function(T);
            typedef Alias2<T> = Alias1<T>;
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

    test('typedef_A01_t11',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: return type of Function cannot be a static method, top-level
      // function, or variable
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              int i = 5;
              typedef WAlias6<T> = i Function(T, int, [int]);
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A01_t12',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: T cannot be null literal
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef void Alias1<T> = null;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === typedef_A02: Old-style function typedef with generics ===

    test('typedef_A02_t01',
        skip: 'GenericTypeAlias + reified T not supported', () {
      // RT: old-style function typedef with metadata, reified T checks
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef int test1<T extends num>();
            typedef T test2<T>(T x, int y);
            int t1<T extends int>() { return 0; }
            T t2<T>(T x, int y) { return 14 as T; }
            void main() {
              test1 res1 = t1;
              res1();
              test2 res2 = t2;
              var x = res2("123", 14);
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

    test('typedef_A02_t02',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: non-const metadata on old-style function typedef
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              int i = 1;
              @i typedef int test<T extends num>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A02_t03',
        skip: 'GenericTypeAlias not supported', () {
      // RT: old-style function typedef with optional positional args
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef int test1<T extends num>(int x, [int y]);
            int t1<T extends int>(int x, [int y = 0]) {
              return y == 0 ? x : y;
            }
            void main() {
              test1 res = t1;
              print(res(1, 14));
              print(res(1));
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('14\n1\n'),
      );
    });

    // === typedef_A03: Old-style function typedef with named args ===

    test('typedef_A03_t01',
        skip: 'GenericTypeAlias not supported', () {
      // RT: old-style function typedef with named args
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef int test1<T extends num>(int x, {int? y, int? z});
            int t1<T extends int>(int x, {int? y, int? z}) {
              return x + (y == null ? 0 : y) + (z == null ? 0 : z);
            }
            void main() {
              test1 res = t1;
              print(t1(1, y: 14, z: 4));
              print(res(1));
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('19\n1\n'),
      );
    });

    // === typedef_A04: D introduces mapping from type arg lists to types ===

    test('typedef_A04_t01',
        skip: 'GenericTypeAlias + reified T not supported', () {
      // RT: typedef maps args to class type, checks T reified
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<T> {
              String get typeName => T.toString();
            }
            typedef AAlias<T> = A<T>;
            void main() {
              print(AAlias<int>().typeName);
              print(AAlias<String>().typeName);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('int\nString\n'),
      );
    });

    test('typedef_A04_t02',
        skip: 'GenericTypeAlias + reified T not supported', () {
      // RT: typedef with multiple type params, checks T1, T2, T3 reified
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<T1, T2, T3> {
              String get types => '\$T1,\$T2,\$T3';
            }
            typedef AAlias<T1, T2, T3> = A<T1, T2, T3>;
            typedef DAlias<T> = A<T, T, T>;
            void main() {
              print(AAlias<int, String, num>().types);
              print(DAlias<int>().types);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('int,String,num\nint,int,int\n'),
      );
    });

    test('typedef_A04_t03',
        skip: 'GenericTypeAlias + function is checks not supported', () {
      // RT: typedef maps to function type, is-checks on functions
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            class Y extends X {}
            dynamic checkme1() {}
            int? checkme2() {}
            typedef Func1<T> = T Function();
            void main() {
              print(checkme1 is Func1);
              print(checkme2 is Func1);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('typedef_A04_t04',
        skip: 'GenericTypeAlias + function is checks not supported', () {
      // RT: function typedef with param types, is-checks with contravariance
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            class Y extends X {}
            void checkme1(dynamic a) {}
            void checkme4(X a) {}
            typedef Func1<T> = void Function(T);
            typedef Func2<T extends X> = void Function(T);
            void main() {
              print(checkme1 is Func1);
              print(checkme4 is Func2);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('typedef_A04_t05',
        skip: 'GenericTypeAlias + function is checks not supported', () {
      // RT: function typedef with return+param, covariance+contravariance
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            class Y extends X {}
            dynamic checkme1(dynamic a) {}
            X checkme4(X a) { throw "no"; }
            typedef Func1<T> = T Function(T);
            typedef Func2<T extends X> = T Function(T);
            void main() {
              print(checkme1 is Func1);
              print(checkme4 is Func2);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('typedef_A04_t06',
        skip: 'GenericTypeAlias + function is checks not supported', () {
      // RT: generic function typedef, is-checks with generic functions
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            void checkme1<T>() {}
            void checkme2<T extends X>() {}
            typedef Func1<T> = void Function<T1 extends T>();
            typedef Func2<T extends X> = void Function<T1 extends T>();
            void main() {
              print(checkme1 is Func1);
              print(checkme2 is Func2);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('typedef_A04_t07',
        skip: 'GenericTypeAlias + function is checks not supported', () {
      // RT: generic function typedef with return+param, complex is-checks
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            class Y extends X {}
            T checkme1<T>(T t) { throw "no"; }
            X checkme2<T extends X>(X x) { throw "no"; }
            typedef Func1<T> = T1 Function<T1 extends T>(T1 t);
            typedef Func2<T extends X> = T Function<T1 extends T>(T t);
            void main() {
              print(checkme1 is Func1);
              print(checkme2 is Func2);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('typedef_A04_t08',
        skip: 'GenericTypeAlias + function is checks not supported', () {
      // RT: function typedef with optional positional params, is-checks
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            void checkme1([dynamic a]) {}
            void checkme4([X? a]) {}
            typedef Func1<T> = void Function([T t]);
            typedef Func2<T extends X> = void Function([T t]);
            void main() {
              print(checkme1 is Func1);
              print(checkme4 is Func2);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('typedef_A04_t09',
        skip: 'GenericTypeAlias + function is checks not supported', () {
      // RT: function typedef with named params, is-checks
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            void checkme1({dynamic a}) {}
            void checkme4({X? a}) {}
            typedef Func1<T> = void Function({T a});
            typedef Func2<T extends X> = void Function({T a});
            void main() {
              print(checkme1 is Func1);
              print(checkme4 is Func2);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    // === typedef_A05: Old-style typedef mapping ===

    test('typedef_A05_t01',
        skip: 'GenericTypeAlias + reified T not supported', () {
      // RT: old-style typedef, assigns generic functions, checks T reified
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            class Y extends X {}
            void checkme1<T>(expected) { print(T == expected); }
            typedef Test1<T>(dynamic);
            void main() {
              Test1 t1 = checkme1;
              t1(dynamic);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\n'),
      );
    });

    test('typedef_A05_t02',
        skip: 'GenericTypeAlias + reified T not supported', () {
      // RT: old-style typedef with return type, assigns generic functions
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            T checkme1<T>(expected, ret) { print(T == expected); return ret; }
            typedef T Test1<T>(dynamic d1, dynamic d2);
            void main() {
              Test1 t1 = checkme1;
              t1(dynamic, 1);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\n'),
      );
    });

    test('typedef_A05_t03',
        skip: 'GenericTypeAlias + reified T not supported', () {
      // RT: old-style typedef with typed parameter, assigns generic functions
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            void checkme1<T>(expected, T t) { print(T == expected); }
            typedef void Test1<T>(dynamic, T t);
            void main() {
              Test1 t1 = checkme1;
              t1(dynamic, dynamic);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\n'),
      );
    });

    test('typedef_A05_t04',
        skip: 'GenericTypeAlias + reified T not supported', () {
      // RT: old-style typedef with optional positional typed param
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            void checkme1<T>(expected, [T? t]) { print(T == expected); }
            typedef void Test1<T>(dynamic, [T? t]);
            void main() {
              Test1 t1 = checkme1;
              t1(Object, dynamic);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\n'),
      );
    });

    test('typedef_A05_t05',
        skip: 'GenericTypeAlias + reified T not supported', () {
      // RT: old-style typedef with named typed param
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class X {}
            void checkme1<T>(expected, {T? t}) { print(T == expected); }
            typedef void Test1<T>(dynamic, {T? t});
            void main() {
              Test1 t1 = checkme1;
              t1(Object, t: null);
            }
          ''',
        },
      });
      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\n'),
      );
    });

    // === typedef_A06: Well-boundedness ===

    test('typedef_A06_t01',
        skip: 'GenericTypeAlias not supported', () {
      // RT: well-bounded function type alias, empty main
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {}
            class B<X> {}
            class C<X extends C<X>> {}
            typedef Alias<X> = Function<Y extends X>(X x);
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

    test('typedef_A06_t02',
        skip: 'GenericTypeAlias not supported', () {
      // RT: F-bounded typedef (X extends A<X>), empty main
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<X extends A<X>> {}
            typedef AAlias<X> = Function<X extends A<X>>();
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

    test('typedef_A06_t03',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: not well-bounded (F-bounded with wrong variable)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends A<X>> {}
              typedef AAlias<X> = Function<X1 extends A<X>>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A06_t04',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: not well-bounded (A<X extends A<X>>, Function<X extends A()>)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends A<X>> {}
              typedef AAlias = Function<X extends A>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A06_t05',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: not well-bounded (X extends A without A being well-bounded)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends A<X>> {}
              typedef AAlias3<X extends A> = Function<Y extends X>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A06_t06',
        skip: 'GenericTypeAlias not supported', () {
      // RT: Function with two type params, one depends on other
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef AAlias = void Function<X, Y extends X>();
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

    test('typedef_A06_t07',
        skip: 'GenericTypeAlias not supported', () {
      // RT: typedef param used in Function type param bound
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef AAlias<X> = void Function<X1 extends X, Y extends X1>();
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

    test('typedef_A06_t08',
        skip: 'GenericTypeAlias not supported', () {
      // RT: typedef with two type params, one depends on other
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef AAlias1<X, Y extends X> = void Function<X1 extends X, Y1 extends Y>();
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

    test('typedef_A06_t09',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: not well-bounded (B<X> where X must extend A<int>)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X> {}
              class B<X extends A<int>> {}
              typedef AAlias2<X extends A<X>> = Function<Y extends B<X>>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A06_t10',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: not well-bounded (B<X1> where X1 not constrained to A<int>)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X> {}
              class B<X extends A<int>> {}
              typedef AAlias2<X> = Function<X1 extends X, Y extends B<X1>>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A06_t11',
        skip: 'GenericTypeAlias not supported', () {
      // RT: well-bounded class type aliases
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<X> {}
            class C<X extends C<X>> {}
            typedef AAlias1<X> = A<X>;
            typedef AAlias2<X extends num> = A<X>;
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

    test('typedef_A06_t12',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: A<X extends A<X>>, typedef AAlias<X> = A (missing type arg)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends A<X>> {}
              typedef AAlias<X> = A;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A06_t13',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: A<X extends A<X>>, typedef with A<A<int>> (int not <: A<int>)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends A<X>> {}
              typedef AAlias<X> = A<A<int>>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A06_t14',
        skip: 'GenericTypeAlias not supported', () {
      // RT: typedef for class with two typed params
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A<X, Y> {}
            typedef AAlias1<X, Y> = A<X, Y>;
            typedef AAlias2<X extends num, Y extends String> = A<X, Y>;
            typedef AAlias3<X, Y extends X> = A<X, Y>;
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

    // === typedef_A07: Type param count must match ===

    test('typedef_A07_t01',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: wrong number of type args for typedef aliasing class
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T> {}
              typedef AAlias<T> = A<T>;
              void main() {
                AAlias<dynamic, dynamic>? a3;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A07_t02',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: wrong number of type args for typedef aliasing function
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef AAlias<T> = T Function<T1 extends T>();
              void main() {
                AAlias<dynamic, dynamic> a3;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A07_t03',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: wrong number of type args for old-style function typedef
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef void AAlias<T>(T);
              void main() {
                AAlias<dynamic, dynamic> a3;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === typedef_A08: U must be well-bounded ===

    test('typedef_A08_t01',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: typedef AAlias<T> = A<T> where A<T extends A<T>>, T unconstrained
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<T extends A<T>> {}
              typedef AAlias<T> = A<T>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A08_t02',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: parameterized type AAlias<A<int>> where int not <: A<int>
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends A<X>> {}
              typedef AAlias<T extends A<T>> = T Function<T>();
              void main() {
                AAlias<A<int>> a6;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A08_t03',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: parameterized type AAlias<int> where int not <: A<int>
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends A<X>> {}
              typedef AAlias<T extends A<T>> = T Function<T1 extends T>();
              void main() {
                AAlias<int> a7;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A08_t04',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: old-style typedef, parameterized type AAlias<int> not well-bounded
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends A<X>> {}
              typedef AAlias<T extends A<T>>(T);
              void main() {
                AAlias<int> a7;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === typedef_A09: Bounds in body must be implied by typedef bounds ===

    test('typedef_A09_t01',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: A<X extends num>, typedef F<Y extends String> = A<Y> Function()
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends num> {}
              typedef F<Y extends String> = A<Y> Function();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A09_t02',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: A<X extends void Function(num)>, typedef with Function(Y)
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends void Function(num)> {}
              typedef F<Y> = A<void Function(Y)> Function();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A09_t03',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: old-style typedef, A<X extends num>, typedef A<Y> Testme<Y extends String>()
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends num> {}
              typedef A<Y> Testme<Y extends String>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A09_t04',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: old-style typedef, A<X extends void Function(num)>
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends void Function(num)> {}
              typedef A<Y> Testme<Y>();
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A09_t05',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: A<X extends num>, typedef AAlias<Y extends String> = A<Y>
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends num> {}
              typedef AAlias<Y extends String> = A<Y>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A09_t06',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: A<X extends void Function(num)>, typedef AAlias<Y> = A<Y>
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A<X extends void Function(num)> {}
              typedef AAlias<Y> = A<Y>;
              void main() {}
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    // === typedef_A10: Non-generic typedef with type parameter is error ===

    test('typedef_A10_t01',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: non-generic class typedef used with type args
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              typedef AAlias = A;
              void main() {
                AAlias<int>? a1;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A10_t02',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: non-generic function typedef used with type args
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef Alias1 = void Function(int);
              void main() {
                Alias1<int> a2;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('typedef_A10_t03',
        skip: 'GenericTypeAlias + compile validation not supported', () {
      // CE: old-style non-generic typedef used with type args
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              typedef void MyTypedef(int);
              void main() {
                MyTypedef<int> a2;
              }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });
  });
}
