import '../models/project.dart';

class ExecutionPolicy {
  bool canModifyFiles(ConversationMode mode, {required bool planApproved}) =>
      mode == ConversationMode.build && planApproved;
  final int maximumRepairAttempts = 3;
}
