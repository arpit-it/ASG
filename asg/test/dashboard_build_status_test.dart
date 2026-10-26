import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/dashboard_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/project_build_summary.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/project_build_summary_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/views/dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

StudioProject project(String id, {String description = 'Requirements'}) =>
    StudioProject(
      id: id,
      name: id,
      description: description,
      type: 'Flutter',
      platforms: const ['Web'],
      location: '',
    );
const definition = AppDefinition(
  title: 'App',
  theme: 'green',
  elements: [
    AppElement(
      id: 'count',
      kind: ElementKind.counter,
      label: 'Count',
      value: '1',
    ),
  ],
);
GeneratedProject outcome(
  StudioProject p,
  SourceGenerationPhase phase, {
  Map<String, String>? sources,
}) => GeneratedProject(
  directory: '/unused',
  sdk: '/unused/sdk',
  python: 'python3',
  sources: sources ?? GenerationInput(p, definition).fingerprints,
  phase: phase,
  steps: phase == SourceGenerationPhase.ready
      ? [
          for (final op in ['resolve', 'analyze', 'test', 'build'])
            GenerationStep(
              operation: op,
              exitCode: 0,
              output: 'saved evidence fixture',
            ),
        ]
      : [],
  outputs: phase == SourceGenerationPhase.ready
      ? {'index.html': '0' * 64, 'main.dart.js': '0' * 64}
      : {},
);

class Records implements RecordStorage {
  final data = <String, String>{};
  int writes = 0;
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    data[key] = value;
    return true;
  }
}

