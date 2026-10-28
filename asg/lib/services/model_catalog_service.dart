// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/model_catalog.dart';

const codingModelCatalog = [
  ModelCatalogEntry(
    repository: 'mlx-community/Qwen3.5-9B-4bit',
    name: 'Qwen3.5 9B · 4-bit',
    description: 'General engineering and structured coding assistant.',
    github: 'https://github.com/QwenLM/Qwen3.5',
  ),
  ModelCatalogEntry(
    repository: 'mlx-community/Qwen3.5-27B-4bit',
    name: 'Qwen3.5 27B · 4-bit',
    description:
        'Larger general engineering candidate; measure before relying on it.',
    github: 'https://github.com/QwenLM/Qwen3.5',
  ),
  ModelCatalogEntry(
    repository: 'mlx-community/Qwen3.8-27B-4bit',
    name: 'Qwen3.8 27B · 4-bit',
    description:
        'Newer coding-capable candidate; no local inference verification.',
    github: 'https://github.com/AlibabaCloud-Official/Qwen3.8-27B',
  ),
  ModelCatalogEntry(
    repository: 'mlx-community/Qwen2.5-Coder-7B-Instruct-4bit',
    name: 'Qwen2.5 Coder 7B · 4-bit',
    description:
        'Coding specialist; requires another managed architecture adapter.',
    github: 'https://github.com/QwenLM/Qwen2.5-Coder',
  ),
  ModelCatalogEntry(
    repository: 'mlx-community/Qwen2.5-Coder-14B-Instruct-4bit',
    name: 'Qwen2.5 Coder 14B · 4-bit',
    description:
        'Coding specialist; requires another managed architecture adapter.',
    github: 'https://github.com/QwenLM/Qwen2.5-Coder',
  ),
  ModelCatalogEntry(
    repository: 'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit',
    name: 'Qwen2.5 Coder 32B · 4-bit',
    description:
        'Larger coding specialist; requires another architecture adapter.',
    github: 'https://github.com/QwenLM/Qwen2.5-Coder',
  ),
  ModelCatalogEntry(
    repository: 'mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit',
    name: 'Qwen3 Coder 30B A3B · 4-bit',
    description:
        'MoE coding candidate. All resident weights count toward memory.',
    github: 'https://github.com/QwenLM/Qwen3-Coder',
  ),
  ModelCatalogEntry(
    repository: 'mlx-community/Devstral-Small-2507-4bit',
    name: 'Devstral Small 2507 · 4-bit',
    description:
        'Engineering candidate; requires another managed architecture adapter.',
    github: 'https://github.com/mistralai/mistral-inference',
  ),
];

