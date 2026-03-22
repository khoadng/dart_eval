import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/src/eval/compiler/context.dart';
import 'package:dart_eval/src/eval/compiler/expression/expression.dart';
import 'package:dart_eval/src/eval/compiler/helpers/fpl.dart';
import 'package:dart_eval/src/eval/compiler/scope.dart';
import 'package:dart_eval/src/eval/compiler/statement/block.dart';
import 'package:dart_eval/src/eval/compiler/statement/statement.dart';
import 'package:dart_eval/src/eval/compiler/type.dart';
import 'package:dart_eval/src/eval/compiler/variable.dart';
import 'package:dart_eval/src/eval/runtime/runtime.dart';

class ExtensionInfo {
  ExtensionInfo(
    this.onType,
    this.methods,
    this.getters,
    this.setters,
    this.statics,
    this.returnTypes,
  );

  final TypeRef onType;
  final Map<String, int> methods;
  final Map<String, int> getters;
  final Map<String, int> setters;
  final Map<String, int> statics;
  final Map<String, TypeRef> returnTypes;

  bool appliesTo(CompilerContext ctx, TypeRef type) {
    final a = type.copyWith(boxed: false);
    final b = onType.copyWith(boxed: false);
    if (a.isAssignableTo(ctx, b)) return true;
    // Cross-library: same type name may have different file indices
    if (a.name == b.name) return true;
    return false;
  }
}

void compileExtensionDeclaration(CompilerContext ctx, ExtensionDeclaration d) {
  final extName = d.name?.lexeme ?? '_ext_${d.offset}';
  final onClause = d.onClause;
  if (onClause == null) return;
  final onType = TypeRef.fromAnnotation(
    ctx,
    ctx.library,
    onClause.extendedType,
  );

  final methods = <String, int>{};
  final getters = <String, int>{};
  final setters = <String, int>{};
  final statics = <String, int>{};
  final returnTypes = <String, TypeRef>{};

  // Create ExtensionInfo early so methods compiled later can reference
  // earlier members in the same extension (e.g. quadrupled calls doubled)
  final extInfo = ExtensionInfo(onType, methods, getters, setters, statics, returnTypes);
  ctx.extensionDeclarations[ctx.library] ??= {};
  ctx.extensionDeclarations[ctx.library]![extName] = extInfo;
  ctx.currentExtension = extInfo;

  // Temporarily set currentClass so that unqualified property access
  // (e.g. x instead of this.x) resolves through the on-type's members.
  // Save and restore to avoid polluting later compilation.
  final savedClass = ctx.currentClass;
  NamedCompilationUnitMember? extensionClass;
  if (onClause.extendedType is NamedType) {
    final typeName =
        (onClause.extendedType as NamedType).name.stringValue ??
        (onClause.extendedType as NamedType).name.value();
    final classDecl =
        ctx.topLevelDeclarationsMap[ctx.library]?[typeName as String];
    if (classDecl != null &&
        !classDecl.isBridge &&
        classDecl.declaration is ClassDeclaration) {
      extensionClass = classDecl.declaration as ClassDeclaration;
    }
  }

  for (final member in d.members) {
    if (member is MethodDeclaration) {
      final methodName = member.name.lexeme;

      if (member.isStatic) {
        ctx.resetStack(position: 0);
        final pos = _compileExtensionMethod(member, ctx, extName, onType);
        statics[methodName] = pos;
        if (member.returnType != null) {
          returnTypes[methodName] =
              TypeRef.fromAnnotation(ctx, ctx.library, member.returnType!);
        }
        continue;
      }

      ctx.resetStack(position: 1);
      if (member.operatorKeyword == null) {
        ctx.currentClass = extensionClass;
      }

      final pos = _compileExtensionMethod(member, ctx, extName, onType);
      ctx.currentClass = null;

      if (member.returnType != null) {
        returnTypes[methodName] =
            TypeRef.fromAnnotation(ctx, ctx.library, member.returnType!);
      }

      if (member.isGetter) {
        getters[methodName] = pos;
      } else if (member.isSetter) {
        setters[methodName] = pos;
      } else {
        methods[methodName] = pos;
      }
    }
  }

  ctx.currentClass = savedClass;
  ctx.currentExtension = null;
}

int _compileExtensionMethod(
  MethodDeclaration d,
  CompilerContext ctx,
  String extName,
  TypeRef onType,
) {
  ctx.inExtension = true;
  final b = d.body;
  final methodName = d.name.lexeme;
  final pos = beginMethod(ctx, d, d.offset, '$extName.$methodName()');

  ctx.beginAllocScope(existingAllocLen: (d.parameters?.parameters.length ?? 0));
  ctx.scopeFrameOffset += d.parameters?.parameters.length ?? 0;

  if (!d.isStatic) {
    ctx.setLocal('#this', Variable(0, onType.copyWith(boxed: true)));
  }

  final resolvedParams = d.parameters == null
      ? <PossiblyValuedParameter>[]
      : resolveFPLDefaults(ctx, d.parameters, true, allowUnboxed: false);

  var i = d.isStatic ? 0 : 1;

  for (final param in resolvedParams) {
    final p = param.parameter;
    p as SimpleFormalParameter;
    var type = CoreTypes.dynamic.ref(ctx);
    if (p.type != null) {
      type = TypeRef.fromAnnotation(
        ctx,
        ctx.library,
        p.type!,
      ).copyWith(boxed: true);
    }
    ctx.setLocal(p.name!.lexeme, Variable(i, type));
    i++;
  }

  StatementInfo? stInfo;
  if (b is BlockFunctionBody) {
    stInfo = compileBlock(
      b.block,
      AlwaysReturnType.fromAnnotation(
        ctx,
        ctx.library,
        d.returnType,
        CoreTypes.dynamic.ref(ctx),
      ),
      ctx,
      name: '$methodName()',
    );
  } else if (b is ExpressionFunctionBody) {
    ctx.beginAllocScope();
    final V = compileExpression(b.expression, ctx);
    // Extension methods always box return values (like instance methods)
    // since they may be called in a dynamic dispatch context
    final boxed = V.boxIfNeeded(ctx);
    ctx.pushOp(Return.make(boxed.scopeFrameOffset), Return.LEN);
    stInfo = StatementInfo(-1, willAlwaysReturn: true);
    ctx.endAllocScope();
  } else if (b is EmptyFunctionBody) {
    ctx.endAllocScope();
    return -1;
  }

  if (!(stInfo!.willAlwaysReturn || stInfo.willAlwaysThrow)) {
    ctx.pushOp(Return.make(-1), Return.LEN);
  }

  ctx.endAllocScope();
  ctx.inExtension = false;
  return pos;
}

