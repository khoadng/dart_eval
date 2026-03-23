import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:test/test.dart';

void main() {
  group('Generic tests', () {
    late Compiler compiler;

    setUp(() {
      compiler = Compiler();
    });

    // === Generic Classes ===

    test('generic class stores and retrieves typed value', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              final T value;
              Box(this.value);
            }

            int main() {
              final box = Box<int>(42);
              return box.value;
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 42);
    });

    test('generic class with multiple type parameters', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Pair<A, B> {
              final A first;
              final B second;
              Pair(this.first, this.second);
            }

            String main() {
              final pair = Pair<int, String>(1, 'hello');
              return pair.second;
            }
          ''',
        },
      });

      expect(
        runtime.executeLib('package:example/main.dart', 'main'),
        $String('hello'),
      );
    });

    test('generic class with bounded type parameter', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class NumBox<T extends num> {
              final T value;
              NumBox(this.value);

              num doubled() => value * 2;
            }

            num main() {
              final box = NumBox<int>(5);
              return box.doubled();
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), $int(10));
    });

    test('generic class with method using class type parameter', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Container<T> {
              final List<T> items;
              Container(this.items);

              T first() => items[0];
            }

            int main() {
              final c = Container<int>([10, 20, 30]);
              return c.first();
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 10);
    });

    test('nested generic types', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              final T value;
              Box(this.value);
            }

            int main() {
              final inner = Box<int>(7);
              final outer = Box<Box<int>>(inner);
              return outer.value.value;
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 7);
    });

    // === Generic Functions ===

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

    test('generic function with inferred type argument', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            T identity<T>(T value) => value;

            int main() {
              return identity(42);
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), $int(42));
    });

    test('generic function with bounded type parameter', () {
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

    test('generic function returning generic type', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            List<T> wrap<T>(T value) => [value];

            int main() {
              final list = wrap<int>(5);
              return list[0];
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 5);
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

    // === Type Checking with Generics ===

    test('is check on generic type preserves type argument', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box<T> {
              final T value;
              Box(this.value);
            }

            bool check(Object obj) => obj is Box<int>;

            void main() {
              final intBox = Box<int>(42);
              final strBox = Box<String>('hi');
              print(check(intBox));
              print(check(strBox));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\nfalse\n'),
      );
    });

    test('is check on List with type args',
        () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            bool isListOfInt(Object obj) => obj is List<int>;

            void main() {
              print(isListOfInt(<int>[1, 2]));
              print(isListOfInt(<String>['a']));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\nfalse\n'),
      );
    });

    test('is check on Map with type args',
        () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            bool isMapStringInt(Object obj) => obj is Map<String, int>;

            void main() {
              print(isMapStringInt(<String, int>{'a': 1}));
              print(isMapStringInt(<int, String>{1: 'a'}));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\nfalse\n'),
      );
    });

    test('is check on Set with type args',
        skip: 'Set typeArgs not populated through boxIfNeeded path', () {
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

    // === Generic Inheritance ===

    test('generic class extends another generic class', skip: 'resolveTypeChain does not thread type substitutions', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Base<T> {
              final T value;
              Base(this.value);
            }

            class Derived<T> extends Base<T> {
              Derived(T value) : super(value);
            }

            int main() {
              final d = Derived<int>(99);
              return d.value;
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 99);
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

    test('generic class with mixin', skip: 'MixinDeclaration not supported', () {
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

    // === Generic Type Aliases ===

    test('generic typedef', skip: 'GenericTypeAlias not supported', () {
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

    // === Variance / Covariance ===

    test('covariant generic assignment', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            void main() {
              List<int> ints = [1, 2, 3];
              List<num> nums = ints;
              print(nums.length);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('3\n'),
      );
    });

    // === Generic Factory Constructors ===

    test('generic class with factory constructor', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Wrapper<T> {
              final T value;
              Wrapper._(this.value);

              factory Wrapper.of(T value) {
                return Wrapper._(value);
              }
            }

            int main() {
              final w = Wrapper<int>.of(55);
              return w.value;
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 55);
    });

    // === Generic class with method that returns T ===

    test('generic class method returns typed value', () {
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

    // === Multiple generic instances with different type args ===

    test('different specializations of same generic class', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Holder<T> {
              final T value;
              Holder(this.value);
            }

            void main() {
              final intHolder = Holder<int>(42);
              final strHolder = Holder<String>('hello');
              print(intHolder.value);
              print(strHolder.value);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('42\nhello\n'),
      );
    });

    // === Generic class with multiple methods using T ===

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

    // === Generic function with multiple type params ===

    test('generic function with two type parameters', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            String combine<A, B>(A a, B b) => '\$a-\$b';

            String main() {
              return combine<int, String>(42, 'hello');
            }
          ''',
        },
      });

      expect(
        runtime.executeLib('package:example/main.dart', 'main'),
        $String('42-hello'),
      );
    });

    // === Generic class used as function parameter ===

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

    // === Generic class with string interpolation using T ===

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

    // === Chained generic method calls ===

    test('chained access on generic class', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Opt<T> {
              final T value;
              Opt(this.value);

              Opt<T> copy() => Opt<T>(value);
            }

            int main() {
              final a = Opt<int>(5);
              final b = a.copy();
              return b.value;
            }
          ''',
        },
      });

      expect(runtime.executeLib('package:example/main.dart', 'main'), 5);
    });
    // === Reified type args verification ===

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

              // Verify field access works with different type args
              print(b1.value);
              print(b2.value);
              print(p.first);
              print(p.second);

              // Verify nested generic with type args
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
    // === Generic class with method that takes T parameter ===

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

    // === Generic function with multiple bounded params ===

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

    // === Generic class used as return type ===

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

    // === Generic class with conditional logic ===

    test('generic class with conditional method', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Maybe<T> {
              final T? _value;
              Maybe(this._value);
              Maybe.empty() : _value = null;

              bool get hasValue => _value != null;
              T get value => _value!;
            }

            void main() {
              final a = Maybe<int>(42);
              final b = Maybe<int>.empty();
              print(a.hasValue);
              print(b.hasValue);
              print(a.value);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\nfalse\n42\n'),
      );
    });

    // === Generic class storing list of T ===

    test('generic class wrapping List<T> with methods', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Queue<T> {
              final List<T> _items;
              Queue() : _items = [];

              void add(T item) { _items.add(item); }
              T removeFirst() => _items.removeAt(0);
              int get length => _items.length;
            }

            void main() {
              final q = Queue<String>();
              q.add('a');
              q.add('b');
              q.add('c');
              print(q.length);
              print(q.removeFirst());
              print(q.length);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('3\na\n2\n'),
      );
    });

    // === Multiple generic classes interacting ===

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

    // === Generic function returning void ===

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

    // === Generic class with multiple constructors ===

    test('generic class with named constructors', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Result<T> {
              final T? _value;
              final String? _error;
              Result.ok(this._value) : _error = null;
              Result.err(this._error) : _value = null;

              bool get isOk => _error == null;
            }

            void main() {
              final ok = Result<int>.ok(42);
              final err = Result<int>.err('fail');
              print(ok.isOk);
              print(err.isOk);
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('true\nfalse\n'),
      );
    });

    // === Bounded generic with arithmetic ===

    test('bounded generic function with arithmetic', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            num clamp2<T extends num>(T value, T low, T high) {
              if (value < low) return low;
              if (value > high) return high;
              return value;
            }

            void main() {
              print(clamp2<int>(5, 1, 10));
              print(clamp2<int>(-3, 1, 10));
              print(clamp2<int>(15, 1, 10));
            }
          ''',
        },
      });

      expect(
        () => runtime.executeLib('package:example/main.dart', 'main'),
        prints('5\n1\n10\n'),
      );
    });

    // === Non-numeric bounded generics ===

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
  });
}
