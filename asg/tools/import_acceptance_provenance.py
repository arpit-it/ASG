# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Import one explicitly attested F10 observation; never runs or verifies a scenario."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile

from product_acceptance import (STATUSES, digest, identity, read_json, report,
                                require, sha, shape)

PROVENANCE_FIELDS = ('schemaVersion', 'scope', 'scenarioId', 'sourceRevision',
                     'requirementSha256', 'inputSha256', 'generatedSourceSha256',
                     'approvalSha256', 'savedRunSha256')
CHECKS = {'reviewed-candidate': ('model-proposal', 'confined-checks'),
          'bounded-repair': ('real-repair-rerun', 'repair-confined-checks')}


def import_observation(spec, environment, evidence, provenance, *, check_id,
                       target, status, observed_at, now):
    """Return new saved evidence, validating the entire document before writing.

    Identity and status are caller attestations, not measured by this importer.
    Three exact F10 identity fields must agree; snapshot digests remain artifacts.
    """
    identity(environment)
    shape(provenance, PROVENANCE_FIELDS)
    require(type(provenance['schemaVersion']) is int and
            provenance['schemaVersion'] == 1 and
            provenance['scope'] == 'f10-saved-snapshot-link-only',
            'Invalid provenance version or scope')
    scenario = provenance['scenarioId']
    require(type(scenario) is str and scenario in CHECKS and
            type(check_id) is str and check_id in CHECKS[scenario],
            'Unsupported provenance mapping')
    for field in ('sourceRevision', 'requirementSha256', 'inputSha256'):
        require(provenance[field] == environment[field], 'Identity mismatch')
    artifacts = []
    for field in ('generatedSourceSha256', 'approvalSha256', 'savedRunSha256'):
        digest(provenance[field])
        artifacts.append(provenance[field])
    # Bind the full linkage, including scenario and all named digest roles.
    artifacts.append(sha(provenance))
    require(type(status) is str and status in STATUSES, 'Invalid observation status')
    shape(evidence, ('schemaVersion', 'records'))
    # Validate existing evidence before using its records or returning any output.
    report(spec, environment, evidence, now)
    record = dict(scenarioId=scenario, checkId=check_id, target=target,
                  status=status, observedAt=observed_at, identity=dict(environment),
                  manifestSha256=sha(spec), artifactSha256=artifacts)
    result = dict(schemaVersion=1, records=[*evidence['records'], record])
    report(spec, environment, result, now)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ('manifest', 'identity', 'evidence', 'provenance', 'check',
                 'target', 'status', 'observed-at', 'output'):
        parser.add_argument('--' + flag, required=True)
    args = parser.parse_args()
    temporary = None
    try:
        output = Path(args.output)
        inputs = [Path(x).resolve() for x in
                  (args.manifest, args.identity, args.evidence, args.provenance)]
        require(output.resolve() not in inputs, 'Output must differ from inputs')
        result = import_observation(
            read_json(args.manifest), read_json(args.identity),
            read_json(args.evidence), read_json(args.provenance),
            check_id=args.check, target=args.target, status=args.status,
            observed_at=args.observed_at,
            now=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8',
                                         dir=output.parent, delete=False) as stream:
            temporary = stream.name
            json.dump(result, stream, indent=2)
            stream.write('\n')
        os.replace(temporary, output)
        temporary = None
    except (ValueError, OSError, TypeError, RecursionError):
        parser.exit(2, 'Acceptance import failed: invalid input or inaccessible output.\n')
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
