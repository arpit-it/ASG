# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Inventory separate saved observations; never create a passing support matrix."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import tempfile
from datetime import datetime, timezone

from product_acceptance import read_json, report, require, sha, digest, shape, utc, TARGETS, manifest

CLAIM = 'separate-historical-observations-only'


def file_sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_file(root, relative):
    require(type(relative) is str and len(relative) <= 240, 'Invalid reference')
    parts = PurePosixPath(relative).parts
    require(parts and not relative.startswith('/') and '\\' not in relative
            and all(p not in ('.', '..') for p in parts)
            and str(PurePosixPath(relative)) == relative, 'Invalid reference')
    path = root / relative
    require(path.resolve().is_relative_to(root.resolve()), 'Escaping reference')
    require(not any(parent.is_symlink() for parent in (path, *path.parents)
                    if parent != root.parent), 'Symlink reference')
    return path


def source_comparison(app, folder):
    """Compare supplied recorded paths, not Git ancestry or binary equivalence."""
    path = folder / 'source-manifest.json'
    if not path.exists():
        return {'status': 'not-recorded'}
    values = read_json(safe_file(app, path.relative_to(app).as_posix()))
    require(type(values) is dict and len(values) <= 4096, 'Invalid source manifest')
    seen, changed, absent = set(), [], []
    runtime_recorded = set()
    for name, expected in sorted(values.items()):
        digest(expected)
        relative = name.removeprefix('asg/')
        candidate = safe_file(app, relative)
        require(relative not in seen, 'Duplicate normalized source path')
        seen.add(relative)
        if relative.startswith('lib/'):
            runtime_recorded.add(relative)
        if not candidate.is_file():
            absent.append(relative)
        elif file_sha(candidate) != expected:
            changed.append(relative)
    runtime = {p.relative_to(app).as_posix() for p in (app / 'lib').rglob('*.dart')}
    return {'status': 'compared-recorded-files-only',
            'manifestSha256': file_sha(path), 'recordedFiles': len(values),
            'changedRecordedFiles': changed, 'absentRecordedFiles': absent,
            'unrecordedRuntimeFiles': sorted(runtime - runtime_recorded)}


def validate_saved_report(path, spec, identity, evidence, now):
    """Validate historical rendering without treating it as today's manifest."""
    value = read_json(path)
    shape(value, ('schemaVersion', 'generatedAt', 'manifestSha256', 'identity', 'claim', 'cells'))
    require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1
            and value['claim'] == 'saved-evidence-only' and value['identity'] == identity,
            'Invalid saved report')
    digest(value['manifestSha256'])
    require(utc(value['generatedAt']) <= utc(now), 'Future report')
    report(spec, identity, evidence, value['generatedAt'])
    require(type(value['cells']) is list and len(value['cells']) <= 12288,
            'Invalid report cells')
    checks = {(s['id'], c['id']): (c['kind'], s['requirementIds'])
              for s in spec['scenarios'] for c in s['checks']}
    saved = {(r['scenarioId'], r['checkId'], r['target']): r for r in evidence['records']}
    seen, groups, found = set(), {}, set()
    for cell in value['cells']:
        shape(cell, ('scenarioId', 'checkId', 'kind', 'requirementIds', 'target',
                     'status', 'currentPass', 'savedEvidence'))
        require(all(type(cell[k]) is str for k in ('scenarioId', 'checkId', 'target')),
                'Invalid cell key')
        pair = (cell['scenarioId'], cell['checkId'])
        key = (*pair, cell['target'])
        require(pair in checks and cell['target'] in TARGETS and key not in seen,
                'Invalid or duplicate cell')
        seen.add(key)
        groups.setdefault(pair, set()).add(cell['target'])
        require((cell['kind'], cell['requirementIds']) == checks[pair], 'Invalid cell metadata')
        record = saved.get(key)
        require(cell['savedEvidence'] == record and type(cell['currentPass']) is bool,
                'Inconsistent saved evidence')
        if record is None:
            require(cell['status'] in ('missing', 'unavailable') and not cell['currentPass'],
                    'Invalid absent status')
        else:
            found.add(key)
            expected = record['status'] if (record['identity'] == identity and
                record['manifestSha256'] == value['manifestSha256']) else 'stale'
            require(cell['status'] == expected and cell['currentPass'] == (expected == 'passed'),
                    'Inconsistent saved status')
    require(groups and all(targets == set(TARGETS) for targets in groups.values())
            and found == set(saved), 'Incomplete saved report')


