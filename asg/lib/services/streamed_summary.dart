/// Extracts only human-readable summary text from an incomplete JSON response.
/// Partial edit JSON is never shown as prose or applied to the live application.
String streamedSummary(String buffer) {
  final match = RegExp(r'"summary"\s*:\s*"').firstMatch(buffer);
  if (match == null) return '';
  final output = StringBuffer();
  for (var index = match.end; index < buffer.length; index++) {
    final char = buffer[index];
    if (char == '"') break;
    if (char != '\\') {
      output.write(char);
      continue;
    }
    if (++index >= buffer.length) break;
    final escape = buffer[index];
    if (escape == 'u') {
      if (index + 4 >= buffer.length) break;
      final code = int.tryParse(
        buffer.substring(index + 1, index + 5),
        radix: 16,
      );
      if (code == null) break;
      output.writeCharCode(code);
      index += 4;
    } else {
      output.write(switch (escape) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '"' => '"',
        '\\' => '\\',
        '/' => '/',
        'b' => '\b',
        'f' => '\f',
        _ => '',
      });
    }
  }
  return output.toString();
}
