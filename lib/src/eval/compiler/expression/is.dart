import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_eval/src/eval/compiler/builtins.dart';
import 'package:dart_eval/src/eval/compiler/context.dart';
import 'package:dart_eval/src/eval/compiler/expression/expression.dart';
import 'package:dart_eval/src/eval/compiler/type.dart';
import 'package:dart_eval/src/eval/compiler/variable.dart';
import 'package:dart_eval/src/eval/runtime/runtime.dart';
import 'package:dart_eval/src/eval/shared/types.dart';

Variable compileIsExpression(IsExpression e, CompilerContext ctx) {
  var V = compileExpression(e.expression, ctx);
  final slot = TypeRef.fromAnnotation(ctx, ctx.library, e.type);
  final not = e.notOperator != null;

  V.inferType(ctx, slot);

  /// If the type is definitely a subtype of the slot, we can just return true.
  if (V.type.isAssignableTo(ctx, slot, forceAllowDynamic: false)) {
    return BuiltinValue(boolval: !not).push(ctx);
  }

  V = V.boxIfNeeded(ctx);

  /// Check if the target type has type args — if so, use IsTypeGeneric
  /// which compares reified type args on the instance.
  if (slot.specifiedTypeArgs.isNotEmpty) {
    // Push expected type arg indices onto the frame
    final typeArgStart = ctx.scopeFrameOffset;
    for (final typeArg in slot.specifiedTypeArgs) {
      final typeIdx = ctx.typeRefIndexMap[typeArg] ?? -1;
      BuiltinValue(intval: typeIdx).push(ctx);
    }
    ctx.pushOp(
      IsTypeGeneric.make(
        V.scopeFrameOffset,
        ctx.typeRefIndexMap[slot]!,
        not,
        typeArgStart,
        slot.specifiedTypeArgs.length,
      ),
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
