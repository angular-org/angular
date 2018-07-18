import 'package:angular_compiler/cli.dart';
import 'package:source_span/source_span.dart' show SourceSpan;

import '../analyzed_class.dart';
import '../chars.dart';
import '../compile_metadata.dart' show CompileDirectiveMetadata;
import '../expression_parser/ast.dart' as compiler_ast;
import '../identifiers.dart' show Identifiers;
import '../output/output_ast.dart' as o;

// TODO: Remove the following lines (for --no-implicit-casts).
// ignore_for_file: argument_type_not_assignable
// ignore_for_file: invalid_assignment
// ignore_for_file: list_element_type_not_assignable
// ignore_for_file: non_bool_operand
// ignore_for_file: return_of_invalid_type

final _implicitReceiverVal = o.variable("#implicit");

abstract class NameResolver {
  o.Expression callPipe(
      String name, o.Expression input, List<o.Expression> args);

  /// Returns a variable that references the [name] local.
  o.Expression getLocal(String name);

  /// Returns variable declarations for all locals used in this scope.
  List<o.Statement> getLocalDeclarations();

  /// Creates a closure that returns a list of [type] when [values] change.
  o.Expression createLiteralList(
    List<o.Expression> values, {
    o.OutputType type,
  });

  /// Creates a closure that returns a map of [type] when [values] change.
  o.Expression createLiteralMap(
    List<List<dynamic /* String | o.Expression */ >> values, {
    o.OutputType type,
  });

  int createUniqueBindIndex();

  /// Creates a name resolver with shared state for use in a new method scope.
  NameResolver scope();
}

/// Converts a bound [AST] expression to an [Expression].
///
/// If non-null, [boundType] is the type of the input to which [expression] is
/// bound. This is used to support empty expressions for boolean inputs, and to
/// type annotate collection literal bindings.
o.Expression convertCdExpressionToIr(
  NameResolver nameResolver,
  o.Expression implicitReceiver,
  compiler_ast.AST expression,
  SourceSpan expressionSourceSpan,
  CompileDirectiveMetadata metadata,
  o.OutputType boundType,
) {
  assert(nameResolver != null);
  final visitor =
      new _AstToIrVisitor(nameResolver, implicitReceiver, metadata, boundType);
  return _visit(expression, visitor, _Mode.Expression, expressionSourceSpan);
}

List<o.Statement> convertCdStatementToIr(
  NameResolver nameResolver,
  o.Expression implicitReceiver,
  compiler_ast.AST stmt,
  SourceSpan stmtSourceSpan,
  CompileDirectiveMetadata metadata,
) {
  assert(nameResolver != null);
  final visitor =
      new _AstToIrVisitor(nameResolver, implicitReceiver, metadata, null);
  final result = _visit(stmt, visitor, _Mode.Statement, stmtSourceSpan);
  final statements = <o.Statement>[];
  _flattenStatements(result, statements);
  return statements;
}

/// Visits [ast] in [mode] using [visitor].
///
/// If [span] is non-null, it will be used to provide context to any
/// [BuildError] thrown by [visitor].
dynamic _visit(
  compiler_ast.AST ast,
  _AstToIrVisitor visitor,
  _Mode mode,
  SourceSpan span,
) {
  try {
    return ast.visit(visitor, mode);
  } on BuildError catch (e) {
    if (span == null) rethrow;
    throwFailure(span.message(e.message));
  }
}

enum _Mode { Statement, Expression }

class _AstToIrVisitor implements compiler_ast.AstVisitor<dynamic, _Mode> {
  final NameResolver _nameResolver;
  final o.Expression _implicitReceiver;
  final CompileDirectiveMetadata _metadata;

  /// The type to which this expression is bound.
  ///
  /// This is used to support empty expressions for booleans bindings, and type
  /// pure proxy fields for collection literals.
  final o.OutputType _boundType;

  /// Whether the current AST is the root of the expression.
  ///
  /// This is used to indicate whether [_boundType] can be used to type pure
  /// proxy fields for collection literals.
  bool _visitingRoot;

  _AstToIrVisitor(
    this._nameResolver,
    this._implicitReceiver,
    this._metadata,
    this._boundType,
  ) : _visitingRoot = true {
    assert(_nameResolver != null);
  }