void main() {
  late Records records;
  late ProjectBuildSummaryStore summaries;
  final p = project('Example');
  setUp(() {
    records = Records();
    summaries = ProjectBuildSummaryStore(records);
  });
  Future<void> save(StudioProject item, SourceGenerationPhase phase) async {
    await ApplicationStore(records)
        .save(item.id, const ApplicationSnapshot(definition, [], 2));
    await SourceGenerationStore(records).save(item.id, outcome(item, phase));
  }

  test('no history is not a build and summaries never write starter data', () {
    expect(summaries.load(p).state, ProjectBuildState.none);
    expect(summaries.load(p).snapshot, GeneratedSnapshotStatus.none);
    expect(records.writes, 0);
    expect(records.data, isEmpty);
  });
  test(
    'all persisted generation phases survive reopening with current inputs',
    () async {
      for (final pair in {
        SourceGenerationPhase.generated: ProjectBuildState.generated,
        SourceGenerationPhase.verifying: ProjectBuildState.unfinished,
        SourceGenerationPhase.ready: ProjectBuildState.passed,
        SourceGenerationPhase.failed: ProjectBuildState.failed,
      }.entries) {
        await save(p, pair.key);
        final before = Map.of(records.data);
        final writes = records.writes;
        final result = ProjectBuildSummaryStore(records).load(p);
        expect(result.state, pair.value);
        expect(result.snapshot, GeneratedSnapshotStatus.current);
        expect(records.data, before);
        expect(records.writes, writes);
      }
    },
  );
  test(
    'requirements and persisted interaction changes identify earlier inputs',
    () async {
      await save(p, SourceGenerationPhase.ready);
      expect(
        summaries.load(project(p.id, description: 'Revised')).snapshot,
        GeneratedSnapshotStatus.outdated,
      );
      await ApplicationStore(records).save(
        p.id,
        const ApplicationSnapshot(
          AppDefinition(
            title: 'App',
            theme: 'green',
            elements: [
              AppElement(
                id: 'count',
                kind: ElementKind.counter,
                label: 'Count',
                value: '2',
              ),
            ],
          ),
          [],
          2,
        ),
      );
      expect(summaries.load(p).snapshot, GeneratedSnapshotStatus.outdated);
      expect(summaries.load(p).state, ProjectBuildState.passed);
    },
  );
  test(
    'unknown identity and corrupt application retain saved build evidence',
    () async {
      await save(p, SourceGenerationPhase.ready);
      records.data['studio.application.v1.${p.id}'] = 'broken';
      expect(summaries.load(p).state, ProjectBuildState.passed);
      expect(summaries.load(p).snapshot, GeneratedSnapshotStatus.unknown);
      await ApplicationStore(records)
          .save(p.id, const ApplicationSnapshot(definition, [], 2));
      await SourceGenerationStore(records).save(
        p.id,
        outcome(
          p,
          SourceGenerationPhase.ready,
          sources: {'lib/main.dart': '0' * 64},
        ),
      );
      expect(summaries.load(p).snapshot, GeneratedSnapshotStatus.unknown);
    },
  );
  test(
    'corrupt or forged successful history cannot claim successful verification',
    () async {
      records.data['studio.generation.v1.${p.id}'] = 'broken';
      expect(summaries.load(p).state, ProjectBuildState.unavailable);
      // An unverified record relabeled ready lacks required successful steps/output.
      records.data.remove('studio.generation.v1.${p.id}');
      // Invalid terminal records are refused before publication; a forged raw
      // record still fails closed when read.
      final forged = outcome(
        p,
        SourceGenerationPhase.generated,
      ).copy(phase: SourceGenerationPhase.ready);
      await expectLater(
        SourceGenerationStore(records).save(p.id, forged),
        throwsFormatException,
      );
      records.data['studio.generation.v1.${p.id}'] = jsonEncode(
        forged.toJson(),
      );
      expect(summaries.load(p).state, ProjectBuildState.unavailable);
      expect(summaries.load(project('Other')).state, ProjectBuildState.none);
    },
  );
  test(
    'controller keeps mixed projects searchable and refreshes saved outcomes',
    () async {
      final other = project('Other');
      final store = StudioStore(records);
      await store.save([p, other]);
      await save(p, SourceGenerationPhase.ready);
      records.data['studio.generation.v1.Other'] = 'broken';
      final c = DashboardController(store, [p, other]);
      expect(c.buildSummary(p).state, ProjectBuildState.passed);
      expect(c.buildSummary(other).state, ProjectBuildState.unavailable);
      c.search('other');
      expect(c.filtered.single.id, 'Other');
      await save(p, SourceGenerationPhase.failed);
      c.refreshBuildStatus();
      expect(c.filtered.single.id, 'Other');
      expect(c.buildSummary(p).state, ProjectBuildState.failed);
      c.dispose();
    },
  );
  testWidgets(
    'mixed dashboard status supports narrow scaled layout and selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final other = project('Other');
      final store = StudioStore(records);
      await store.save([p, other]);
      await save(p, SourceGenerationPhase.ready);
      records.data['studio.generation.v1.Other'] = 'broken';
      StudioProject? selected;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Dashboard(
            store: store,
            initialProjects: [p, other],
            onSelect: (value) => selected = value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byType(Dashboard),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Saved web verification passed'),
        250,
        scrollable: scrollable,
      );
      expect(find.text('Matches current app and requirements'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Saved build history unreadable'),
        200,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Other'));
      expect(selected!.id, 'Other');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('returning from project refreshes saved dashboard status', (
    tester,
  ) async {
    final store = StudioStore(records);
    await store.save([p]);
    await save(p, SourceGenerationPhase.generated);
    await tester.pumpWidget(
      MaterialApp(
        home: Dashboard(store: store, initialProjects: [p]),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(Dashboard),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text(p.name),
      200,
      scrollable: scrollable,
    );
    await tester.tap(find.text(p.name));
    await tester.pumpAndSettle();
    await save(p, SourceGenerationPhase.ready);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Saved web verification passed'), findsOneWidget);
    expect(find.textContaining('No builds yet'), findsNothing);
    expect(find.textContaining('not connected.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'real database reopen isolates damaged project records without replacing bytes',
    (tester) async {
      late Directory directory;
      late Database db;
      late StudioDatabase restored;
      late Map<String, String> before;
      final raw = StoreRef<String, String>('records');
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('asg-dashboard-');
        final path = '${directory.path}/studio.db';
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        db = await databaseFactoryIo.openDatabase(
          path,
          mode: DatabaseMode.create,
        );

        final native = await StudioDatabase.migrate(db, prefs);
        final badHistory = project('Bad history');
        final badApp = project('Bad app');
        await StudioStore(native).save([p, badHistory, badApp]);
        for (final item in [p, badApp]) {
          await ApplicationStore(native)
              .save(item.id, const ApplicationSnapshot(definition, [], 2));
          await SourceGenerationStore(native)
              .save(item.id, outcome(item, SourceGenerationPhase.ready));
        }
        final badGenerationKey = 'studio.generation.v1.${badHistory.id}';
        final badAppKey = 'studio.application.v1.${badApp.id}';
        await raw.record(badGenerationKey).put(db, 'broken generation bytes');
        await raw.record(badAppKey).put(db, 'broken application bytes');
        before = {for (final r in await raw.find(db)) r.key: r.value};
        await db.close();
        db = await databaseFactoryIo.openDatabase(
          path,
          mode: DatabaseMode.create,
        );
        restored = await StudioDatabase.migrate(db, prefs);
        final service = ProjectBuildSummaryStore(restored);
        expect(service.load(p).state, ProjectBuildState.passed);
        expect(service.load(p).snapshot, GeneratedSnapshotStatus.current);
        expect(service.load(badHistory).state, ProjectBuildState.unavailable);
        expect(service.load(badApp).state, ProjectBuildState.passed);
        expect(service.load(badApp).snapshot, GeneratedSnapshotStatus.unknown);
        expect(
          () => ApplicationStore(restored).load(badApp),
          throwsFormatException,
        );
        await expectLater(
          restored.setString(badAppKey, 'still invalid'),
          throwsFormatException,
        );
        expect(ApplicationStore(restored).load(p).revision, 2);
      });
      try {
        StudioProject? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Dashboard(
              store: StudioStore(restored),
              initialProjects: StudioStore(restored).load(),
              onSelect: (value) => selected = value,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(
              of: find.byType(Dashboard),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text(p.name),
          200,
          scrollable: scrollable,
        );
        await tester.tap(find.text(p.name));
        expect(selected!.id, p.id);
        await tester.scrollUntilVisible(
          find.text('Saved build history unreadable'),
          200,
          scrollable: scrollable,
        );
        expect(find.text('Saved build history unreadable'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Input match unavailable'),
          200,
          scrollable: scrollable,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          expect({for (final r in await raw.find(db)) r.key: r.value}, before);
        });
      } finally {
        await tester.runAsync(() async {
          await db.close();
          await directory.delete(recursive: true);
        });
      }
    },
  );
}
