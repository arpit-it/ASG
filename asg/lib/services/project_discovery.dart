import '../models/project_blueprint.dart';

/// Deterministic starting suggestions; works without a model connection.
class ProjectDiscovery {
  ProjectBlueprint suggest(String idea) {
    final text = idea.toLowerCase();
    final task = RegExp(r'task|todo|to-do|habit|planner').hasMatch(text);
    final business = RegExp(r'business|inventory|customer|invoice|expense')
        .hasMatch(text);
    final name = task
        ? 'My Task Planner'
        : business
        ? 'My Business Workspace'
        : RegExp(r'portfolio|website').hasMatch(text)
        ? 'My Website'
        : 'My New Project';
    final approach = RegExp(r'website|browser|web app|portfolio').hasMatch(text)
        ? 'web'
        : RegExp(r'desktop|macos|windows|linux').hasMatch(text)
        ? 'desktop'
        : RegExp(r'phone|mobile|android|iphone|ios').hasMatch(text)
        ? 'mobile'
        : 'all';
    return ProjectBlueprint(
      suggestedName: name,
      recommendedApproach: approach,
      features: task
          ? [
              'Task list',
              'Add and edit tasks',
              'Due dates',
              'Search and filters',
            ]
          : business
          ? [
              'Overview dashboard',
              'Add and edit records',
              'Search and filters',
              'Reports',
            ]
          : RegExp(r'portfolio|website').hasMatch(text)
          ? [
              'Welcome page',
              'About section',
              'Project gallery',
              'Contact details',
            ]
          : ['Welcome screen', 'Add and edit items', 'Search', 'Settings'],
    );
  }
}
