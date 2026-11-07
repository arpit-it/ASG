// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

// Developer fixture uses the reviewed installed SDK closure, not app dependencies.
// ignore: depend_on_referenced_packages
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  final root = Directory(args[1]).uri;
  final stage = args[2];
  final inputFile = File.fromUri(root.resolve('input.json'));
  if (args[0] == 'input') {
    final HookInputBuilder builder;
    if (stage == 'build') {
      builder = BuildInputBuilder()..setupBuildInput();
      (builder as BuildInputBuilder).config.setupBuild(linkingEnabled: true);
    } else {
      builder = LinkInputBuilder()
        ..setupLink(assets: [], assetsFromLinking: [], recordedUsesFile: null);
    }
    builder.setupShared(
      packageRoot: Directory(args[3]).uri,
      packageName: 'asg_authored_hook_fixture',
      outputDirectoryShared: root.resolve('shared/'),
      outputFile: root.resolve('output.json'),
    );
    inputFile.writeAsStringSync(jsonEncode(builder.json));
  } else {
    final input =
        jsonDecode(inputFile.readAsStringSync()) as Map<String, Object?>;
    final output = jsonDecode(
      File.fromUri(root.resolve('output.json')).readAsStringSync(),
    ) as Map<String, Object?>;
    final errors = stage == 'build'
        ? await ProtocolBase.validateBuildOutput(
            BuildInput(input),
            BuildOutput(output),
          )
        : await ProtocolBase.validateLinkOutput(
            LinkInput(input),
            LinkOutput(output),
          );
    if (errors.isNotEmpty) {
      stderr.writeln('Hook protocol validation refused');
      exit(2);
    }
  }
}
