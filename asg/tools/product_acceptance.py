# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""F17 saved-evidence matrix. Never executes scenarios or infers product support."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from datetime import datetime, timezone

TARGETS = ('macos', 'web', 'android', 'ios', 'windows', 'linux')
KINDS = ('fixture', 'build', 'launch', 'liveInference', 'generatedOutput', 'manual')
STATUSES = ('passed', 'failed', 'skipped', 'unavailable')
DIGEST_FIELDS = ('requirementSha256', 'inputSha256', 'configurationSha256',
                 'modelSha256', 'deviceSha256')
IDENTITY_FIELDS = ('sourceRevision', *DIGEST_FIELDS, 'sdkVersion',
                   'runtimeVersion', 'backend', 'host', 'browserVersion')
LIMIT = 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def shape(value, fields):
    require(type(value) is dict and set(value) == set(fields), 'Invalid fields')


def digest(value, length=64):
    require(type(value) is str and re.fullmatch('[0-9a-f]{%d}' % length, value),
            'Invalid digest')


def identifier(value):
    require(type(value) is str and re.fullmatch('[a-z][a-z0-9-]{0,63}', value),
            'Invalid identifier')


def identity(value):
    shape(value, IDENTITY_FIELDS)
    digest(value['sourceRevision'], 40)
    for field in DIGEST_FIELDS:
        digest(value[field])
    for field in ('sdkVersion', 'runtimeVersion', 'browserVersion'):
        require(type(value[field]) is str and re.fullmatch(
            r'(?:unavailable|[0-9]{1,4}(?:\.[0-9]{1,4}){0,3})', value[field]),
            'Invalid version')
    require(value['backend'] in ('mlx', 'torch-mps', 'none', 'unavailable'),
            'Invalid backend')
    require(value['host'] in TARGETS, 'Invalid host')


def manifest(value):
    shape(value, ('schemaVersion', 'scenarios'))
    require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1,
            'Unsupported manifest version')
    require(type(value['scenarios']) is list and 0 < len(value['scenarios']) <= 64,
            'Invalid scenarios')
    seen = set()
    for scenario in value['scenarios']:
        shape(scenario, ('id', 'requirementIds', 'targets', 'checks'))
        identifier(scenario['id'])
        require(scenario['id'] not in seen, 'Duplicate scenario')
        seen.add(scenario['id'])
        ids = scenario['requirementIds']
        require(type(ids) is list and 0 < len(ids) <= 32 and
                all(type(x) is str and re.fullmatch(r'F[0-9]{2,4}', x) for x in ids)
                and len(set(ids)) == len(ids), 'Invalid requirements')
        targets = scenario['targets']
        require(type(targets) is list and 0 < len(targets) <= len(TARGETS) and
                all(type(x) is str and x in TARGETS for x in targets) and
                len(set(targets)) == len(targets), 'Invalid targets')
        checks = scenario['checks']
        require(type(checks) is list and 0 < len(checks) <= 32, 'Invalid checks')
        check_ids = set()
        for check in checks:
            shape(check, ('id', 'kind', 'testReferences'))
            identifier(check['id'])
            require(check['id'] not in check_ids, 'Duplicate check')
            check_ids.add(check['id'])
            require(check['kind'] in KINDS, 'Invalid evidence kind')
            refs = check['testReferences']
            require(type(refs) is list and len(refs) <= 16 and all(
                type(x) is str and re.fullmatch(r'test/[a-z0-9_]+_test\.dart', x)
                for x in refs), 'Invalid test references')
    return value


def sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True,
                                    separators=(',', ':')).encode()).hexdigest()


def utc(value):
    require(type(value) is str and re.fullmatch(
        r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value), 'Invalid UTC time')
    return datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)


def report(spec, current, saved, now):
    """Validate all input before returning any report. Saved claims are untrusted."""
    manifest(spec)
    identity(current)
    utc(now)
    shape(saved, ('schemaVersion', 'records'))
    require(type(saved['schemaVersion']) is int and saved['schemaVersion'] == 1,
            'Unsupported evidence version')
    records = saved['records']
    require(type(records) is list and len(records) <= 4096, 'Invalid records')
    index = {}
    scenarios = {s['id']: s for s in spec['scenarios']}
    for record in records:
        shape(record, ('scenarioId', 'checkId', 'target', 'status', 'observedAt',
                       'identity', 'manifestSha256', 'artifactSha256'))
        # Validate scalar types before dictionary/set membership.
        identifier(record['scenarioId'])
        identifier(record['checkId'])
        require(type(record['target']) is str and record['target'] in TARGETS,
                'Invalid target')
        scenario = scenarios.get(record['scenarioId'])
        require(scenario is not None, 'Unknown scenario')
        require(record['checkId'] in {c['id'] for c in scenario['checks']},
                'Unknown check')
        require(record['target'] in scenario['targets'], 'Unconfigured target')
        require(record['status'] in STATUSES, 'Invalid status')
        require(utc(record['observedAt']) <= utc(now), 'Future evidence')
        identity(record['identity'])
        digest(record['manifestSha256'])
        artifacts = record['artifactSha256']
        require(type(artifacts) is list and len(artifacts) <= 16, 'Invalid artifacts')
        for artifact in artifacts:
            digest(artifact)
        key = (record['scenarioId'], record['checkId'], record['target'])
        require(key not in index, 'Duplicate evidence')
        index[key] = record
    cells = []
    manifest_sha = sha(spec)
    for scenario in spec['scenarios']:
        for check in scenario['checks']:
            for target in TARGETS:
                record = index.get((scenario['id'], check['id'], target))
                status = ('missing' if target in scenario['targets'] else 'unavailable')
                if record:
                    status = record['status']
                    if record['identity'] != current or record['manifestSha256'] != manifest_sha:
                        status = 'stale'
                cells.append({'scenarioId': scenario['id'], 'checkId': check['id'],
                              'kind': check['kind'], 'requirementIds': scenario['requirementIds'],
                              'target': target, 'status': status,
                              'currentPass': status == 'passed', 'savedEvidence': record})
    return {'schemaVersion': 1, 'generatedAt': now, 'manifestSha256': manifest_sha,
            'identity': current, 'claim': 'saved-evidence-only', 'cells': cells}


def read_json(path):
    with Path(path).open('rb') as stream:
        data = stream.read(LIMIT + 1)
    require(len(data) <= LIMIT, 'Input too large')
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON field')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--evidence', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    temporary = None
    try:
        output = Path(args.output)
        inputs = [Path(x).resolve() for x in (args.manifest, args.identity, args.evidence)]
        require(output.resolve() not in inputs, 'Output must differ from inputs')
        result = report(read_json(args.manifest), read_json(args.identity),
                        read_json(args.evidence),
                        datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8',
                                         dir=output.parent, delete=False) as stream:
            temporary = stream.name
            json.dump(result, stream, indent=2)
            stream.write('\n')
        os.replace(temporary, output)
        temporary = None
    except (ValueError, OSError, TypeError, RecursionError):
        # Never echo input, prompts, paths or parser details in diagnostics.
        parser.exit(2, 'Acceptance report failed: invalid input or inaccessible output.\n')
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