  dynamic visitBinary(compiler_ast.Binary ast, _Mode mode) {
    _visitingRoot = false;
    o.BinaryOperator op;
    switch (ast.operation) {
      case "+":
        op = o.BinaryOperator.Plus;
        break;
      case "-":
        op = o.BinaryOperator.Minus;
        break;
      case "*":
        op = o.BinaryOperator.Multiply;
        break;
      case "/":
        op = o.BinaryOperator.Divide;
        break;
      case "%":
        op = o.BinaryOperator.Modulo;
        break;
      case "&&":
        op = o.BinaryOperator.And;
        break;
      case "||":
        op = o.BinaryOperator.Or;
        break;
      case "==":
        op = o.BinaryOperator.Equals;
        break;
      case "!=":
        op = o.BinaryOperator.NotEquals;
        break;
      case "===":
        op = o.BinaryOperator.Identical;
        break;
      case "!==":
        op = o.BinaryOperator.NotIdentical;
        break;
      case "<":
        op = o.BinaryOperator.Lower;
        break;
      case ">":
        op = o.BinaryOperator.Bigger;
        break;
      case "<=":
        op = o.BinaryOperator.LowerEquals;
        break;
      case ">=":
        op = o.BinaryOperator.BiggerEquals;
        break;
      default:
        throwFailure('Unsupported operation "${ast.operation}"');
    }
    return _convertToStatementIfNeeded(
        mode,
        new o.BinaryOperatorExpr(
            op,
            ast.left.visit<dynamic, _Mode>(this, _Mode.Expression)
                as o.Expression,
            ast.right.visit<dynamic, _Mode>(this, _Mode.Expression)
                as o.Expression));
  }

  dynamic visitChain(compiler_ast.Chain ast, _Mode mode) {
    _visitingRoot = false;
    _ensureStatementMode(mode, ast);
    return _visitAll(ast.expressions, mode);
  }

  dynamic visitConditional(compiler_ast.Conditional ast, _Mode mode) {
    _visitingRoot = false;
    o.Expression value =
        ast.condition.visit<dynamic, _Mode>(this, _Mode.Expression);
    return _convertToStatementIfNeeded(
        mode,
        value.conditional(
            ast.trueExp.visit<dynamic, _Mode>(this, _Mode.Expression),
            ast.falseExp.visit<dynamic, _Mode>(this, _Mode.Expression)));
  }

  dynamic visitEmptyExpr(compiler_ast.EmptyExpr ast, _Mode mode) {
    final value = _isBoolType(_boundType)
        ? new o.LiteralExpr(true, o.BOOL_TYPE)
        : new o.LiteralExpr('', o.STRING_TYPE);
    return _convertToStatementIfNeeded(mode, value);
  }

  dynamic visitPipe(compiler_ast.BindingPipe ast, _Mode mode) {
    _visitingRoot = false;
    var input = ast.exp.visit<dynamic, _Mode>(this, _Mode.Expression);
    var args = _visitAll(ast.args, _Mode.Expression).cast<o.Expression>();
    var value = _nameResolver.callPipe(ast.name, input, args);
    return _convertToStatementIfNeeded(mode, value);
  }

  dynamic visitFunctionCall(compiler_ast.FunctionCall ast, _Mode mode) {
    _visitingRoot = false;
    o.Expression e = ast.target.visit<dynamic, _Mode>(this, _Mode.Expression);
    return _convertToStatementIfNeeded(
        mode,
        e.callFn(_visitAll(ast.args, _Mode.Expression),
            namedParams: _visitAll(ast.namedArgs, _Mode.Expression)));
  }

  dynamic visitIfNull(compiler_ast.IfNull ast, _Mode mode) {
    _visitingRoot = false;
    o.Expression value =
        ast.condition.visit<dynamic, _Mode>(this, _Mode.Expression);
    return _convertToStatementIfNeeded(
        mode,
        value
            .ifNull(ast.nullExp.visit<dynamic, _Mode>(this, _Mode.Expression)));
  }

  dynamic visitImplicitReceiver(compiler_ast.ImplicitReceiver ast, _Mode mode) {
    _visitingRoot = false;
    _ensureExpressionMode(mode, ast);
    return _implicitReceiverVal;
  }

  /// Trim text in preserve whitespace mode if it contains \n preceding
  /// interpolation.
  String _compressWhitespacePreceding(String value) {
    if (_metadata.template.preserveWhitespace ||
        value.contains('\u00A0') ||
        value.contains(ngSpace) ||
        !value.contains('\n')) return replaceNgSpace(value);
    return replaceNgSpace(value.replaceAll('\n', '').trimLeft());
  }

  /// Trim text in preserve whitespace mode if it contains \n following
  /// interpolation.
  String _compressWhitespaceFollowing(String value) {
    if (_metadata.template.preserveWhitespace ||
        value.contains('\u00A0') ||
        value.contains(ngSpace) ||
        !value.contains('\n')) return replaceNgSpace(value);
    return replaceNgSpace(value.replaceAll('\n', '').trimRight());
  }

