// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:typed_data';

enum SourceLineKind { context, removed, added }

/// An exact line token, including its original terminator (if any).
class SourceDiffLine {
  const SourceDiffLine(this.kind, this.text, this.beforeLine, this.afterLine);

  final SourceLineKind kind;
  final String text;
  final int? beforeLine, afterLine;

  String get display {
    final marker = switch (kind) {
      SourceLineKind.context => ' ',
      SourceLineKind.removed => '-',
      SourceLineKind.added => '+',
    };
    final ending = text.endsWith('\r\n')
        ? 'CRLF'
        : text.endsWith('\n')
        ? 'LF'
        : text.endsWith('\r')
        ? 'CR'
        : 'no newline';
    final content = text.replaceFirst(RegExp(r'[\r\n]+$'), '');
    return '$marker ${beforeLine ?? "·"} ${afterLine ?? "·"} | $content [$ending]';
  }
}

/// Bounded, deterministic review comparison; never a patch or write authority.
class SourceLineDiff {
  SourceLineDiff._(List<SourceDiffLine> lines, this.coarse)
    : lines = List.unmodifiable(lines);

  // Includes the sentinel row/column. Bounds allocation and comparison work.
  static const maxCells = 65536;
  final List<SourceDiffLine> lines;
  final bool coarse;

  String get display => lines.map((line) => line.display).join('\n');

  factory SourceLineDiff.compare(String before, String after) {
    List<String> split(String value) =>
        RegExp(r'[^\r\n]*(?:\r\n|\r|\n)|[^\r\n]+$')
            .allMatches(value)
            .map((match) => match.group(0)!)
            .toList();
    final old = split(before), next = split(after);
    var prefix = 0, suffix = 0;
    while (prefix < old.length &&
        prefix < next.length &&
        old[prefix] == next[prefix]) {
      prefix++;
    }
    while (suffix < old.length - prefix &&
        suffix < next.length - prefix &&
        old[old.length - suffix - 1] == next[next.length - suffix - 1]) {
      suffix++;
    }
    final rows = <SourceDiffLine>[];
    var i = 0, j = 0;
    void context() {
      rows.add(SourceDiffLine(SourceLineKind.context, old[i], i + 1, j + 1));
      i++;
      j++;
    }

    void remove() {
      rows.add(SourceDiffLine(SourceLineKind.removed, old[i], i + 1, null));
      i++;
    }

    void add() {
      rows.add(SourceDiffLine(SourceLineKind.added, next[j], null, j + 1));
      j++;
    }

    while (i < prefix) {
      context();
    }
    final n = old.length - suffix - prefix;
    final m = next.length - suffix - prefix;
    final coarse = n > 0 && m > 0 && (n + 1) * (m + 1) > maxCells;
    if (coarse || n == 0 || m == 0) {
      while (i < old.length - suffix) {
        remove();
      }
      while (j < next.length - suffix) {
        add();
      }
    } else {
      final width = m + 1;
      final lengths = Uint16List((n + 1) * width);
      for (var a = n - 1; a >= 0; a--) {
        for (var b = m - 1; b >= 0; b--) {
          final down = lengths[(a + 1) * width + b];
          final right = lengths[a * width + b + 1];
          lengths[a * width + b] = old[prefix + a] == next[prefix + b]
              ? 1 + lengths[(a + 1) * width + b + 1]
              : down >= right
              ? down
              : right;
        }
      }
      while (i < old.length - suffix && j < next.length - suffix) {
        if (old[i] == next[j]) {
          context();
        } else if (lengths[(i - prefix + 1) * width + j - prefix] >=
            lengths[(i - prefix) * width + j - prefix + 1]) {
          remove();
        } else {
          add();
        }
      }
      while (i < old.length - suffix) {
        remove();
      }
      while (j < next.length - suffix) {
        add();
      }
    }
    while (i < old.length) {
      context();
    }
    return SourceLineDiff._(rows, coarse);
  }
}
