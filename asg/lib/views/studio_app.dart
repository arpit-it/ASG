// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/studio_store.dart';
import 'studio_home.dart';

class StudioApp extends StatelessWidget {
  const StudioApp({
    super.key,
    required this.store,
    this.initialProjects = const [],
  });
  final StudioStore store;
  final List<StudioProject> initialProjects;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Automated Software Generator',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xffa7a0ff),
      scaffoldBackgroundColor: const Color(0xff101118),
      cardTheme: const CardThemeData(margin: EdgeInsets.only(bottom: 12)),
    ),
    home: StudioHome(store: store, projects: initialProjects),
  );
}