class ModelCatalogFailure implements Exception {
  const ModelCatalogFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModelCatalogService {
  ModelCatalogService({http.Client? client, DateTime Function()? now})
    : _createClient = (client == null ? http.Client.new : () => client),
      _now = now ?? DateTime.now;
  final http.Client Function() _createClient;
  final _active = <http.Client>{};
  bool _closed = false;
  final _known = codingModelCatalog.map((e) => e.repository).toSet();
  final DateTime Function() _now;
  void close() {
    _closed = true;
    for (final client in _active) {
      client.close();
    }
    _active.clear();
  }

  Future<Object?> _json(http.Client client, Uri uri) async {
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      throw const ModelCatalogFailure(
        'Public model metadata is unavailable. Check connection/access and retry.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const ModelCatalogFailure(
          'Model metadata exceeds the supported size.',
        );
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  Future<List<ModelCatalogEntry>> search(String query) async {
    if (_closed) throw const ModelCatalogFailure('Catalog is closed.');
    final term = query.trim();
    if (!RegExp(r'^[A-Za-z0-9 ._-]{2,80}$').hasMatch(term)) {
      throw const ModelCatalogFailure(
        'Enter 2–80 letters, numbers, spaces or model-name punctuation.',
      );
    }
    final client = _createClient();
    _active.add(client);
    try {
      final raw = await _json(
        client,
        Uri.https('huggingface.co', '/api/models', {
          'author': 'mlx-community',
          'search': term,
          'limit': '40',
          'sort': 'downloads',
          'direction': '-1',
        }),
      ).timeout(const Duration(seconds: 20));
      if (raw is! List || raw.length > 40) {
        throw const FormatException('Invalid search response');
      }
      final results = <ModelCatalogEntry>[];
      for (final item in raw) {
        final repo = item is Map<String, dynamic> ? item['id'] : null;
        if (repo is! String ||
            !RegExp(r'^mlx-community/[A-Za-z0-9_.-]{1,160}$').hasMatch(repo)) {
          throw const FormatException('Invalid result');
        }
        if (!repo.toLowerCase().contains('4bit')) continue;
        if (results.any((e) => e.repository == repo)) continue;
        results.add(
          ModelCatalogEntry(
            repository: repo,
            name: repo.split('/').last,
            description: 'Public search result. Check metadata, license and runtime architecture before choosing.',
            github: '',
          ),
        );
      }
      _known.addAll(results.map((e) => e.repository));
      return List.unmodifiable(results);
    } on ModelCatalogFailure {
      rethrow;
    } catch (_) {
      throw const ModelCatalogFailure(
        'Public model search failed. Retry when online.',
      );
    } finally {
      _active.remove(client);
      client.close();
    }
  }

  Future<ModelCatalogMetadata> check(ModelCatalogEntry entry) async {
    if (_closed) throw const ModelCatalogFailure('Catalog is closed.');
    final client = _createClient();
    _active.add(client);
    try {
      return await _check(client, entry).timeout(const Duration(seconds: 35));
    } on ModelCatalogFailure {
      rethrow;
    } catch (_) {
      throw const ModelCatalogFailure(
        'Could not validate public model metadata. Retry when online. Existing model settings are unchanged.',
      );
    } finally {
      _active.remove(client);
      client.close();
    }
  }

  Future<ModelCatalogMetadata> _check(
    http.Client client,
    ModelCatalogEntry entry,
  ) async {
    if (!_known.contains(entry.repository)) {
      throw const ModelCatalogFailure('Select a registered catalog source.');
    }
    final raw = await _json(
      client,
      Uri.https('huggingface.co', '/api/models/${entry.repository}', {
        'blobs': 'true',
      }),
    );
    if (raw is! Map<String, dynamic> || raw['id'] != entry.repository) {
      throw const FormatException('Wrong repository');
    }
    final revision = raw['sha'];
    if (revision is! String || !RegExp(r'^[a-f0-9]{40}$').hasMatch(revision)) {
      throw const FormatException('Invalid revision');
    }
    final files = raw['siblings'];
    if (files is! List || files.length > 2000) {
      throw const FormatException('Invalid files');
    }
    var weights = 0, download = 0;
    final names = <String>{};
    for (final value in files) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid file');
      }
      final name = value['rfilename'];
      final size = value['size'];
      if (name is! String ||
          name.length > 300 ||
          name.contains('..') ||
          !names.add(name)) {
        throw const FormatException('Invalid filename');
      }
      final artifact =
          [
            '.json',
            '.safetensors',
            '.txt',
            '.model',
            '.jinja',
          ].any(name.endsWith) ||
          name == 'README.md' ||
          name.startsWith('LICENSE');
      if (artifact) {
        if (size is! int || size < 0 || size > 1024 * gib) {
          throw const FormatException('Unknown file size');
        }
        download += size;
        if (name.endsWith('.safetensors')) weights += size;
      }
    }
    if (weights == 0 ||
        !names.contains('config.json') ||
        !names.contains('tokenizer.json')) {
      throw const ModelCatalogFailure(
        'This repository has no complete model artifacts. Documentation-only GitHub projects are not downloadable checkpoints.',
      );
    }
    if (names.contains('model.safetensors.index.json')) {
      final index = await _json(
        client,
        Uri.https(
          'huggingface.co',
          '/${entry.repository}/resolve/$revision/model.safetensors.index.json',
        ),
      );
      final map = index is Map<String, dynamic> ? index['weight_map'] : null;
      if (map is! Map<String, dynamic> ||
          map.isEmpty ||
          map.values.any(
            (value) =>
                value is! String ||
                !value.endsWith('.safetensors') ||
                !names.contains(value),
          )) {
        throw const ModelCatalogFailure(
          'Weight index references missing or invalid shards.',
        );
      }
    } else if (!names.contains('model.safetensors')) {
      throw const ModelCatalogFailure(
        'Missing weight index or standalone model.safetensors.',
      );
    }
    final config = await _json(
      client,
      Uri.https(
        'huggingface.co',
        '/${entry.repository}/resolve/$revision/config.json',
      ),
    );
    if (config is! Map<String, dynamic>) {
      throw const FormatException('Invalid configuration');
    }
    final architectures = config['architectures'];
    if (architectures is! List ||
        architectures.length != 1 ||
        architectures.single is! String ||
        !RegExp(r'^[A-Za-z0-9_]{1,100}$')
            .hasMatch(architectures.single as String)) {
      throw const FormatException('Missing architecture');
    }
    final quantization =
        config['quantization'] ?? config['quantization_config'];
    final bits = quantization is Map ? quantization['bits'] : null;
    // Do not equate AWQ/GPTQ's bits field with MLX's quantization layout.
    final mlx = config['quantization'];
    final mlxFormat =
        mlx is Map &&
        [32, 64, 128].contains(mlx['group_size']) &&
        (mlx['mode'] == null || mlx['mode'] == 'affine') &&
        (mlx['quant_method'] == null || mlx['quant_method'] == 'mlx');
    final card = raw['cardData'];
    final license = card is Map ? card['license'] : null;
    if (license is! String ||
        !RegExp(r'^[a-z0-9.-]{1,80}$').hasMatch(license)) {
      throw const FormatException('Missing license');
    }
    return ModelCatalogMetadata(
      revision: revision,
      license: license,
      architecture: architectures.single as String,
      bits: bits is int ? bits : 0,
      mlxFormat: mlxFormat,
      weightBytes: weights,
      downloadBytes: download,
      checkedAt: _now().toUtc(),
    );
  }
}
