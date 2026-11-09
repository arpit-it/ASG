# F12 fixed stock test events

Issue [#406](https://github.com/arpit-it/ASG/issues/406) remains open. This
developer fixture exercises the installed Dart test libraries' suite declaration,
test dispatch and terminal event protocol through the actual Flutter tester. The
application's source candidate runner remains disabled.

The tool accepts only its bundled, hash-checked sources, a reviewed installed
Flutter SDK and a named fixture case. It uses Flutter 3.47.6 framework
`5fc346839b5d0eef006ed8404392afb4dfae428d`, Dart 3.13.5, `test_api` 0.7.12 and
`test_core` 0.6.18. No SDK, package cache or application changes are needed.
Compiler reports identify the actual source dependencies of the compiled
programs. The tool checks the installed package configuration, compiler tools,
source bytes, generated kernels and outside sentinel for preservation.

The default case runs an authored bootstrap that uses the unchanged
`RemoteListener.start` and connects to an already retained IPv4 or IPv6 socket
through the exact fresh session path. The trusted driver uses the existing
`OwnedDevice` adapter and extends its token gate at the installed stock
device's `HttpServer.first` seam. The request still goes through the stock
WebSocket upgrade, and the fixture guards the detached socket's inbound stream.
The driver relays individual JSON messages from the actual
`FlutterTesterTestDevice.start` channel to the unchanged `deserializeSuite`
and observes the terminal state from each real live test.
The generated cases invoke the installed Flutter tool's `generateTestBootstrap`
for each loopback family and compile its output as emitted. The generated source,
fixed test file, installed generator dependency and resulting kernels are
identified in the private report. The stock launch command must request the
owned numeric port. The confined process adapter then supplies the same port
with a fresh session path for these cases, which the generated bootstrap
includes in its request. The missing-token case supplies only the numeric
port and requires an observed gate refusal and settled process group.

The generated widget case enables the installed bootstrap's `flutter_test`
branch. It pumps a fixed text widget, checks that it is present, then reports
a deliberate finder failure in a separate widget test. Flutter reports the
finder failure as `Result.error`. Both families must return the named
results and emit the original finder diagnostic. Its Stop case waits inside
a third widget test until the supervisor cancels the owned process group. It uses an engine
package configuration built from the SDK's tool configuration plus pinned
installed Flutter and cache packages. The report hashes the overlay and the
compiler's source closure, including `flutter` and `flutter_test` library
entry points. The compiler omits embedded source text and the duplicate
dependency log so the widget case fits the existing file and output limits.
The dependency file still supplies the closure used for verification.

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
rejects unsupported flags, opcodes, masks and lengths before forwarding a
frame to the stock decoder. The authored bootstrap disables compression.
After the token check, the generated cases admit only the installed client's
exact default compression offer. The driver hides that offer from stock
negotiation and checks that the outgoing upgrade response has no extension
header before detaching the socket. A fixed authenticated client offering
different parameters must observe HTTP 403 before the driver stops it.

The frame guard caps each payload at 16 KiB, and each incoming session at 128 KiB of framed
bytes and 128 frames, including close. It assembles at most one frame at a time.
The fixed raw peer writes the offending header a byte at a time and withholds
the mask and body. The byte-budget and frame-budget cases first send legal text
frames, then a header that would exceed the corresponding session limit. An
adverse receipt requires the specific guard refusal, peer EOF before the
driver requests engine termination, no test outcomes, and settled processes.
Decoded text, event count and hybrid spawn checks still run before suite
deserialization.

After reaping the driver, the fixture checks whether its process group still
exists before sending a final SIGKILL. A denied signal leaves cleanup
unconfirmed. The fixture polls for up to half a second and accepts cleanup
only after a signal-zero probe reports that the group is absent. If cleanup
cannot be confirmed, the report keeps the fixture observations and includes a
cleanup error. The run fails even if the fixture observed the expected result.

These limits apply to bytes after HTTP upgrade on the owned socket. HTTP parsing,
process memory, aggregate disk use, general WebSocket behavior, full Flutter CLI
or reporter integration, arbitrary test and candidate execution, native assets,
stable application replacement and failed replacement recovery remain outside
this fixture's validation.

From the repository root, with the reviewed SDK already installed:

```sh
python3 -B -m unittest discover -s asg/tools -p test_f12_stock_test_events.py -v
python3 -B asg/tools/f12_stock_test_events.py --synthetic-fixture --sdk "$SDK"
python3 -B asg/tools/f12_stock_test_events.py --synthetic-fixture --sdk "$SDK" --case generated-positive
python3 -B asg/tools/f12_stock_test_events.py --synthetic-fixture --sdk "$SDK" --case generated-widget-positive
```

Add `--case wrong-token`, `missing-suite`, `wrong-suite`, `wrong-result`,
`deadline`, `stop`, `oversized-header`, `fragmented-header`, `session-bytes`,
`session-frames`, `generated-missing-token`, `generated-stop`,
`generated-widget-stop`, or `unexpected-extension` to observe a fixed adverse case. An expected adverse case
exits zero with `adverseCaseObserved: true` and `pass: false`. The command
prints the path to a private report with observed outcomes and exact local
identities. Portable tests validate refusal and parsing logic; use the live Mac
fixture for actual Flutter test protocol evidence.
