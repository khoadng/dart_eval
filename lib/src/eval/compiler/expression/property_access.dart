import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/src/eval/compiler/builtins.dart';
import 'package:dart_eval/src/eval/compiler/helpers/equality.dart';
import 'package:dart_eval/src/eval/compiler/macros/branch.dart';
import 'package:dart_eval/src/eval/compiler/reference.dart';
import 'package:dart_eval/src/eval/compiler/context.dart';
import 'package:dart_eval/src/eval/compiler/expression/expression.dart';
import 'package:dart_eval/src/eval/compiler/statement/statement.dart';
import 'package:dart_eval/src/eval/compiler/variable.dart';
import 'package:dart_eval/src/eval/compiler/type.dart';

import 'package:dart_eval/src/eval/runtime/runtime.dart';

Variable compilePropertyAccess(
  PropertyAccess pa,
  CompilerContext ctx, {
  Variable? cascadeTarget,
}) {
  final L = cascadeTarget ?? compileExpression(pa.realTarget, ctx);

  if (pa.operator.type == TokenType.QUESTION_PERIOD) {
    var out = BuiltinValue().push(ctx).boxIfNeeded(ctx);
    if (L.concreteTypes.length == 1 &&
        L.concreteTypes[0] == CoreTypes.nullType.ref(ctx)) {
      return out;
    }
    macroBranch(
      ctx,
      null,
      condition: (ctx) {
        return checkNotEqual(ctx, L, out);
      },
      thenBranch: (ctx, rt) {
        final V = L.getProperty(ctx, pa.propertyName.name).boxIfNeeded(ctx);
        out = out.copyWith(type: V.type.copyWith(nullable: true));
        ctx.pushOp(
          CopyValue.make(out.scopeFrameOffset, V.scopeFrameOffset),
          CopyValue.LEN,
        );
        return StatementInfo(-1);
      },
      source: pa,
    );
    return out;
  }

  // Check extension getters
  final extGetter = _resolveExtensionGetter(ctx, L, pa.propertyName.name);
  if (extGetter != null) {
    return extGetter;
  }

  return L.getProperty(ctx, pa.propertyName.name);
}

Variable? _resolveExtensionGetter(
  CompilerContext ctx,
  Variable L,
  String name,
) {
  for (final libEntry in ctx.extensionDeclarations.entries) {
    for (final extEntry in libEntry.value.entries) {
      final ext = extEntry.value;
      if (!ext.appliesTo(ctx, L.type)) continue;

      final offset = ext.getters[name];
      if (offset == null) continue;

      L.boxIfNeeded(ctx).pushArg(ctx);
      ctx.pushOp(Call.make(offset), Call.length);
      ctx.pushOp(PushReturnValue.make(), PushReturnValue.LEN);

      return Variable.alloc(ctx, CoreTypes.dynamic.ref(ctx));
    }
  }
  return null;
}

Reference compilePropertyAccessAsReference(
  PropertyAccess pa,
  CompilerContext ctx, {
  Variable? cascadeTarget,
}) {
  final L = cascadeTarget ?? compileExpression(pa.realTarget, ctx);
  return IdentifierReference(L, pa.propertyName.name);
}
