// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/parser/formal_parameter_kind.dart';
import 'package:_fe_analyzer_shared/src/scanner/token.dart' show Token;
import 'package:_fe_analyzer_shared/src/util/resolve_relative_uri.dart'
    show resolveRelativeUri;
import 'package:kernel/ast.dart' hide Combinator, MapLiteralEntry;
import 'package:kernel/names.dart' show indexSetName;
import 'package:kernel/reference_from_index.dart'
    show IndexedClass, IndexedContainer, IndexedLibrary;
import 'package:kernel/src/bounds_checks.dart' show VarianceCalculationValue;

import '../api_prototype/experimental_flags.dart';
import '../api_prototype/lowering_predicates.dart';
import '../base/combinator.dart' show CombinatorBuilder;
import '../base/configuration.dart' show Configuration;
import '../base/export.dart' show Export;
import '../base/identifiers.dart' show Identifier, QualifiedNameIdentifier;
import '../base/import.dart' show Import;
import '../base/messages.dart';
import '../base/modifier.dart'
    show
        abstractMask,
        augmentMask,
        constMask,
        externalMask,
        finalMask,
        declaresConstConstructorMask,
        hasInitializerMask,
        initializingFormalMask,
        superInitializingFormalMask,
        lateMask,
        namedMixinApplicationMask,
        staticMask;
import '../base/problems.dart' show internalProblem, unhandled;
import '../base/scope.dart';
import '../base/uris.dart';
import '../builder/builder.dart';
import '../builder/constructor_reference_builder.dart';
import '../builder/declaration_builders.dart';
import '../builder/formal_parameter_builder.dart';
import '../builder/function_type_builder.dart';
import '../builder/library_builder.dart';
import '../builder/metadata_builder.dart';
import '../builder/mixin_application_builder.dart';
import '../builder/named_type_builder.dart';
import '../builder/nullability_builder.dart';
import '../builder/omitted_type_builder.dart';
import '../builder/synthesized_type_builder.dart';
import '../builder/type_builder.dart';
import '../builder/void_type_builder.dart';
import '../fragment/fragment.dart';
import '../util/local_stack.dart';
import 'builder_factory.dart';
import 'name_scheme.dart';
import 'offset_map.dart';
import 'source_class_builder.dart' show SourceClassBuilder;
import 'source_enum_builder.dart';
import 'source_library_builder.dart';
import 'source_loader.dart' show SourceLoader;
import 'type_parameter_scope_builder.dart';

class BuilderFactoryImpl implements BuilderFactory, BuilderFactoryResult {
  final SourceCompilationUnit _compilationUnit;

  final ProblemReporting _problemReporting;

  /// The object used as the root for creating augmentation libraries.
  // TODO(johnniwinther): Remove this once parts support augmentations.
  final SourceLibraryBuilder _augmentationRoot;

  /// [SourceLibraryBuilder] used for passing a parent [Builder] to created
  /// [Builder]s. These uses are only needed because we creating [Builder]s
  /// instead of fragments.
  // TODO(johnniwinther): Remove this when we no longer create [Builder]s in
  // the outline builder.
  final SourceLibraryBuilder _parent;

  final LibraryNameSpaceBuilder _libraryNameSpaceBuilder;

  /// Index of the library we use references for.
  final IndexedLibrary? indexedLibrary;

  String? _name;

  Uri? _partOfUri;

  String? _partOfName;

  List<MetadataBuilder>? _metadata;

  /// The part directives in this compilation unit.
  final List<Part> _parts = [];

  final List<LibraryPart> _libraryParts = [];

  @override
  final List<Import> imports = <Import>[];

  @override
  final List<Export> exports = <Export>[];

  /// Map from synthesized names used for omitted types to their corresponding
  /// synthesized type declarations.
  ///
  /// This is used in macro generated code to create type annotations from
  /// inferred types in the original code.
  final Map<String, Builder>? _omittedTypeDeclarationBuilders;

  /// Map from mixin application classes to their mixin types.
  ///
  /// This is used to check that super access in mixin declarations have a
  /// concrete target.
  Map<SourceClassBuilder, TypeBuilder>? _mixinApplications = {};

  final List<NominalVariableBuilder> _unboundNominalVariables = [];

  final List<StructuralVariableBuilder> _unboundStructuralVariables = [];

  final List<FactoryFragment> _nativeFactoryFragments = [];

  final List<MethodFragment> _nativeMethodFragments = [];

  final List<ConstructorFragment> _nativeConstructorFragments = [];

  final LibraryName libraryName;

  final LookupScope _compilationUnitScope;

  /// Index for building unique lowered names for wildcard variables.
  int wildcardVariableIndex = 0;

  final LocalStack<TypeScope> _typeScopes;

  final LocalStack<NominalParameterNameSpace> _nominalParameterNameSpaces =
      new LocalStack([]);

  final LocalStack<Map<String, StructuralVariableBuilder>>
      _structuralParameterScopes = new LocalStack([]);

  final LocalStack<DeclarationFragment> _declarationFragments =
      new LocalStack([]);

  BuilderFactoryImpl(
      {required SourceCompilationUnit compilationUnit,
      required SourceLibraryBuilder augmentationRoot,
      required SourceLibraryBuilder parent,
      required LibraryNameSpaceBuilder libraryNameSpaceBuilder,
      required ProblemReporting problemReporting,
      required LookupScope scope,
      required LibraryName libraryName,
      required IndexedLibrary? indexedLibrary,
      required Map<String, Builder>? omittedTypeDeclarationBuilders})
      : _compilationUnit = compilationUnit,
        _augmentationRoot = augmentationRoot,
        _libraryNameSpaceBuilder = libraryNameSpaceBuilder,
        _problemReporting = problemReporting,
        _parent = parent,
        _compilationUnitScope = scope,
        libraryName = libraryName,
        indexedLibrary = indexedLibrary,
        _omittedTypeDeclarationBuilders = omittedTypeDeclarationBuilders,
        _typeScopes =
            new LocalStack([new TypeScope(TypeScopeKind.library, scope)]);

  SourceLoader get loader => _compilationUnit.loader;

  LibraryFeatures get libraryFeatures => _compilationUnit.libraryFeatures;

  final List<ConstructorReferenceBuilder> _constructorReferences = [];