  dynamic visitInterpolation(compiler_ast.Interpolation ast, _Mode mode) {
    _visitingRoot = false;
    _ensureExpressionMode(mode, ast);

    /// Handle most common case where prefix and postfix are empty.
    if (ast.expressions.length == 1) {
      String firstArg = _compressWhitespacePreceding(ast.strings[0]);
      String secondArg = _compressWhitespaceFollowing(ast.strings[1]);
      if (firstArg.isEmpty && secondArg.isEmpty) {
        var args = <o.Expression>[
          ast.expressions[0].visit<dynamic, _Mode>(this, _Mode.Expression)
        ];
        return o.importExpr(Identifiers.interpolate[0]).callFn(args);
      } else {
        var args = <o.Expression>[
          o.literal(firstArg),
          ast.expressions[0].visit<dynamic, _Mode>(this, _Mode.Expression),
          o.literal(secondArg),
        ];
        return o.importExpr(Identifiers.interpolate[1]).callFn(args);
      }
    } else {
      var args = <o.Expression>[];
      for (var i = 0; i < ast.strings.length - 1; i++) {
        String literalText = i == 0
            ? _compressWhitespacePreceding(ast.strings[i])
            : replaceNgSpace(ast.strings[i]);
        args.add(o.literal(literalText));
        args.add(
            ast.expressions[i].visit<dynamic, _Mode>(this, _Mode.Expression));
      }
      args.add(o.literal(
          _compressWhitespaceFollowing(ast.strings[ast.strings.length - 1])));
      return o
          .importExpr(Identifiers.interpolate[ast.expressions.length])
          .callFn(args);
    }
  }

  dynamic visitKeyedRead(compiler_ast.KeyedRead ast, _Mode mode) {
    _visitingRoot = false;
    return _convertToStatementIfNeeded(
        mode,
        ast.obj
            .visit(this, _Mode.Expression)
            .key(ast.key.visit<dynamic, _Mode>(this, _Mode.Expression)));
  }

  dynamic visitKeyedWrite(compiler_ast.KeyedWrite ast, _Mode mode) {
    _visitingRoot = false;
    o.Expression obj = ast.obj.visit<dynamic, _Mode>(this, _Mode.Expression);
    o.Expression key = ast.key.visit<dynamic, _Mode>(this, _Mode.Expression);
    o.Expression value =
        ast.value.visit<dynamic, _Mode>(this, _Mode.Expression);
    return _convertToStatementIfNeeded(mode, obj.key(key).set(value));
  }

  dynamic visitLiteralArray(compiler_ast.LiteralArray ast, _Mode mode) {
    final isRootExpression = _visitingRoot;
    _visitingRoot = false;
    return _convertToStatementIfNeeded(
      mode,
      _nameResolver.createLiteralList(
          _visitAll(ast.expressions, mode).cast<o.Expression>(),
          type: isRootExpression ? _boundType : null),
    );
  }

  dynamic visitLiteralMap(compiler_ast.LiteralMap ast, _Mode mode) {
    final isRootExpression = _visitingRoot;
    _visitingRoot = false;
    var parts = <List>[];
    for (var i = 0; i < ast.keys.length; i++) {
      parts.add([
        ast.keys[i],
        ast.values[i].visit<dynamic, _Mode>(this, _Mode.Expression)
      ]);
    }
    return _convertToStatementIfNeeded(
        mode,
        _nameResolver.createLiteralMap(parts,
            type: isRootExpression ? _boundType : null));
  }

  dynamic visitLiteralPrimitive(compiler_ast.LiteralPrimitive ast, _Mode mode) {
    _visitingRoot = false;
    return _convertToStatementIfNeeded(mode, o.literal(ast.value));
  }

  dynamic visitMethodCall(compiler_ast.MethodCall ast, _Mode mode) {
    _visitingRoot = false;
    var args = _visitAll<o.Expression>(ast.args, _Mode.Expression);
    var namedArgs = _visitAll<o.NamedExpr>(ast.namedArgs, _Mode.Expression);
    o.Expression result;
    o.Expression receiver =
        ast.receiver.visit<dynamic, _Mode>(this, _Mode.Expression);
    if (identical(receiver, _implicitReceiverVal)) {
      var varExpr = _nameResolver.getLocal(ast.name);
      if (varExpr != null) {
        result = varExpr.callFn(args, namedParams: namedArgs);
      } else {
        receiver = _getImplicitOrStaticReceiver(ast.name, isStaticMethod);
      }
    }
    result ??= receiver.callMethod(ast.name, args, namedParams: namedArgs);
    return _convertToStatementIfNeeded(mode, result);
  }

  dynamic visitPrefixNot(compiler_ast.PrefixNot ast, _Mode mode) {
    _visitingRoot = false;
    return _convertToStatementIfNeeded(mode,
        o.not(ast.expression.visit<dynamic, _Mode>(this, _Mode.Expression)));
  }

