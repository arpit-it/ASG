class LocalModelConfig {
  const LocalModelConfig({
    this.baseUrl = 'http://127.0.0.1:8765/v1',
    this.model = 'Qwen3.5-9B',
    this.chatOutputTokens = defaultChatOutputTokens,
  });
  static const defaultChatOutputTokens = 1536;
  static const chatTokenOptions = [512, 1024, 1536, 2048];
  final int chatOutputTokens;
  final String baseUrl, model;

  void validateChatLimit() {
    if (!chatTokenOptions.contains(chatOutputTokens)) {
      throw const FormatException(
        'Choose a supported chat output-token limit.',
      );
    }
  }

  Uri get endpoint {
    final uri = Uri.parse(baseUrl);
    if (uri.scheme != 'http' ||
        !['localhost', '127.0.0.1', '::1', '10.0.2.2'].contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Use a local HTTP endpoint, for example http://127.0.0.1:8765/v1 (10.0.2.2 on Android Emulator).',
      );
    }
    if (model.trim().isEmpty) {
      throw const FormatException(
        'Enter the exact model identifier reported by your server.',
      );
    }
    return uri.replace(path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/');
  }
}
