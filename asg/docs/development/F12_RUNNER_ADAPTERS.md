# F12 real hook orchestration and stock Flutter device adapters

Issue [#406](https://github.com/arpit-it/ASG/issues/406) remains open.
Application candidate execution remains **disabled**. These developer fixtures
accept only fixed authored sources and named cases; there is no candidate,
command, package URL, graph or test-file CLI argument. No installed SDK, package
cache, stable app, application service or execution allowlist is modified.

## Actual integration and trust split

The reviewed installed toolchain is Flutter 3.47.6 framework
`5fc346839b5d0eef006ed8404392afb4dfae428d`, Dart 3.13.5,
`hooks_runner` 1.5.0 and `hooks` 2.0.2. The owner-selected SDK/cache is trusted;
observed hashes detect changed inputs, not package authenticity or hostile
same-user tampering. Existing setup must already contain these packages. There
is no installation, `pub get`, network request or SDK patch.

The authored trusted Dart orchestrator imports the **installed unchanged**
`NativeAssetsBuildRunner` and `FlutterTesterTestDevice`. Its actual transitive
source dependencies are taken from the compiler's dependency file and hashed,
with a 3,000-file / 40-MiB observation bound and a 2-MiB individual-file bound.
The installed package configuration and hooks_runner version are recorded too.
A separate bounded read-only copy of the hooks library import closure supplies
hook compilation inputs, as in the preceding supervisor fixture. These observed
inputs, helper dependencies, compiler tools and generated kernels are checked
for preservation. Trusted orchestration executes outside child confinement; it
never imports a package hook entrypoint into its own isolate. Only fixed trusted
SDK/package libraries and the pinned driver are imported.

### Real package graph planning, compilation and build/link dispatch

An isolated package configuration and graph contain authored `fixture_a` depending
on `fixture_b`. Each has real `hook/build.dart` and `hook/link.dart` entrypoints.
The real runner plans and validates the graph, creates actual inputs, compiles
hooks, calls the real hook APIs, validates output, and invokes build and link.
The observed invocation order must be exactly B-build, A-build, A-link, B-link.
This is eight actual child dispatches: compiler and hook for each graph stage.
Neither the planner nor the hook API is replaced with a lookalike.

`NativeAssetsBuildRunner.dartExecutable` is the adapter seam: its value is a
private manifest-bound executable shim. The unchanged runner's real
`runProcess` calls reach that shim. There is no fallback executable. The shim
admits only the installed runner's exact compiler and hook argument shapes,
package configuration, incoming working directory, fixed source entrypoints,
canonical cache paths and package identity. It rejects added flags, other commands,
unknown kernels, changed inputs and paths outside the private cache before launch.
Hook execution must reference exactly one previously admitted compiler result,
with its recorded kernel hash. It ignores inherited environment and constructs
an explicit small environment; hook results cannot request commands or policy.

The compiler wrapper (`dart compile kernel`) would need child-process authority.
The adapter instead invokes installed `dartaotruntime` and the real
`gen_kernel_aot.dart.snapshot` directly, preserving actual runner arguments and
output/depfile locations. It normalizes the compiler's child working directory
to that output stage; hook children retain the requested package working directory.
Each compiler/hook receives a separate deny-network/no-fork policy. Read-only
source/imports are separated from the orchestration cache. A hook may write only
its own cache/output directory and exact shared output directory. Inputs must
remain byte-identical. Outside-sentinel reads/writes, subprocess creation and
both-family broker connections are attempted by the authored hooks and must fail.
The supervisor independently checks preservation and strictly refuses command-
bearing, asset-bearing, linked or oversized output before the runner can proceed.
Any hook/compiler failure prevents remaining graph work and stock device launch.

These no-assets fixtures exercise real graph orchestration and real build/link
validation. Native C toolchain discovery, asset routing/loading, caching reuse,
arbitrary dependency graphs and third-party hooks are not verified or enabled.
Each invocation uses a fresh private graph/cache; no stale success carries over.

### Actual stock Flutter test IPC, without a reserve/rebind gap

The trusted orchestrator binds IPv4 and IPv6-only `HttpServer`s to one numeric
loopback port before graph dispatch. A subclass of the installed
`FlutterTesterTestDevice` overrides only its documented protected `bind` seam to
return those already-bound servers. It calls the real stock `start` and inherited
`remoteChannel`; the stock implementation itself performs WebSocket upgrade and
JSON-string stream transport. This is actual stock device IPC, not the previous
custom broker reproducing its shape. No Flutter SDK source is copied or patched.

A `HttpServer` stream adapter filters the exact fresh session-token path, query
and Origin before the stock `remoteChannel` can observe its first request.
Rejected requests receive 403 and cannot become the stock first upgraded client.
The adapter's `close` deliberately retains the underlying server: the outer
supervisor owns both listeners until both devices settle, including the interval
between IPv4 and IPv6 runs. It never closes a reserved socket to rebind a port.
The parent records the owned port before permitting graph work or engine dispatch.

A `ProcessManager` adapter validates the complete actual stock engine command,
its port and allowed launch options. It then dispatches that command through the
existing deny-fork engine policy, permitting outbound access only to the exact
owned port. It supplies an explicit environment, no shell or detached mode.
The actual Flutter engine imports `dart:ui`, connects using stock `SERVER_PORT`,
and sends a fixed canonical session/source/kernel observation. The first result
must exactly equal the expected typed JSON encoding, rejecting duplicate keys,
noninteger schema variants, extra keys and changed identity. Both families must
succeed; results grant no execution, approval or promotion authority.

The transport now uses Dart's stock WebSocket decoder. A 4,096-character result
limit is checked **after decoding**; it is not a preallocation/raw-frame or memory
bound. The fixed oversized fixture is rejected, but arbitrary huge, fragmented,
compressed or control-frame streams are not proven contained. No complete
`package:test` event protocol or generated stock test bootstrap is advertised.
The authored bootstrap drives the actual stock device/channel seam only. These
limits prohibit enabling arbitrary candidate tests from this fixture result.

## Owned work, Stop and evidence

The Python parent owns one process group containing the trusted orchestrator,
shim processes and all confined children. Shim children inherit that group and
cannot fork or escape it. No nested detached group is created. Each shim applies
CPU/file/descriptor limits and streams at most 64 KiB of combined output, killing
and waiting on overflow/deadline rather than buffering unlimited output first.
The parent bounds the complete orchestrator to 30 seconds and 64 KiB, sends Stop,
then TERM/KILL as needed, reaps the owner and verifies no group remains. The stock
device kills and awaits each owned engine; the outer owner closes both listeners
only at settlement. A separately owned dual-family unauthorized port must receive
no connection. Authored engine probes also attempt denied sentinel access,
subprocess creation and both-family canary connections.

Profiles retain the earlier 20 CPU-second/process, 32-MiB/file, 128-descriptor,
no-core limits. Memory and aggregate disk are unbounded. Resource exhaustion,
malicious installed SDK/cache, hostile same-user peers and general candidate
safety are outside this increment. An unauthorized peer may cause denial of
service; it receives no channel or command authority. Token possession binds a
session, not a trustworthy assertion about arbitrary code.

Reports retain exact helper/fixture/source/tool/kernel identities, dispatched
argv, graph order, measured stages, stock-call observations and preservation/
cleanup results. Adverse reports remain `pass: false`; `adverseCaseObserved`
requires the selected specific failure, preserved inputs and clean owned work.
Hook failures additionally require that no stock device started. Portable tests
are defenses, not live Mac capability evidence.

## Reproduce with the already installed SDK

From repository root:

```sh
python3 -B asg/tools/test_f12_runner_adapters.py
python3 -B asg/tools/f12_runner_adapters.py --synthetic-fixture --sdk "$SDK"
```

Use `--case` for `hook-failure`, `hook-timeout`, `hook-output`, `hook-overflow`,
`wrong-token`, `oversized-message`, `malformed-message`, `engine-timeout` or `stop`.
Exit zero means the fixed positive case or selected expected adverse observation
passed. Unknown inputs and unavailable prerequisites fail, rather than counting
skipped checks as live capability. Final revision reports, independent review,
required CI and verified protected merge are recorded in the canonical ledger.
F12 remains open; this developer adapter is not connected to application actions.
