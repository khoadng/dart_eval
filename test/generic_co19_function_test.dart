import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/src/eval/compiler/errors.dart';
import 'package:test/test.dart';

/// co19 Language/Generics/function_* tests.
void main() {
  group('co19 function', () {
    late Compiler compiler;

    setUp(() {
      compiler = Compiler();
    });

    test('Language/Generics/function_A01_t01',
        () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              void testme() {}
              void main() { testme<int>(); }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('Language/Generics/function_A02_t01',
        () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              void testme1<T>() {}
              void main() { testme1<int, dynamic>(); }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });

    test('Language/Generics/function_A03_t01', () {
      expect(
        () => compiler.compileWriteAndLoad({
          'example': {
            'main.dart': '''
              class A {}
              class D {}
              void testme2<T extends A>() {}
              void main() { testme2<D>(); }
            ''',
          },
        }),
        throwsA(isA<CompileError>()),
      );
    });
  });
}
