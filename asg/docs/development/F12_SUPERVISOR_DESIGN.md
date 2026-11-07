# F12 supervisor design: package hooks and Flutter test IPC

Issue [#406](https://github.com/arpit-it/ASG/issues/406) remains open. This is a
reviewable supervisor design with fixed authored Mac fixtures. **Application
candidate execution remains disabled.** No application service, operation enum,
execution allowlist, stable installation or SDK file changes. The probe has no
candidate path, command, package URL or test-file argument. An authored fixture
is never evidence that arbitrary candidate code is safe.

## Why a supervisor must own dispatch

At reviewed Flutter framework `5fc346839b5d0eef006ed8404392afb4dfae428d`, Flutter's
`FlutterNativeAssetsBuildRunnerImpl` delegates build/link to installed
`hooks_runner` 1.5.0. Its `build_runner.dart` compiles hook kernels and invokes
Dart with `--packages=... hook.dill --config=...`. It also plans dependencies,
manages caches and routes native assets. Running this complete orchestration
outside confinement would execute package hooks with host authority; running it
inside the existing no-fork stage would refuse required child launches.

`FlutterTesterTestDevice.start` separately binds `host, 0`, exports `SERVER_PORT`
and upgrades its first HTTP request to WebSocket. Its VM-service port is unrelated.
Its overrideable `bind` method is a test seam, not an external server-handoff API.
A brief reserve/close/rebind window cannot establish socket ownership. The stock
first-client transport does not authenticate a session before channel authority.

The proposed trust split is therefore explicit:

| Component | Authority | Must never accept |
| --- | --- | --- |
| Supervisor | Read a reviewed manifest; create private stages; compile known inputs; retain IPC; dispatch fixed tool invocations; revoke all owned work | Commands, environment additions or policy text from hook output/test messages |
| Hook planner adapter, future | Produce a bounded declarative package DAG and input description for supervisor validation | Direct child launch, network/install effects, reused mutable cache authority |
| Hook child | Read only admitted source/dependencies and exact input/kernel; write only its own derivative directory | Fork/exec descendants, network, repository/stable-app writes |
| Trusted test bootstrap adapter, future | Bind candidate test invocation to a preowned session channel before tests load | Candidate-selected endpoints or self-declared successful checks |
| Test/engine child | Use only exact owned broker port; emit bounded session-bound protocol | Broader localhost authority, host commands or approval/promotion |

A supervisor-owned dispatcher handles compilation as its own confined child,
then dispatches the hook kernel directly. `dart compile kernel` itself launches
a compiler child and is intentionally denied by the stage policy; the fixture
uses the installed `dartaotruntime` / `gen_kernel_aot.dart.snapshot` directly.
No fork permission is granted to make the wrapper work.

## What the executable fixture establishes

`tools/f12_supervisor_design.py --synthetic-fixture --sdk ...` accepts only fixed
cases and hash-pinned bundled sources. It requires the installed reviewed Flutter
revision and `hooks` 2.0.2. It copies the installed Dart-library import closure
into a private read-only input tree (at most 1,500 files / 20 MiB, each at most
1 MiB), creates an isolated package configuration, and records every copied file
and pubspec hash. There is no dependency resolution, installation or download.
These hashes record observed identity; the owner-selected SDK/package cache is
trusted input, not cryptographically authenticated by the fixture.

The fixed package has `hook/build.dart` and `hook/link.dart`. Each is separately
compiled and actually calls the installed `package:hooks/hooks.dart` `build` or
`link` API with an actual `--config` input. This is real package-hook protocol
execution, rather than the earlier standalone Dart hook-shaped probe. The hooks
emit no native assets. Their fixed probes observe denied outside-sentinel reads,
writes, process launch and both address-family broker connections while writing
inside their assigned output directory.

A separate confined trusted fixture uses the actual `BuildInputBuilder` /
`LinkInputBuilder` and `ProtocolBase.validateBuildOutput` /
`validateLinkOutput`. The supervisor additionally rejects linked, oversized,
duplicate-key, command-bearing, asset-bearing or failed output using a strict
no-assets schema. The hook input must remain byte-identical. Failed hook or
validation never dispatches the engine. Stale output is avoided by unique private
runs, with all artifacts retained for inspection; no result/cache carries forward.
The parent checks pinned source, copied dependency and tool/kernel identities
before subsequent stages and at settlement.

This tests direct authored hooks using the real installed API. It does **not**
implement or verify the complete `NativeAssetsBuildRunner` planner, transitive
hook ordering, extension/native toolchain dispatch, asset routing, native library
loading, caching or arbitrary third-party package hooks.

## Owned WebSocket boundary

The supervisor binds and retains IPv4 and IPv6-only listeners on one numeric
loopback port before any hook or engine launch. Both families must succeed or the
run fails closed. The confined engine can connect only to this exact port. A
separate trusted broker process inherits the listener objects; no Python broker
thread exists across `fork`/`preexec` child resource setup. The parent retains its
socket copies until engine and broker settle. The broker has no command handler
and does not evaluate source. It is trusted supervisor code, **not** a confined
candidate child. Its deadline and process ownership are bounded by its parent.

The authored actual Flutter engine bootstrap imports `dart:ui`, observes an engine
view, consumes `SERVER_PORT`, and uses Dart's real `WebSocket.connect`/JSON-string
transport. It connects in both address families. This matches the relevant stock
transport shape while strengthening channel admission:

- A fresh random 192-bit session token is required in the exact HTTP request path
  before upgrade. Wrong paths, duplicate headers, Origin/subprotocol negotiation,
  wrong version/key and oversized upgrades are rejected. A token is not a trusted
  assertion about a candidate: it binds this owned bootstrap session only.
- Client frames must be masked, final UTF-8 text, at most 4 KiB, with canonical
  lengths. Fragmentation, compression/RSV bits, binary/control frames in the data
  position, unmasked/large/truncated frames and extra/replayed messages fail.
- Each family has exactly one strict JSON message with integer schema, exact
  session/source/kernel identity and actual authored engine observation; duplicate
  keys, nonfinite numbers and other fields fail. Only a normal close may follow.
  This deliberately narrow protocol is not a general WebSocket implementation.
- Each connection has a two-second I/O deadline; the broker has a 12-second
  acceptance deadline and the parent reaps it after engine settlement. An early
  unauthorized peer may cause refusal/denial of service; it cannot gain execution
  or promotion authority. Availability against hostile same-user peers is not
  claimed.

The unchanged stock Flutter tools/harness is **not integrated**: the actual
`FlutterTesterTestDevice` still owns its internal bind. A future reviewed trusted
adapter must either accept a retained server/channel or replace that specific
bootstrap/launcher seam without widening candidate authority. Merely setting a
port flag, authenticating child prose or passing these fixtures is insufficient.

## Stop, resource and evidence boundaries

The existing stage supervisor supplies separate mode-0700 writable directories,
no-network hook/compiler policy, no process-fork/session/group escape, owned
process-group TERM/KILL/reap, at most 64 KiB combined output, 20 CPU seconds per
process, 32 MiB per output file, 128 descriptors and no core dumps. Wall deadlines
are at most 30 seconds; adverse hook/engine fixtures use one second and explicit
engine Stop uses 0.2 seconds. A supervisor-wide signal handler retains ownership
between stages. The broker runs separately with bounded frames/deadlines and is
terminated/reaped on failure or Stop. Listeners close only after owned work settles.

Memory and aggregate disk are not bounded; resource exhaustion and hostile
same-user/SDK/package-cache tampering are not contained by this design fixture.
System/SDK library reads retain the earlier documented policy scope. Full
candidate enablement needs its own security acceptance, stable-app recovery,
review/approval binding and unsupported-host refusal. None is inferred here.

Every run retains source/package/tool/compiler/kernel hashes, fixed argv, policy
hashes, measured stage durations, exit/termination reasons, group/broker cleanup,
canary and preservation observations in a private `report.json`. A positive pass
requires both actual hook APIs and validators, compilation, engine and both
WebSocket sessions. Adverse reports remain `pass: false`; `adverseCaseObserved`
requires the specific expected failure rather than treating any failure as success.
Portable unit tests are parser defenses, not live Mac/stock-harness capability.

## Reproduce with the already installed reviewed SDK

From repository root:

```sh
python3 -B asg/tools/test_f12_supervisor_design.py
python3 -B asg/tools/f12_supervisor_design.py --synthetic-fixture --sdk "$SDK"
python3 -B asg/tools/f12_supervisor_design.py --synthetic-fixture --sdk "$SDK" --case hook-timeout
python3 -B asg/tools/f12_supervisor_design.py --synthetic-fixture --sdk "$SDK" --case hook-output
python3 -B asg/tools/f12_supervisor_design.py --synthetic-fixture --sdk "$SDK" --case wrong-token
python3 -B asg/tools/f12_supervisor_design.py --synthetic-fixture --sdk "$SDK" --case extra-frame
python3 -B asg/tools/f12_supervisor_design.py --synthetic-fixture --sdk "$SDK" --case engine-timeout
python3 -B asg/tools/f12_supervisor_design.py --synthetic-fixture --sdk "$SDK" --case stop
```

Exit zero means the fixed positive acceptance or the selected expected adverse
observation passed. Missing prerequisites, unexpected failure, unknown fixture
bytes or unsupported execution produce failure; no skipped check establishes
live capability. Exact final revision results and merge receipts belong in the
canonical requirements/history evidence. F12 and issue #406 remain unchecked.
