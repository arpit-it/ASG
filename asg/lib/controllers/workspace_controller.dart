import '../models/project.dart';
import 'base_controller.dart';

class WorkspaceController extends BaseController {
  ConversationMode mode = ConversationMode.discuss;
  String section = 'Overview';
  void selectMode(ConversationMode value) {
    mode = value;
    update();
  }

  void selectSection(String value) {
    section = value;
    update();
  }
}
