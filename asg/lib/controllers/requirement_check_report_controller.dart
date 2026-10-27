import '../models/project.dart';
import '../models/requirement_check_report.dart';
import '../services/requirement_check_report_store.dart';
import 'base_controller.dart';

class RequirementCheckReportController extends BaseController {
  RequirementCheckReportController(this.project, this.store);
  final StudioProject project;
  final RequirementCheckReportStore store;
  RequirementCheckReport? _report;
  RequirementCheckReport? get report => _report;
  String? _error;
  String? get error => _error;
  void load() {
    if (isDisposed) return;
    try {
      _report = store.load(project);
      _error = null;
    } catch (_) {
      _report = null;
      _error = 'Saved review evidence is unavailable or unreadable. Records have not been changed. Check saved project data, then reload.';
    }
    update();
  }
}
