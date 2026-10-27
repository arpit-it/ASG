// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

enum ConversationMode { discuss, plan, build, review }

class StudioProject {
  const StudioProject({
    required this.id,
    required this.name,
    required this.description,
    required this.type,
    required this.platforms,
    required this.location,
  });
  static String? validateName(String? name) {
    if (name == null || name.trim().isEmpty) return 'Enter a project name';
    if (name.contains('/') ||
        name.contains('\\') ||
        name.runes.any((r) => r < 32)) {
      return 'Use a name without path separators';
    }
    return null;
  }

  final String id, name, description, type, location;
  final List<String> platforms;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'type': type,
    'platforms': platforms,
    'location': location,
  };
  factory StudioProject.fromJson(Map<String, dynamic> json) => StudioProject(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String,
    type: json['type'] as String,
    platforms: List<String>.from(json['platforms'] as List),
    location: json['location'] as String,
  );
}
