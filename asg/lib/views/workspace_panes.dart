import 'package:flutter/material.dart';

import '../controllers/workspace_layout_controller.dart';

/// Keeps both child elements mounted at fixed positions in the tree across
/// resizing, collapse and responsive transitions, including active requests.
class WorkspacePanes extends StatefulWidget {
  const WorkspacePanes({super.key, required this.chat, required this.preview});
  final Widget chat;
  final Widget preview;

  @override
  State<WorkspacePanes> createState() => _WorkspacePanesState();
}

class _WorkspacePanesState extends State<WorkspacePanes> {
  final layout = WorkspaceLayoutController();
  final resizeFocus = FocusNode(debugLabel: 'Resize workspace panes');

  @override
  void dispose() {
    resizeFocus.dispose();
    layout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: layout,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final minimum = 360 * scale.clamp(1.0, 2.0);
        final wide = constraints.maxWidth >= minimum * 2 + 32;
        final available = constraints.maxWidth - 16;
        final minimumFraction = wide ? minimum / available : 0.0;
        final fraction = layout.fraction.clamp(
          minimumFraction,
          1 - minimumFraction,
        );
        final split = wide && layout.collapsed == null;
        return Column(
          children: [
            if (wide)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () => layout.toggle(0),
                    icon: Icon(
                      layout.collapsed == 0
                          ? Icons.chevron_right
                          : Icons.chevron_left,
                    ),
                    label: Text(
                      layout.collapsed == 0 ? 'Restore chat' : 'Collapse chat',
                    ),
                  ),
                  if (split)
                    SizedBox(
                      width: 200,
                      child: Slider(
                        key: const ValueKey('workspaceResize'),
                        focusNode: resizeFocus,
                        onChangeStart: (_) => resizeFocus.requestFocus(),
                        label: 'Chat ${(fraction * 100).round()}%',
                        semanticFormatterCallback: (value) =>
                            'Chat ${(value * 100).round()} percent',
                        min: minimumFraction,
                        max: 1 - minimumFraction,
                        value: fraction,
                        onChanged: (value) =>
                            layout.resize(value, minimumFraction),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () => layout.toggle(1),
                    icon: Icon(
                      layout.collapsed == 1
                          ? Icons.chevron_left
                          : Icons.chevron_right,
                    ),
                    label: Text(
                      layout.collapsed == 1
                          ? 'Restore preview'
                          : 'Collapse preview',
                    ),
                  ),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.all(8),
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      label: Text('Chat'),
                      icon: Icon(Icons.chat_bubble_outline),
                    ),
                    ButtonSegment(
                      value: 1,
                      label: Text('Preview'),
                      icon: Icon(Icons.preview_outlined),
                    ),
                  ],
                  selected: {layout.mobilePane},
                  onSelectionChanged: (value) => layout.select(value.single),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, body) {
                  final showChat = wide
                      ? layout.collapsed != 0
                      : layout.mobilePane == 0;
                  final showPreview = wide
                      ? layout.collapsed != 1
                      : layout.mobilePane == 1;
                  final chatWidth = split
                      ? available * fraction
                      : body.maxWidth;
                  final previewWidth = split
                      ? available - chatWidth
                      : body.maxWidth;
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: chatWidth,
                        child: Offstage(
                          offstage: !showChat,
                          child: ExcludeFocus(
                            excluding: !showChat,
                            child: TickerMode(
                              enabled: showChat,
                              child: widget.chat,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        width: previewWidth,
                        child: Offstage(
                          offstage: !showPreview,
                          child: ExcludeFocus(
                            excluding: !showPreview,
                            child: TickerMode(
                              enabled: showPreview,
                              child: widget.preview,
                            ),
                          ),
                        ),
                      ),
                      if (split)
                        Positioned(
                          left: chatWidth,
                          top: 0,
                          bottom: 0,
                          width: 16,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.resizeColumn,
                            child: GestureDetector(
                              key: const ValueKey('workspaceDivider'),
                              behavior: HitTestBehavior.opaque,
                              onHorizontalDragUpdate: (details) =>
                                  layout.resize(
                                    fraction + details.delta.dx / available,
                                    minimumFraction,
                                  ),
                              child: const Center(
                                child: VerticalDivider(width: 1),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    ),
  );
}
