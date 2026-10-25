import 'dart:convert';

/// Scan validated JSON, decoding keys so escaped spellings share an identity.
/// Strings are consumed as tokens: punctuation inside them cannot alter nesting.
void rejectDuplicateJsonMembers(String json) {
  final objects = <Set<String>>[];
  for (var i = 0; i < json.length; i++) {
    final char = json[i];
    if (char == '{') {
      objects.add(<String>{});
    } else if (char == '}') {
      objects.removeLast();
    } else if (char == '"') {
      final start = i;
      i++;
      while (json[i] != '"') {
        if (json[i] == r'\') i++;
        i++;
      }
      var next = i + 1;
      while (next < json.length && json[next].trim().isEmpty) {
        next++;
      }
      if (next < json.length && json[next] == ':') {
        final key = jsonDecode(json.substring(start, i + 1)) as String;
        if (!objects.last.add(key)) {
          throw const FormatException('Duplicate JSON member.');
        }
      }
    }
  }
}
