# Application security boundaries

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

Discuss, Plan and advisory Review have no source/file/command tools. Interpreted prototype edits accept only validated bounded data. The macOS fixed Flutter starter flow writes a new directory exclusively and runs only approved trusted SDK operations using argument arrays and a bounded Python process-group helper. Paths, source/dependency metadata and compiled output are validated/fingerprinted; changed evidence blocks work/preview. Exact latest Plan/project/board/prototype approval plus separate operation consent are required. These controls do not provide OS isolation or permit arbitrary downloaded/untrusted source execution. See [generation boundaries](../architecture/GENERATION.md).

Explicit public-repository model downloads and selected local checkpoint startup are available in runtime setup; opening setup never downloads a model. Repository Python is not loaded (`trust_remote_code=False`). Only app-owned processes can be stopped. The owner-approved macOS App Sandbox disablement permits trusted host Python/SDK integration using host-user permissions; it does not alter system protections or isolate children. See [runtime setup](../setup/RUNTIME_SETUP.md).

Transactional native/IndexedDB storage is unencrypted and is not a secrets vault. Preserve corrupt data and retained migration backups; do not reset to empty state. Cross-process/tab synchronization and malicious same-user host tampering are outside current guarantees. Resumable action auditing/limits, arbitrary source edits and isolated self-development remain F03/F04/F12 in [requirements](../REQUIREMENTS.md).

Repository access, CI permissions, branch protection and private vulnerability reporting are documented in the root [security policy](../../../SECURITY.md). Never publish credentials in issue/review evidence.
