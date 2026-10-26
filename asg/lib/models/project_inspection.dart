/// Point-in-time findings; no execution or write approval.
class ProjectInspection {
  ProjectInspection({
    required this.root,
    required this.packageName,
    required this.dartSdk,
    required List<String> runners,
  }) : runners = List.unmodifiable(runners);
  final String root;
  final String packageName;
  final String dartSdk;
  final List<String> runners;
  static const limitations = [
    'Dependencies and toolchain availability have not been verified.',
    'Included runners do not establish tested platform support.',
    'Import, execution and source modification require separate approval.',
  ];
}
