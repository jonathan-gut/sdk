// Copyright (c) 2015, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../analyzer.dart';
import '../linter_lint_codes.dart';
import '../util/ascii_utils.dart';

const _desc = r'Specify type annotations.';

class AlwaysSpecifyTypes extends LintRule {
  AlwaysSpecifyTypes()
      : super(
          name: 'always_specify_types',
          description: _desc,
        );

  @override
  List<String> get incompatibleRules => const [
        'avoid_types_on_closure_parameters',
        'omit_local_variable_types',
        'omit_obvious_local_variable_types',
      ];

  @override
  List<LintCode> get lintCodes => [
        LinterLintCode.always_specify_types_add_type,
        LinterLintCode.always_specify_types_replace_keyword,
        LinterLintCode.always_specify_types_specify_type,
        LinterLintCode.always_specify_types_split_to_types
      ];

  @override
  void registerNodeProcessors(
      NodeLintRegistry registry, LinterContext context) {
    var visitor = _Visitor(this);
    registry.addDeclaredIdentifier(this, visitor);
    registry.addListLiteral(this, visitor);
    registry.addSetOrMapLiteral(this, visitor);
    registry.addSimpleFormalParameter(this, visitor);
    registry.addNamedType(this, visitor);
    registry.addDeclaredVariablePattern(this, visitor);
    registry.addVariableDeclarationList(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  final LintRule rule;

  _Visitor(this.rule);

  void checkLiteral(TypedLiteral literal) {
    if (literal.typeArguments == null) {
      rule.reportLintForToken(literal.beginToken,
          errorCode: LinterLintCode.always_specify_types_add_type);
    }
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    var keyword = node.keyword;
    if (node.type == null && keyword != null) {
      var element = node.declaredElement;
      if (element is VariableElement) {
        if (keyword.keyword == Keyword.VAR) {
          rule.reportLintForToken(keyword,
              arguments: [keyword.lexeme, element!.type],
              errorCode: LinterLintCode.always_specify_types_replace_keyword);
        } else {
          rule.reportLintForToken(keyword,
              arguments: [element!.type],
              errorCode: LinterLintCode.always_specify_types_specify_type);
        }
      }
    }
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    if (node.type == null) {
      var type = node.matchedValueType!;
      var keyword = node.keyword;
      var tokenToLint = keyword ?? node.name;
      if (keyword != null && keyword.keyword == Keyword.VAR) {
        rule.reportLintForToken(tokenToLint,
            arguments: [keyword.lexeme, type],
            errorCode: LinterLintCode.always_specify_types_replace_keyword);
      } else {
        rule.reportLintForToken(tokenToLint,
            arguments: [type],
            errorCode: LinterLintCode.always_specify_types_specify_type);
      }
    }
  }

  @override
  void visitListLiteral(ListLiteral literal) {
    checkLiteral(literal);
  }

  @override
  void visitNamedType(NamedType namedType) {
    var type = namedType.type;
    if (type is InterfaceType) {
      var element = namedType.element;
      if (element is TypeParameterizedElement &&
          element.typeParameters.isNotEmpty &&
          namedType.typeArguments == null &&
          namedType.parent is! IsExpression &&
          !element.hasOptionalTypeArgs) {
        rule.reportLint(namedType,
            errorCode: LinterLintCode.always_specify_types_add_type);
      }
    }
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral literal) {
    checkLiteral(literal);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter param) {
    var name = param.name;
    if (name != null && param.type == null && !name.lexeme.isJustUnderscores) {
      var keyword = param.keyword;
      if (keyword != null) {
        var type = param.declaredElement?.type;

        if (keyword.type == Keyword.VAR &&
            type != null &&
            type is! DynamicType) {
          rule.reportLintForToken(keyword,
              arguments: [keyword.lexeme, type],
              errorCode: LinterLintCode.always_specify_types_replace_keyword);
        } else {
          rule.reportLintForToken(keyword,
              errorCode: LinterLintCode.always_specify_types_add_type);
        }
      } else if (param.declaredElement != null) {
        var type = param.declaredElement!.type;

        if (type is DynamicType) {
          rule.reportLint(param,
              errorCode: LinterLintCode.always_specify_types_add_type);
        } else {
          rule.reportLint(param,
              arguments: [type],
              errorCode: LinterLintCode.always_specify_types_specify_type);
        }
      }
    }
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList list) {
    var keyword = list.keyword;
    if (list.type == null && keyword != null) {
      Set<String> types;
      var parent = list.parent;
      if (parent is TopLevelVariableDeclaration) {
        types = _getTypes(parent.variables);
      } else if (parent is ForPartsWithDeclarations) {
        types = _getTypes(parent.variables);
      } else if (parent is FieldDeclaration) {
        types = _getTypes(parent.fields);
      } else if (parent is VariableDeclarationStatement) {
        types = _getTypes(parent.variables);
      } else {
        return;
      }

      var singleType = types.length == 1;

      List<Object> arguments;
      ErrorCode errorCode;
      if (types.isEmpty) {
        arguments = [];
        errorCode = LinterLintCode.always_specify_types_add_type;
      } else if (keyword.type == Keyword.VAR) {
        if (singleType) {
          arguments = [keyword.lexeme, types.first];
          errorCode = LinterLintCode.always_specify_types_replace_keyword;
        } else {
          arguments = [];
          errorCode = LinterLintCode.always_specify_types_split_to_types;
        }
      } else {
        if (singleType) {
          arguments = [types.first];
          errorCode = LinterLintCode.always_specify_types_specify_type;
        } else {
          arguments = [];
          errorCode = LinterLintCode.always_specify_types_add_type;
        }
      }
      rule.reportLintForToken(keyword,
          arguments: arguments, errorCode: errorCode);
    }
  }

  Set<String> _getTypes(VariableDeclarationList list) {
    var types = <String>{};
    for (var variable in list.variables) {
      var initializer = variable.initializer;
      if (initializer != null) {
        DartType? type;
        if (initializer is Identifier) {
          var staticElement = initializer.staticElement;
          if (staticElement is VariableElement) {
            type = staticElement.type;
          }
        }

        type ??= variable.initializer?.staticType;

        if (type != null) {
          types.add(type.getDisplayString());
        }
      }
    }
    return types;
  }
}
