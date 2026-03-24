import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:test/test.dart';

/// Tests for generic features not covered by co19 suite (generic_co19_test.dart).
void main() {
  group('Generic tests', () {
    late Compiler compiler;

    setUp(() {
      compiler = Compiler();
    });

    test('generic function with explicit type argument', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            T identity<T>(T value) => value;

            int main() {
              return identity<int>(42);
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), $int(42));
    });

    test('generic function with bounded type parameter',
        skip: 'bounded generic boxing not yet implemented', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            T max2<T extends num>(T a, T b) => a > b ? a : b;

            num main() {
              return max2<int>(3, 7);
            }
          ''',
        },
      });

      expect(
        runtime.executeLib('package:example/main.dart', 'main'),
        $int(7),
      );
    });

    test('generic method on a class', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Converter {
              Converter();

              T convert<T extends num>(num value) => value as T;
            }

            int main() {
              final c = Converter();
              return c.convert<int>(42);
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 42);
    });

    test('is check on Set with type args', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            bool isSetOfInt(Object obj) => obj is Set<int>;

            void main() {
              print(isSetOfInt(<int>{1, 2}));
              print(isSetOfInt(<String>{'a'}));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\nfalse\n'),
      );
    });

    test('List.of preserves type arg through assignment',
        skip:
            'variable type widening loses original TAV (List<int> assigned to List<num>)',
        () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            void main() {
              List<num> nums = <int>[1, 2, 3];
              print(nums is List<int>);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\n'),
      );
    });

    test('generic class implements interface with concrete type', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            abstract class Getter<T> {
              T get();
            }

            class IntGetter implements Getter<int> {
              final int _value;
              IntGetter(this._value);

              int get() => _value;
            }

            int main() {
              final g = IntGetter(42);
              return g.get();
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 42);
    });

    test('generic class with mixin',
        skip: 'MixinDeclaration not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            mixin Describable<T> {
              T get value;
              String describe() => 'Value: \$value';
            }

            class Box<T> with Describable<T> {
              final T value;
              Box(this.value);
            }

            String main() {
              final box = Box<int>(42);
              return box.describe();
            }
          ''',
        },
      });

      expect(
        runtime.executeLib('package:example/main.dart', 'main'),
        $String('Value: 42'),
      );
    });

    test('generic typedef',
        skip: 'GenericTypeAlias not supported', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            typedef Mapper<T> = T Function(T);

            T applyTwice<T>(T value, Mapper<T> fn) => fn(fn(value));

            int main() {
              return applyTwice<int>(2, (x) => x * 3);
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 18);
    });

    test('generic class with getter and setter', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Cell<T> {
              T _value;
              Cell(this._value);

              T get value => _value;
              void set value(T v) { _value = v; }
            }

            void main() {
              final c = Cell<int>(1);
              print(c.value);
              c.value = 99;
              print(c.value);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('1\n99\n'),
      );
    });

    test('generic class passed as argument', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              final T value;
              Box(this.value);
            }

            int unwrap(Box<int> box) => box.value;

            int main() {
              return unwrap(Box<int>(77));
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 77);
    });

    test('generic class toString uses field', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Named<T> {
              final String name;
              final T data;
              Named(this.name, this.data);

              String describe() => '\$name: \$data';
            }

            String main() {
              final n = Named<int>('count', 42);
              return n.describe();
            }
          ''',
        },
      });

      expect(
        runtime.executeLib('package:example/main.dart', 'main'),
        $String('count: 42'),
      );
    });

    test('instance carries reified type args', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              final T value;
              Box(this.value);
            }

            class Pair<A, B> {
              final A first;
              final B second;
              Pair(this.first, this.second);
            }

            void main() {
              final b1 = Box<int>(42);
              final b2 = Box<String>('hello');
              final p = Pair<int, String>(1, 'two');

              print(b1.value);
              print(b2.value);
              print(p.first);
              print(p.second);

              final outer = Box<Box<int>>(b1);
              print(outer.value.value);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('42\nhello\n1\ntwo\n42\n'),
      );
    });

    test('generic class method accepts T parameter', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Holder<T> {
              T _value;
              Holder(this._value);

              void update(T newValue) { _value = newValue; }
              T get value => _value;
            }

            void main() {
              final h = Holder<int>(1);
              print(h.value);
              h.update(99);
              print(h.value);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('1\n99\n'),
      );
    });

    test('generic function with multiple type parameters both bounded', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            num add2<A extends num, B extends num>(A a, B b) => a + b;

            void main() {
              print(add2<int, double>(3, 4.5));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('7.5\n'),
      );
    });

    test('function returns generic class', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Wrap<T> {
              final T val;
              Wrap(this.val);
            }

            Wrap<int> makeWrap(int x) => Wrap<int>(x);

            int main() {
              return makeWrap(10).val;
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 10);
    });

    test('generic class method returns typed value (Stack)', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Stack<T> {
              final List<T> _items;
              Stack(this._items);

              T pop() => _items.removeLast();
              int get length => _items.length;
            }

            void main() {
              final s = Stack<int>([10, 20, 30]);
              print(s.pop());
              print(s.length);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('30\n2\n'),
      );
    });

    test('generic classes passed between functions', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              final T value;
              Box(this.value);
            }

            Box<int> doubleBox(Box<int> b) => Box<int>(b.value * 2);

            int main() {
              final b = Box<int>(5);
              final b2 = doubleBox(b);
              return b2.value;
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 10);
    });

    test('generic function with side effect', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            void printTyped<T>(T value) {
              print(value);
            }

            void main() {
              printTyped<int>(42);
              printTyped<String>('hello');
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('42\nhello\n'),
      );
    });

    test('bounded generic function with non-numeric bound', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            T pick<T extends Object>(T a, T b) => a;

            String main() {
              return pick<String>('apple', 'banana');
            }
          ''',
        },
      });

      expect(
        runtime.executeLib('package:example/main.dart', 'main'),
        $String('apple'),
      );
    });

    test('access inherited field typed T through generic subclass', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              T value;
              Box(this.value);
            }

            class SpecialBox<T> extends Box<T> {
              SpecialBox(T value) : super(value);
            }

            int main() {
              final sb = SpecialBox<int>(42);
              return sb.value;
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 42);
    });

    test('method on parent class using T with subclass instance', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              T value;
              Box(this.value);
              T getValue() {
                return value;
              }
            }

            class SpecialBox<T> extends Box<T> {
              SpecialBox(T value) : super(value);
            }

            int main() {
              final sb = SpecialBox<int>(42);
              return sb.getValue();
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 42);
    });

    test('reified T in top-level generic function', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            void check<T>(Type expected) {
              print(T == expected);
            }

            void main() {
              check<int>(int);
              check<String>(String);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('reified T in generic method on non-generic class', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Checker {
              Checker();
              bool check<T>(Type expected) => T == expected;
            }

            void main() {
              final c = Checker();
              print(c.check<int>(int));
              print(c.check<String>(String));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('method type param shadows class type param', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<T> {
              C();

              bool classT(Type expected) => T == expected;

              bool methodT<T>(Type expected) => T == expected;
            }

            void main() {
              final c = C<int>();
              // Class T is int
              print(c.classT(int));
              // Method T is String (shadows class T)
              print(c.methodT<String>(String));
              // Class T still int after call
              print(c.classT(int));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\ntrue\n'),
      );
    });

    test('method type param forwarded to another generic function', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            Type typeOf<T>() => T;

            class C<T> {
              void checkMethod<U>() {
                print(typeOf<U>() == String);
                print(typeOf<T>() == int);
              }
            }

            void main() {
              C<int>().checkMethod<String>();
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\n'),
      );
    });

    test('reified T inside generic class body', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              Type get typeArg => T;
            }

            void main() {
              print(Box<int>().typeArg == int);
              print(Box<String>().typeArg == String);
              print(Box<int>().typeArg == String);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\ntrue\nfalse\n'),
      );
    });

    test('as T cast succeeds and fails at runtime', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class C<T> {
              T cast(Object v) => v as T;
            }

            void main() {
              print(C<int>().cast(42));
              try {
                C<int>().cast('hello');
                print('no error');
              } catch (e) {
                print('error');
              }
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('42\nerror\n'),
      );
    });
  });
}
