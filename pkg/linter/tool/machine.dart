// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/src/lint/registry.dart';
import 'package:analyzer/src/lint/state.dart';
import 'package:args/args.dart';
import 'package:linter/src/analyzer.dart';
import 'package:linter/src/rules.dart';
import 'package:linter/src/utils.dart';
import 'package:yaml/yaml.dart';

import '../tool/util/path_utils.dart';
import 'messages_data.dart';
import 'since.dart';
import 'util/score_utils.dart' as score_utils;

/// Generates a list of lint rules in machine format suitable for consumption by
/// other tools.
void main(List<String> args) async {
  var parser = ArgParser()
    ..addFlag('write', abbr: 'w', help: 'Write `rules.json` file.')
    ..addFlag('pretty',
        abbr: 'p', help: 'Pretty-print output.', defaultsTo: true)
    ..addFlag('sets', abbr: 's', help: 'Include rule sets', defaultsTo: true);
  var options = parser.parse(args);

  var json = await generateRulesJson(
      pretty: options['pretty'] == true,
      includeSetInfo: options['sets'] == true);

  if (options['write'] == true) {
    var outFile = machineJsonFile();
    printToConsole('Writing to ${outFile.path}');
    outFile.writeAsStringSync(json);
  } else {
    printToConsole(json);
  }
}

Future<String> generateRulesJson({
  bool pretty = true,
  bool includeSetInfo = true,
}) async {
  registerLintRules();
  var fixStatusMap = readFixStatusMap();
  return await getMachineListing(Registry.ruleRegistry,
      fixStatusMap: fixStatusMap, sinceInfo: sinceMap, pretty: pretty);
}

Future<String> getMachineListing(
  Iterable<LintRule> ruleRegistry, {
  Map<String, String>? fixStatusMap,
  bool pretty = true,
  bool includeSetInfo = true,
  Map<String, SinceInfo>? sinceInfo,
}) async {
  var rules = List<LintRule>.of(ruleRegistry, growable: false)
    ..sort((a, b) => a.name.compareTo(b.name));
  var encoder = pretty ? JsonEncoder.withIndent('  ') : JsonEncoder();
  fixStatusMap ??= {};

  var (
    coreRules: coreRules,
    recommendedRules: recommendedRules,
    flutterRules: flutterRules
  ) = await _fetchSetRules(fetch: includeSetInfo);

  var categories = messagesYaml.categoryMappings;
  var deprecatedDetails = messagesYaml.deprecatedDetails;
  var json = encoder.convert([
    for (var rule in rules.where((rule) => !rule.state.isInternal))
      {
        'name': rule.name,
        'description': rule.description,
        'categories': categories[rule.name]?.toList() ?? [],
        'state': rule.state.label,
        'incompatible': rule.incompatibleRules,
        'sets': [
          if (coreRules.contains(rule.name)) 'core',
          if (recommendedRules.contains(rule.name)) 'recommended',
          if (flutterRules.contains(rule.name)) 'flutter',
        ],
        'fixStatus':
            fixStatusMap[rule.lintCodes.first.uniqueName] ?? 'unregistered',
        'details': deprecatedDetails[rule.name],
        if (sinceInfo != null)
          'sinceDartSdk': sinceInfo[rule.name]?.sinceDartSdk ?? 'Unreleased',
      }
  ]);
  return json;
}

File machineJsonFile() {
  var outPath = pathRelativeToPackageRoot(['tool', 'machine', 'rules.json']);
  return File(outPath);
}

Map<String, String> readFixStatusMap() {
  var statusFilePath = pathRelativeToPkgDir([
    'analysis_server',
    'lib',
    'src',
    'services',
    'correction',
    'error_fix_status.yaml'
  ]);
  var contents = File(statusFilePath).readAsStringSync();

  var yaml = loadYamlNode(contents) as YamlMap;
  return <String, String>{
    for (var MapEntry(key: String code, :YamlMap value) in yaml.entries)
      if (code.startsWith('LintCode.')) code: value['status'] as String,
  };
}

Future<
    ({
      Set<String> coreRules,
      Set<String> recommendedRules,
      Set<String> flutterRules,
    })> _fetchSetRules({bool fetch = true}) async {
  if (!fetch) {
    return const (
      coreRules: <String>{},
      recommendedRules: <String>{},
      flutterRules: <String>{},
    );
  }

  var coreRules = {...await score_utils.coreRules};
  var recommendedRules = {...coreRules, ...await score_utils.recommendedRules};
  var flutterRules = {...recommendedRules, ...await score_utils.flutterRules};

  return (
    coreRules: coreRules,
    recommendedRules: recommendedRules,
    flutterRules: flutterRules,
  );
}
