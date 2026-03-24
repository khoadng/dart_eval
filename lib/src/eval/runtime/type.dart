import 'package:collection/collection.dart';

class RuntimeType {
  const RuntimeType(this.type, this.typeArgs);
  final int type;
  final List<RuntimeType> typeArgs;

  factory RuntimeType.fromJson(List json) {
    return RuntimeType(json[0], [
      for (final ta in json[1]) RuntimeType.fromJson(ta),
    ]);
  }

  List toJson() {
    return [
      type,
      [for (final ta in typeArgs) ta.toJson()],
    ];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RuntimeType &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          typeArgs == other.typeArgs;

  @override
  int get hashCode => type.hashCode ^ typeArgs.hashCode;

  /// Covariant runtime type check for `is`/`is!` expressions.
  static bool isSubtypeOf(
    RuntimeType objectType,
    RuntimeType targetType,
    List<Set<int>> typeTypes,
  ) {
    // Base type check
    final objBase = objectType.type;
    final targetBase = targetType.type;
    if (objBase < 0) {
      if (objBase != targetBase) return false;
    } else {
      if (!typeTypes[objBase].contains(targetBase)) return false;
    }

    // If target has no type args, base check is sufficient
    if (targetType.typeArgs.isEmpty) return true;

    // No TAV on the object but target expects type args → fail.
    // Types with $TypeArgHolder (eval instances, $List, $Map, $Set)
    // get TAV stamped at construction. Bridge types wrapping generics
    // must add `with $TypeArgHolder` to support generic is-checks.
    if (objectType.typeArgs.isEmpty) return false;

    // Check each type arg covariantly
    final ota = objectType.typeArgs;
    final tta = targetType.typeArgs;
    if (ota.length != tta.length) return false;
    for (var i = 0; i < tta.length; i++) {
      if (!isSubtypeOf(ota[i], tta[i], typeTypes)) return false;
    }
    return true;
  }
}

/// Represents a type and all of the interfaces it conforms to
class RuntimeTypeSet {
  const RuntimeTypeSet(this.rt, this.types, this.typeArgs);

  static const _equality = DeepCollectionEquality();

  factory RuntimeTypeSet.fromJson(List json) {
    return RuntimeTypeSet(json[0], Set.from(json[1]), [
      for (final a in json[2]) RuntimeTypeSet.fromJson(a),
    ]);
  }

  final int rt;
  final Set<int> types;
  final List<RuntimeTypeSet> typeArgs;

  /// Check if this type set is assignable to [type].
  /// Uses pre-computed [types] sets at each level (no Runtime needed).
  bool isAssignableTo(RuntimeType type) {
    if (!types.contains(type.type)) return false;
    if (type.typeArgs.isEmpty) return true;
    final ta = typeArgs;
    final tta = type.typeArgs;
    if (ta.length != tta.length) return false;
    for (var i = 0; i < tta.length; i++) {
      if (!ta[i].isAssignableTo(tta[i])) return false;
    }
    return true;
  }

  List toJson() => [
    rt,
    types.toList(),
    [for (final a in typeArgs) a.toJson()],
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RuntimeTypeSet &&
          runtimeType == other.runtimeType &&
          rt == other.rt &&
          types == other.types &&
          DeepCollectionEquality().equals(typeArgs, other.typeArgs);

  @override
  int get hashCode =>
      rt.hashCode ^ _equality.hash(types) ^ _equality.hash(typeArgs);
}
