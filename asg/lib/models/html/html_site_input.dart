// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Bounded plain text for the fixed static-site template, never HTML or code.
class HtmlSiteInput {
  HtmlSiteInput({required String title, required String description})
    : title = _text(title, 'title', 120),
      description = _text(description, 'description', 2000);

  final String title, description;

  static String _text(String value, String name, int limit) {
    final text = value.trim();
    if (text.isEmpty ||
        text.length > limit ||
        text.runes.any(
          (rune) =>
              (rune < 32 && rune != 10 && rune != 13 && rune != 9) ||
              rune == 127,
        )) {
      throw FormatException(
        'Invalid site $name. Use 1–$limit plain-text characters.',
      );
    }
    return text;
  }
}
