enum CreationStep { idea, options, review }

class ProjectApproach {
  const ProjectApproach(this.id, this.title, this.description, this.platforms);
  final String id, title, description;
  final List<String> platforms;
}

class ProjectBlueprint {
  const ProjectBlueprint({
    required this.suggestedName,
    required this.recommendedApproach,
    required this.features,
  });
  final String suggestedName, recommendedApproach;
  final List<String> features;
  static const approaches = [
    ProjectApproach('mobile', 'Mobile app', 'An app for Android and iPhone.', [
      'Android',
      'iOS',
    ]),
    ProjectApproach('web', 'Web app', 'Open your app in a browser.', ['Web']),
    ProjectApproach(
      'desktop',
      'Desktop app',
      'A workspace for larger screens.',
      ['macOS', 'Windows', 'Linux'],
    ),
    ProjectApproach(
      'all',
      'Across all devices',
      'Start with mobile, desktop and web.',
      ['Android', 'iOS', 'Web', 'macOS', 'Windows', 'Linux'],
    ),
  ];
}
