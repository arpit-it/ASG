// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

// Disposable native entrypoint. Never used by production main.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const fixtureBundle = 'com.arsinha.asg.restartfixture';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (!Platform.isMacOS) throw StateError('Mac fixture only.');
    final executable = File(Platform.resolvedExecutable);
    final plist = path.join(executable.parent.parent.path, 'Info.plist');
    final identity = await Process.run('/usr/bin/plutil', [
      '-extract',
      'CFBundleIdentifier',
      'raw',
      '-o',
      '-',
      plist,
    ]);
    if (identity.exitCode != 0 ||
        '${identity.stdout}'.trim() != fixtureBundle) {
      throw StateError('Disposable bundle identity required.');
    }
    final control = Directory(
      Platform.environment['ASG_RESTART_PROBE_ROOT'] ?? '',
    );
    final temporary = await Directory.systemTemp.resolveSymbolicLinks();
    final canonical = await control.resolveSymbolicLinks();
    if (canonical != path.normalize(control.absolute.path) ||
        !path.isWithin(temporary, canonical) ||
        !path.basename(canonical).startsWith('asg-restart-probe-') ||
        (await control.stat()).mode & 0x3f != 0) {
      throw StateError('Private temporary control directory required.');
    }
    final challenge = File(path.join(canonical, 'challenge.json'));
    if (await FileSystemEntity.isLink(challenge.path) ||
        await challenge.length() > 2048) {
      throw StateError('Invalid challenge file.');
    }
    final value = jsonDecode(await challenge.readAsString());
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        value['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['nonce'] as String) ||
        ![1, 2].contains(value['launch'])) {
      throw StateError('Invalid challenge.');
    }
    final nonce = value['nonce'] as String;
    final launch = value['launch'] as int;
    final support = await getApplicationSupportDirectory();
    if (path.basename(support.path) != fixtureBundle ||
        await support.resolveSymbolicLinks() !=
            path.normalize(support.absolute.path)) {
      throw StateError('Disposable support identity required.');
    }
    final sentinel = File(path.join(support.path, 'restart-probe-$nonce.txt'));
    if (await FileSystemEntity.isLink(sentinel.path)) {
      throw StateError('Linked probe sentinel refused.');
    }
    final preferences = await SharedPreferences.getInstance();
    final key = 'asg.restartProbe.$nonce';
    if (launch == 1) {
      if (await sentinel.exists() || preferences.containsKey(key)) {
        throw StateError('Probe identity already reserved.');
      }
      await sentinel.create(exclusive: true);
      await sentinel.writeAsString(nonce, flush: true);
      if (!await preferences.setString(key, nonce)) {
        throw StateError('Probe preference write failed.');
      }
    } else if (!await sentinel.exists() ||
        await sentinel.readAsString() != nonce ||
        preferences.getString(key) != nonce) {
      throw StateError('Probe persistence mismatch.');
    }
    final report = File(path.join(canonical, 'launch-$launch.json'));
    await report.create(exclusive: true);
    await report.writeAsString(
      jsonEncode({
        'version': 1,
        'bundle': fixtureBundle,
        'nonce': nonce,
        'launch': launch,
        'support': support.path,
        'preferencesPersisted': launch == 2,
      }),
      flush: true,
    );
    exit(0);
  } catch (_) {
    stderr.writeln('Native restart probe refused or failed.');
    exit(2);
  }
}
