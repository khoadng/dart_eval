import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_eval/src/eval/compiler/context.dart';
import 'package:dart_eval/src/eval/compiler/errors.dart';
import 'package:dart_eval/src/eval/compiler/type.dart';
import 'package:dart_eval/src/eval/compiler/variable.dart';
import 'package:dart_eval/src/eval/runtime/runtime.dart';
import 'package:dart_eval/src/eval/shared/types.dart';

TypeRef applyAstTypeArgs(
  CompilerContext ctx,
  TypeRef type,
  TypeArgumentList? astTypeArgs,
) {
  if (astTypeArgs == null || astTypeArgs.arguments.isEmpty) return type;

  final actual = astTypeArgs.arguments.length;
  final expected = declaredTypeParamCount(ctx, type);
  if (expected != null && actual != expected) {
    throw CompileError(
      'Expected $expected type argument(s) for ${type.name}, got $actual',
      astTypeArgs,
    );
  }

  final resolved = [
    for (final arg in astTypeArgs.arguments)
      TypeRef.fromAnnotation(ctx, ctx.library, arg),
  ];

  final typeParamDecls = declaredTypeParams(ctx, type);
  if (typeParamDecls != null) {
    validateTypeArgBounds(
      ctx,
      ctx.library,
      typeParamDecls,
      resolved,
      astTypeArgs.arguments.toList(),
    );
  }

  return type.copyWith(specifiedTypeArgs: resolved);
}

/// Emits a [SetInstanceTAV] opcode if the type has specified type arguments.
///
/// Called at the call site after constructor return (not inside the
/// constructor body). This is necessary because dart_eval's single-pass
/// compiler interleaves analysis and codegen — type arg inference needs
/// the compiled argument types, which aren't available until after
/// compileArgumentList runs. The TAV pool index can't be pushed before
/// the args because it may depend on them (via inferConstructorTypeArgs).
///
/// A Dart VM-style approach (TAV as implicit constructor arg) would
/// require separating type inference from codegen — a two-pass change.
///
/// Temporarily binds the class's type parameters to the concrete type args
/// so that type chain resolution (e.g. `extends Box<T>` → `extends Box<int>`)
/// works correctly.
void emitSetInstanceTAV(CompilerContext ctx, Variable instance, TypeRef type) {
  if (type.specifiedTypeArgs.isEmpty) return;

  ctx.withClassTypeScope(type, () {
    final rts = type.toRuntimeTypeSet(ctx);
    final poolIndex = ctx.runtimeTypes.addOrGet(rts);
    ctx.pushOp(
      SetInstanceTAV.make(instance.scopeFrameOffset, poolIndex),
      SetInstanceTAV.length,
    );
  });
}

/// Emits [SetMethodTypeArgs] before a method/function call so the callee
/// can read method-level type args at runtime via [PushMethodTypeArg].
///
/// Resolves type args from either explicit AST type arguments or inferred
/// bindings in [resolveGenerics], ordered by [typeParams].
///
/// When a type arg is itself a type parameter (method or class level),
/// emits a runtime forward entry instead of a compile-time constant.
void emitSetMethodTypeArgs(
  CompilerContext ctx,
  List<TypeParameter>? typeParams,
  TypeArgumentList? astTypeArgs,
  Map<String, TypeRef> resolveGenerics,
) {
  if (typeParams == null || typeParams.isEmpty) return;

  final entries = <MethodTypeArgEntry>[];
  for (var i = 0; i < typeParams.length; i++) {
    final name = typeParams[i].name.lexeme;
    String? argName;

    if (astTypeArgs != null && i < astTypeArgs.arguments.length) {
      final arg = astTypeArgs.arguments[i];
      if (arg is NamedType && arg.typeArguments == null) {
        argName = arg.name.lexeme;
      }
    }

    // Check if the type arg is a method-level type param (forward from MTAV)
    if (argName != null) {
      final mtIdx = ctx.currentMethodTypeParams?.indexOf(argName) ?? -1;
      if (mtIdx >= 0) {
        entries.add(MethodTypeArgEntry.fromMethod(mtIdx));
        continue;
      }

      // Check if it's a class-level type param (forward from TAV)
      final ctIdx = _classTypeParamIndex(ctx, argName);
      if (ctIdx != null) {
        entries.add(MethodTypeArgEntry.fromClass(ctIdx));
        continue;
      }
    }

    // Concrete type — resolve at compile time
    TypeRef? resolved;
    if (astTypeArgs != null && i < astTypeArgs.arguments.length) {
      resolved = TypeRef.fromAnnotation(
        ctx,
        ctx.library,
        astTypeArgs.arguments[i],
      );
    } else {
      resolved = resolveGenerics[name];
    }

    if (resolved != null && resolved != CoreTypes.dynamic.ref(ctx)) {
      entries.add(
        MethodTypeArgEntry.constant(resolved.toRuntimeType(ctx).type),
      );
    } else {
      entries.add(MethodTypeArgEntry.constant(-1));
    }
  }

  ctx.pushOp(
    SetMethodTypeArgs.make(entries),
    SetMethodTypeArgs.len(entries.length),
  );
}

