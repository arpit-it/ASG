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
