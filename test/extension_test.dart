import 'package:dart_eval/dart_eval.dart';
import 'package:test/test.dart';

void main() {
  group('Extension methods', () {
    late Compiler compiler;
    setUp(() => compiler = Compiler());

    test('Method on bridge type', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension StringExt on String {
              String exclaim() => this + '!';
            }
            void main() {
              print('hello'.exclaim());
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('hello!\n'));
    });

    test('Chained extension calls', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension StringExt on String {
              String exclaim() => this + '!';
            }
            void main() {
              print('hi'.exclaim().exclaim());
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('hi!!\n'));
    });

    test('Method with parameters', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension StringExt on String {
              String wrap(String left, String right) => left + this + right;
            }
            void main() {
              print('hello'.wrap('[', ']'));
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('[hello]\n'));
    });

    test('Method returning different type', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension IntExt on int {
              bool get isPositive => this > 0;
            }
            void main() {
              print(5.isPositive);
              print((-3).isPositive);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('true\nfalse\n'));
    });

    test('Getter on bridge type', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension IntExt on int {
              int get doubled => this * 2;
            }
            void main() {
              print(21.doubled);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('42\n'));
    });

    test('Getter on eval class', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Point {
              final int x, y;
              Point(this.x, this.y);
            }
            extension PointExt on Point {
              int get sum => x + y;
            }
            void main() {
              var p = Point(3, 4);
              print(p.sum);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('7\n'));
    });

    test('Multiple extensions on same type', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension IntMath on int {
              int get tripled => this * 3;
            }
            extension IntCheck on int {
              bool get isEven2 => this % 2 == 0;
            }
            void main() {
              print(5.tripled);
              print(4.isEven2);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('15\ntrue\n'));
    });

    test('Extension setter', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Box {
              String value = '';
            }
            extension BoxExt on Box {
              set upper(String v) { value = v.toUpperCase(); }
            }
            void main() {
              var b = Box();
              b.upper = 'hello';
              print(b.value);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('HELLO\n'));
    });

    test('Extension operator', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class Vec {
              final int x, y;
              Vec(this.x, this.y);
            }
            extension VecOps on Vec {
              Vec operator +(Vec other) => Vec(x + other.x, y + other.y);
            }
            void main() {
              var a = Vec(1, 2);
              var b = Vec(3, 4);
              var c = a + b;
              print(c.x);
              print(c.y);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('4\n6\n'));
    });

    test('Implicit this.property on bridge type', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension StringExt on String {
              bool get isShort => length < 5;
            }
            void main() {
              print('hi'.isShort);
              print('hello world'.isShort);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('true\nfalse\n'));
    });

    test('Static method accessed via extension name', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension IntUtils on int {
              static int clamp(int value, int min, int max) {
                if (value < min) return min;
                if (value > max) return max;
                return value;
              }
            }
            void main() {
              print(IntUtils.clamp(150, 0, 100));
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('100\n'));
    });

    test('Extension method calls another member of same extension', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension IntExt on int {
              int get doubled => this * 2;
              int get quadrupled => doubled * 2;
            }
            void main() {
              print(5.quadrupled);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('20\n'));
    });

    test('Implicit this method call on bridge type', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension StringExt on String {
              String explicit() => this.toUpperCase();
              String implicit() => toUpperCase();
            }
            void main() {
              print('hi'.explicit());
              print('hi'.implicit());
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('HI\nHI\n'));
    });

    test('Extension on Object applies to all types', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension ObjExt on Object {
              String describe() => this.toString() + '!';
            }
            void main() {
              print(42.describe());
              print('hi'.describe());
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('42!\nhi!\n'));
    });

    test('Unused extension compiles without error', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension NeverUsed on int {
              int get tripled => this * 3;
            }
            void main() {
              print('hello');
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('hello\n'));
    });
  });
}