int? _classTypeParamIndex(CompilerContext ctx, String name) {
  final cls = ctx.currentClass;
  final typeParams = switch (cls) {
    ClassDeclaration d => d.typeParameters?.typeParameters,
    EnumDeclaration d => d.typeParameters?.typeParameters,
    _ => null,
  };
  if (typeParams == null) return null;
  for (var i = 0; i < typeParams.length; i++) {
    if (typeParams[i].name.lexeme == name) return i;
  }
  return null;
}

/// Returns (source, index) if [typeAnnotation] is a type parameter name,
/// where source 1=MTAV, 2=TAV. Returns null for concrete types.
(int, int)? resolveTypeParamSource(
  TypeAnnotation typeAnnotation,
  CompilerContext ctx,
) {
  if (typeAnnotation case NamedType(typeArguments: null, name: final n)) {
    final name = n.lexeme;

    final mtIdx = ctx.currentMethodTypeParams?.indexOf(name) ?? -1;
    if (mtIdx >= 0) return (1, mtIdx);

    final ctIdx = _classTypeParamIndex(ctx, name);
    if (ctIdx != null) return (2, ctIdx);
  }
  return null;
}

/// Infer type arguments for a generic constructor from argument types.
///
/// For `Box(42)` where `class Box<T> { T value; Box(this.value); }`,
/// matches the argument type `int` against the field type `T` and infers
/// `T = int`, returning `Box<int>`.
///
/// Supports deep inference: `Wrapper(<int>[1])` where field is `List<T> items`
/// will infer `T = int` by walking the type annotation and matching against
/// the argument type's specifiedTypeArgs.
///
// TODO: unify with compileArgumentList's resolveGenerics inference. Both
// infer type params from argument types — resolveGenerics does direct name
// matching for function params, this does deep matching via _extractTypeParams
// for constructor field formals. The shared primitive is _extractTypeParams;
// compileArgumentList should use it instead of its own name-matching loop,
// then this function becomes unnecessary.
TypeRef inferConstructorTypeArgs(
  CompilerContext ctx,
  Declaration? declaration,
  TypeRef returnType,
  List<TypeRef?> argTypes,
) {
  if (declaration is! ConstructorDeclaration) return returnType;
  final parent = declaration.parent;
  if (parent is! ClassDeclaration) return returnType;
  final classTypeParams = parent.typeParameters?.typeParameters;
  if (classTypeParams == null || classTypeParams.isEmpty) return returnType;

  final typeParamNames = {for (final tp in classTypeParams) tp.name.lexeme};
  final inferred = <String, TypeRef>{};
  final params = declaration.parameters.parameters;

  for (var i = 0; i < params.length && i < argTypes.length; i++) {
    final argType = argTypes[i];
    if (argType == null) continue;

    final param = params[i] is DefaultFormalParameter
        ? (params[i] as DefaultFormalParameter).parameter
        : params[i];

    TypeAnnotation? annotation;
    if (param is FieldFormalParameter) {
      for (final member in parent.members) {
        if (member is! FieldDeclaration) continue;
        for (final variable in member.fields.variables) {
          if (variable.name.lexeme == param.name.lexeme) {
            annotation = member.fields.type;
          }
        }
      }
    } else if (param is SimpleFormalParameter) {
      annotation = param.type;
    }

    if (annotation != null) {
      _extractTypeParams(annotation, argType, typeParamNames, inferred);
    }
  }

  if (inferred.isEmpty) return returnType;

  final inferredArgs = <TypeRef>[
    for (final tp in classTypeParams)
      inferred[tp.name.lexeme] ?? CoreTypes.dynamic.ref(ctx),
  ];
  return returnType.copyWith(specifiedTypeArgs: inferredArgs);
}

/// Recursively walk a type annotation AST and match it against an argument
/// type to extract type parameter bindings.
///
/// For `List<T>` matched against `List<int>`, extracts `T → int`.
/// For `T` matched against `int`, extracts `T → int`.
/// For `Map<K, V>` matched against `Map<String, int>`, extracts both.
void _extractTypeParams(
  TypeAnnotation annotation,
  TypeRef argType,
  Set<String> typeParamNames,
  Map<String, TypeRef> inferred,
) {
  if (annotation is! NamedType) return;

  final name = annotation.name.lexeme;

  if (typeParamNames.contains(name)) {
    inferred[name] = argType;
    return;
  }

  final annotationTypeArgs = annotation.typeArguments?.arguments;
  if (annotationTypeArgs == null || annotationTypeArgs.isEmpty) return;

  final argSpecifiedTypeArgs = argType.specifiedTypeArgs;
  for (
    var i = 0;
    i < annotationTypeArgs.length && i < argSpecifiedTypeArgs.length;
    i++
  ) {
    _extractTypeParams(
      annotationTypeArgs[i],
      argSpecifiedTypeArgs[i],
      typeParamNames,
      inferred,
    );
  }
}
