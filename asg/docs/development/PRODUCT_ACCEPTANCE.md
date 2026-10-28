# Product acceptance evidence (F17)

The version 1 [scenario manifest](product_acceptance_manifest.json) inventories
initial macOS/web checks and references existing tests. References identify a
suite to extend/run; their presence does not establish that the scenario passed.
The fixture, build, application launch, live inference, generated output and
manual interaction kinds remain separate. Native Android, iOS, Windows and Linux
cells are unavailable in this initial manifest, including on a host where a
fixture or build succeeds. This is an evidence collection foundation, not the
completed F17 baseline or a product support certification. No scenario is executed
by this tool. UI integration and real isolated-profile workflows remain pending.

`tools/product_acceptance.py` reads three JSON files and atomically writes a saved
evidence matrix. It uses only Python's standard library:

```sh
python3 -B tools/product_acceptance.py \
  --manifest docs/development/product_acceptance_manifest.json \
  --identity /tmp/current-acceptance-identity.json \
  --evidence /tmp/saved-acceptance-evidence.json \
  --output /tmp/acceptance-report.json
python3 -B tools/test_product_acceptance.py
```

The identity object has exactly these fields:

| Field | Required representation |
| --- | --- |
| sourceRevision | 40 lowercase hexadecimal characters, exact tested Git commit |
| requirementSha256 | SHA-256 of exact requirement snapshot used by F10 |
| inputSha256 | SHA-256 of exact approved source/input snapshot used by F10 |
| configurationSha256 | SHA-256 of effective scenario configuration |
| modelSha256 | SHA-256 of the exact model/revision/format identity |
| deviceSha256 | SHA-256 of sanitized host/device identity |
| sdkVersion, runtimeVersion, browserVersion | Numeric dotted version (up to four components) or `unavailable` |
| backend | `mlx`, `torch-mps`, `none` or `unavailable` |
| host | `macos`, `web`, `android`, `ios`, `windows` or `linux` |

Hash absent components using a stable explicit sentinel, e.g. the UTF-8 bytes
`unavailable`; do not invent a working model/device. Callers must collect exact
identities and rerun affected scenarios when they change. The collector compares
identities; it cannot discover changes or authenticate caller-supplied results.
Requirement/input hashes must come from the same F10 snapshots, not a prose
summary. Never hash credentials/prompts as identities or include them in records.

Evidence has `schemaVersion: 1` and `records: []` initially. Each record contains
exactly `scenarioId`, `checkId` (from the manifest), `target`, `status`,
`observedAt` (UTC `YYYY-MM-DDTHH:MM:SSZ`), `identity`, `manifestSha256`, and
`artifactSha256` (up to 16 SHA-256 digests of sanitized artifacts). Compute the
manifest hash using the module's `sha(manifest)` canonical JSON function. Only
`passed`, `failed`, `skipped`, and `unavailable` are accepted saved statuses.
Record one observation per scenario/check/target; replace it deliberately after
a rerun rather than relying on ordering. Keep historical runs separately.

The report marks absent configured evidence `missing`, unconfigured targets
`unavailable`, and any identity/manifest mismatch `stale`. Only an exact-current
saved `passed` record sets that cell's `currentPass`. This flag describes the
submitted observation, not semantic acceptance or current support. No aggregate
verified/support claim is produced. A saved failure also becomes stale after an
identity change; its original status remains visible in `savedEvidence`.

Inputs are bounded to 1 MiB each. Unknown/duplicate fields, unknown scenarios,
duplicate observations, future timestamps, invalid versions/digests and raw
artifact content are rejected before output changes. The schema accepts digest
artifacts only, no paths, prompts, logs, URLs, credentials or model weights.
Sanitize external artifacts before hashing/sharing; a digest does not sanitize
its underlying file. Errors deliberately omit input content and filesystem paths.
Existing report output survives validation failures. Do not overwrite evidence
inputs with report output. Reports are saved observations, never live health.
