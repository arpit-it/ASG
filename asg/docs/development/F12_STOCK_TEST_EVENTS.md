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
`OwnedDevice` and `Gate` adapters unchanged. It relays individual JSON messages
from the actual `FlutterTesterTestDevice.start` channel to the unchanged
`deserializeSuite` and observes the terminal state from each real live test.
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

The existing WebSocket implementation allocates incoming frames before the
fixture can limit decoded text size and event count. The fixture refuses hybrid
spawn events before handing them to the stock deserializer. It does not prove
memory or aggregate disk bounds, full Flutter CLI or reporter integration,
general package graphs, arbitrary test or candidate execution, native assets,
stable application replacement, or recovery from a failed replacement.

From the repository root, with the reviewed SDK already installed:

```sh
python3 -B -m unittest discover -s asg/tools -p test_f12_stock_test_events.py -v
python3 -B asg/tools/f12_stock_test_events.py --synthetic-fixture --sdk "$SDK"
```

Add `--case wrong-token`, `missing-suite`, `wrong-suite`, `wrong-result`,
`deadline`, or `stop` to observe a fixed adverse case. An expected adverse case
exits zero with `adverseCaseObserved: true` and `pass: false`. The command
prints the path to a private report with observed outcomes and exact local
identities. Portable tests validate refusal and parsing logic; use the live Mac
fixture for actual Flutter test protocol evidence.
