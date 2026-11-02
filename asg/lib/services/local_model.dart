// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/local_model_config.dart';
import '../models/generation_event.dart';
import '../models/model_runtime_metrics.dart';
import 'model_provider.dart';

// Only locally authored guidance may cross the transport error boundary.
class _SafeModelFailure extends StateError {
  _SafeModelFailure(super.message);
}

/// Token streaming with bounded startup, inactivity and total request duration.
class LocalModelProvider
    implements StreamingModelProvider, ModelMetricsProvider {
  LocalModelProvider(
    this.config, {
    http.Client? client,
    this.maxTokens = 256,
    this.idleTimeout = const Duration(seconds: 30),
    this.totalTimeout = const Duration(minutes: 3),
  }) : _client = client ?? http.Client();

  /// Bounds all response bytes before UTF-8, JSON and SSE line buffering.
  /// This is a transport safety ceiling, not a model token/context budget.
  static const maxResponseBytes = 1024 * 1024;

  final LocalModelConfig config;
  final int maxTokens;
  final Duration idleTimeout, totalTimeout;
  final http.Client _client;
  bool _cancelled = false;
  ModelRuntimeMetrics? _completedMetrics;
  @override
  ModelRuntimeMetrics? get completedMetrics => _completedMetrics;
  ModelRuntimeMetrics? _pendingMetrics;
  bool _transportSucceeded = false;
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
        _completedMetrics = null;
        _pendingMetrics = null;
        _transportSucceeded = false;
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
            _pendingMetrics = null;
            _transportSucceeded = false;
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
            if (!_cancelled && _transportSucceeded) {
              _completedMetrics = _pendingMetrics;
            }
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
          // A redirect must not change the selected connection or send prompts
          // to another destination. BrowserClient also uses fetch redirect:error.
          ..followRedirects = false
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
      if (response.statusCode >= 300 && response.statusCode < 400) {
        // Do not await an untrusted redirect body before refusing it.
        _client.close();
        throw _SafeModelFailure(
          'Local model redirects are refused. Check the selected local endpoint and retry.',
        );
      }
      // Close the response stream even on a rejected request.
      await response.stream.take(1).drain<void>();
      throw _SafeModelFailure(
        response.statusCode == 429
            ? 'The local model is busy. Cancel or wait for the current request.'
            : 'Local model request failed (HTTP ${response.statusCode}). Check the model ID and streaming runtime.',
      );
    }
    if ((response.contentLength ?? 0) > maxResponseBytes) {
      _responseTooLarge();
    }
    final bodyStream = _boundedResponse(response.stream);
    if (!(response.headers['content-type'] ?? '').contains(
      'text/event-stream',
    )) {
      // Compatibility with older non-streaming providers, without fake tokenization.
      final body = await http.ByteStream(bodyStream)
          .bytesToString()
          .timeout(idleTimeout);
      final data = jsonDecode(body) as Map<String, dynamic>;
      _validateResponseModel(data);
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
      if (!_cancelled) {
        _pendingMetrics = choice['finish_reason'] == 'stop'
            ? ModelRuntimeMetrics.parse(data['metrics'], outputLimit: maxTokens)
            : null;
        yield GenerationEvent.text(content);
        _transportSucceeded = true;
      }
      return;
    }
    var eventName = 'message';
    final dataLines = <String>[];
    var receivedText = false;
    await for (final line
        in bodyStream
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
        _transportSucceeded = true;
        return;
      }
      final data = jsonDecode(payload) as Map<String, dynamic>;
      if (name == 'error' || data.containsKey('error')) {
        throw _SafeModelFailure(
          'Local generation failed. Check the runtime and retry.',
        );
      }
      _validateResponseModel(data);
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
      // Only the terminal successful choice can provide telemetry. It remains
      // private until DONE; errors, truncation and EOF never publish it.
      if (choice['finish_reason'] == 'stop') {
        _pendingMetrics = ModelRuntimeMetrics.parse(
          data['metrics'],
          outputLimit: maxTokens,
        );
      } else if (content is String && content.isNotEmpty) {
        _pendingMetrics = null;
      }
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

  Stream<List<int>> _boundedResponse(Stream<List<int>> source) {
    var bytes = 0;
    return source.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          if (chunk.length > maxResponseBytes - bytes) {
            try {
              _responseTooLarge();
            } catch (error, stack) {
              sink.addError(error, stack);
              sink.close();
            }
            return;
          }
          bytes += chunk.length;
          sink.add(chunk);
        },
      ),
    );
  }

  Never _responseTooLarge() {
    _client.close();
    throw _SafeModelFailure(
      'Local model response exceeded the 1 MiB transport limit. '
      'Try a smaller output budget or check the local server; no completion was accepted.',
    );
  }

  // A reported identity is a server assertion, not proof of loaded weights.
  // Older compatible servers omit it; omission must not manufacture evidence.
  void _validateResponseModel(Map<String, dynamic> data) {
    if (data.containsKey('model') &&
        (data['model'] is! String ||
            (data['model'] as String).isEmpty ||
            data['model'] != config.model)) {
      throw _SafeModelFailure(
        'Local server reported a different or invalid model ID. Check the selected model and local runtime, then retry.',
      );
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _completedMetrics = null;
    _pendingMetrics = null;
    _client.close();
  }
}