  dynamic visitPropertyRead(compiler_ast.PropertyRead ast, _Mode mode) {
    _visitingRoot = false;
    o.Expression result;
    o.Expression receiver =
        ast.receiver.visit<dynamic, _Mode>(this, _Mode.Expression);
    if (identical(receiver, _implicitReceiverVal)) {
      result = _nameResolver.getLocal(ast.name);
      if (result == null) {
        receiver = _getImplicitOrStaticReceiver(ast.name, isStaticGetter);
      }
    }
    result ??= receiver.prop(ast.name);
    return _convertToStatementIfNeeded(mode, result);
  }

  dynamic visitPropertyWrite(compiler_ast.PropertyWrite ast, _Mode mode) {
    _visitingRoot = false;
    o.Expression receiver =
        ast.receiver.visit<dynamic, _Mode>(this, _Mode.Expression);
    if (identical(receiver, _implicitReceiverVal)) {
      var varExpr = _nameResolver.getLocal(ast.name);
      if (varExpr != null) {
        throwFailure('Cannot assign to a reference or variable "${ast.name}"');
      }
      receiver = _getImplicitOrStaticReceiver(ast.name, isStaticSetter);
    }
    return _convertToStatementIfNeeded(
        mode,
        receiver
            .prop(ast.name)
            .set(ast.value.visit<dynamic, _Mode>(this, _Mode.Expression)));
  }

  dynamic visitSafePropertyRead(compiler_ast.SafePropertyRead ast, _Mode mode) {
    _visitingRoot = false;
    var receiver = ast.receiver.visit<dynamic, _Mode>(this, _Mode.Expression);
    return _convertToStatementIfNeeded(mode,
        receiver.isBlank().conditional(o.NULL_EXPR, receiver.prop(ast.name)));
  }

  dynamic visitSafeMethodCall(compiler_ast.SafeMethodCall ast, _Mode mode) {
    _visitingRoot = false;
    var receiver = ast.receiver.visit<dynamic, _Mode>(this, _Mode.Expression);
    var args = _visitAll(ast.args, _Mode.Expression).cast<o.Expression>();
    return _convertToStatementIfNeeded(
        mode,
        receiver
            .isBlank()
            .conditional(o.NULL_EXPR, receiver.callMethod(ast.name, args)));
  }

  dynamic visitStaticRead(compiler_ast.StaticRead ast, _Mode mode) {
    _visitingRoot = false;
    return _convertToStatementIfNeeded(
        mode, o.importExpr(ast.id.identifier, isConst: true));
  }

  dynamic visitNamedExpr(compiler_ast.NamedExpr ast, __) =>
      new o.NamedExpr(ast.name, ast.expression.visit<dynamic, _Mode>(this));

  List<R> _visitAll<R>(List<compiler_ast.AST> asts, _Mode mode) {
    return asts
        .map((ast) => ast.visit<dynamic, _Mode>(this, mode) as R)
        .toList();
  }

  /// Returns the receiver necessary to access [memberName].
  ///
  /// If [memberName] is a static member of the current view's component,
  /// determined by the predicate [isStaticMember], the static receiver is
  /// returned. Otherwise the implicit receiver is returned.
  o.Expression _getImplicitOrStaticReceiver(
    String memberName,
    bool Function(String, AnalyzedClass) isStaticMember,
  ) {
    return isStaticMember(memberName, _metadata.analyzedClass)
        ? o.importExpr(_metadata.identifier)
        : _implicitReceiver;
  }
}

dynamic /* o.Expression | o.Statement */ _convertToStatementIfNeeded(
    _Mode mode, o.Expression expr) {
  if (identical(mode, _Mode.Statement)) {
    return expr.toStmt();
  } else {
    return expr;
  }
}

void _ensureStatementMode(_Mode mode, compiler_ast.AST ast) {
  if (!identical(mode, _Mode.Statement)) {
    throwFailure('Expected a statement, but saw "$ast"');
  }
}

void _ensureExpressionMode(_Mode mode, compiler_ast.AST ast) {
  if (!identical(mode, _Mode.Expression)) {
    throwFailure('Expected an expression, but saw "$ast"');
  }
}

void _flattenStatements(dynamic arg, List<o.Statement> output) {
  if (arg is List) {
    for (var entry in arg) {
      _flattenStatements(entry, output);
    }
  } else {
    output.add(arg as o.Statement);
  }
}

bool _isBoolType(o.OutputType type) {
  if (type == o.BOOL_TYPE) return true;
  if (type is o.ExternalType) {
    String name = type.value.name;
    return 'bool' == name.trim();
  }
  return false;
}
