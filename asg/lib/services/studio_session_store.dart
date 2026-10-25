import '../models/project.dart';
import 'studio_store.dart';

class StudioSessionStore {
  StudioSessionStore(this.projects);
  final StudioStore projects;
  String? get lastProject =>
      projects.preferences.getString('studio.lastProject.v1');
  Future<void> select(String id) async {
    if (!await projects.preferences.setString('studio.lastProject.v1', id)) {
      throw StateError('Project selection could not be saved.');
    }
  }

  List<StudioProject> load() => projects.load();
}
