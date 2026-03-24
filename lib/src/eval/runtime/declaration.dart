import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/src/eval/runtime/exception.dart';

/// Type definition (see [Type]) for a class declared in the evaluated code.
/// Serialized to a program, contains mappings from method and field names
/// to implementation locations in the code.
class EvalClass implements $Instance {
  EvalClass(
    this.delegatedType,
    this.superclass,
    this.mixins,
    this.getters,
    this.setters,
    this.methods,
  );

  factory EvalClass.fromJson(List def) {
    return EvalClass(
      def[3] as int,
      null,
      [],
      (def[0] as Map).cast(),
      (def[1] as Map).cast(),
      (def[2] as Map).cast(),
    );
  }

  final int delegatedType;

  final EvalClass? superclass;
  final List<EvalClass?> mixins;

  final Map<String, int> getters;
  final Map<String, int> setters;
  final Map<String, int> methods;

  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType(CoreTypes.type);

  @override
  $Value? $getProperty(Runtime runtime, String identifier) {
    throw EvalUnknownPropertyException(identifier);
  }

  @override
  void $setProperty(Runtime runtime, String identifier, $Value value) {
    throw EvalUnknownPropertyException(identifier);
  }

  @override
  Never get $reified => throw UnimplementedError();

  @override
  Never get $value => throw UnimplementedError();
}