  @override
  void beginClassOrNamedMixinApplicationHeader() {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.declarationTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void beginClassDeclaration(String name, int charOffset,
      List<NominalVariableBuilder>? typeVariables) {
    _declarationFragments.push(new ClassFragment(
        name,
        _compilationUnit.fileUri,
        charOffset,
        typeVariables,
        _typeScopes.current.lookupScope,
        _nominalParameterNameSpaces.current));
  }

  @override
  void beginClassBody() {
    _typeScopes.push(new TypeScope(TypeScopeKind.classDeclaration,
        _declarationFragments.current.bodyScope, _typeScopes.current));
  }

  @override
  void endClassDeclaration(String name) {
    TypeScope bodyScope = _typeScopes.pop();
    assert(bodyScope.kind == TypeScopeKind.classDeclaration,
        "Unexpected type scope: $bodyScope.");
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");
  }

  @override
  // Coverage-ignore(suite): Not run.
  void endClassDeclarationForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope bodyScope = _typeScopes.pop();
    assert(bodyScope.kind == TypeScopeKind.classDeclaration,
        "Unexpected type scope: $bodyScope.");
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");

    _declarationFragments.pop();
    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginMixinDeclaration(String name, int charOffset,
      List<NominalVariableBuilder>? typeVariables) {
    _declarationFragments.push(new MixinFragment(
        name,
        _compilationUnit.fileUri,
        charOffset,
        typeVariables,
        _typeScopes.current.lookupScope,
        _nominalParameterNameSpaces.current));
  }

  @override
  void beginMixinBody() {
    _typeScopes.push(new TypeScope(TypeScopeKind.mixinDeclaration,
        _declarationFragments.current.bodyScope, _typeScopes.current));
  }

  @override
  void endMixinDeclaration(String name) {
    TypeScope bodyScope = _typeScopes.pop();
    assert(bodyScope.kind == TypeScopeKind.mixinDeclaration,
        "Unexpected type scope: $bodyScope.");
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");
  }

  @override
  // Coverage-ignore(suite): Not run.
  void endMixinDeclarationForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope bodyScope = _typeScopes.pop();
    assert(bodyScope.kind == TypeScopeKind.mixinDeclaration,
        "Unexpected type scope: $bodyScope.");
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");

    _declarationFragments.pop();
    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginNamedMixinApplication(String name, int charOffset,
      List<NominalVariableBuilder>? typeVariables) {}

  @override
  void endNamedMixinApplication(String name) {
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");
  }

  @override
  void endNamedMixinApplicationForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginEnumDeclarationHeader(String name) {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.declarationTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void beginEnumDeclaration(String name, int charOffset,
      List<NominalVariableBuilder>? typeVariables) {
    _declarationFragments.push(new EnumFragment(
        name,
        _compilationUnit.fileUri,
        charOffset,
        typeVariables,
        _typeScopes.current.lookupScope,
        _nominalParameterNameSpaces.current));
  }

  @override
  void beginEnumBody() {
    _typeScopes.push(new TypeScope(TypeScopeKind.enumDeclaration,
        _declarationFragments.current.bodyScope, _typeScopes.current));
  }

  @override
  void endEnumDeclaration(String name) {
    TypeScope bodyScope = _typeScopes.pop();
    assert(bodyScope.kind == TypeScopeKind.enumDeclaration,
        "Unexpected type scope: $bodyScope.");
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");
  }

  @override
  void endEnumDeclarationForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope bodyScope = _typeScopes.pop();
    assert(bodyScope.kind == TypeScopeKind.enumDeclaration,
        "Unexpected type scope: $bodyScope.");
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");

    _declarationFragments.pop();
    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginExtensionOrExtensionTypeHeader() {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.declarationTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void beginExtensionDeclaration(String? name, int charOffset,
      List<NominalVariableBuilder>? typeVariables) {
    _declarationFragments.push(new ExtensionFragment(
        name,
        _compilationUnit.fileUri,
        charOffset,
        typeVariables,
        _typeScopes.current.lookupScope,
        _nominalParameterNameSpaces.current));
  }

  @override
  void beginExtensionBody(TypeBuilder? extensionThisType) {
    ExtensionFragment declarationFragment =
        _declarationFragments.current as ExtensionFragment;
    _typeScopes.push(new TypeScope(TypeScopeKind.extensionDeclaration,
        declarationFragment.bodyScope, _typeScopes.current));
    if (extensionThisType != null) {
      declarationFragment.registerExtensionThisType(extensionThisType);
    }
  }

  @override
  void endExtensionDeclaration(String? name) {
    TypeScope bodyScope = _typeScopes.pop();
    assert(bodyScope.kind == TypeScopeKind.extensionDeclaration,
        "Unexpected type scope: $bodyScope.");
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");
  }

  @override
  void beginExtensionTypeDeclaration(String name, int charOffset,
      List<NominalVariableBuilder>? typeVariables) {
    _declarationFragments.push(new ExtensionTypeFragment(
        name,
        _compilationUnit.fileUri,
        charOffset,
        typeVariables,
        _typeScopes.current.lookupScope,
        _nominalParameterNameSpaces.current));
  }

  @override
  void beginExtensionTypeBody() {
    _typeScopes.push(new TypeScope(TypeScopeKind.extensionTypeDeclaration,
        _declarationFragments.current.bodyScope, _typeScopes.current));
  }

  @override
  void endExtensionTypeDeclaration(String name) {
    TypeScope bodyScope = _typeScopes.pop();
    assert(bodyScope.kind == TypeScopeKind.extensionTypeDeclaration,
        "Unexpected type scope: $bodyScope.");
    TypeScope typeParameterScope = _typeScopes.pop();
    assert(typeParameterScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeParameterScope.");
  }

  @override
  void beginFactoryMethod() {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.memberTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void endFactoryMethod() {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");
  }

  @override
  // Coverage-ignore(suite): Not run.
  void endFactoryMethodForParserRecovery() {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");

    _nominalParameterNameSpaces.pop().addTypeVariables(_problemReporting, null,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginConstructor() {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.memberTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void endConstructor() {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");
  }

  @override
  void endConstructorForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginStaticMethod() {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.memberTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void endStaticMethod() {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");
  }

  @override
  // Coverage-ignore(suite): Not run.
  void endStaticMethodForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginInstanceMethod() {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.memberTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void endInstanceMethod() {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");
  }

  @override
  void endInstanceMethodForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginTopLevelMethod() {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.memberTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void endTopLevelMethod() {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");
  }

  @override
  void endTopLevelMethodForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.memberTypeParameters,
        "Unexpected type scope: $typeVariableScope.");

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginTypedef() {
    NominalParameterNameSpace nominalParameterNameSpace =
        new NominalParameterNameSpace();
    _nominalParameterNameSpaces.push(nominalParameterNameSpace);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.declarationTypeParameters,
        new NominalParameterScope(
            _typeScopes.current.lookupScope, nominalParameterNameSpace),
        _typeScopes.current));
  }

  @override
  void endTypedef() {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeVariableScope.");
  }

  @override
  // Coverage-ignore(suite): Not run.
  void endTypedefForParserRecovery(
      List<NominalVariableBuilder>? typeVariables) {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.declarationTypeParameters,
        "Unexpected type scope: $typeVariableScope.");

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: null, allowNameConflict: true);
  }

  @override
  void beginFunctionType() {
    Map<String, StructuralVariableBuilder> structuralParameterScope = {};
    _structuralParameterScopes.push(structuralParameterScope);
    _typeScopes.push(new TypeScope(
        TypeScopeKind.functionTypeParameters,
        new TypeParameterScope(
            _typeScopes.current.lookupScope, structuralParameterScope),
        _typeScopes.current));
  }

  @override
  void endFunctionType() {
    TypeScope typeVariableScope = _typeScopes.pop();
    assert(typeVariableScope.kind == TypeScopeKind.functionTypeParameters,
        "Unexpected type scope: $typeVariableScope.");
  }

  @override
  void checkStacks() {
    assert(
        _typeScopes.isSingular,
        "Unexpected type scope stack: "
        "$_typeScopes.");
    assert(
        _declarationFragments.isEmpty,
        "Unexpected declaration fragment stack: "
        "$_declarationFragments.");
    assert(
        _nominalParameterNameSpaces.isEmpty,
        "Unexpected nominal parameter name space stack : "
        "$_nominalParameterNameSpaces.");
    assert(
        _structuralParameterScopes.isEmpty,
        "Unexpected structural parameter scope stack : "
        "$_structuralParameterScopes.");
  }

  // TODO(johnniwinther): Use [_indexedContainer] for library members and make
  // it [null] when there is null corresponding [IndexedContainer].
  IndexedContainer? _indexedContainer;

  @override
  void beginIndexedContainer(String name,
      {required bool isExtensionTypeDeclaration}) {
    if (indexedLibrary != null) {
      if (isExtensionTypeDeclaration) {
        _indexedContainer =
            indexedLibrary!.lookupIndexedExtensionTypeDeclaration(name);
      } else {
        _indexedContainer = indexedLibrary!.lookupIndexedClass(name);
      }
    }
  }

  @override
  void endIndexedContainer() {
    _indexedContainer = null;
  }

  @override
  // Coverage-ignore(suite): Not run.
  void registerUnboundStructuralVariables(
      List<StructuralVariableBuilder> variableBuilders) {
    _unboundStructuralVariables.addAll(variableBuilders);
  }

  Uri _resolve(Uri baseUri, String? uri, int uriOffset, {isPart = false}) {
    if (uri == null) {
      // Coverage-ignore-block(suite): Not run.
      _problemReporting.addProblem(
          messageExpectedUri, uriOffset, noLength, _compilationUnit.fileUri);
      return new Uri(scheme: MALFORMED_URI_SCHEME);
    }
    Uri parsedUri;
    try {
      parsedUri = Uri.parse(uri);
    } on FormatException catch (e) {
      // Point to position in string indicated by the exception,
      // or to the initial quote if no position is given.
      // (Assumes the directive is using a single-line string.)
      _problemReporting.addProblem(
          templateCouldNotParseUri.withArguments(uri, e.message),
          uriOffset +
              1 +
              (e.offset ?? // Coverage-ignore(suite): Not run.
                  -1),
          1,
          _compilationUnit.fileUri);
      return new Uri(
          scheme: MALFORMED_URI_SCHEME, query: Uri.encodeQueryComponent(uri));
    }
    if (isPart && baseUri.isScheme("dart")) {
      // Coverage-ignore-block(suite): Not run.
      // Resolve using special rules for dart: URIs
      return resolveRelativeUri(baseUri, parsedUri);
    } else {
      return baseUri.resolveUri(parsedUri);
    }
  }

  @override
  void addPart(OffsetMap offsetMap, Token partKeyword,
      List<MetadataBuilder>? metadata, String uri, int charOffset) {
    Uri resolvedUri =
        _resolve(_compilationUnit.importUri, uri, charOffset, isPart: true);
    // To support absolute paths from within packages in the part uri, we try to
    // translate the file uri from the resolved import uri before resolving
    // through the file uri of this library. See issue #52964.
    Uri newFileUri = loader.target.uriTranslator.translate(resolvedUri) ??
        _resolve(_compilationUnit.fileUri, uri, charOffset);
    // TODO(johnniwinther): Add a LibraryPartBuilder instead of using
    // [LibraryBuilder] to represent both libraries and parts.
    CompilationUnit compilationUnit = loader.read(resolvedUri, charOffset,
        origin: _compilationUnit.isAugmenting ? _augmentationRoot.origin : null,
        originImportUri: _compilationUnit.originImportUri,
        fileUri: newFileUri,
        accessor: _compilationUnit,
        isPatch: _compilationUnit.isAugmenting,
        referencesFromIndex: indexedLibrary,
        referenceIsPartOwner: indexedLibrary != null);
    _parts.add(new Part(charOffset, compilationUnit));

    // TODO(ahe): [metadata] should be stored, evaluated, and added to [part].
    LibraryPart part = new LibraryPart(<Expression>[], uri)
      ..fileOffset = charOffset;
    _libraryParts.add(part);
    offsetMap.registerPart(partKeyword, part);
  }

  @override
  void addPartOf(List<MetadataBuilder>? metadata, String? name, String? uri,
      int uriOffset) {
    _partOfName = name;
    if (uri != null) {
      Uri resolvedUri =
          _partOfUri = _resolve(_compilationUnit.importUri, uri, uriOffset);
      // To support absolute paths from within packages in the part of uri, we
      // try to translate the file uri from the resolved import uri before
      // resolving through the file uri of this library. See issue #52964.
      Uri newFileUri = loader.target.uriTranslator.translate(resolvedUri) ??
          _resolve(_compilationUnit.fileUri, uri, uriOffset);
      loader.read(partOfUri!, uriOffset,
          fileUri: newFileUri, accessor: _compilationUnit);
    }
    if (_scriptTokenOffset != null) {
      _problemReporting.addProblem(messageScriptTagInPartFile,
          _scriptTokenOffset!, noLength, _compilationUnit.fileUri);
    }
  }

  /// Offset of the first script tag (`#!...`) in this library or part.
  int? _scriptTokenOffset;

  @override
  void addScriptToken(int charOffset) {
    _scriptTokenOffset ??= charOffset;
  }

  @override
  void addImport(
      {OffsetMap? offsetMap,
      Token? importKeyword,
      required List<MetadataBuilder>? metadata,
      required bool isAugmentationImport,
      required String uri,
      required List<Configuration>? configurations,
      required String? prefix,
      required List<CombinatorBuilder>? combinators,
      required bool deferred,
      required int charOffset,
      required int prefixCharOffset,
      required int uriOffset,
      required int importIndex}) {
    if (configurations != null) {
      for (Configuration config in configurations) {
        if (loader.getLibrarySupportValue(config.dottedName) ==
            config.condition) {
          uri = config.importUri;
          break;
        }
      }
    }

    CompilationUnit? compilationUnit = null;
    Uri? resolvedUri;
    String? nativePath;
    const String nativeExtensionScheme = "dart-ext:";
    if (uri.startsWith(nativeExtensionScheme)) {
      _problemReporting.addProblem(messageUnsupportedDartExt, charOffset,
          noLength, _compilationUnit.fileUri);
      String strippedUri = uri.substring(nativeExtensionScheme.length);
      if (strippedUri.startsWith("package")) {
        // Coverage-ignore-block(suite): Not run.
        resolvedUri = _resolve(_compilationUnit.importUri, strippedUri,
            uriOffset + nativeExtensionScheme.length);
        resolvedUri = loader.target.translateUri(resolvedUri);
        nativePath = resolvedUri.toString();
      } else {
        resolvedUri = new Uri(scheme: "dart-ext", pathSegments: [uri]);
        nativePath = uri;
      }
    } else {
      resolvedUri = _resolve(_compilationUnit.importUri, uri, uriOffset);
      compilationUnit = loader.read(resolvedUri, uriOffset,
          origin: isAugmentationImport ? _augmentationRoot : null,
          accessor: _compilationUnit,
          isAugmentation: isAugmentationImport,
          referencesFromIndex: isAugmentationImport ? indexedLibrary : null);
    }

    Import import = new Import(
        _parent,
        compilationUnit,
        isAugmentationImport,
        deferred,
        prefix,
        combinators,
        configurations,
        charOffset,
        prefixCharOffset,
        importIndex,
        nativeImportPath: nativePath);
    imports.add(import);
    offsetMap?.registerImport(importKeyword!, import);
  }

  @override
  void addExport(
      OffsetMap offsetMap,
      Token exportKeyword,
      List<MetadataBuilder>? metadata,
      String uri,
      List<Configuration>? configurations,
      List<CombinatorBuilder>? combinators,
      int charOffset,
      int uriOffset) {
    if (configurations != null) {
      // Coverage-ignore-block(suite): Not run.
      for (Configuration config in configurations) {
        if (loader.getLibrarySupportValue(config.dottedName) ==
            config.condition) {
          uri = config.importUri;
          break;
        }
      }
    }

    CompilationUnit exportedLibrary = loader.read(
        _resolve(_compilationUnit.importUri, uri, uriOffset), charOffset,
        accessor: _compilationUnit);
    exportedLibrary.addExporter(_compilationUnit, combinators, charOffset);
    Export export =
        new Export(_compilationUnit, exportedLibrary, combinators, charOffset);
    exports.add(export);
    offsetMap.registerExport(exportKeyword, export);
  }

  @override
  void addClass(
      OffsetMap offsetMap,
      List<MetadataBuilder>? metadata,
      int modifiers,
      Identifier identifier,
      List<NominalVariableBuilder>? typeVariables,
      TypeBuilder? supertype,
      MixinApplicationBuilder? mixins,
      List<TypeBuilder>? interfaces,
      int startOffset,
      int nameOffset,
      int endOffset,
      int supertypeOffset,
      {required bool isMacro,
      required bool isSealed,
      required bool isBase,
      required bool isInterface,
      required bool isFinal,
      required bool isAugmentation,
      required bool isMixinClass}) {
    String className = identifier.name;

    endClassDeclaration(className);

    ClassFragment declarationFragment =
        _declarationFragments.pop() as ClassFragment;

    NominalParameterNameSpace nominalParameterNameSpace =
        _nominalParameterNameSpaces.pop();
    nominalParameterNameSpace.addTypeVariables(_problemReporting, typeVariables,
        ownerName: className, allowNameConflict: false);

    if (declarationFragment.declaresConstConstructor) {
      modifiers |= declaresConstConstructorMask;
    }

    declarationFragment.compilationUnitScope = _compilationUnitScope;
    declarationFragment.metadata = metadata;
    declarationFragment.modifiers = modifiers;
    declarationFragment.supertype = supertype;
    declarationFragment.mixins = mixins;
    declarationFragment.interfaces = interfaces;
    declarationFragment.constructorReferences =
        new List<ConstructorReferenceBuilder>.of(_constructorReferences);
    declarationFragment.startOffset = startOffset;
    declarationFragment.charOffset = nameOffset;
    declarationFragment.endOffset = endOffset;
    declarationFragment.indexedLibrary = indexedLibrary;
    declarationFragment.indexedClass = _indexedContainer as IndexedClass?;
    declarationFragment.isAugmentation = isAugmentation;
    declarationFragment.isBase = isBase;
    declarationFragment.isFinal = isFinal;
    declarationFragment.isInterface = isInterface;
    declarationFragment.isMacro = isMacro;
    declarationFragment.isMixinClass = isMixinClass;
    declarationFragment.isSealed = isSealed;

    _constructorReferences.clear();

    _addFragment(declarationFragment,
        getterReference: _indexedContainer?.reference);
    offsetMap.registerNamedDeclarationFragment(identifier, declarationFragment);
  }

  @override
  void addEnum(
      OffsetMap offsetMap,
      List<MetadataBuilder>? metadata,
      Identifier identifier,
      List<NominalVariableBuilder>? typeVariables,
      MixinApplicationBuilder? supertypeBuilder,
      List<TypeBuilder>? interfaceBuilders,
      List<EnumConstantInfo?>? enumConstantInfos,
      int startCharOffset,
      int charEndOffset) {
    String name = identifier.name;
    int charOffset = identifier.nameOffset;

    IndexedClass? referencesFromIndexedClass;
    if (indexedLibrary != null) {
      referencesFromIndexedClass = indexedLibrary!.lookupIndexedClass(name);
    }
    // Nested declaration began in `OutlineBuilder.beginEnum`.
    endEnumDeclaration(name);

    EnumFragment declarationFragment =
        _declarationFragments.pop() as EnumFragment;

    NominalParameterNameSpace nominalParameterNameSpace =
        _nominalParameterNameSpaces.pop();
    nominalParameterNameSpace.addTypeVariables(_problemReporting, typeVariables,
        ownerName: name, allowNameConflict: false);

    declarationFragment.compilationUnitScope = _compilationUnitScope;
    declarationFragment.metadata = metadata;
    declarationFragment.supertypeBuilder = supertypeBuilder;
    declarationFragment.interfaces = interfaceBuilders;
    declarationFragment.enumConstantInfos = enumConstantInfos;
    declarationFragment.constructorReferences =
        new List<ConstructorReferenceBuilder>.of(_constructorReferences);
    declarationFragment.startCharOffset = startCharOffset;
    declarationFragment.charOffset = charOffset;
    declarationFragment.charEndOffset = charEndOffset;
    declarationFragment.indexedLibrary = indexedLibrary;
    declarationFragment.indexedClass = referencesFromIndexedClass;

    _constructorReferences.clear();

    _addFragment(declarationFragment,
        getterReference: referencesFromIndexedClass?.reference);

    offsetMap.registerNamedDeclarationFragment(identifier, declarationFragment);
  }

  @override
  void addMixinDeclaration(
      OffsetMap offsetMap,
      List<MetadataBuilder>? metadata,
      Identifier identifier,
      List<NominalVariableBuilder>? typeVariables,
      List<TypeBuilder>? supertypeConstraints,
      List<TypeBuilder>? interfaces,
      int startOffset,
      int nameOffset,
      int endOffset,
      int supertypeOffset,
      {required bool isBase,
      required bool isAugmentation}) {
    TypeBuilder? supertype;
    MixinApplicationBuilder? mixinApplication;
    if (supertypeConstraints != null && supertypeConstraints.isNotEmpty) {
      supertype = supertypeConstraints.first;
      if (supertypeConstraints.length > 1) {
        mixinApplication = new MixinApplicationBuilder(
            supertypeConstraints.skip(1).toList(),
            supertype.fileUri!,
            supertype.charOffset!);
      }
    }

    String className = identifier.name;
    endMixinDeclaration(className);

    MixinFragment declarationFragment =
        _declarationFragments.pop() as MixinFragment;

    NominalParameterNameSpace nominalParameterNameSpace =
        _nominalParameterNameSpaces.pop();
    nominalParameterNameSpace.addTypeVariables(_problemReporting, typeVariables,
        ownerName: className, allowNameConflict: false);

    int modifiers = abstractMask;
    if (declarationFragment.declaresConstConstructor) {
      modifiers |= declaresConstConstructorMask;
    }

    declarationFragment.compilationUnitScope = _compilationUnitScope;
    declarationFragment.metadata = metadata;
    declarationFragment.modifiers = modifiers;
    declarationFragment.supertype = supertype;
    declarationFragment.mixins = mixinApplication;
    declarationFragment.interfaces = interfaces;
    declarationFragment.constructorReferences =
        new List<ConstructorReferenceBuilder>.of(_constructorReferences);
    declarationFragment.startOffset = startOffset;
    declarationFragment.charOffset = nameOffset;
    declarationFragment.endOffset = endOffset;
    declarationFragment.indexedLibrary = indexedLibrary;
    declarationFragment.indexedClass = _indexedContainer as IndexedClass?;
    declarationFragment.isAugmentation = isAugmentation;
    declarationFragment.isBase = isBase;

    _constructorReferences.clear();

    _addFragment(declarationFragment,
        getterReference: _indexedContainer?.reference);

    offsetMap.registerNamedDeclarationFragment(identifier, declarationFragment);
  }

  @override
  MixinApplicationBuilder addMixinApplication(
      List<TypeBuilder> mixins, int charOffset) {
    return new MixinApplicationBuilder(
        mixins, _compilationUnit.fileUri, charOffset);
  }

  @override
  void addNamedMixinApplication(
      List<MetadataBuilder>? metadata,
      String name,
      List<NominalVariableBuilder>? typeVariables,
      int modifiers,
      TypeBuilder? supertype,
      MixinApplicationBuilder mixinApplication,
      List<TypeBuilder>? interfaces,
      int startCharOffset,
      int charOffset,
      int charEndOffset,
      {required bool isMacro,
      required bool isSealed,
      required bool isBase,
      required bool isInterface,
      required bool isFinal,
      required bool isAugmentation,
      required bool isMixinClass}) {
    // Nested declaration began in `OutlineBuilder.beginNamedMixinApplication`.
    endNamedMixinApplication(name);

    assert(
        _mixinApplications != null, "Late registration of mixin application.");

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: name, allowNameConflict: false);

    _addFragment(
        new NamedMixinApplicationFragment(
          name: name,
          fileUri: _compilationUnit.fileUri,
          startCharOffset: startCharOffset,
          charOffset: charOffset,
          charEndOffset: charEndOffset,
          modifiers: modifiers,
          metadata: metadata,
          typeParameters: typeVariables,
          supertype: supertype,
          mixins: mixinApplication,
          interfaces: interfaces,
          isAugmentation: isAugmentation,
          isBase: isBase,
          isFinal: isFinal,
          isInterface: isInterface,
          isMacro: isMacro,
          isMixinClass: isMixinClass,
          isSealed: isSealed,
          compilationUnitScope: _compilationUnitScope,
          indexedLibrary: indexedLibrary,
        ),
        // References are looked up in [BuilderFactoryImpl.applyMixin] when the
        // [SourceClassBuilder] is created.
        getterReference: null);
  }

  static TypeBuilder? applyMixins(
      {required ProblemReporting problemReporting,
      required SourceLibraryBuilder enclosingLibraryBuilder,
      required List<NominalVariableBuilder> unboundNominalVariables,
      required TypeBuilder? supertype,
      required MixinApplicationBuilder? mixinApplicationBuilder,
      required int startCharOffset,
      required int charOffset,
      required int charEndOffset,
      required String subclassName,
      required bool isMixinDeclaration,
      required IndexedLibrary? indexedLibrary,
      required LookupScope compilationUnitScope,
      required Map<SourceClassBuilder, TypeBuilder> mixinApplications,
      required Uri fileUri,
      List<MetadataBuilder>? metadata,
      String? name,
      List<NominalVariableBuilder>? typeVariables,
      int modifiers = 0,
      List<TypeBuilder>? interfaces,
      required bool isMacro,
      required bool isSealed,
      required bool isBase,
      required bool isInterface,
      required bool isFinal,
      required bool isAugmentation,
      required bool isMixinClass,
      required TypeBuilder objectTypeBuilder,
      required void Function(String name, Builder declaration, int charOffset,
              {Reference? getterReference})
          addBuilder}) {
    if (name == null) {
      // The following parameters should only be used when building a named
      // mixin application.
      if (metadata != null) {
        unhandled("metadata", "unnamed mixin application", charOffset, fileUri);
      } else if (interfaces != null) {
        unhandled(
            "interfaces", "unnamed mixin application", charOffset, fileUri);
      }
    }
    if (mixinApplicationBuilder != null) {
      // Documentation below assumes the given mixin application is in one of
      // these forms:
      //
      //     class C extends S with M1, M2, M3;
      //     class Named = S with M1, M2, M3;
      //
      // When we refer to the subclass, we mean `C` or `Named`.

      /// The current supertype.
      ///
      /// Starts out having the value `S` and on each iteration of the loop
      /// below, it will take on the value corresponding to:
      ///
      /// 1. `S with M1`.
      /// 2. `(S with M1) with M2`.
      /// 3. `((S with M1) with M2) with M3`.
      supertype ??= objectTypeBuilder;

      /// The variable part of the mixin application's synthetic name. It
      /// starts out as the name of the superclass, but is only used after it
      /// has been combined with the name of the current mixin. In the examples
      /// from above, it will take these values:
      ///
      /// 1. `S&M1`
      /// 2. `S&M1&M2`
      /// 3. `S&M1&M2&M3`.
      ///
      /// The full name of the mixin application is obtained by prepending the
      /// name of the subclass (`C` or `Named` in the above examples) to the
      /// running name. For the example `C`, that leads to these full names:
      ///
      /// 1. `_C&S&M1`
      /// 2. `_C&S&M1&M2`
      /// 3. `_C&S&M1&M2&M3`.
      ///
      /// For a named mixin application, the last name has been given by the
      /// programmer, so for the example `Named` we see these full names:
      ///
      /// 1. `_Named&S&M1`
      /// 2. `_Named&S&M1&M2`
      /// 3. `Named`.
      String runningName;
      if (supertype.typeName == null) {
        assert(supertype is FunctionTypeBuilder);

        // Function types don't have names, and we can supply any string that
        // doesn't have to be unique. The actual supertype of the mixin will
        // not be built in that case.
        runningName = "";
      } else {
        runningName = supertype.typeName!.name;
      }

      /// True when we're building a named mixin application. Notice that for
      /// the `Named` example above, this is only true on the last
      /// iteration because only the full mixin application is named.
      bool isNamedMixinApplication;

      /// The names of the type variables of the subclass.
      Set<String>? typeVariableNames;
      if (typeVariables != null) {
        typeVariableNames = new Set<String>();
        for (NominalVariableBuilder typeVariable in typeVariables) {
          typeVariableNames.add(typeVariable.name);
        }
      }

      /// Iterate over the mixins from left to right. At the end of each
      /// iteration, a new [supertype] is computed that is the mixin
      /// application of [supertype] with the current mixin.
      for (int i = 0; i < mixinApplicationBuilder.mixins.length; i++) {
        TypeBuilder mixin = mixinApplicationBuilder.mixins[i];
        isNamedMixinApplication =
            name != null && mixin == mixinApplicationBuilder.mixins.last;
        bool isGeneric = false;
        if (!isNamedMixinApplication) {
          if (typeVariableNames != null) {
            if (supertype != null) {
              isGeneric =
                  isGeneric || supertype.usesTypeVariables(typeVariableNames);
            }
            isGeneric = isGeneric || mixin.usesTypeVariables(typeVariableNames);
          }
          TypeName? typeName = mixin.typeName;
          if (typeName != null) {
            runningName += "&${typeName.name}";
          }
        }
        String fullname =
            isNamedMixinApplication ? name : "_$subclassName&$runningName";
        List<NominalVariableBuilder>? applicationTypeVariables;
        List<TypeBuilder>? applicationTypeArguments;
        if (isNamedMixinApplication) {
          // If this is a named mixin application, it must be given all the
          // declared type variables.
          applicationTypeVariables = typeVariables;
        } else {
          // Otherwise, we pass the fresh type variables to the mixin
          // application in the same order as they're declared on the subclass.
          if (isGeneric) {
            NominalParameterNameSpace nominalParameterNameSpace =
                new NominalParameterNameSpace();

            NominalVariableCopy nominalVariableCopy = copyTypeVariables(
                unboundNominalVariables, typeVariables,
                kind: TypeVariableKind.extensionSynthesized,
                instanceTypeVariableAccess:
                    InstanceTypeVariableAccessState.Allowed)!;

            applicationTypeVariables = nominalVariableCopy.newVariableBuilders;
            Map<NominalVariableBuilder, NominalVariableBuilder>
                newToOldVariableMap = nominalVariableCopy.newToOldVariableMap;

            Map<NominalVariableBuilder, TypeBuilder> substitutionMap =
                nominalVariableCopy.substitutionMap;

            applicationTypeArguments = [];
            for (NominalVariableBuilder typeVariable in typeVariables!) {
              TypeBuilder applicationTypeArgument =
                  new NamedTypeBuilderImpl.fromTypeDeclarationBuilder(
                      // The type variable types passed as arguments to the
                      // generic class representing the anonymous mixin
                      // application should refer back to the type variables of
                      // the class that extend the anonymous mixin application.
                      typeVariable,
                      const NullabilityBuilder.omitted(),
                      fileUri: fileUri,
                      charOffset: charOffset,
                      instanceTypeVariableAccess:
                          InstanceTypeVariableAccessState.Allowed);
              applicationTypeArguments.add(applicationTypeArgument);
            }
            nominalParameterNameSpace.addTypeVariables(
                problemReporting, applicationTypeVariables,
                ownerName: fullname, allowNameConflict: true);
            if (supertype != null) {
              supertype = new SynthesizedTypeBuilder(
                  supertype, newToOldVariableMap, substitutionMap);
            }
            mixin = new SynthesizedTypeBuilder(
                mixin, newToOldVariableMap, substitutionMap);
          }
        }
        final int computedStartCharOffset =
            !isNamedMixinApplication || metadata == null
                ? startCharOffset
                : metadata.first.charOffset;

        IndexedClass? referencesFromIndexedClass;
        if (indexedLibrary != null) {
          referencesFromIndexedClass =
              indexedLibrary.lookupIndexedClass(fullname);
        }

        LookupScope typeParameterScope =
            TypeParameterScope.fromList(compilationUnitScope, typeVariables);
        DeclarationNameSpaceBuilder nameSpaceBuilder =
            new DeclarationNameSpaceBuilder.empty();
        SourceClassBuilder application = new SourceClassBuilder(
            isNamedMixinApplication ? metadata : null,
            isNamedMixinApplication
                ? modifiers | namedMixinApplicationMask
                : abstractMask,
            fullname,
            applicationTypeVariables,
            isMixinDeclaration ? null : supertype,
            isNamedMixinApplication
                ? interfaces
                : isMixinDeclaration
                    ? [supertype!, mixin]
                    : null,
            null,
            // No `on` clause types.
            typeParameterScope,
            nameSpaceBuilder,
            enclosingLibraryBuilder,
            <ConstructorReferenceBuilder>[],
            fileUri,
            computedStartCharOffset,
            charOffset,
            charEndOffset,
            referencesFromIndexedClass,
            mixedInTypeBuilder: isMixinDeclaration ? null : mixin,
            isMacro: isNamedMixinApplication && isMacro,
            isSealed: isNamedMixinApplication && isSealed,
            isBase: isNamedMixinApplication && isBase,
            isInterface: isNamedMixinApplication && isInterface,
            isFinal: isNamedMixinApplication && isFinal,
            isAugmentation: isNamedMixinApplication && isAugmentation,
            isMixinClass: isNamedMixinApplication && isMixinClass);
        // TODO(ahe, kmillikin): Should always be true?
        // pkg/analyzer/test/src/summary/resynthesize_kernel_test.dart can't
        // handle that :(
        application.cls.isAnonymousMixin = !isNamedMixinApplication;
        addBuilder(fullname, application, charOffset,
            getterReference: referencesFromIndexedClass?.cls.reference);
        supertype = new NamedTypeBuilderImpl.fromTypeDeclarationBuilder(
            application, const NullabilityBuilder.omitted(),
            arguments: applicationTypeArguments,
            fileUri: fileUri,
            charOffset: charOffset,
            instanceTypeVariableAccess:
                InstanceTypeVariableAccessState.Allowed);
        mixinApplications[application] = mixin;
      }
      return supertype;
    } else {
      return supertype;
    }
  }

  @override
  void addExtensionDeclaration(
      OffsetMap offsetMap,
      Token beginToken,
      List<MetadataBuilder>? metadata,
      int modifiers,
      Identifier? identifier,
      List<NominalVariableBuilder>? typeVariables,
      TypeBuilder type,
      int startOffset,
      int nameOffset,
      int endOffset) {
    String? name = identifier?.name;
    // Nested declaration began in
    // `OutlineBuilder.beginExtensionDeclarationPrelude`.
    endExtensionDeclaration(name);

    ExtensionFragment declarationFragment =
        _declarationFragments.pop() as ExtensionFragment;

    NominalParameterNameSpace nominalParameterNameSpace =
        _nominalParameterNameSpaces.pop();
    nominalParameterNameSpace.addTypeVariables(_problemReporting, typeVariables,
        ownerName: name, allowNameConflict: false);

    Extension? referenceFrom;
    if (name != null) {
      referenceFrom = indexedLibrary?.lookupExtension(name);
    }

    declarationFragment.metadata = metadata;
    declarationFragment.modifiers = modifiers;
    declarationFragment.onType = type;
    declarationFragment.startOffset = startOffset;
    declarationFragment.nameOffset = nameOffset;
    declarationFragment.endOffset = endOffset;
    declarationFragment.reference = referenceFrom?.reference;

    _constructorReferences.clear();

    _addFragment(declarationFragment,
        getterReference: referenceFrom?.reference);

    if (identifier != null) {
      offsetMap.registerNamedDeclarationFragment(
          identifier, declarationFragment);
    } else {
      offsetMap.registerUnnamedDeclaration(beginToken, declarationFragment);
    }
  }

  @override
  void addExtensionTypeDeclaration(
      OffsetMap offsetMap,
      List<MetadataBuilder>? metadata,
      int modifiers,
      Identifier identifier,
      List<NominalVariableBuilder>? typeVariables,
      List<TypeBuilder>? interfaces,
      int startOffset,
      int endOffset) {
    String name = identifier.name;
    // Nested declaration began in `OutlineBuilder.beginExtensionDeclaration`.
    endExtensionTypeDeclaration(name);

    ExtensionTypeFragment declarationFragment =
        _declarationFragments.pop() as ExtensionTypeFragment;

    NominalParameterNameSpace nominalParameterNameSpace =
        _nominalParameterNameSpaces.pop();
    nominalParameterNameSpace.addTypeVariables(_problemReporting, typeVariables,
        ownerName: name, allowNameConflict: false);

    IndexedContainer? indexedContainer =
        indexedLibrary?.lookupIndexedExtensionTypeDeclaration(name);

    declarationFragment.metadata = metadata;
    declarationFragment.modifiers = modifiers;
    declarationFragment.interfaces = interfaces;
    declarationFragment.constructorReferences =
        new List<ConstructorReferenceBuilder>.of(_constructorReferences);
    declarationFragment.startOffset = startOffset;
    declarationFragment.endOffset = endOffset;
    declarationFragment.indexedContainer = indexedContainer;

    _constructorReferences.clear();

    _addFragment(declarationFragment,
        getterReference: indexedContainer?.reference);
    offsetMap.registerNamedDeclarationFragment(identifier, declarationFragment);
  }

  @override
  void addFunctionTypeAlias(
      List<MetadataBuilder>? metadata,
      String name,
      List<NominalVariableBuilder>? typeVariables,
      TypeBuilder type,
      int charOffset) {
    if (typeVariables != null) {
      for (NominalVariableBuilder typeVariable in typeVariables) {
        typeVariable.varianceCalculationValue =
            VarianceCalculationValue.pending;
      }
    }
    Reference? reference = indexedLibrary?.lookupTypedef(name)?.reference;
    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: name, allowNameConflict: true);
    // Nested declaration began in `OutlineBuilder.beginFunctionTypeAlias`.
    endTypedef();
    TypedefFragment fragment = new TypedefFragment(
        metadata: metadata,
        name: name,
        typeVariables: typeVariables,
        type: type,
        fileUri: _compilationUnit.fileUri,
        fileOffset: charOffset,
        reference: reference);
    _addFragment(fragment, getterReference: reference);
  }

  @override
  void addClassMethod(
      {required OffsetMap offsetMap,
      required List<MetadataBuilder>? metadata,
      required Identifier identifier,
      required String name,
      required TypeBuilder? returnType,
      required List<FormalParameterBuilder>? formals,
      required List<NominalVariableBuilder>? typeVariables,
      required Token? beginInitializers,
      required int startCharOffset,
      required int endCharOffset,
      required int charOffset,
      required int formalsOffset,
      required int modifiers,
      required bool inConstructor,
      required bool isStatic,
      required bool isConstructor,
      required bool forAbstractClassOrMixin,
      required bool isExtensionMember,
      required bool isExtensionTypeMember,
      required AsyncMarker asyncModifier,
      required String? nativeMethodName,
      required ProcedureKind? kind}) {
    DeclarationFragment declarationFragment = _declarationFragments.current;
    // TODO(johnniwinther): Avoid discrepancy between [inConstructor] and
    // [isConstructor]. The former is based on the enclosing declaration name
    // and get/set keyword. The latter also takes initializers into account.
    if (inConstructor) {
      endConstructor();
    } else if (isStatic) {
      endStaticMethod();
    } else {
      endInstanceMethod();
    }

    if (isConstructor) {
      switch (declarationFragment) {
        case ExtensionFragment():
        case ExtensionTypeFragment():
          NominalVariableCopy? nominalVariableCopy = copyTypeVariables(
              _unboundNominalVariables, declarationFragment.typeParameters,
              kind: TypeVariableKind.extensionSynthesized,
              instanceTypeVariableAccess:
                  InstanceTypeVariableAccessState.Allowed);

          if (nominalVariableCopy != null) {
            if (typeVariables != null) {
              // Coverage-ignore-block(suite): Not run.
              typeVariables = nominalVariableCopy.newVariableBuilders
                ..addAll(typeVariables);
            } else {
              typeVariables = nominalVariableCopy.newVariableBuilders;
            }
          }
        case ClassFragment():
        case MixinFragment():
        case EnumFragment():
      }
    } else if (!isStatic) {
      switch (declarationFragment) {
        case ExtensionFragment():
          NominalVariableCopy? nominalVariableCopy = copyTypeVariables(
              _unboundNominalVariables, declarationFragment.typeParameters,
              kind: TypeVariableKind.extensionSynthesized,
              instanceTypeVariableAccess:
                  InstanceTypeVariableAccessState.Allowed);

          if (nominalVariableCopy != null) {
            if (typeVariables != null) {
              typeVariables = nominalVariableCopy.newVariableBuilders
                ..addAll(typeVariables);
            } else {
              typeVariables = nominalVariableCopy.newVariableBuilders;
            }
          }

          TypeBuilder thisType = declarationFragment.extensionThisType;
          if (nominalVariableCopy != null) {
            thisType = new SynthesizedTypeBuilder(
                thisType,
                nominalVariableCopy.newToOldVariableMap,
                nominalVariableCopy.substitutionMap);
          }
          List<FormalParameterBuilder> synthesizedFormals = [
            new FormalParameterBuilder(FormalParameterKind.requiredPositional,
                finalMask, thisType, syntheticThisName, charOffset,
                fileUri: _compilationUnit.fileUri,
                isExtensionThis: true,
                hasImmediatelyDeclaredInitializer: false)
          ];
          if (formals != null) {
            synthesizedFormals.addAll(formals);
          }
          formals = synthesizedFormals;
        case ExtensionTypeFragment():
          NominalVariableCopy? nominalVariableCopy = copyTypeVariables(
              _unboundNominalVariables, declarationFragment.typeParameters,
              kind: TypeVariableKind.extensionSynthesized,
              instanceTypeVariableAccess:
                  InstanceTypeVariableAccessState.Allowed);

          if (nominalVariableCopy != null) {
            if (typeVariables != null) {
              typeVariables = nominalVariableCopy.newVariableBuilders
                ..addAll(typeVariables);
            } else {
              typeVariables = nominalVariableCopy.newVariableBuilders;
            }
          }

          TypeBuilder thisType = addNamedType(
              new SyntheticTypeName(declarationFragment.name, charOffset),
              const NullabilityBuilder.omitted(),
              declarationFragment.typeParameters != null
                  ? new List<TypeBuilder>.generate(
                      declarationFragment.typeParameters!.length,
                      (int index) =>
                          new NamedTypeBuilderImpl.fromTypeDeclarationBuilder(
                              typeVariables![index],
                              const NullabilityBuilder.omitted(),
                              instanceTypeVariableAccess:
                                  InstanceTypeVariableAccessState.Allowed))
                  : null,
              charOffset,
              instanceTypeVariableAccess:
                  InstanceTypeVariableAccessState.Allowed);

          if (nominalVariableCopy != null) {
            thisType = new SynthesizedTypeBuilder(
                thisType,
                nominalVariableCopy.newToOldVariableMap,
                nominalVariableCopy.substitutionMap);
          }
          List<FormalParameterBuilder> synthesizedFormals = [
            new FormalParameterBuilder(FormalParameterKind.requiredPositional,
                finalMask, thisType, syntheticThisName, charOffset,
                fileUri: _compilationUnit.fileUri,
                isExtensionThis: true,
                hasImmediatelyDeclaredInitializer: false)
          ];
          if (formals != null) {
            synthesizedFormals.addAll(formals);
          }
          formals = synthesizedFormals;
        case ClassFragment():
        case MixinFragment():
        case EnumFragment():
      }
    }

    if (isConstructor) {
      String constructorName =
          computeAndValidateConstructorName(declarationFragment, identifier) ??
              name;
      addConstructor(
          offsetMap,
          metadata,
          modifiers,
          identifier,
          constructorName,
          typeVariables,
          formals,
          startCharOffset,
          charOffset,
          formalsOffset,
          endCharOffset,
          nativeMethodName,
          beginInitializers: beginInitializers,
          forAbstractClassOrMixin: forAbstractClassOrMixin);
    } else {
      addProcedure(
          offsetMap,
          metadata,
          modifiers,
          returnType,
          identifier,
          name,
          typeVariables,
          formals,
          kind!,
          startCharOffset,
          charOffset,
          formalsOffset,
          endCharOffset,
          nativeMethodName,
          asyncModifier,
          isInstanceMember: !isStatic,
          isExtensionMember: isExtensionMember,
          isExtensionTypeMember: isExtensionTypeMember);
    }
  }

  @override
  void addConstructor(
      OffsetMap offsetMap,
      List<MetadataBuilder>? metadata,
      int modifiers,
      Identifier identifier,
      String constructorName,
      List<NominalVariableBuilder>? typeVariables,
      List<FormalParameterBuilder>? formals,
      int startCharOffset,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String? nativeMethodName,
      {Token? beginInitializers,
      required bool forAbstractClassOrMixin}) {
    ConstructorFragment fragment = _addConstructor(
        metadata,
        modifiers,
        constructorName,
        typeVariables,
        formals,
        startCharOffset,
        charOffset,
        charOpenParenOffset,
        charEndOffset,
        nativeMethodName,
        beginInitializers: beginInitializers,
        forAbstractClassOrMixin: forAbstractClassOrMixin,
        isConst: modifiers & constMask != 0);
    offsetMap.registerConstructorFragment(identifier, fragment);
  }

  @override
  void addPrimaryConstructor(
      {required OffsetMap offsetMap,
      required Token beginToken,
      required String constructorName,
      required List<FormalParameterBuilder>? formals,
      required int charOffset,
      required bool isConst}) {
    beginConstructor();
    endConstructor();
    NominalVariableCopy? nominalVariableCopy = copyTypeVariables(
        _unboundNominalVariables, _declarationFragments.current.typeParameters,
        kind: TypeVariableKind.extensionSynthesized,
        instanceTypeVariableAccess: InstanceTypeVariableAccessState.Allowed);
    List<NominalVariableBuilder>? typeVariables =
        nominalVariableCopy?.newVariableBuilders;

    ConstructorFragment builder = _addConstructor(
        null,
        isConst ? constMask : 0,
        constructorName,
        typeVariables,
        formals,
        /* startCharOffset = */
        charOffset,
        charOffset,
        /* charOpenParenOffset = */
        charOffset,
        /* charEndOffset = */
        charOffset,
        /* nativeMethodName = */
        null,
        isConst: isConst,
        forAbstractClassOrMixin: false);
    offsetMap.registerPrimaryConstructor(beginToken, builder);
  }

  @override
  void addPrimaryConstructorField(
      {required List<MetadataBuilder>? metadata,
      required TypeBuilder type,
      required String name,
      required int charOffset}) {
    _declarationFragments.current.addPrimaryConstructorField(_addField(
        metadata,
        finalMask,
        /* isTopLevel = */
        false,
        type,
        name,
        /* charOffset = */
        charOffset,
        /* charEndOffset = */
        charOffset,
        /* initializerToken = */
        null,
        /* hasInitializer = */
        false));
  }

  ConstructorFragment _addConstructor(
      List<MetadataBuilder>? metadata,
      int modifiers,
      String constructorName,
      List<NominalVariableBuilder>? typeVariables,
      List<FormalParameterBuilder>? formals,
      int startCharOffset,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String? nativeMethodName,
      {Token? beginInitializers,
      required bool isConst,
      required bool forAbstractClassOrMixin}) {
    ContainerType containerType = _declarationFragments.current.containerType;
    ContainerName? containerName = _declarationFragments.current.containerName;
    NameScheme nameScheme = new NameScheme(
        isInstanceMember: false,
        containerName: containerName,
        containerType: containerType,
        libraryName: indexedLibrary != null
            ? new LibraryName(indexedLibrary!.library.reference)
            : libraryName);

    Reference? constructorReference;
    Reference? tearOffReference;

    IndexedContainer? indexedContainer = _indexedContainer;
    if (indexedContainer != null) {
      constructorReference = indexedContainer.lookupConstructorReference(
          nameScheme
              .getConstructorMemberName(constructorName, isTearOff: false)
              .name);
      tearOffReference = indexedContainer.lookupGetterReference(nameScheme
          .getConstructorMemberName(constructorName, isTearOff: true)
          .name);
    }

    ConstructorFragment fragment = new ConstructorFragment(
        name: constructorName,
        fileUri: _compilationUnit.fileUri,
        startCharOffset: startCharOffset,
        charOffset: charOffset,
        charOpenParenOffset: charOpenParenOffset,
        charEndOffset: charEndOffset,
        modifiers: modifiers & ~abstractMask,
        metadata: metadata,
        returnType: addInferableType(),
        typeParameters: typeVariables,
        formals: formals,
        constructorReference: constructorReference,
        tearOffReference: tearOffReference,
        nameScheme: nameScheme,
        nativeMethodName: nativeMethodName,
        forAbstractClassOrMixin: forAbstractClassOrMixin,
        beginInitializers: isConst || libraryFeatures.superParameters.isEnabled

            // const constructors will have their initializers compiled and
            // written into the outline. In case of super-parameters language
            // feature, the super initializers are required to infer the types
            // of super parameters.
            // TODO(johnniwinther): Avoid using a dummy token to ensure building
            // of constant constructors in the outline phase.
            ? (beginInitializers ?? new Token.eof(-1))
            : null);

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: constructorName, allowNameConflict: true);
    // TODO(johnniwinther): There is no way to pass the tear off reference here.
    _addFragment(fragment, getterReference: constructorReference);
    if (nativeMethodName != null) {
      _addNativeConstructorFragment(fragment);
    }
    if (isConst) {
      _declarationFragments.current.declaresConstConstructor = true;
    }
    return fragment;
  }

  @override
  void addFactoryMethod(
      OffsetMap offsetMap,
      List<MetadataBuilder>? metadata,
      int modifiers,
      Identifier identifier,
      List<FormalParameterBuilder>? formals,
      ConstructorReferenceBuilder? redirectionTarget,
      int startCharOffset,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String? nativeMethodName,
      AsyncMarker asyncModifier) {
    TypeBuilder returnType;
    List<TypeBuilder>? returnTypeArguments;
    DeclarationFragment enclosingDeclaration = _declarationFragments.current;
    if (enclosingDeclaration.kind ==
        DeclarationFragmentKind.extensionDeclaration) {
      // Make the synthesized return type invalid for extensions.
      String name = enclosingDeclaration.name;
      returnType = new NamedTypeBuilderImpl.forInvalidType(
          name,
          const NullabilityBuilder.omitted(),
          messageExtensionDeclaresConstructor.withLocation(
              _compilationUnit.fileUri, charOffset, name.length));
    } else {
      returnType = addNamedType(
          new SyntheticTypeName(enclosingDeclaration.name, charOffset),
          const NullabilityBuilder.omitted(),
          returnTypeArguments = [],
          charOffset,
          instanceTypeVariableAccess: InstanceTypeVariableAccessState.Allowed);
    }

    // Prepare the simple procedure name.
    String procedureName;
    String? constructorName = computeAndValidateConstructorName(
        enclosingDeclaration, identifier,
        isFactory: true);
    if (constructorName != null) {
      procedureName = constructorName;
    } else {
      procedureName = identifier.name;
    }

    ContainerType containerType = enclosingDeclaration.containerType;
    ContainerName containerName = enclosingDeclaration.containerName;

    NameScheme procedureNameScheme = new NameScheme(
        containerName: containerName,
        containerType: containerType,
        isInstanceMember: false,
        libraryName: indexedLibrary != null
            ? new LibraryName(
                (_indexedContainer ?? // Coverage-ignore(suite): Not run.
                        indexedLibrary)!
                    .library
                    .reference)
            : libraryName);

    Reference? constructorReference;
    Reference? tearOffReference;
    if (_indexedContainer != null) {
      constructorReference = _indexedContainer!.lookupConstructorReference(
          procedureNameScheme
              .getConstructorMemberName(procedureName, isTearOff: false)
              .name);
      tearOffReference = _indexedContainer!.lookupGetterReference(
          procedureNameScheme
              .getConstructorMemberName(procedureName, isTearOff: true)
              .name);
    } else if (indexedLibrary != null) {
      // Coverage-ignore-block(suite): Not run.
      constructorReference = indexedLibrary!.lookupGetterReference(
          procedureNameScheme
              .getConstructorMemberName(procedureName, isTearOff: false)
              .name);
      tearOffReference = indexedLibrary!.lookupGetterReference(
          procedureNameScheme
              .getConstructorMemberName(procedureName, isTearOff: true)
              .name);
    }
    List<NominalVariableBuilder>? typeVariables = copyTypeVariables(
            _unboundNominalVariables, enclosingDeclaration.typeParameters,
            kind: TypeVariableKind.function,
            instanceTypeVariableAccess: InstanceTypeVariableAccessState.Allowed)
        ?.newVariableBuilders;
    FactoryFragment fragment = new FactoryFragment(
        name: procedureName,
        fileUri: _compilationUnit.fileUri,
        startCharOffset: startCharOffset,
        charOffset: charOffset,
        charOpenParenOffset: charOpenParenOffset,
        charEndOffset: charEndOffset,
        modifiers: staticMask | modifiers,
        metadata: metadata,
        returnType: returnType,
        typeParameters: typeVariables,
        formals: formals,
        constructorReference: constructorReference,
        tearOffReference: tearOffReference,
        asyncModifier: asyncModifier,
        nameScheme: procedureNameScheme,
        nativeMethodName: nativeMethodName,
        redirectionTarget: redirectionTarget);

    if (returnTypeArguments != null && typeVariables != null) {
      for (TypeVariableBuilder typeVariable in typeVariables) {
        returnTypeArguments.add(addNamedType(
            new SyntheticTypeName(typeVariable.name, charOffset),
            const NullabilityBuilder.omitted(),
            null,
            charOffset,
            instanceTypeVariableAccess:
                InstanceTypeVariableAccessState.Allowed));
      }
    }

    // Nested declaration began in `OutlineBuilder.beginFactoryMethod`.
    endFactoryMethod();

    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: identifier.name, allowNameConflict: true);

    _addFragment(fragment, getterReference: constructorReference);
    if (nativeMethodName != null) {
      _addNativeFactoryFragment(fragment);
    }
    offsetMap.registerFactoryFragment(identifier, fragment);
  }

  @override
  ConstructorReferenceBuilder addConstructorReference(TypeName name,
      List<TypeBuilder>? typeArguments, String? suffix, int charOffset) {
    ConstructorReferenceBuilder ref = new ConstructorReferenceBuilder(
        name, typeArguments, suffix, _compilationUnit.fileUri, charOffset);
    _constructorReferences.add(ref);
    return ref;
  }

  @override
  ConstructorReferenceBuilder? addUnnamedConstructorReference(
      List<TypeBuilder>? typeArguments, Identifier? suffix, int charOffset) {
    // At the moment, the name of the type in a constructor reference can be
    // omitted only within an enum element declaration.
    DeclarationFragment enclosingDeclaration = _declarationFragments.current;
    if (enclosingDeclaration.kind == DeclarationFragmentKind.enumDeclaration) {
      if (libraryFeatures.enhancedEnums.isEnabled) {
        int constructorNameOffset = suffix?.nameOffset ?? charOffset;
        return addConstructorReference(
            new SyntheticTypeName(
                enclosingDeclaration.name, constructorNameOffset),
            typeArguments,
            suffix?.name,
            constructorNameOffset);
      } else {
        // Coverage-ignore-block(suite): Not run.
        // For entries that consist of their name only, all of the elements
        // of the constructor reference should be null.
        if (typeArguments != null || suffix != null) {
          _compilationUnit.reportFeatureNotEnabled(
              libraryFeatures.enhancedEnums,
              _compilationUnit.fileUri,
              charOffset,
              noLength);
        }
        return null;
      }
    } else {
      internalProblem(
          messageInternalProblemOmittedTypeNameInConstructorReference,
          charOffset,
          _compilationUnit.fileUri);
    }
  }

  @override
  String? computeAndValidateConstructorName(
      DeclarationFragment enclosingDeclaration, Identifier identifier,
      {isFactory = false}) {
    String className = enclosingDeclaration.name;
    String prefix;
    String? suffix;
    int charOffset;
    if (identifier is QualifiedNameIdentifier) {
      Identifier qualifier = identifier.qualifier;
      prefix = qualifier.name;
      suffix = identifier.name;
      charOffset = qualifier.nameOffset;
    } else {
      prefix = identifier.name;
      suffix = null;
      charOffset = identifier.nameOffset;
    }
    if (libraryFeatures.constructorTearoffs.isEnabled) {
      suffix = suffix == "new" ? "" : suffix;
    }
    if (prefix == className) {
      return suffix ?? "";
    }
    if (suffix == null && !isFactory) {
      // A legal name for a regular method, but not for a constructor.
      return null;
    }

    _problemReporting.addProblem(messageConstructorWithWrongName, charOffset,
        prefix.length, _compilationUnit.fileUri,
        context: [
          templateConstructorWithWrongNameContext
              .withArguments(enclosingDeclaration.name)
              .withLocation(
                  _compilationUnit.importUri,
                  enclosingDeclaration.fileOffset,
                  enclosingDeclaration.name.length)
        ]);

    return suffix;
  }

  void _addNativeMethodFragment(MethodFragment fragment) {
    _nativeMethodFragments.add(fragment);
  }

  void _addNativeConstructorFragment(ConstructorFragment fragment) {
    _nativeConstructorFragments.add(fragment);
  }

  void _addNativeFactoryFragment(FactoryFragment method) {
    _nativeFactoryFragments.add(method);
  }

  @override
  void addProcedure(
      OffsetMap offsetMap,
      List<MetadataBuilder>? metadata,
      int modifiers,
      TypeBuilder? returnType,
      Identifier identifier,
      String name,
      List<NominalVariableBuilder>? typeVariables,
      List<FormalParameterBuilder>? formals,
      ProcedureKind kind,
      int startCharOffset,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String? nativeMethodName,
      AsyncMarker asyncModifier,
      {required bool isInstanceMember,
      required bool isExtensionMember,
      required bool isExtensionTypeMember}) {
    DeclarationFragment? enclosingDeclaration =
        _declarationFragments.currentOrNull;
    assert(!isExtensionMember ||
        enclosingDeclaration?.kind ==
            DeclarationFragmentKind.extensionDeclaration);
    assert(!isExtensionTypeMember ||
        enclosingDeclaration?.kind ==
            DeclarationFragmentKind.extensionTypeDeclaration);
    ContainerType containerType =
        enclosingDeclaration?.containerType ?? ContainerType.Library;
    ContainerName? containerName = enclosingDeclaration?.containerName;
    NameScheme nameScheme = new NameScheme(
        containerName: containerName,
        containerType: containerType,
        isInstanceMember: isInstanceMember,
        libraryName: indexedLibrary != null
            ? new LibraryName(indexedLibrary!.library.reference)
            : libraryName);

    if (returnType == null) {
      if (kind == ProcedureKind.Operator &&
          identical(name, indexSetName.text)) {
        returnType = addVoidType(charOffset);
      } else if (kind == ProcedureKind.Setter) {
        returnType = addVoidType(charOffset);
      }
    }
    Reference? procedureReference;
    Reference? tearOffReference;
    IndexedContainer? indexedContainer = _indexedContainer ?? indexedLibrary;

    bool isAugmentation =
        _compilationUnit.isAugmenting && (modifiers & augmentMask) != 0;
    if (indexedContainer != null && !isAugmentation) {
      Name nameToLookup = nameScheme.getProcedureMemberName(kind, name).name;
      if (kind == ProcedureKind.Setter) {
        if ((isExtensionMember || isExtensionTypeMember) && isInstanceMember) {
          // Extension (type) instance setters are encoded as methods.
          procedureReference =
              indexedContainer.lookupGetterReference(nameToLookup);
        } else {
          procedureReference =
              indexedContainer.lookupSetterReference(nameToLookup);
        }
      } else {
        procedureReference =
            indexedContainer.lookupGetterReference(nameToLookup);
        if ((isExtensionMember || isExtensionTypeMember) &&
            kind == ProcedureKind.Method) {
          tearOffReference = indexedContainer.lookupGetterReference(nameScheme
              .getProcedureMemberName(ProcedureKind.Getter, name)
              .name);
        }
      }
    }
    MethodFragment fragment = new MethodFragment(
        name: name,
        fileUri: _compilationUnit.fileUri,
        startCharOffset: startCharOffset,
        charOffset: charOffset,
        charOpenParenOffset: charOpenParenOffset,
        charEndOffset: charEndOffset,
        metadata: metadata,
        modifiers: modifiers,
        returnType: returnType ?? addInferableType(),
        typeParameters: typeVariables,
        formals: formals,
        kind: kind,
        procedureReference: procedureReference,
        tearOffReference: tearOffReference,
        asyncModifier: asyncModifier,
        nameScheme: nameScheme,
        nativeMethodName: nativeMethodName);
    _nominalParameterNameSpaces.pop().addTypeVariables(
        _problemReporting, typeVariables,
        ownerName: name, allowNameConflict: true);
    _addFragment(fragment, getterReference: procedureReference);
    if (nativeMethodName != null) {
      _addNativeMethodFragment(fragment);
    }
    offsetMap.registerProcedure(identifier, fragment);
  }

  @override
  void addFields(
      OffsetMap offsetMap,
      List<MetadataBuilder>? metadata,
      int modifiers,
      bool isTopLevel,
      TypeBuilder? type,
      List<FieldInfo> fieldInfos) {
    for (FieldInfo info in fieldInfos) {
      bool isConst = modifiers & constMask != 0;
      bool isFinal = modifiers & finalMask != 0;
      bool potentiallyNeedInitializerInOutline = isConst || isFinal;
      Token? startToken;
      if (potentiallyNeedInitializerInOutline || type == null) {
        startToken = info.initializerToken;
      }
      if (startToken != null) {
        // Extract only the tokens for the initializer expression from the
        // token stream.
        Token endToken = info.beforeLast!;
        endToken.setNext(new Token.eof(endToken.next!.offset));
        new Token.eof(startToken.previous!.offset).setNext(startToken);
      }
      bool hasInitializer = info.initializerToken != null;
      offsetMap.registerField(
          info.identifier,
          _addField(
              metadata,
              modifiers,
              isTopLevel,
              type ?? addInferableType(),
              info.identifier.name,
              info.identifier.nameOffset,
              info.charEndOffset,
              startToken,
              hasInitializer,
              constInitializerToken:
                  potentiallyNeedInitializerInOutline ? startToken : null));
    }
  }

  FieldFragment _addField(
      List<MetadataBuilder>? metadata,
      int modifiers,
      bool isTopLevel,
      TypeBuilder type,
      String name,
      int charOffset,
      int charEndOffset,
      Token? initializerToken,
      bool hasInitializer,
      {Token? constInitializerToken}) {
    if (hasInitializer) {
      modifiers |= hasInitializerMask;
    }
    bool isLate = (modifiers & lateMask) != 0;
    bool isFinal = (modifiers & finalMask) != 0;
    bool isStatic = (modifiers & staticMask) != 0;
    bool isExternal = (modifiers & externalMask) != 0;
    final bool fieldIsLateWithLowering = isLate &&
        (loader.target.backendTarget.isLateFieldLoweringEnabled(
                hasInitializer: hasInitializer,
                isFinal: isFinal,
                isStatic: isTopLevel || isStatic) ||
            (loader.target.backendTarget.useStaticFieldLowering &&
                (isStatic || isTopLevel)));

    DeclarationFragment? enclosingDeclaration =
        _declarationFragments.currentOrNull;
    final bool isInstanceMember = enclosingDeclaration != null && !isStatic;
    final bool isExtensionMember = enclosingDeclaration?.kind ==
        DeclarationFragmentKind.extensionDeclaration;
    final bool isExtensionTypeMember = enclosingDeclaration?.kind ==
        DeclarationFragmentKind.extensionTypeDeclaration;
    ContainerType containerType =
        enclosingDeclaration?.containerType ?? ContainerType.Library;
    ContainerName? containerName = enclosingDeclaration?.containerName;

    Reference? fieldReference;
    Reference? fieldGetterReference;
    Reference? fieldSetterReference;
    Reference? lateIsSetFieldReference;
    Reference? lateIsSetGetterReference;
    Reference? lateIsSetSetterReference;
    Reference? lateGetterReference;
    Reference? lateSetterReference;

    NameScheme nameScheme = new NameScheme(
        isInstanceMember: isInstanceMember,
        containerName: containerName,
        containerType: containerType,
        libraryName: indexedLibrary != null
            ? new LibraryName(indexedLibrary!.reference)
            : libraryName);
    IndexedContainer? indexedContainer = _indexedContainer ?? indexedLibrary;
    if (indexedContainer != null) {
      if ((isExtensionMember || isExtensionTypeMember) &&
          isInstanceMember &&
          isExternal) {
        /// An external extension (type) instance field is special. It is
        /// treated as an external getter/setter pair and is therefore encoded
        /// as a pair of top level methods using the extension instance member
        /// naming convention.
        fieldGetterReference = indexedContainer.lookupGetterReference(
            nameScheme.getProcedureMemberName(ProcedureKind.Getter, name).name);
        fieldSetterReference = indexedContainer.lookupGetterReference(
            nameScheme.getProcedureMemberName(ProcedureKind.Setter, name).name);
      } else if (isExtensionTypeMember && isInstanceMember) {
        Name nameToLookup = nameScheme
            .getFieldMemberName(FieldNameType.RepresentationField, name,
                isSynthesized: true)
            .name;
        fieldGetterReference =
            indexedContainer.lookupGetterReference(nameToLookup);
      } else {
        Name nameToLookup = nameScheme
            .getFieldMemberName(FieldNameType.Field, name,
                isSynthesized: fieldIsLateWithLowering)
            .name;
        fieldReference = indexedContainer.lookupFieldReference(nameToLookup);
        fieldGetterReference =
            indexedContainer.lookupGetterReference(nameToLookup);
        fieldSetterReference =
            indexedContainer.lookupSetterReference(nameToLookup);
      }

      if (fieldIsLateWithLowering) {
        Name lateIsSetName = nameScheme
            .getFieldMemberName(FieldNameType.IsSetField, name,
                isSynthesized: fieldIsLateWithLowering)
            .name;
        lateIsSetFieldReference =
            indexedContainer.lookupFieldReference(lateIsSetName);
        lateIsSetGetterReference =
            indexedContainer.lookupGetterReference(lateIsSetName);
        lateIsSetSetterReference =
            indexedContainer.lookupSetterReference(lateIsSetName);
        lateGetterReference = indexedContainer.lookupGetterReference(nameScheme
            .getFieldMemberName(FieldNameType.Getter, name,
                isSynthesized: fieldIsLateWithLowering)
            .name);
        lateSetterReference = indexedContainer.lookupSetterReference(nameScheme
            .getFieldMemberName(FieldNameType.Setter, name,
                isSynthesized: fieldIsLateWithLowering)
            .name);
      }
    }

    FieldFragment fragment = new FieldFragment(
        name: name,
        fileUri: _compilationUnit.fileUri,
        charOffset: charOffset,
        charEndOffset: charEndOffset,
        initializerToken: initializerToken,
        constInitializerToken: constInitializerToken,
        metadata: metadata,
        type: type,
        fieldReference: fieldReference,
        fieldGetterReference: fieldGetterReference,
        fieldSetterReference: fieldSetterReference,
        lateGetterReference: lateGetterReference,
        lateSetterReference: lateSetterReference,
        lateIsSetFieldReference: lateIsSetFieldReference,
        lateIsSetGetterReference: lateIsSetGetterReference,
        lateIsSetSetterReference: lateIsSetSetterReference,
        isTopLevel: isTopLevel,
        modifiers: modifiers,
        nameScheme: nameScheme);
    _addFragment(fragment,
        getterReference: fieldGetterReference,
        setterReference: fieldSetterReference);
    return fragment;
  }

  @override
  FormalParameterBuilder addFormalParameter(
      List<MetadataBuilder>? metadata,
      FormalParameterKind kind,
      int modifiers,
      TypeBuilder type,
      String name,
      bool hasThis,
      bool hasSuper,
      int charOffset,
      Token? initializerToken,
      {bool lowerWildcard = false}) {
    assert(!hasThis || !hasSuper,
        "Formal parameter '${name}' has both 'this' and 'super' prefixes.");
    if (hasThis) {
      modifiers |= initializingFormalMask;
    }
    if (hasSuper) {
      modifiers |= superInitializingFormalMask;
    }
    String formalName = name;
    bool isWildcard =
        libraryFeatures.wildcardVariables.isEnabled && formalName == '_';
    if (isWildcard && lowerWildcard) {
      formalName = createWildcardFormalParameterName(wildcardVariableIndex);
      wildcardVariableIndex++;
    }
    FormalParameterBuilder formal = new FormalParameterBuilder(
        kind, modifiers, type, formalName, charOffset,
        fileUri: _compilationUnit.fileUri,
        hasImmediatelyDeclaredInitializer: initializerToken != null,
        isWildcard: isWildcard)
      ..initializerToken = initializerToken;
    return formal;
  }

  @override
  TypeBuilder addNamedType(
      TypeName typeName,
      NullabilityBuilder nullabilityBuilder,
      List<TypeBuilder>? arguments,
      int charOffset,
      {required InstanceTypeVariableAccessState instanceTypeVariableAccess}) {
    if (_omittedTypeDeclarationBuilders != null) {
      // Coverage-ignore-block(suite): Not run.
      Builder? builder = _omittedTypeDeclarationBuilders[typeName.name];
      if (builder is OmittedTypeDeclarationBuilder) {
        return new DependentTypeBuilder(builder.omittedTypeBuilder);
      }
    }
    return _registerUnresolvedNamedType(new NamedTypeBuilderImpl(
        typeName, nullabilityBuilder,
        arguments: arguments,
        fileUri: _compilationUnit.fileUri,
        charOffset: charOffset,
        instanceTypeVariableAccess: instanceTypeVariableAccess));
  }

  NamedTypeBuilder _registerUnresolvedNamedType(NamedTypeBuilder type) {
    _typeScopes.current.registerUnresolvedNamedType(type);
    return type;
  }

  @override
  FunctionTypeBuilder addFunctionType(
      TypeBuilder returnType,
      List<StructuralVariableBuilder>? structuralVariableBuilders,
      List<FormalParameterBuilder>? formals,
      NullabilityBuilder nullabilityBuilder,
      Uri fileUri,
      int charOffset,
      {required bool hasFunctionFormalParameterSyntax}) {
    FunctionTypeBuilder builder = new FunctionTypeBuilderImpl(
        returnType,
        structuralVariableBuilders,
        formals,
        nullabilityBuilder,
        fileUri,
        charOffset,
        hasFunctionFormalParameterSyntax: hasFunctionFormalParameterSyntax);
    _checkStructuralVariables(structuralVariableBuilders);
    if (structuralVariableBuilders != null) {
      for (StructuralVariableBuilder builder in structuralVariableBuilders) {
        if (builder.metadata != null) {
          if (!libraryFeatures.genericMetadata.isEnabled) {
            _problemReporting.addProblem(
                messageAnnotationOnFunctionTypeTypeVariable,
                builder.charOffset,
                builder.name.length,
                builder.fileUri);
          }
        }
      }
    }
    // Nested declaration began in `OutlineBuilder.beginFunctionType` or
    // `OutlineBuilder.beginFunctionTypedFormalParameter`.
    endFunctionType();
    return builder;
  }

  void _checkStructuralVariables(
      List<StructuralVariableBuilder>? typeVariables) {
    Map<String, StructuralVariableBuilder> typeVariablesByName =
        _structuralParameterScopes.pop();
    if (typeVariables == null || typeVariables.isEmpty) return null;
    for (StructuralVariableBuilder tv in typeVariables) {
      if (tv.isWildcard) continue;
      StructuralVariableBuilder? existing = typeVariablesByName[tv.name];
      if (existing != null) {
        // Coverage-ignore-block(suite): Not run.
        _problemReporting.addProblem(messageTypeVariableDuplicatedName,
            tv.charOffset, tv.name.length, _compilationUnit.fileUri,
            context: [
              templateTypeVariableDuplicatedNameCause
                  .withArguments(tv.name)
                  .withLocation(_compilationUnit.fileUri, existing.charOffset,
                      existing.name.length)
            ]);
      } else {
        typeVariablesByName[tv.name] = tv;
      }
    }
  }

  @override
  TypeBuilder addVoidType(int charOffset) {
    return new VoidTypeBuilder(_compilationUnit.fileUri, charOffset);
  }

  @override
  NominalVariableBuilder addNominalTypeVariable(List<MetadataBuilder>? metadata,
      String name, TypeBuilder? bound, int charOffset, Uri fileUri,
      {required TypeVariableKind kind}) {
    String variableName = name;
    bool isWildcard =
        libraryFeatures.wildcardVariables.isEnabled && variableName == '_';
    if (isWildcard) {
      variableName = createWildcardTypeVariableName(wildcardVariableIndex);
      wildcardVariableIndex++;
    }
    NominalVariableBuilder builder = new NominalVariableBuilder(
        variableName, charOffset, fileUri,
        bound: bound, metadata: metadata, kind: kind, isWildcard: isWildcard);

    _unboundNominalVariables.add(builder);
    return builder;
  }

  @override
  StructuralVariableBuilder addStructuralTypeVariable(
      List<MetadataBuilder>? metadata,
      String name,
      TypeBuilder? bound,
      int charOffset,
      Uri fileUri) {
    String variableName = name;
    bool isWildcard =
        libraryFeatures.wildcardVariables.isEnabled && variableName == '_';
    if (isWildcard) {
      variableName = createWildcardTypeVariableName(wildcardVariableIndex);
      wildcardVariableIndex++;
    }
    StructuralVariableBuilder builder = new StructuralVariableBuilder(
        variableName, charOffset, fileUri,
        bound: bound, metadata: metadata, isWildcard: isWildcard);

    _unboundStructuralVariables.add(builder);
    return builder;
  }

  /// Creates a [NominalVariableCopy] object containing a copy of
  /// [oldVariableBuilders] into the scope of [declaration].
  ///
  /// This is used for adding copies of class type parameters to factory
  /// methods and unnamed mixin applications, and for adding copies of
  /// extension type parameters to extension instance methods.
  static NominalVariableCopy? copyTypeVariables(
      List<NominalVariableBuilder> _unboundNominalVariables,
      List<NominalVariableBuilder>? oldVariableBuilders,
      {required TypeVariableKind kind,
      required InstanceTypeVariableAccessState instanceTypeVariableAccess}) {
    if (oldVariableBuilders == null || oldVariableBuilders.isEmpty) {
      return null;
    }

    List<TypeBuilder> newTypeArguments = [];
    Map<NominalVariableBuilder, TypeBuilder> substitutionMap =
        new Map.identity();
    Map<NominalVariableBuilder, NominalVariableBuilder> newToOldVariableMap =
        new Map.identity();

    List<NominalVariableBuilder> newVariableBuilders =
        <NominalVariableBuilder>[];
    for (NominalVariableBuilder oldVariable in oldVariableBuilders) {
      NominalVariableBuilder newVariable = new NominalVariableBuilder(
          oldVariable.name, oldVariable.charOffset, oldVariable.fileUri,
          kind: kind,
          variableVariance: oldVariable.parameter.isLegacyCovariant
              ? null
              :
              // Coverage-ignore(suite): Not run.
              oldVariable.variance,
          isWildcard: oldVariable.isWildcard);
      newVariableBuilders.add(newVariable);
      newToOldVariableMap[newVariable] = oldVariable;
      _unboundNominalVariables.add(newVariable);
    }
    for (int i = 0; i < newVariableBuilders.length; i++) {
      NominalVariableBuilder oldVariableBuilder = oldVariableBuilders[i];
      TypeBuilder newTypeArgument =
          new NamedTypeBuilderImpl.fromTypeDeclarationBuilder(
              newVariableBuilders[i], const NullabilityBuilder.omitted(),
              instanceTypeVariableAccess: instanceTypeVariableAccess);
      substitutionMap[oldVariableBuilder] = newTypeArgument;
      newTypeArguments.add(newTypeArgument);

      if (oldVariableBuilder.bound != null) {
        newVariableBuilders[i].bound = new SynthesizedTypeBuilder(
            oldVariableBuilder.bound!, newToOldVariableMap, substitutionMap);
      }
    }
    return new NominalVariableCopy(newVariableBuilders, newTypeArguments,
        substitutionMap, newToOldVariableMap);
  }

  @override
  void addLibraryDirective(
      {required String? libraryName,
      required List<MetadataBuilder>? metadata,
      required bool isAugment}) {
    _name = libraryName;
    _metadata = metadata;
  }

  @override
  InferableTypeBuilder addInferableType() {
    return _compilationUnit.loader.inferableTypes.addInferableType();
  }

  void _addFragment(Fragment fragment,
      {required Reference? getterReference, Reference? setterReference}) {
    if (getterReference != null) {
      loader.fragmentsCreatedWithReferences[getterReference] = fragment;
    }
    if (setterReference != null) {
      loader.fragmentsCreatedWithReferences[setterReference] = fragment;
    }
    if (_declarationFragments.isEmpty) {
      _libraryNameSpaceBuilder.addFragment(fragment);
    } else {
      _declarationFragments.current.addFragment(fragment);
    }
  }

  @override
  void takeMixinApplications(
      Map<SourceClassBuilder, TypeBuilder> mixinApplications) {
    assert(_mixinApplications != null,
        "Mixin applications have already been processed.");
    mixinApplications.addAll(_mixinApplications!);
    _mixinApplications = null;
  }

  @override
  void collectUnboundTypeVariables(
      SourceLibraryBuilder libraryBuilder,
      Map<NominalVariableBuilder, SourceLibraryBuilder> nominalVariables,
      Map<StructuralVariableBuilder, SourceLibraryBuilder>
          structuralVariables) {
    for (NominalVariableBuilder builder in _unboundNominalVariables) {
      nominalVariables[builder] = libraryBuilder;
    }
    for (StructuralVariableBuilder builder in _unboundStructuralVariables) {
      structuralVariables[builder] = libraryBuilder;
    }
    _unboundStructuralVariables.clear();
    _unboundNominalVariables.clear();
  }

  @override
  TypeScope get typeScope => _typeScopes.current;

  @override
  String? get name => _name;

  @override
  List<MetadataBuilder>? get metadata => _metadata;

  @override
  bool get isPart => _partOfName != null || _partOfUri != null;

  @override
  String? get partOfName => _partOfName;

  @override
  Uri? get partOfUri => _partOfUri;

  @override
  List<Part> get parts => _parts;

  @override
  void registerUnresolvedStructuralVariables(
      List<StructuralVariableBuilder> unboundTypeVariables) {
    this._unboundStructuralVariables.addAll(unboundTypeVariables);
  }

  @override
  int finishNativeMethods() {
    for (FactoryFragment fragment in _nativeFactoryFragments) {
      fragment.builder.becomeNative(loader);
    }
    for (MethodFragment fragment in _nativeMethodFragments) {
      fragment.builder.becomeNative(loader);
    }
    for (ConstructorFragment fragment in _nativeConstructorFragments) {
      fragment.builder.becomeNative(loader);
    }
    return _nativeFactoryFragments.length;
  }

  @override
  List<LibraryPart> get libraryParts => _libraryParts;
}
