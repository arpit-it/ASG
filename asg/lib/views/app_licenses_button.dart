// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

/// Opens the bundled application and third-party notices without network access.
class AppLicensesButton extends StatelessWidget {
  const AppLicensesButton({super.key, this.enabled = true});

  final bool enabled;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Licenses',
    icon: const Icon(Icons.policy_outlined),
    onPressed: enabled
        ? () => showLicensePage(
            context: context,
            applicationName: 'Automated Software Generator',
            applicationLegalese:
                'Copyright © 2026 Arpit Sinha\n'
                'Mozilla Public License 2.0\n'
                'Third-party components retain their own licenses.',
          )
        : null,
  );
}
