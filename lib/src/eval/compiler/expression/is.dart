import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_eval/src/eval/compiler/builtins.dart';
import 'package:dart_eval/src/eval/compiler/context.dart';
import 'package:dart_eval/src/eval/compiler/expression/expression.dart';
import 'package:dart_eval/src/eval/compiler/helpers/type_args.dart';
import 'package:dart_eval/src/eval/compiler/type.dart';
import 'package:dart_eval/src/eval/compiler/variable.dart';
import 'package:dart_eval/src/eval/runtime/runtime.dart';
import 'package:dart_eval/src/eval/shared/types.dart';

Variable compileIsExpression(IsExpression e, CompilerContext ctx) {
  var V = compileExpression(e.expression, ctx);
  final not = e.notOperator != null;

  // Check if the target type is a type parameter (is T / is! T)
  final typeParamSource = resolveTypeParamSource(e.type, ctx);
  if (typeParamSource != null) {
    V = V.boxIfNeeded(ctx);
    ctx.pushOp(
      IsTypeParam.make(
        V.scopeFrameOffset,
        typeParamSource.$1,
        typeParamSource.$2,
        not,
      ),
      IsTypeParam.length,
    );
    return Variable.alloc(ctx, CoreTypes.bool.ref(ctx).copyWith(boxed: false));
  }

  final slot = TypeRef.fromAnnotation(ctx, ctx.library, e.type);

  V.inferType(ctx, slot);

  /// If the type is definitely a subtype of the slot, we can just return true.
  if (slot.specifiedTypeArgs.isEmpty &&
      V.type.isAssignableTo(ctx, slot, forceAllowDynamic: false)) {
    return BuiltinValue(boolval: !not).push(ctx);
  }

  V = V.boxIfNeeded(ctx);

  /// If the target type has type arguments, use the generic-aware opcode.
  if (slot.specifiedTypeArgs.isNotEmpty) {
    final rts = slot.toRuntimeTypeSet(ctx);
    final poolIndex = ctx.runtimeTypes.addOrGet(rts);
    ctx.pushOp(
      IsTypeGeneric.make(V.scopeFrameOffset, poolIndex, not),
      IsTypeGeneric.length,
    );
  } else {
    ctx.pushOp(
      IsType.make(V.scopeFrameOffset, ctx.typeRefIndexMap[slot]!, not),
      IsType.length,
    );
  }
  return Variable.alloc(ctx, CoreTypes.bool.ref(ctx).copyWith(boxed: false));
}
