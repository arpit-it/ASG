import 'package:flutter/material.dart';

import '../models/project.dart';
import '../controllers/dashboard_controller.dart';
import '../services/studio_store.dart';
import '../services/model_settings_store.dart';
import '../services/folder_picker.dart';
import 'model_settings.dart';
import 'runtime_setup_screen.dart';
import '../controllers/runtime_setup_controller.dart';
import '../services/runtime_setup_store.dart';
import '../services/runtime_host_factory.dart';
import 'project_wizard.dart';
import 'project_workspace.dart';

class Dashboard extends StatefulWidget {
  const Dashboard({
    super.key,
    required this.store,
    required this.initialProjects,
    this.onSelect,
  });
  final ValueChanged<StudioProject>? onSelect;
  final StudioStore store;
  final List<StudioProject> initialProjects;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  late final controller = DashboardController(
    widget.store,
    widget.initialProjects,
  );
  final picker = FolderPicker();
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    super.dispose();
  }

  Future<void> create() async {
    final project = await showDialog<StudioProject>(
      context: context,
      builder: (_) => const ProjectWizard(),
    );
    if (project == null) return;
    final saved = await controller.add(project);
    if (saved && mounted && widget.onSelect != null) {
      widget.onSelect!(project);
      return;
    }
    if (saved && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ProjectWorkspace(records: widget.store.records, project: project),
        ),
      );
      return;
    }
    if (!saved && mounted && controller.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(controller.error!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = controller.filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automated Software Generator'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ModelSettings(
                store: ModelSettingsStore(widget.store.records),
              ),
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: const RuntimeFabLocation(),
      floatingActionButton: FloatingActionButton(
        heroTag: 'runtimeSetup',
        tooltip: 'Set up runtime',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RuntimeSetupScreen(
              controller: RuntimeSetupController(
                store: RuntimeSetupStore(widget.store.records),
                modelStore: ModelSettingsStore(widget.store.records),
                host: createRuntimeHost(),
              ),
            ),
          ),
        ),
        child: const Icon(Icons.memory),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 80, 28, 28),
            children: [
              const Text(
                'YOUR SOFTWARE WORKSPACE',
                style: TextStyle(
                  color: Color(0xffb4adff),
                  letterSpacing: 2,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'What would you like to create?',
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              const Text(
                'Tell me your idea. I’ll guide the choices and set up a project around what you need.',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: create,
                    icon: const Icon(Icons.add),
                    label: const Text('Let’s create something'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (!picker.supported) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Opening local folders is available on supported desktop and Android devices.',
                            ),
                          ),
                        );
                        return;
                      }
                      try {
                        final path = await picker.pick();
                        if (path != null && context.mounted) {
                          showDialog<void>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Folder selected'),
                              content: Text(
                                '$path\n\nRepository import is planned for a later milestone. Create a project record to track this folder.',
                              ),
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Unable to open folder: $e'),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open folder'),
                  ),
                ],
              ),
              const SizedBox(height: 36),
              Text(
                'Projects · ${controller.projects.length}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                onChanged: controller.search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search projects',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              if (filtered.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.auto_awesome_outlined,
                          size: 42,
                          color: Color(0xffb4adff),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          controller.projects.isEmpty
                              ? 'Start with an idea'
                              : 'No matching projects',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Create a project to capture its requirements and target platforms.',
                        ),
                      ],
                    ),
                  ),
                ),
              ...filtered.map(
                (p) => Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(18),
                    leading: const Icon(Icons.widgets_outlined),
                    title: Text(p.name),
                    subtitle: Text(
                      '${p.type} · ${p.platforms.join(', ')}\nDiscovery · No builds yet',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.arrow_forward),
                    onTap: () {
                      if (widget.onSelect != null) {
                        widget.onSelect!(p);
                        return;
                      }
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ProjectWorkspace(
                            records: widget.store.records,
                            project: p,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Foundation milestone · AI generation and execution are not connected.',
                style: TextStyle(color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Leaves the app bar settings action unobstructed while keeping runtime at top right.
class RuntimeFabLocation extends FloatingActionButtonLocation {
  const RuntimeFabLocation();
  @override
  Offset getOffset(ScaffoldPrelayoutGeometry geometry) =>
      FloatingActionButtonLocation.endTop.getOffset(geometry) +
      const Offset(0, 56);
}
