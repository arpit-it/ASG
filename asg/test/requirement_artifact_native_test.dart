// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/models/artifact_inspection.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'requirement_check_report_test.dart' show Records, prepare, project;

void main() {
  test(
    'report inspects real source/output changes without writes or execution',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'asg-report-inspection-',
      );
      addTearDown(() => root.delete(recursive: true));
      final directory = await root.resolveSymbolicLinks();
      final source = File('$directory/lib/main.dart');
      await source.parent.create(recursive: true);
      await source.writeAsString('fixture source');
      final output = File('$directory/build/web/index.html');
      await output.parent.create(recursive: true);
      await output.writeAsString('fixture output');
      await File('$directory/build/web/main.dart.js')
          .writeAsString('fixture js');
      final records = Records();
      final base = await prepare(records);
      final saved = GeneratedProject.fromJson(
        base.toJson()
          ..['directory'] = directory
          ..['sources'] = await NativeGenerationHost.fingerprints(
            directory,
            source: true,
          )
          ..['outputs'] = await NativeGenerationHost.fingerprints(
            output.parent.path,
            source: false,
          ),
      );
      await SourceGenerationStore(records).save('p', saved);
      final before = Map.of(records.data);
      final controller = RequirementCheckReportController(
        project,
        RequirementCheckReportStore(records),
      );
      addTearDown(controller.dispose);
      await controller.inspectArtifacts();
      expect(controller.inspection, ArtifactInspection.matching);
      expect(await source.readAsString(), 'fixture source');
      expect(await output.readAsString(), 'fixture output');
      await output.writeAsString('changed');
      await controller.inspectArtifacts();
      expect(controller.inspection, ArtifactInspection.stale);
      await output.delete();
      await controller.inspectArtifacts();
      expect(controller.inspection, ArtifactInspection.missing);
      expect(await source.readAsString(), 'fixture source');
      expect(records.data, before);
      expect(controller.report!.evidenceJson, isNot(contains(directory)));
    },
  );
}
