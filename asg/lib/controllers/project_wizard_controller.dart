import '../models/project.dart';
import '../models/project_blueprint.dart';
import '../services/project_discovery.dart';
import '../services/folder_picker.dart';
import 'base_controller.dart';

class ProjectWizardController extends BaseController {
  ProjectWizardController({FolderPicker? picker, ProjectDiscovery? discovery})
    : picker = picker ?? FolderPicker(),
      discovery = discovery ?? ProjectDiscovery();
  final ProjectDiscovery discovery;
  final FolderPicker picker;
  String type = 'Flutter', location = '';
  final Set<String> _platforms = {'macOS'};
  Set<String> get platforms => Set.unmodifiable(_platforms);
  String? error;
  CreationStep _step = CreationStep.idea;
  CreationStep get step => _step;
  String _idea = '';
  String get idea => _idea;
  ProjectBlueprint? _blueprint;
  ProjectBlueprint? get blueprint => _blueprint;
  String? _approachId;
  ProjectApproach? get approach {
    for (final option in ProjectBlueprint.approaches) {
      if (option.id == _approachId) return option;
    }
    return null;
  }

  final Set<String> _features = {};
  Set<String> get features => Set.unmodifiable(_features);
  bool discover(String value) {
    if (value.trim().length < 10) {
      error = 'Tell me a little more about what you want to create (at least 10 characters).';
      update();
      return false;
    }
    final changed = _idea != value.trim();
    _idea = value.trim();
    if (changed || _blueprint == null) {
      final suggested = discovery.suggest(_idea);
      _blueprint = suggested;
      selectApproach(suggested.recommendedApproach);
      _features
        ..clear()
        ..addAll(suggested.features.take(2));
    }
    error = null;
    _step = CreationStep.options;
    update();
    return true;
  }

  void selectApproach(String id) {
    final option = ProjectBlueprint.approaches
        .where((item) => item.id == id)
        .firstOrNull;
    if (option == null) return;
    _approachId = id;
    type = 'Flutter';
    _platforms
      ..clear()
      ..addAll(option.platforms);
    update();
  }

  void toggleFeature(String feature, bool selected) {
    if (!(_blueprint?.features.contains(feature) ?? false)) return;
    selected ? _features.add(feature) : _features.remove(feature);
    update();
  }

  bool review() {
    if (_blueprint == null || approach == null) {
      error = 'Choose how people will use your app.';
      update();
      return false;
    }
    error = null;
    _step = CreationStep.review;
    update();
    return true;
  }

  void back() {
    if (_step == CreationStep.review) {
      _step = CreationStep.options;
    } else if (_step == CreationStep.options) {
      _step = CreationStep.idea;
    }
    error = null;
    update();
  }

  StudioProject? createFromChoices(String name) {
    if (_step != CreationStep.review || _idea.isEmpty || approach == null) {
      error = 'Review your choices before creating the project.';
      update();
      return null;
    }
    return create(
      name,
      '$_idea\n\nSelected experience: ${approach!.title}\nInitial features: ${_features.isEmpty ? 'Basic starting screen' : _features.join(', ')}',
    );
  }

  static String? validateName(String? name) => StudioProject.validateName(name);

  void selectType(String value) {
    type = value;
    update();
  }

  void selectPlatform(String value, bool selected) {
    selected ? _platforms.add(value) : _platforms.remove(value);
    update();
  }

  Future<void> chooseFolder() async {
    try {
      final selected = await picker.pick();
      if (!isDisposed && selected != null) location = selected;
    } catch (e) {
      error = 'Folder selection failed: $e';
    }
    update();
  }

  StudioProject? create(String name, String description) {
    error = validateName(name);
    if (error == null && _platforms.isEmpty) {
      error = 'Choose at least one platform.';
    }
    if (error != null) {
      update();
      return null;
    }
    return StudioProject(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      description: description.trim(),
      type: type,
      platforms: _platforms.toList(),
      location: location,
    );
  }
}
