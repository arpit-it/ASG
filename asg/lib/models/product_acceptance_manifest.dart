// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'product_acceptance_report.dart';

/// The specification shipped with this app, not a measurement of live state.
class ProductAcceptanceManifest {
  ProductAcceptanceManifest._(this.sha256Digest, this.checks);
  final String sha256Digest;
  final List<ProductAcceptanceExpectedCheck> checks;

  factory ProductAcceptanceManifest.parse(String source) {
    final root = jsonDecode(source) as Map<String, dynamic>;
    if (root['schemaVersion'] != 1) throw const FormatException();
    final checks = <ProductAcceptanceExpectedCheck>[];
    for (final scenario in root['scenarios'] as List) {
      for (final check in scenario['checks'] as List) {
        for (final target
            in (check['targets'] ?? scenario['targets']) as List) {
          checks.add(
            ProductAcceptanceExpectedCheck(
              scenario['id'] as String,
              check['id'] as String,
              target as String,
              check['kind'] as String,
              List<String>.unmodifiable(scenario['requirementIds'] as List),
            ),
          );
        }
      }
    }
    return ProductAcceptanceManifest._(
      sha256.convert(utf8.encode(jsonEncode(_canonical(root)))).toString(),
      List.unmodifiable(checks),
    );
  }

  ProductAcceptanceComparison compare(ProductAcceptanceReport report) {
    final absent = <String>[];
    final mismatched = <String>[];
    for (final expected in checks) {
      final matches = report.cells.where(
        (cell) =>
            cell.scenarioId == expected.scenarioId &&
            cell.checkId == expected.checkId &&
            cell.target == expected.target,
      );
      if (matches.isEmpty) {
        absent.add(expected.label);
      } else {
        final cell = matches.single;
        if (cell.kind != expected.kind ||
            cell.requirementIds.length != expected.requirementIds.length ||
            !cell.requirementIds.toSet().containsAll(expected.requirementIds) ||
            (cell.status == 'unavailable' && cell.savedStatus == null)) {
          mismatched.add(expected.label);
        }
      }
    }
    return ProductAcceptanceComparison(
      report.manifestSha256 == sha256Digest,
      checks.length,
      List.unmodifiable(absent),
      List.unmodifiable(mismatched),
    );
  }
}

Object? _canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

class ProductAcceptanceExpectedCheck {
  const ProductAcceptanceExpectedCheck(
    this.scenarioId,
    this.checkId,
    this.target,
    this.kind,
    this.requirementIds,
  );
  final String scenarioId, checkId, target, kind;
  final List<String> requirementIds;
  String get label => '$scenarioId / $checkId / $target';
}

class ProductAcceptanceComparison {
  const ProductAcceptanceComparison(
    this.manifestMatches,
    this.configuredCount,
    this.absentChecks,
    this.mismatchedChecks,
  );
  final bool manifestMatches;
  final int configuredCount;
  final List<String> absentChecks, mismatchedChecks;
}
