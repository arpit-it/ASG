# F12 fixed stock test events

Issue [#406](https://github.com/arpit-it/ASG/issues/406) remains open. This
developer fixture exercises the installed Dart test libraries' suite declaration,
test dispatch and terminal event protocol through the actual Flutter tester. The
application's source candidate runner remains disabled.

The tool accepts only its bundled, hash-checked sources, a reviewed installed
Flutter SDK and a named fixture case. It uses Flutter 3.47.6 framework
`5fc346839b5d0eef006ed8404392afb4dfae428d`, Dart 3.13.5, `test_api` 0.7.12 and
`test_core` 0.6.18. No SDK, package cache or application changes are needed.
Compiler reports identify the actual source dependencies of both compiled
programs. The tool checks the installed package configuration, compiler tools,
source bytes, generated kernels and outside sentinel for preservation.

The confined engine runs an authored bootstrap that uses the unchanged
`RemoteListener.start` and connects to an already retained IPv4 or IPv6 socket
through the exact fresh session path. The trusted driver uses the existing
`OwnedDevice` adapter and extends its token gate at the installed stock
device's `HttpServer.first` seam. The request still goes through the stock
WebSocket upgrade, and the fixture guards the detached socket's inbound stream.
The driver relays individual JSON messages from the actual
`FlutterTesterTestDevice.start` channel to the unchanged `deserializeSuite`
and observes the terminal state from each real live test.
The bootstrap is purpose-built for the token path. The installed Flutter
bootstrap generator emits a bare socket URL and is not part of this fixture.

The passing test requires an actual engine view and checks denied sentinel
reads/writes, subprocess start and connection to an independent canary port.
The deliberate failure must produce the actual stock failure state and its
expected error. Both families must report the two named tests in order for the
positive case to pass. Missing or wrong suite names and premature or wrong
results cannot be recorded as success. The Stop and deadline cases run a third
test that records entry from inside the engine's writable directory before
waiting. The supervisor bounds time and output, settles the owned process group
and checks both independent canary listeners for zero connections.

The guard accepts masked, final text frames and bounded close frames. It
refuses compression offers before upgrade, and rejects unsupported flags,
opcodes, masks and lengths before forwarding a frame to the stock decoder.
It caps each payload at 16 KiB, and each incoming session at 128 KiB of framed
bytes and 128 frames, including close. It assembles at most one frame at a time.
The fixed raw peer writes the offending header a byte at a time and withholds
the mask and body. The byte-budget and frame-budget cases first send legal text
frames, then a header that would exceed the corresponding session limit. An
adverse receipt requires the specific guard refusal, peer EOF before the
driver requests engine termination, no test outcomes, and settled processes.
Decoded text, event count and hybrid spawn checks still run before suite
deserialization.

These limits apply to bytes after HTTP upgrade on the owned socket. HTTP parsing,
process memory, aggregate disk use, general WebSocket behavior, full Flutter CLI
or reporter integration, arbitrary test and candidate execution, native assets,
stable application replacement and failed replacement recovery remain outside
this fixture's validation.

From the repository root, with the reviewed SDK already installed:

```sh
python3 -B -m unittest discover -s asg/tools -p test_f12_stock_test_events.py -v
python3 -B asg/tools/f12_stock_test_events.py --synthetic-fixture --sdk "$SDK"
```

Add `--case wrong-token`, `missing-suite`, `wrong-suite`, `wrong-result`,
`deadline`, `stop`, `oversized-header`, `fragmented-header`, `session-bytes`,
or `session-frames` to observe a fixed adverse case. An expected adverse case
exits zero with `adverseCaseObserved: true` and `pass: false`. The command
prints the path to a private report with observed outcomes and exact local
identities. Portable tests validate refusal and parsing logic; use the live Mac
fixture for actual Flutter test protocol evidence.
