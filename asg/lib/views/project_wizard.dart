import 'package:flutter/material.dart';

import '../controllers/project_wizard_controller.dart';
import '../models/project_blueprint.dart';

class ProjectWizard extends StatefulWidget {
  const ProjectWizard({super.key});
  @override
  State<ProjectWizard> createState() => _ProjectWizardState();
}

class _ProjectWizardState extends State<ProjectWizard> {
  final name = TextEditingController(), idea = TextEditingController();
  final controller = ProjectWizardController();
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
    name.dispose();
    idea.dispose();
    super.dispose();
  }

  void next() {
    switch (controller.step) {
      case CreationStep.idea:
        final previous = controller.blueprint;
        if (controller.discover(idea.text) &&
            (name.text.isEmpty || previous != controller.blueprint)) {
          name.text = controller.blueprint!.suggestedName;
        }
      case CreationStep.options:
        controller.review();
      case CreationStep.review:
        final project = controller.createFromChoices(name.text);
        if (project != null) Navigator.pop(context, project);
    }
  }

  Widget get ideaStep => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text(
        'Tell me what you want to create. I’ll suggest a starting point and guide you through the choices.',
      ),
      const SizedBox(height: 20),
      TextField(
        controller: idea,
        autofocus: true,
        minLines: 3,
        maxLines: 5,
        maxLength: 2000,
        decoration: const InputDecoration(
          labelText: 'What would you like to create?',
          hintText: 'For example, an app to track my daily tasks',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      const Text('Need a starting idea?'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children:
            const [
                  'A daily task planner',
                  'An inventory app for my business',
                  'A portfolio website',
                  'A mobile habit tracker',
                ]
                .map(
                  (suggestion) => ActionChip(
                    label: Text(suggestion),
                    onPressed: () => idea.text = suggestion,
                  ),
                )
                .toList(),
      ),
    ],
  );
  Widget get optionsStep => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('You want to create: ${controller.idea}'),
      const SizedBox(height: 20),
      const Text(
        'How should people use it?',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      ...ProjectBlueprint.approaches.map(
        (option) => Card(
          child: ListTile(
            selected: controller.approach?.id == option.id,
            title: Text(
              '${option.title}${controller.blueprint?.recommendedApproach == option.id ? ' · Suggested' : ''}',
            ),
            subtitle: Text(option.description),
            trailing: Icon(
              controller.approach?.id == option.id
                  ? Icons.check_circle
                  : Icons.circle_outlined,
            ),
            onTap: () => controller.selectApproach(option.id),
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'What should the first version include?',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      ...?controller.blueprint?.features.map(
        (feature) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(feature),
          value: controller.features.contains(feature),
          onChanged: (value) =>
              controller.toggleFeature(feature, value ?? false),
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'These starting suggestions work offline. You can refine the requirements with your local model after creating the project.',
      ),
    ],
  );
  Widget get reviewStep => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('Here’s the project I’ll set up from your choices.'),
      const SizedBox(height: 20),
      TextField(
        controller: name,
        decoration: const InputDecoration(
          labelText: 'Project name',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      Text(controller.idea),
      const SizedBox(height: 16),
      Text('Experience: ${controller.approach?.title}'),
      const SizedBox(height: 8),
      Text('Platforms: ${controller.platforms.join(', ')}'),
      const SizedBox(height: 8),
      Text(
        'First version: ${controller.features.isEmpty ? 'Basic starting screen' : controller.features.join(', ')}',
      ),
      const SizedBox(height: 16),
      if (controller.picker.supported)
        OutlinedButton.icon(
          onPressed: controller.chooseFolder,
          icon: const Icon(Icons.folder_outlined),
          label: const Text('Choose workspace folder (optional)'),
        ),
      if (controller.location.isNotEmpty) Text(controller.location),
      const SizedBox(height: 16),
      const Text(
        'This saves your project and selected requirements. App code is not generated yet.',
        style: TextStyle(color: Colors.white60),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(switch (controller.step) {
      CreationStep.idea => 'What would you like to create?',
      CreationStep.options => 'Let’s shape your app',
      CreationStep.review => 'Ready to set up your project?',
    }),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Step ${controller.step.index + 1} of 3',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 16),
            switch (controller.step) {
              CreationStep.idea => ideaStep,
              CreationStep.options => optionsStep,
              CreationStep.review => reviewStep,
            },
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      if (controller.step != CreationStep.idea)
        TextButton(onPressed: controller.back, child: const Text('Back')),
      FilledButton(
        onPressed: next,
        child: Text(switch (controller.step) {
          CreationStep.idea => 'Show my options',
          CreationStep.options => 'Review project',
          CreationStep.review => 'Create project',
        }),
      ),
    ],
  );
}
