import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/local_model_config.dart';
import '../models/generation_event.dart';
import 'model_provider.dart';

// Only locally authored guidance may cross the transport error boundary.
class _SafeModelFailure extends StateError {
  _SafeModelFailure(super.message);
}

/// Token streaming with bounded startup, inactivity and total request duration.
class LocalModelProvider implements StreamingModelProvider {
  LocalModelProvider(
    this.config, {
    http.Client? client,
    this.maxTokens = 256,
    this.idleTimeout = const Duration(seconds: 30),
    this.totalTimeout = const Duration(minutes: 3),
  }) : _client = client ?? http.Client();
  final LocalModelConfig config;
  final int maxTokens;
  final Duration idleTimeout, totalTimeout;
  final http.Client _client;
  bool _cancelled = false;
  @override
  Stream<String> generate(String prompt) async* {
    await for (final event in generateEvents(prompt)) {
      if (event.text.isNotEmpty) yield event.text;
    }
  }

  @override
  Stream<GenerationEvent> generateEvents(String prompt) {
    late final StreamController<GenerationEvent> output;
    Timer? deadline;
    var finished = false;

    void stopListening() {
      if (!finished) {
        _cancelled = true;
        _client.close();
      }
      finished = true;
      deadline?.cancel();
      // Keep the upstream error handler until pending reads unwind after client
      // closure. Cancelling its async generator during an awaited read can leave
      // late transport errors unhandled. Caller completion does not wait for it.
    }

    output = StreamController<GenerationEvent>(
      onListen: () {
        deadline = Timer(totalTimeout, () {
          if (finished) return;
          finished = true;
          _cancelled = true;
          _client.close();
          output.addError(
            TimeoutException(
              'Local model exceeded the total generation limit.',
            ),
          );
          unawaited(output.close());
        });
        _generateEvents(prompt).listen(
          (event) {
            if (!finished) output.add(event);
          },
          onError: (Object error, StackTrace stack) {
            if (finished) return;
            // Raw errors can include echoed prompts, response bodies or URLs.
            final safe = error is _SafeModelFailure
                ? error
                : error is TimeoutException
                ? TimeoutException(
                    'Local model timed out. Check the runtime and retry.',
                  )
                : StateError(
                    'Local model request failed. Check the local server, model ID and streaming API, then retry.',
                  );
            output.addError(safe);
          },
          onDone: () {
            if (finished) return;
            finished = true;
            deadline?.cancel();
            unawaited(output.close());
          },
        );
      },
      onCancel: stopListening,
    );
    return output.stream;
  }

  Stream<GenerationEvent> _generateEvents(String prompt) async* {
    if (_cancelled) throw _SafeModelFailure('Provider has been cancelled.');
    yield const GenerationEvent.phase(GenerationPhase.thinking);
    final request =
        http.Request('POST', config.endpoint.resolve('chat/completions'))
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode({
            'model': config.model,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'stream': true,
            'max_tokens': maxTokens,
            'temperature': 0.2,
          });
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (_cancelled) return;
    if (response.statusCode != 200) {
      // Close the response stream even on a rejected request.
      await response.stream.take(1).drain<void>();
      throw _SafeModelFailure(
        response.statusCode == 429
            ? 'The local model is busy. Cancel or wait for the current request.'
            : 'Local model request failed (HTTP ${response.statusCode}). Check the model ID and streaming runtime.',
      );
    }
    if (!(response.headers['content-type'] ?? '').contains(
      'text/event-stream',
    )) {
      // Compatibility with older non-streaming providers, without fake tokenization.
      final body = await response.stream.bytesToString().timeout(idleTimeout);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final choice = (data['choices'] as List).first as Map;
      if (choice['finish_reason'] == 'length') {
        throw _SafeModelFailure(
          'Model output was truncated. Try a smaller instruction.',
        );
      }
      final content = (choice['message'] as Map)['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw _SafeModelFailure('Local model returned no text.');
      }
      if (!_cancelled) yield GenerationEvent.text(content);
      return;
    }
    var eventName = 'message';
    final dataLines = <String>[];
    var receivedText = false;
    await for (final line
        in response.stream
            .timeout(idleTimeout)
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (_cancelled) return;
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
        continue;
      }
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
        continue;
      }
      if (line.isNotEmpty || dataLines.isEmpty) continue;
      final payload = dataLines.join('\n');
      dataLines.clear();
      final name = eventName;
      eventName = 'message';
      if (payload == '[DONE]') {
        if (!receivedText) {
          throw _SafeModelFailure('Local model returned no text.');
        }
        return;
      }
      final data = jsonDecode(payload) as Map<String, dynamic>;
      if (name == 'error' || data.containsKey('error')) {
        throw _SafeModelFailure(
          'Local generation failed. Check the runtime and retry.',
        );
      }
      if (name == 'ping') continue;
      if (name == 'status') {
        if (data['phase'] == 'thinking') {
          yield const GenerationEvent.phase(GenerationPhase.thinking);
        }
        if (data['phase'] == 'writing') {
          yield const GenerationEvent.phase(GenerationPhase.writing);
        }
        continue;
      }
      final choices = data['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first as Map;
      if (choice['finish_reason'] == 'length') {
        throw _SafeModelFailure(
          'Model output was truncated. Try a smaller instruction.',
        );
      }
      final content = (choice['delta'] as Map?)?['content'];
      if (content is String && content.isNotEmpty) {
        receivedText = true;
        yield GenerationEvent.text(content);
      }
    }
    if (!_cancelled) {
      throw _SafeModelFailure(
        'The model stream ended before completion. Your application was not changed.',
      );
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _client.close();
  }
}
