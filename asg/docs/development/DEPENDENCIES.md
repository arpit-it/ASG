# Dependency inventory

Inventory reconciled against committed pubspec.lock on 25 October 2026; no dependencies were upgraded during this audit. Bundled package/SDK notices remain authoritative, and table membership is not a new license audit. No model checkpoint is included.

| Package | Notice location |
| --- | --- |
| args | Bundled package/SDK notices |
| async | Bundled package/SDK notices |
| boolean_selector | Bundled package/SDK notices |
| characters | Bundled package/SDK notices |
| clock | Bundled package/SDK notices |
| code_assets | Bundled package/SDK notices |
| collection | Bundled package/SDK notices |
| cross_file | Bundled package/SDK notices |
| crypto | Bundled package/SDK notices |
| cupertino_icons | Bundled package/SDK notices |
| fake_async | Bundled package/SDK notices |
| ffi | Bundled package/SDK notices |
| file | Bundled package/SDK notices |
| file_selector | Bundled package/SDK notices |
| file_selector_android | Bundled package/SDK notices |
| file_selector_ios | Bundled package/SDK notices |
| file_selector_linux | Bundled package/SDK notices |
| file_selector_macos | Bundled package/SDK notices |
| file_selector_platform_interface | Bundled package/SDK notices |
| file_selector_web | Bundled package/SDK notices |
| file_selector_windows | Bundled package/SDK notices |
| flutter | Bundled package/SDK notices |
| flutter_lints | Bundled package/SDK notices |
| flutter_test | Bundled package/SDK notices |
| flutter_web_plugins | Bundled package/SDK notices |
| hooks | Bundled package/SDK notices |
| http | Bundled package/SDK notices |
| http_parser | Bundled package/SDK notices |
| idb_shim | Bundled package/SDK notices |
| jni | Bundled package/SDK notices |
| jni_flutter | Bundled package/SDK notices |
| jni_util | Bundled package/SDK notices |
| leak_tracker | Bundled package/SDK notices |
| leak_tracker_flutter_testing | Bundled package/SDK notices |
| leak_tracker_testing | Bundled package/SDK notices |
| lints | Bundled package/SDK notices |
| logging | Bundled package/SDK notices |
| matcher | Bundled package/SDK notices |
| material_color_utilities | Bundled package/SDK notices |
| meta | Bundled package/SDK notices |
| objective_c | Bundled package/SDK notices |
| package_config | Bundled package/SDK notices |
| path | Bundled package/SDK notices |
| path_provider | Bundled package/SDK notices |
| path_provider_android | Bundled package/SDK notices |
| path_provider_foundation | Bundled package/SDK notices |
| path_provider_linux | Bundled package/SDK notices |
| path_provider_platform_interface | Bundled package/SDK notices |
| path_provider_windows | Bundled package/SDK notices |
| platform | Bundled package/SDK notices |
| plugin_platform_interface | Bundled package/SDK notices |
| pub_semver | Bundled package/SDK notices |
| record_use | Bundled package/SDK notices |
| sembast | Bundled package/SDK notices |
| sembast_web | Bundled package/SDK notices |
| shared_preferences | Bundled package/SDK notices |
| shared_preferences_android | Bundled package/SDK notices |
| shared_preferences_foundation | Bundled package/SDK notices |
| shared_preferences_linux | Bundled package/SDK notices |
| shared_preferences_platform_interface | Bundled package/SDK notices |
| shared_preferences_web | Bundled package/SDK notices |
| shared_preferences_windows | Bundled package/SDK notices |
| sky_engine | Bundled package/SDK notices |
| source_span | Bundled package/SDK notices |
| stack_trace | Bundled package/SDK notices |
| stream_channel | Bundled package/SDK notices |
| string_scanner | Bundled package/SDK notices |
| synchronized | Bundled package/SDK notices |
| term_glyph | Bundled package/SDK notices |
| test_api | Bundled package/SDK notices |
| typed_data | Bundled package/SDK notices |
| vector_math | Bundled package/SDK notices |
| vm_service | Bundled package/SDK notices |
| web | Bundled package/SDK notices |
| xdg_directories | Bundled package/SDK notices |
| yaml | Bundled package/SDK notices |

Review exact license terms before commercial distribution. Flutter/Dart and platform SDK terms also apply.


ASG local runtime: existing Torch 2.12.1 and Transformers 5.16.1, plus project-local Accelerate 1.15.0. Qwen3.5-9B local original model card declares Apache-2.0. Runtime/model license and reproducibility details: LOCAL_QWEN.md.


Optimized runtime: MLX LM 0.32.2 / MLX 0.32.4 / MLX Metal 0.32.4, isolated in tools/.mlx-venv and pinned in tools/requirements-mlx.txt. MLX and MLX LM use MIT licenses; Qwen model licensing remains Apache-2.0 as recorded above. No model weights or runtime environment are committed.

## Transactional storage — issue #4

Added sembast 3.9.0 and sembast_web 2.4.6+1 (BSD-3-Clause), idb_shim 2.10.1+1 (BSD-2-Clause), synchronized 3.5.0 (MIT), and direct path 1.9.1 (BSD-3-Clause). Licenses reviewed in downloaded package sources. Native storage uses existing path_provider; browser uses IndexedDB. Lockfile committed; no model/runtime dependencies changed. Retain required notices in distributed artifacts.

## Source generation — issue #3

crypto 3.0.7 is now a direct dependency for SHA-256 source/resolution/output fingerprints (BSD-3-Clause; reviewed installed package license). It was already a transitive dependency. The command helper uses the selected installed Python standard library; generated apps depend only on Flutter/Flutter test from the selected SDK. No external package/model installation is added to generation.
