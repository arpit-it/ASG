// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Point-in-time identity evidence only, never execution or syntax approval.
class HtmlSourceCheck {
  const HtmlSourceCheck({required this.files, required this.bytes});
  final int files, bytes;
  String get summary =>
      '$files fixed starter files match ($bytes bytes). '
      'Point-in-time source identity only; no lint, browser or runtime checks.';
}
