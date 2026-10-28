// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'app_definition.dart';
import 'chat_message.dart';
import 'portable_project_archive.dart';
import 'requirements_board.dart';

/// Rewrites authored text only. Identifiers, links, revisions, timestamps,
/// status and historical consent retain their original meaning.
class PortableExportRedaction {
  PortableExportRedaction._(this.archive, this.matches);

  final PortableProjectArchive archive;
  final int matches;

  static PortableExportRedaction apply(
    PortableProjectArchive source,
    String literal,
  ) {
    if (literal.isEmpty ||
        literal.length > PortableProjectArchive.maxMessageCharacters) {
      throw const FormatException('Select nonempty literal text to redact.');
    }
    var matches = 0;
    String redact(String value) {
      final parts = value.split(literal);
      matches += parts.length - 1;
      return parts.join('[redacted]');
    }

    List<ChatMessage> messages(List<ChatMessage> values) => values
        .map((m) => ChatMessage(role: m.role, content: redact(m.content)))
        .toList();
    final project = source.project;
    final prototype = source.prototype;
    final decision = source.decision;
    final candidate = PortableProjectArchive(
      project: project == null
          ? null
          : PortableProjectIntent(
              description: redact(project.description),
              type: redact(project.type),
              platforms: project.platforms.map(redact).toList(),
            ),
      requirements: RequirementsBoard(
        revision: source.requirements.revision,
        requirements: source.requirements.requirements
            .map(
              (r) => ProjectRequirement(
                id: r.id,
                title: redact(r.title),
                acceptance: redact(r.acceptance),
                checks: [
                  for (final c in r.checks)
                    AcceptanceCheckDefinition(
                      id: c.id,
                      type: c.type,
                      expectation: redact(c.expectation),
                      // Redaction changes literal selectors: remove the target
                      // instead of retaining sensitive text or changing meaning.
                      target:
                          c.target == null ||
                              redact(c.target!.file) != c.target!.file ||
                              redact(c.target!.name) != c.target!.name
                          ? null
                          : c.target,
                    ),
                ],
              ),
            )
            .toList(),
        tasks: source.requirements.tasks
            .map(
              (t) => DevelopmentTask(
                id: t.id,
                requirementId: t.requirementId,
                title: redact(t.title),
                dependencies: t.dependencies,
                status: t.status,
              ),
            )
            .toList(),
      ),
      prototype: prototype == null
          ? null
          : PortablePrototype(
              revision: prototype.revision,
              messages: messages(prototype.messages),
              definition: AppDefinition(
                title: redact(prototype.definition.title),
                theme: prototype.definition.theme,
                elements: prototype.definition.elements
                    .map(
                      (e) => AppElement(
                        id: e.id,
                        kind: e.kind,
                        label: redact(e.label),
                        items: e.items.map(redact).toList(),
                        completed: e.completed,
                        action: e.action,
                        target: e.target,
                        value: redact(e.value),
                      ),
                    )
                    .toList(),
              ),
            ),
      decision: decision == null
          ? null
          : PortablePlanDecision(
              content: redact(decision.content),
              approved: decision.approved,
              recordedAt: decision.recordedAt,
            ),
      revisions: source.revisions,
      messages: messages(source.messages),
    );
    if (matches == 0) {
      throw const FormatException('No matching authored text.');
    }
    // Decode with the same strict schema/size checks used for restoration.
    return PortableExportRedaction._(
      PortableProjectArchive.decode(candidate.encode()),
      matches,
    );
  }
}
