# Dependency inventory

Resolved packages from pubspec.lock; bundled notices remain authoritative. No model checkpoint is included.

| Package | License file |
| --- | --- |
| args | Present in package |
| async | Present in package |
| boolean_selector | Present in package |
| characters | Present in package |
| clock | Present in package |
| collection | Present in package |
| cross_file | Present in package |
| cupertino_icons | Present in package |
| fake_async | Present in package |
| ffi | Present in package |
| file | Present in package |
| file_selector | Present in package |
| file_selector_android | Present in package |
| file_selector_ios | Present in package |
| file_selector_linux | Present in package |
| file_selector_macos | Present in package |
| file_selector_platform_interface | Present in package |
| file_selector_web | Present in package |
| file_selector_windows | Present in package |
| flutter_lints | Present in package |
| http | Present in package |
| http_parser | Present in package |
| jni | Present in package |
| jni_util | Present in package |
| leak_tracker | Present in package |
| leak_tracker_flutter_testing | Present in package |
| leak_tracker_testing | Present in package |
| lints | Present in package |
| matcher | Present in package |
| material_color_utilities | Present in package |
| meta | Present in package |
| package_config | Present in package |
| path | Present in package |
| path_provider_linux | Present in package |
| path_provider_platform_interface | Present in package |
| path_provider_windows | Present in package |
| platform | Present in package |
| plugin_platform_interface | Present in package |
| shared_preferences | Present in package |
| shared_preferences_android | Present in package |
| shared_preferences_foundation | Present in package |
| shared_preferences_linux | Present in package |
| shared_preferences_platform_interface | Present in package |
| shared_preferences_web | Present in package |
| shared_preferences_windows | Present in package |
| source_span | Present in package |
| stack_trace | Present in package |
| stream_channel | Present in package |
| string_scanner | Present in package |
| term_glyph | Present in package |
| test_api | Present in package |
| typed_data | Present in package |
| vector_math | Present in package |
| vm_service | Present in package |
| web | Present in package |
| xdg_directories | Present in package |

Review exact license terms before commercial distribution. Flutter/Dart and platform SDK terms also apply.


ASG local runtime: existing Torch 2.12.1 and Transformers 5.16.1, plus project-local Accelerate 1.15.0. Qwen3.5-9B local original model card declares Apache-2.0. Runtime/model license and reproducibility details: LOCAL_QWEN.md.


Optimized runtime: MLX LM 0.32.2 / MLX 0.32.4 / MLX Metal 0.32.4, isolated in tools/.mlx-venv and pinned in tools/requirements-mlx.txt. MLX and MLX LM use MIT licenses; Qwen model licensing remains Apache-2.0 as recorded above. No model weights or runtime environment are committed.

## Transactional storage — issue #4

Added sembast 3.9.0 and sembast_web 2.4.6+1 (BSD-3-Clause), idb_shim 2.10.1+1 (BSD-2-Clause), synchronized 3.5.0 (MIT), and direct path 1.9.1 (BSD-3-Clause). Licenses reviewed in downloaded package sources. Native storage uses existing path_provider; browser uses IndexedDB. Lockfile committed; no model/runtime dependencies changed. Retain required notices in distributed artifacts.
