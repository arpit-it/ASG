// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'structured_proposal_json.dart';

/// A validated saved collector report. Its identities are supplied by its author,
/// not measured against this application, current files, hardware or model.
class ProductAcceptanceReport {
  ProductAcceptanceReport._(
    this.generatedAt,
    this.manifestSha256,
    this.identity,
    this.cells,
  );
  final String generatedAt, manifestSha256;
  final Map<String, String> identity;
  final List<ProductAcceptanceCell> cells;
  static const targets = ['macos', 'web', 'android', 'ios', 'windows', 'linux'];
  static const kinds = [
    'fixture',
    'build',
    'launch',
    'liveInference',
    'generatedOutput',
    'manual',
  ];
  static const statuses = [
    'passed',
    'failed',
    'skipped',
    'unavailable',
    'missing',
    'stale',
  ];

  static ProductAcceptanceReport parse(String source) {
    _need(
      source.length <= 1024 * 1024 && utf8.encode(source).length <= 1024 * 1024,
    );
    final decoded = jsonDecode(source);
    rejectDuplicateJsonMembers(source);
    final root = _object(decoded, [
      'schemaVersion',
      'generatedAt',
      'manifestSha256',
      'identity',
      'claim',
      'cells',
    ]);
    _need(
      root['schemaVersion'] == 1 &&
          root['schemaVersion'] is int &&
          root['claim'] == 'saved-evidence-only',
    );
    final generated = _utc(root['generatedAt']);
    _need(!DateTime.parse(generated).isAfter(DateTime.now().toUtc()));
    final manifest = _digest(root['manifestSha256']);
    final current = _identity(root['identity']);
    final rawCells = root['cells'];
    _need(rawCells is List && rawCells.isNotEmpty && rawCells.length <= 12288);
    final cells = <ProductAcceptanceCell>[];
    final groups = <String, List<ProductAcceptanceCell>>{};
    for (final raw in rawCells as List) {
      final c = _object(raw, [
        'scenarioId',
        'checkId',
        'kind',
        'requirementIds',
        'target',
        'status',
        'currentPass',
        'savedEvidence',
      ]);
      final scenario = _id(c['scenarioId']), check = _id(c['checkId']);
      final kind = _choice(c['kind'], kinds),
          target = _choice(c['target'], targets);
      final status = _choice(c['status'], statuses);
      final requirements = c['requirementIds'];
      _need(
        requirements is List &&
            requirements.isNotEmpty &&
            requirements.length <= 32,
      );
      final ids = <String>[];
      for (final id in requirements as List) {
        _need(id is String && RegExp(r'^F[0-9]{2,4}$').hasMatch(id));
        ids.add(id as String);
      }
      _need(
        ids.toSet().length == ids.length &&
            c['currentPass'] == (status == 'passed'),
      );
      String? observed, savedStatus, savedManifest;
      Map<String, String>? savedIdentity;
      final artifacts = <String>[];
      if (c['savedEvidence'] == null) {
        _need(status == 'missing' || status == 'unavailable');
      } else {
        final saved = _object(c['savedEvidence'], [
          'scenarioId',
          'checkId',
          'target',
          'status',
          'observedAt',
          'identity',
          'manifestSha256',
          'artifactSha256',
        ]);
        _need(
          saved['scenarioId'] == scenario &&
              saved['checkId'] == check &&
              saved['target'] == target,
        );
        savedStatus = _choice(saved['status'], statuses.take(4).toList());
        observed = _utc(saved['observedAt']);
        _need(observed.compareTo(generated) <= 0);
        savedIdentity = _identity(saved['identity']);
        savedManifest = _digest(saved['manifestSha256']);
        final same =
            current.keys.every((k) => current[k] == savedIdentity![k]) &&
            savedManifest == manifest;
        _need(status == (same ? savedStatus : 'stale'));
        final hashes = saved['artifactSha256'];
        _need(hashes is List && hashes.length <= 16);
        for (final hash in hashes as List) {
          artifacts.add(_digest(hash));
        }
      }
      final cell = ProductAcceptanceCell(
        scenario,
        check,
        kind,
        List.unmodifiable(ids),
        target,
        status,
        observed,
        savedStatus,
        savedIdentity,
        savedManifest,
        List.unmodifiable(artifacts),
      );
      cells.add(cell);
      groups.putIfAbsent('$scenario/$check', () => []).add(cell);
    }
    for (final group in groups.values) {
      _need(
        group.length == 6 && group.map((c) => c.target).toSet().length == 6,
      );
      _need(
        group.every(
          (c) =>
              c.kind == group.first.kind &&
              c.requirementIds.join(',') ==
                  group.first.requirementIds.join(','),
        ),
      );
    }
    return ProductAcceptanceReport._(
      generated,
      manifest,
      current,
      List.unmodifiable(cells),
    );
  }
}

class ProductAcceptanceCell {
  const ProductAcceptanceCell(
    this.scenarioId,
    this.checkId,
    this.kind,
    this.requirementIds,
    this.target,
    this.status,
    this.observedAt,
    this.savedStatus,
    this.savedIdentity,
    this.savedManifestSha256,
    this.artifactSha256,
  );
  final String scenarioId, checkId, kind, target, status;
  final List<String> requirementIds, artifactSha256;
  final String? observedAt, savedStatus, savedManifestSha256;
  final Map<String, String>? savedIdentity;
}

void _need(bool condition) {
  if (!condition) {
    throw const FormatException('Invalid saved acceptance report.');
  }
}

Map<String, Object?> _object(Object? value, List<String> keys) {
  _need(value is Map<String, Object?>);
  final map = value as Map<String, Object?>;
  _need(map.length == keys.length && keys.every(map.containsKey));
  return map;
}

String _choice(Object? value, List<String> options) {
  _need(value is String && options.contains(value));
  return value as String;
}

String _id(Object? value) {
  _need(value is String && RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(value));
  return value as String;
}

String _digest(Object? value, [int length = 64]) {
  _need(value is String && RegExp('^[0-9a-f]{$length}\$').hasMatch(value));
  return value as String;
}

String _utc(Object? value) {
  _need(
    value is String &&
        RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(value),
  );
  final parsed = DateTime.tryParse(value as String);
  _need(
    parsed != null && '${parsed.toIso8601String().split('.').first}Z' == value,
  );
  return value;
}

Map<String, String> _identity(Object? value) {
  const digests = [
    'requirementSha256',
    'inputSha256',
    'configurationSha256',
    'modelSha256',
    'deviceSha256',
  ];
  const versions = ['sdkVersion', 'runtimeVersion', 'browserVersion'];
  final map = _object(value, [
    'sourceRevision',
    ...digests,
    ...versions,
    'backend',
    'host',
  ]);
  final result = <String, String>{
    'sourceRevision': _digest(map['sourceRevision'], 40),
  };
  for (final key in digests) {
    result[key] = _digest(map[key]);
  }
  for (final key in versions) {
    final v = map[key];
    _need(
      v is String &&
          RegExp(r'^(?:unavailable|[0-9]{1,4}(?:\.[0-9]{1,4}){0,3})$')
              .hasMatch(v),
    );
    result[key] = v as String;
  }
  result['backend'] = _choice(map['backend'], [
    'mlx',
    'torch-mps',
    'none',
    'unavailable',
  ]);
  result['host'] = _choice(map['host'], ProductAcceptanceReport.targets);
  return Map.unmodifiable(result);
}
