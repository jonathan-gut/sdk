// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:meta/meta.dart';

extension Element2OrNullExtension on Element2? {
  Element? get asElement {
    var self = this;
    switch (self) {
      case DynamicElementImpl():
        return self;
      case GetterElement():
        return self.firstFragment as Element;
      case MultiplyDefinedElement element2:
        return element2;
      case NeverElementImpl():
        return self;
      case PrefixElementImpl():
        return self;
      case TopLevelFunctionElementImpl():
        return self.firstFragment as Element;
      case TypeDefiningElement2():
        return self.firstFragment as Element;
      default:
        return null;
    }
  }
}

extension ElementExtension on Element {
  // TODO(scheglov): Maybe just add to `Element`?
  Element? get augmentation {
    if (this case AugmentableElement augmentable) {
      return augmentable.augmentation;
    }
    return null;
  }

  /// Whether the element is effectively [internal].
  bool get isInternal {
    if (hasInternal) {
      return true;
    }
    if (this case PropertyAccessorElement accessor) {
      var variable = accessor.variable2;
      if (variable != null && variable.hasInternal) {
        return true;
      }
    }
    return false;
  }

  /// Whether the element is effectively [protected].
  bool get isProtected {
    var self = this;
    if (self is PropertyAccessorElement &&
        self.enclosingElement3 is InterfaceElement) {
      if (self.hasProtected) {
        return true;
      }
      var variable = self.variable2;
      if (variable != null && variable.hasProtected) {
        return true;
      }
    }
    if (self is MethodElement &&
        self.enclosingElement3 is InterfaceElement &&
        self.hasProtected) {
      return true;
    }
    return false;
  }

  /// Whether the element is effectively [visibleForTesting].
  bool get isVisibleForTesting {
    if (hasVisibleForTesting) {
      return true;
    }
    if (this case PropertyAccessorElement accessor) {
      var variable = accessor.variable2;
      if (variable != null && variable.hasVisibleForTesting) {
        return true;
      }
    }
    return false;
  }

  List<Element> get withAugmentations {
    var result = <Element>[];
    Element? current = this;
    while (current != null) {
      result.add(current);
      current = current.augmentation;
    }
    return result;
  }
}

extension ElementImplExtension on ElementImpl {
  AnnotationImpl annotationAst(int index) {
    return metadata[index].annotationAst;
  }
}

extension ElementOrNullExtension on Element? {
  Element2? get asElement2 {
    var self = this;
    if (self is DynamicElementImpl) {
      return self;
    } else if (self is FunctionElementImpl &&
        self.enclosingElement3 is! CompilationUnitElement) {
      // TODO(scheglov): update `FunctionElementImpl.element` return type?
      return LocalFunctionElementImpl(self);
    } else if (self is LocalVariableElementImpl) {
      return self;
    } else if (self is MultiplyDefinedElementImpl) {
      return self;
    } else if (self is NeverElementImpl) {
      return self;
    } else if (self is PrefixElementImpl) {
      return self;
    } else {
      return (self as Fragment?)?.element;
    }
  }
}

extension ListOfTypeParameterElementExtension on List<TypeParameterElement> {
  List<TypeParameterType> instantiateNone() {
    return map((e) {
      return e.instantiate(
        nullabilitySuffix: NullabilitySuffix.none,
      );
    }).toList();
  }
}

extension ParameterElementExtension on ParameterElement {
  ParameterElementImpl get declarationImpl {
    return declaration as ParameterElementImpl;
  }
}
