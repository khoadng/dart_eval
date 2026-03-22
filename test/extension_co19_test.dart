/// Tests adapted from dart-lang/co19 Extension-methods conformance suite
import 'package:dart_eval/dart_eval.dart';
import 'package:test/test.dart';

void main() {
  group('co19 extension conformance', () {
    late Compiler compiler;
    setUp(() => compiler = Compiler());

    // co19: semantics_of_invocations_t01
    test('this is bound to receiver', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {
              final int id;
              A(this.id);
            }
            extension ExtA on A {
              int checkId() => this.id;
            }
            void main() {
              var a = A(42);
              print(a.checkId());
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('42\n'));
    });

    // co19: semantics_of_extension_members_t02
    test('this accesses inherited fields', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            class A {
              final String a;
              A(this.a);
            }
            class C extends A {
              final String c;
              C(this.c, String a) : super(a);
            }
            extension ExtC on C {
              String describe() => c + ',' + a;
            }
            void main() {
              var obj = C('child', 'parent');
              print(obj.describe());
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('child,parent\n'));
    });

    // co19: static_member_t01
    test('static method via extension name', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension MySmart on Object {
              static int getId() => 128;
            }
            void main() {
              print(MySmart.getId());
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('128\n'));
    });

    // co19: semantics_of_extension_members_t05 (adapted)
    test('extension getter calls another extension getter', () {
      final runtime = compiler.compileWriteAndLoad({
        'example': {
          'main.dart': '''
            extension IntParity on int {
              bool get isEvenExt => this % 2 == 0;
              bool get isOddExt => !isEvenExt;
            }
            void main() {
              print(4.isEvenExt);
              print(4.isOddExt);
            }
          ''',
        },
      });
      expect(() {
        runtime.executeLib('package:example/main.dart', 'main');
      }, prints('true\nfalse\n'));
    });
  });
}
