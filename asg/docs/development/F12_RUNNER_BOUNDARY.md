# F12 synthetic runner boundary prerequisite

Issue #406 remains open. This developer fixture establishes a bounded Mac
compilation/hook/engine isolation increment. Application candidate execution stays
disabled: no application operation, execution allowlist, source-candidate service,
or stable application is changed. No model-written source runs here.

## Contract and threat model

The only accepted source consists of two bundled, authored Dart fixtures whose
SHA-256 bytes are pinned in `tools/f12_runner_boundary.py`. The CLI has no source,
command, package, URL or entrypoint argument. Unknown fixture bytes and unknown
Flutter framework revisions fail before launch. An installed, owner-managed SDK
is a trusted prerequisite; hashes establish observed identity and detect changes,
not SDK authenticity. The reviewed layout is Flutter 3.47.6, framework
`5fc346839b5d0eef006ed8404392afb4dfae428d`, Dart 3.13.5, including the installed
`darwin-x64` engine artifact directory on this Apple Silicon Mac.

The adversarial actions are fixed attempts to read/write an outside sentinel,
spawn a subprocess, reach an unauthorized loopback port in both address families,
flood output, run past a deadline, and send incorrect broker session metadata.
A hostile process already acting as the same logged-in user, SDK compromise,
resource exhaustion and arbitrary candidate/package behavior are outside this
increment. Broad read access to installed SDK and macOS system-library locations
is necessary for these fixed tools; this is not a promise that arbitrary source
can safely access those locations.

## Separate authority for each stage

A private mode-0700 derivative root contains read-only fixed source copies and
separate hook, compilation and engine directories. Each stage can write only its
own directory and `/dev/null`; neither original source nor the installed SDK is
writable through its policy. The outside sentinel and broker nonce are unavailable
to hook/compile reads. The original repository is not mounted as input.

1. An authored standalone Dart hook probe runs under a deny-network policy. It
   verifies denied sentinel reads/writes, subprocess creation and networking,
   while writing a fixed result inside its own directory. It is not general
   Flutter package-hook discovery or orchestration.
2. The installed `dartaotruntime` runs the installed frontend-server snapshot with
   fixed `--target=flutter --no-link-platform` arguments and the Flutter patched
   SDK. Its deny-network policy allows only its own derivative outputs. A failed
   hook/compiler, missing or malformed kernel, linked/oversized output, or changed
   source/tool identity prevents engine launch. The kernel must be a single-link
   regular file with the Dart kernel magic; its bytes are hashed and made read-only.
3. The installed `flutter_tester` executes that fixed kernel. The fixture imports
   `dart:ui` and checks a real engine view. This is actual Flutter engine execution,
   not a pure-Dart substitute. It uses a small custom TCP fixture protocol, **not**
   the unchanged stock Flutter test WebSocket harness or its dynamic parent port.

All three profiles deny process-fork and process-group/session escape calls.
The supervisor owns a process group, handles Stop/SIGINT/SIGTERM, applies deadlines,
retains at most 64 KiB of stdout/stderr, terminates then kills/reaps the group, and
fails if output supervision or group cleanup does not settle. Resource limits are
20 CPU seconds per process, 32 MiB per output file, 128 descriptors and no core
dumps. Stage wall deadlines are at most 30 seconds (engine probes use 1 or 10).
Memory and aggregate disk usage are not bounded. No stress test is used.

## Owned IPC

Before any child launch, the parent binds and retains listeners on both
`127.0.0.1` and `::1` at one numeric TCP port, with IPv6-only binding. Failure to
own either family fails closed and releases acquired sockets. The engine policy
permits outbound TCP only to `localhost:<that exact port>`; hook and compiler have
no network permission. A separately owned dual-family canary port must receive
no connection. No broad loopback or inbound network permission is granted.

The parent owns the listener through engine termination and frame validation.
The fixed small messages fit in the listener backlog; synchronous draining avoids
a broker thread across child resource setup. There is no command dispatcher.
Each of exactly two frames is limited to 4096 bytes and one newline-terminated
JSON object. Duplicate keys, trailing frames, wrong schema/stage/family, unexpected
keys, false/non-boolean observations, incorrect random nonce or source/kernel hash
fail closed. The claimed family must match the actual listener family. The nonce
is passed only to the engine. Authentication does not make child assertions
trusted: fixed known observations are combined with independent empty-canary,
source/tool/sentinel preservation and process-group checks.

## Reproduction and evidence limits

From the repository root, with an already installed reviewed SDK:

```sh
python3 -B -m unittest discover -s asg/tools -p test_f12_runner_boundary.py -v
python3 -B asg/tools/f12_runner_boundary.py --synthetic-fixture --sdk "$SDK"
python3 -B asg/tools/f12_runner_boundary.py --synthetic-fixture --sdk "$SDK" --case timeout
python3 -B asg/tools/f12_runner_boundary.py --synthetic-fixture --sdk "$SDK" --case cancel
python3 -B asg/tools/f12_runner_boundary.py --synthetic-fixture --sdk "$SDK" --case output
python3 -B asg/tools/f12_runner_boundary.py --synthetic-fixture --sdk "$SDK" --case malformed
```

Every live invocation retains a private report with exact helper, fixed-source,
SDK artifact, kernel and policy hashes; fixed argv, measured stage durations,
cleanup, denials and preservation observations. It prints that report as JSON.
For adverse cases, `pass` remains false and `adverseCaseObserved` distinguishes
successful observation of the intended failure. Portable unit tests are not live
Mac capability evidence. Missing runtime, policy refusal and unsupported host
remain failures, not skipped tests passed as execution.

On 8 November 2026 this Mac directly observed fixed hook, Flutter-target kernel
compilation and actual engine completion; timeout, cancellation, output flood
and incorrect nonce were contained. Exact final revision reports are recorded in
the integration evidence. External sentinel and original fixture/tool bytes stayed
unchanged, both unauthorized canary families stayed empty, owned groups were
reaped, and listeners were released. This does not verify arbitrary generated
candidates, general hooks, stock test harness integration, other SDK versions or
platforms, stable replacement/recovery, or full F12 acceptance. Enabling any
candidate operation requires a separately reviewed implementation and evidence.
