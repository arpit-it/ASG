"""Compile and test the actual migration function without touching app records."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'macos/Runner/MainFlutterWindow.swift').read_text()
function = source[source.index('  static func restoreLegacyPreferences'):source.rfind('\n}')].replace('  static func ', 'func ', 1)
checks = '''
let suite = "asg.migration.test.\\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: file) }
let values = ["flutter.studio.projects.v1": "legacy-project", "studio.localModel.v1": "legacy-model", "unrelated": "ignored"]
try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: file)
defaults.set("new-project", forKey: "flutter.studio.projects.v1")
try restoreLegacyPreferences(from: file, into: defaults)
assert(defaults.string(forKey: "flutter.studio.projects.v1") == "new-project")
assert(defaults.string(forKey: "studio.localModel.v1") == "legacy-model")
assert(defaults.object(forKey: "unrelated") == nil)
try Data("invalid plist".utf8).write(to: file)
var failed = false
do { try restoreLegacyPreferences(from: file, into: defaults) } catch { failed = true }
assert(failed)
assert(defaults.string(forKey: "flutter.studio.projects.v1") == "new-project")
print("Legacy preferences migration checks passed")
'''
with tempfile.TemporaryDirectory() as temporary:
    script = Path(temporary) / 'MigrationCheck.swift'
    script.write_text('import Foundation\n' + function + '\n' + checks)
    subprocess.run(['swift', str(script)], check=True)