def inventory(app, directories, now):
    app = Path(app).resolve()
    require(type(directories) is list and len(directories) <= 128
            and len(set(directories)) == len(directories), 'Invalid references')
    spec = manifest(read_json(app / 'docs/development/product_acceptance_manifest.json'))
    cells = {}
    entries = []
    for relative in sorted(directories):
        require(type(relative) is str and relative.startswith('docs/development/acceptance/'),
                'Invalid evidence reference')
        folder = safe_file(app, relative)
        evidence_path = safe_file(app, relative + '/evidence.json')
        identity_path = safe_file(app, relative + '/identity.json')
        report_path = safe_file(app, relative + '/report.json')
        identity = read_json(identity_path)
        evidence = read_json(evidence_path)
        # The existing collector validates every record, including statuses,
        # timestamps, identities, artifacts, duplicates and configured targets.
        evaluated = report(spec, identity, evidence, now)
        validate_saved_report(report_path, spec, identity, evidence, now)
        observations = []
        for cell in evaluated['cells']:
            saved = cell['savedEvidence']
            if saved is None:
                continue
            key = (cell['scenarioId'], cell['checkId'], cell['target'])
            observations.append(saved)
            cells.setdefault(key, []).append(relative)
        entries.append({'directory': relative, 'identity': identity,
                        'evidenceSha256': file_sha(evidence_path),
                        'identitySha256': file_sha(identity_path),
                        # The historical rendered report is referenced by bytes;
                        # its currentPass flags are never imported or promoted.
                        'savedReportSha256': file_sha(report_path),
                        'observations': observations,
                        'sourceComparison': source_comparison(app, folder)})
    configured = []
    for scenario in spec['scenarios']:
        for check in scenario['checks']:
            for target in check.get('targets', scenario['targets']):
                key = (scenario['id'], check['id'], target)
                configured.append({'scenarioId': key[0], 'checkId': key[1],
                                   'target': target, 'kind': check['kind'],
                                   'observationDirectories': cells.get(key, [])})
    runtime = {p.relative_to(app).as_posix(): file_sha(safe_file(app, p.relative_to(app).as_posix()))
               for p in sorted((app / 'lib').rglob('*.dart'))}
    return {'schemaVersion': 1, 'claim': CLAIM, 'manifestSha256': sha(spec),
            'comparisonRuntimeSha256': sha(runtime),
            'limitations': ['No combined identity, current pass, support verdict or authenticated observation.',
                            'Recorded source hashes do not prove bundle equivalence or unaffected behavior.',
                            'Missing source manifests require separate artifact inspection; no inference.',
                            'Non-report viewer interactions are outside this inventory.'],
            'configuredCells': configured, 'reports': entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    temporary = None
    try:
        app = Path(args.app).resolve()
        output = Path(args.output)
        # Publication is deliberately outside inputs; cannot replace an artifact.
        require(not output.resolve().is_relative_to(app) or output.resolve() ==
                app / 'docs/development/acceptance_inventory.json', 'Output overlaps inputs')
        paths = sorted(p.parent.relative_to(app).as_posix() for p in
                       (app / 'docs/development/acceptance').glob('*/report.json'))
        result = inventory(app, paths, datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8',
                                         dir=output.parent, delete=False) as stream:
            temporary = stream.name
            json.dump(result, stream, indent=2)
            stream.write('\n')
        os.replace(temporary, output)
        temporary = None
    except (ValueError, OSError, TypeError, RecursionError):
        parser.exit(2, 'Acceptance inventory failed: invalid input or inaccessible output.\n')
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
