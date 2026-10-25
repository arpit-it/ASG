import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/studio_store.dart';
import 'views/studio_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final store = StudioStore(await SharedPreferences.getInstance());
    final projects = store.load();
    runApp(StudioApp(store: store, initialProjects: projects));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'Unable to load saved records. Your data has not been overwritten.\n$error',
            ),
          ),
        ),
      ),
    );
  }
}
