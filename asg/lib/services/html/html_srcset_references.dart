// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Read-only candidate observations, not responsive image selection or decoding.
/// Tokenization follows the HTML splitting/descriptor states so commas inside
/// URLs (notably data URLs) and parenthesized descriptors are not separators.
/// https://html.spec.whatwg.org/multipage/images.html#parse-a-srcset-attribute
void inspectSrcsetReferences(
  String input, {
  required void Function(String) onReference,
  required void Function(String) onDiagnostic,
}) {
  var position = 0;
  while (position < input.length) {
    var strayComma = false;
    while (position < input.length &&
        (_space(input.codeUnitAt(position)) || input[position] == ',')) {
      if (input[position] == ',') strayComma = true;
      position++;
    }
    if (strayComma) onDiagnostic('Unexpected candidate separator.');
    if (position == input.length) break;
    final start = position;
    while (position < input.length && !_space(input.codeUnitAt(position))) {
      position++;
    }
    var url = input.substring(start, position);
    final descriptors = <String>[];
    if (url.endsWith(',')) {
      final originalLength = url.length;
      var end = originalLength;
      while (end > 0 && url[end - 1] == ',') {
        end--;
      }
      url = url.substring(0, end);
      if (originalLength - url.length > 1) {
        onDiagnostic('Repeated trailing candidate separators.');
      }
    } else {
      var descriptor = StringBuffer();
      var inParens = false;
      while (position < input.length) {
        final character = input[position++];
        if (inParens) {
          descriptor.write(character);
          if (character == ')') inParens = false;
        } else if (character == ',') {
          break;
        } else if (_space(character.codeUnitAt(0))) {
          if (descriptor.isNotEmpty) {
            descriptors.add(descriptor.toString());
            descriptor = StringBuffer();
          }
        } else {
          descriptor.write(character);
          if (character == '(') inParens = true;
        }
      }
      if (descriptor.isNotEmpty) descriptors.add(descriptor.toString());
    }
    if (_supportedDescriptors(descriptors)) {
      onReference(url);
    } else {
      onDiagnostic(
        'Malformed or unsupported candidate descriptors; candidate URL not checked.',
      );
    }
  }
}

bool _space(int character) =>
    character == 0x20 ||
    (character >= 0x09 && character <= 0x0d && character != 0x0b);

final _width = RegExp(r'^[0-9]+w$');
final _density = RegExp(
  r'^-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?x$',
);

bool _supportedDescriptors(List<String> descriptors) {
  if (descriptors.isEmpty) return true;
  // Future-compatible h and multiple descriptors are deliberately unverified.
  if (descriptors.length != 1) return false;
  final descriptor = descriptors.single;
  if (_width.hasMatch(descriptor)) {
    return descriptor
        .substring(0, descriptor.length - 1)
        .contains(RegExp('[1-9]'));
  }
  if (!_density.hasMatch(descriptor)) return false;
  final density = double.tryParse(
    descriptor.substring(0, descriptor.length - 1),
  );
  return density != null && density.isFinite && density >= 0;
}
