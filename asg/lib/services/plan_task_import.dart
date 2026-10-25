import '../models/chat_message.dart';
import '../models/plan_task_proposal.dart';
import '../models/project.dart';
import '../models/requirements_board.dart';
import 'conversation_store.dart';
import 'plan_approval_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

class PlanTaskImport {
  PlanTaskImport(this.records);
  final RecordStorage records;

  RequirementsBoard _current(
    StudioProject project,
    List<ChatMessage> messages,
  ) {
    final approvals = PlanApprovalStore(records);
    final current = approvals.currentProject(project.id);
    final saved = ConversationStore(records).load(project.id);
    final index = PlanApprovalStore.latestPlan(messages);
    if (index < 0 ||
        index != PlanApprovalStore.latestPlan(saved) ||
        messages[index].content != saved[index].content ||
        messages[index].planContext != saved[index].planContext ||
        PlanApprovalStore.context(current) !=
            PlanApprovalStore.context(project) ||
        saved[index].planContext != approvals.contextFor(current)) {
      throw StateError(
        'Plan or requirements changed. Draft a current Plan before adding tasks.',
      );
    }
    return RequirementsStore(records).load(project.id);
  }

  PlanTaskProposal preview(StudioProject project, List<ChatMessage> messages) {
    final board = _current(project, messages);
    final proposal = PlanTaskProposal.parse(
      messages[PlanApprovalStore.latestPlan(messages)].content,
    );
    proposal.addTo(board);
    return proposal;
  }

  Future<void> add(StudioProject project, List<ChatMessage> messages) async {
    final current = _current(project, messages);
    final proposal = PlanTaskProposal.parse(
      messages[PlanApprovalStore.latestPlan(messages)].content,
    );
    await RequirementsStore(records)
        .save(project.id, current, proposal.addTo(current));
  }
}
