// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/model_profile_notes.dart';

class ModelProfileNotesFields extends StatelessWidget {
  const ModelProfileNotesFields({
    super.key,
    required this.fields,
    required this.enabled,
  });
  final List<TextEditingController> fields;
  final bool enabled;
  static const labels = [
    'Model revision note',
    'License note',
    'Architecture note',
    'Quantization note',
    'Backend note',
    'Declared context tokens',
  ];

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('Unverified model profile notes'),
    subtitle: const Text('Saved with connection presets only'),
    children: [
      const Text(ModelProfileNotes.guidance),
      for (var i = 0; i < labels.length; i++)
        TextField(
          key: ValueKey(labels[i]),
          controller: fields[i],
          enabled: enabled,
          maxLength: i == 5 ? 7 : 256,
          keyboardType: i == 5 ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(labelText: labels[i]),
        ),
    ],
  );
}
