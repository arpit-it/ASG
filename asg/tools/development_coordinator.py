# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Cooperative, single-host development ownership; never executes or approves work.

State lives in Git's common directory, not the checkout. Recorded CI/review/merge
facts are manual attestations: the independent reviewer must verify their sources.
This is coordination between trusted local agents, not a security boundary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import secrets
import sqlite3
import subprocess
import sys
import time
import unicodedata
from contextlib import contextmanager

KINDS = ('ci_started', 'ci_finished', 'review_changes', 'checks_passed',
         'review_approved', 'outcome_verified', 'merged', 'escaped_defect')
SHA = re.compile(r'[0-9a-f]{40,64}\Z')
IDENTIFIER = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\Z')


class CoordinationError(Exception):
    """Recoverable refusal; state is preserved."""


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True,
                            text=True, timeout=15, check=False)
    if result.returncode:
        raise CoordinationError('Git repository/ref unavailable; inspect it separately.')
    # NUL-delimited paths are data: whitespace can be part of a filename.
    return result.stdout if '-z' in args else result.stdout.strip()


def identifier(value: object) -> str:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise CoordinationError('Invalid task/owner identifier.')
    return value


def text(value: object) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 2000 or '\x00' in value:
        raise CoordinationError('Expected nonempty bounded text; use evidence references, not logs.')
    return value


def sha(value: object) -> str:
    if not isinstance(value, str) or not SHA.fullmatch(value):
        raise CoordinationError('Expected a full lowercase commit SHA.')
    return value


def scope(value: object) -> str:
    if (not isinstance(value, str) or not value or len(value) > 500 or
            value.startswith('/') or '\\' in value or
            any(c in value for c in '*?[]\x00\n\r') or
            any(p.casefold() in ('', '.', '..', '.git') for p in value.rstrip('/').split('/'))):
        raise CoordinationError('Scopes must be literal confined repository-relative prefixes.')
    return value.rstrip('/')


def folded(value: str) -> str:
    # Conservative on every host: macOS/Windows commonly alias case and Unicode.
    return unicodedata.normalize('NFC', value).casefold()


def overlaps(left: str, right: str) -> bool:
    left, right = folded(left), folded(right)
    return left == right or left.startswith(right + '/') or right.startswith(left + '/')


def contract(value: object) -> dict:
    keys = {'task', 'requirement', 'outcome', 'dependencies', 'scope',
            'acceptance', 'failure_cases', 'validation'}
    if not isinstance(value, dict) or set(value) != keys:
        raise CoordinationError('Invalid execution contract fields.')
    identifier(value['task'])
    if not isinstance(value['requirement'], str) or not re.fullmatch(r'F[0-9]{2,}', value['requirement']):
        raise CoordinationError('Contract must reference a canonical requirement ID.')
    text(value['outcome'])
    for key in ('acceptance', 'failure_cases', 'validation', 'scope'):
        if not isinstance(value[key], list) or not 1 <= len(value[key]) <= 100:
            raise CoordinationError('Contract lists must be nonempty and bounded.')
        for item in value[key]:
            (scope if key == 'scope' else text)(item)
    paths = [scope(item) for item in value['scope']]
    for index, path in enumerate(paths):
        if any(overlaps(path, other) for other in paths[:index]):
            raise CoordinationError('Contract contains duplicate/overlapping scopes.')
    dependencies = value['dependencies']
    if not isinstance(dependencies, list) or len(dependencies) > 100:
        raise CoordinationError('Invalid contract dependencies.')
    seen = set()
    for dependency in dependencies:
        if not isinstance(dependency, dict) or set(dependency) != {'task', 'evidence'}:
            raise CoordinationError('Dependencies require task and verified evidence reference.')
        task = identifier(dependency['task'])
        text(dependency['evidence'])
        if task == value['task'] or task in seen:
            raise CoordinationError('Duplicate/self dependency.')
        seen.add(task)
    return dict(value, scope=paths)


def digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class Coordinator:
    def __init__(self, repo: Path):
        self.repo = repo.resolve(strict=True)
        if Path(git(self.repo, 'rev-parse', '--show-toplevel')).resolve() != self.repo:
            raise CoordinationError('Use a registered worktree root, not a subdirectory.')
        self.common = Path(git(self.repo, 'rev-parse', '--path-format=absolute', '--git-common-dir')).resolve()
        registered = [Path(line[9:]).resolve() for line in
                      git(self.repo, 'worktree', 'list', '--porcelain').splitlines()
                      if line.startswith('worktree ')]
        if self.repo not in registered:
            raise CoordinationError('Unregistered worktree.')
        self.path = self.common / 'asg-development-coordinator.sqlite3'

    @contextmanager
    def transaction(self):
        db = None
        try:
            db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
            db.row_factory = sqlite3.Row
            db.execute('BEGIN IMMEDIATE')
            version = db.execute('PRAGMA user_version').fetchone()[0]
            if version == 0:
                if db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchone():
                    raise CoordinationError('Unversioned coordination state; preserve and inspect it.')
                db.execute('CREATE TABLE claims (task TEXT PRIMARY KEY, owner TEXT NOT NULL, '
                           'token TEXT NOT NULL, worktree TEXT NOT NULL, contract TEXT NOT NULL, '
                           'started REAL NOT NULL, expires REAL NOT NULL, status TEXT NOT NULL)')
                db.execute('CREATE TABLE integration (singleton INTEGER PRIMARY KEY CHECK(singleton=1), '
                           'task TEXT NOT NULL, head TEXT NOT NULL, base TEXT NOT NULL)')
                db.execute('CREATE TABLE events (id INTEGER PRIMARY KEY, task TEXT NOT NULL, '
                           'kind TEXT NOT NULL, head TEXT NOT NULL, base TEXT NOT NULL, actor TEXT NOT NULL, '
                           'evidence TEXT NOT NULL, merge_sha TEXT, observed REAL NOT NULL)')
                db.execute('PRAGMA user_version=1')
            elif version != 1:
                raise CoordinationError('Unsupported coordination schema; preserve existing state.')
            yield db
            db.execute('COMMIT')
        except sqlite3.Error as error:
            raise CoordinationError('Coordination database unavailable/corrupt; preserve it and reconcile.') from error
        finally:
            if db:
                db.close()  # Rollback pending transaction, including failed validation.

    def owned(self, db, task, token, *, allow_expired=False):
        identifier(task)
        row = db.execute('SELECT * FROM claims WHERE task=?', (task,)).fetchone()
        if (row is None or row['status'] != 'active' or
                not secrets.compare_digest(row['token'], digest(token))):
            raise CoordinationError('Ownership token does not match an active task.')
        if Path(row['worktree']) != self.repo:
            raise CoordinationError('Ownership belongs to a different worktree.')
        if not allow_expired and row['expires'] <= time.time():
            raise CoordinationError('Lease expired; explicit reconciliation required before any effects.')
        return row

    def claim(self, value, owner, lease_seconds):
        value = contract(value)
        if Path(git(self.repo, 'rev-parse', '--absolute-git-dir')).resolve() == self.common:
            raise CoordinationError('Writers must use separate linked worktrees, not the primary checkout.')
        identifier(owner)
        self.lease(lease_seconds)
        if git(self.repo, 'status', '--porcelain', '--untracked-files=normal'):
            raise CoordinationError('Claim requires a clean isolated worktree before editing.')
        # Existing symlinks must not alias a different owned prefix or escape.
        for item in value['scope']:
            candidate = self.repo / item
            if not candidate.resolve().is_relative_to(self.repo):
                raise CoordinationError('Scope escapes the worktree through a symlink.')
            for parent in [candidate, *candidate.parents]:
                if parent == self.repo:
                    break
                if parent.is_symlink():
                    raise CoordinationError('Symlink scopes require an explicit non-aliasing path.')
        now = time.time()
        token = secrets.token_hex(32)
        with self.transaction() as db:
            if db.execute('SELECT 1 FROM claims WHERE task=?', (value['task'],)).fetchone():
                raise CoordinationError('Task already exists; use a fresh bounded track ID after reconciliation.')
            active = db.execute("SELECT * FROM claims WHERE status='active'").fetchall()
            if len(active) >= 2:
                raise CoordinationError('Two writer slots are occupied, including expired unreconciled claims.')
            for row in active:
                if row['worktree'] == str(self.repo):
                    raise CoordinationError('A writer already owns this worktree.')
                other = contract(json.loads(row['contract']))
                if any(overlaps(a, b) for a in value['scope'] for b in other['scope']):
                    raise CoordinationError('Write scope overlaps another active/unreconciled task.')
            for dependency in value['dependencies']:
                row = db.execute('SELECT status FROM claims WHERE task=?', (dependency['task'],)).fetchone()
                if row and (row['status'] == 'active' or not db.execute(
                        "SELECT 1 FROM events WHERE task=? AND kind='merged'",
                        (dependency['task'],)).fetchone()):
                    raise CoordinationError('A known dependency has no completed recorded merge.')
            db.execute('INSERT INTO claims VALUES (?,?,?,?,?,?,?,?)',
                       (value['task'], owner, digest(token), str(self.repo), json.dumps(value),
                        now, now + lease_seconds, 'active'))
        return {'task': value['task'], 'token': token, 'expires_at': now + lease_seconds}

    @staticmethod
    def lease(seconds):
        if not isinstance(seconds, int) or not 60 <= seconds <= 3600:
            raise CoordinationError('Lease must be between 60 and 3600 seconds.')

    def renew(self, task, token, seconds):
        self.lease(seconds)
        with self.transaction() as db:
            self.owned(db, task, token)
            db.execute('UPDATE claims SET expires=? WHERE task=?', (time.time() + seconds, task))
        return {'renewed': task}

    def release(self, task, token):
        with self.transaction() as db:
            self.owned(db, task, token)
            if db.execute('SELECT 1 FROM integration WHERE task=?', (task,)).fetchone():
                raise CoordinationError('Finish integration before releasing writer ownership.')
            db.execute("UPDATE claims SET status='released' WHERE task=?", (task,))
        return {'released': task}

    def reconcile(self, task, evidence):
        identifier(task)
        text(evidence)
        with self.transaction() as db:
            row = db.execute('SELECT * FROM claims WHERE task=?', (task,)).fetchone()
            if not row or row['status'] != 'active' or row['expires'] > time.time():
                raise CoordinationError('Only expired active claims can be explicitly reconciled.')
            db.execute('DELETE FROM integration WHERE task=?', (task,))
            db.execute("UPDATE claims SET status='reconciled' WHERE task=?", (task,))
            db.execute('INSERT INTO events(task,kind,head,base,actor,evidence,observed) '
                       'VALUES (?,?,?,?,?,?,?)', (task, 'reconciled', '', '', 'reconciler', evidence, time.time()))
        return {'reconciled': task, 'warning': 'Manual attestation: verify prior worker stopped and remote effects settled.'}

    def revisions(self, head, base):
        sha(head)
        sha(base)
        if git(self.repo, 'rev-parse', 'HEAD') != head or git(self.repo, 'rev-parse', 'origin/main') != base:
            raise CoordinationError('HEAD/origin/main changed; refresh evidence and reacquire integration.')
        # Ref identity alone is insufficient: candidate must include current main.
        if git(self.repo, 'merge-base', base, head) != base:
            raise CoordinationError('Candidate must include the selected main revision.')
        if git(self.repo, 'status', '--porcelain', '--untracked-files=normal'):
            raise CoordinationError('Integration requires committed, clean inputs.')

    def integrate(self, task, token, head, base):
        self.revisions(head, base)
        with self.transaction() as db:
            row = self.owned(db, task, token)
            declared = contract(json.loads(row['contract']))['scope']
            changed = git(self.repo, 'diff', '--no-renames', '--name-only', '-z', base, head).split('\0')
            if any(path and not any(folded(path) == folded(prefix) or folded(path).startswith(folded(prefix) + '/') for prefix in declared) for path in changed):
                raise CoordinationError('Candidate changes exceed claimed write scopes.')
            if db.execute('SELECT 1 FROM integration').fetchone():
                raise CoordinationError('Integration slot occupied; expired owners also require reconciliation.')
            db.execute('INSERT INTO integration VALUES(1,?,?,?)', (task, head, base))
        return {'integration': task, 'head': head, 'base': base,
                'warning': 'Hold and renew through final checks/review/remote merge; local coordination only.'}

    def readiness(self, db, task, token, head, base):
        self.owned(db, task, token)
        sha(head)
        sha(base)
        integration = db.execute('SELECT * FROM integration WHERE task=?', (task,)).fetchone()
        if not integration or (integration['head'], integration['base']) != (head, base):
            raise CoordinationError('Exact revision does not own integration; finish and reacquire after changes.')
        events = db.execute('SELECT * FROM events WHERE task=? AND head=? AND base=? ORDER BY id',
                            (task, head, base)).fetchall()
        last_changes = max((e['id'] for e in events if e['kind'] == 'review_changes'), default=0)
        checks = any(e['kind'] == 'checks_passed' and e['id'] > last_changes for e in events)
        review = any(e['kind'] == 'review_approved' and
                     e['id'] > last_changes for e in events)
        if not checks or not review:
            raise CoordinationError('Matching final checks and PR review evidence are required.')

    def ready(self, task, token, head, base):
        self.revisions(head, base)
        with self.transaction() as db:
            self.readiness(db, task, token, head, base)
        return {'ready': task, 'authority': 'Manual evidence only; reviewer must verify remote head/base/checks before protected merge.'}

    def finish_integration(self, task, token):
        with self.transaction() as db:
            self.owned(db, task, token)
            if not db.execute('SELECT 1 FROM integration WHERE task=?', (task,)).fetchone():
                raise CoordinationError('Task does not own integration.')
            db.execute('DELETE FROM integration WHERE task=?', (task,))
        return {'integration_released': task}

    def record(self, task, token, kind, head, base, actor, evidence, merge_sha=None):
        if kind not in KINDS:
            raise CoordinationError('Unknown observation kind.')
        sha(head)
        sha(base)
        identifier(actor)
        text(evidence)
        if (kind == 'merged') != (merge_sha is not None):
            raise CoordinationError('Only merged observations require a merge SHA.')
        if merge_sha is not None:
            sha(merge_sha)
        now = time.time()
        with self.transaction() as db:
            if kind == 'escaped_defect':
                row = db.execute('SELECT * FROM claims WHERE task=?', (identifier(task),)).fetchone()
                if (not row or row['status'] not in ('active', 'released') or
                        Path(row['worktree']) != self.repo or
                        not secrets.compare_digest(row['token'], digest(token))):
                    raise CoordinationError('Defect observation requires original task ownership.')
            else:
                self.owned(db, task, token)
            if kind == 'merged':
                self.readiness(db, task, token, head, base)
            if kind == 'merged' and db.execute(
                    'SELECT 1 FROM events WHERE task=? AND kind=?', (task, kind)).fetchone():
                raise CoordinationError('A merge is counted once per bounded task.')
            if kind == 'outcome_verified' and db.execute(
                    'SELECT 1 FROM events WHERE task=? AND kind=? AND head=? AND base=?',
                    (task, kind, head, base)).fetchone():
                raise CoordinationError('Outcome already observed for this exact revision.')
            if kind == 'ci_finished':
                started = db.execute('SELECT kind FROM events WHERE task=? AND head=? AND base=? '
                                     "AND kind IN ('ci_started','ci_finished') ORDER BY id DESC LIMIT 1",
                                     (task, head, base)).fetchone()
                if not started or started['kind'] != 'ci_started':
                    raise CoordinationError('CI finish needs a matching unclosed start.')
            if kind == 'ci_started':
                latest = db.execute('SELECT kind FROM events WHERE task=? AND head=? AND base=? '
                                    "AND kind IN ('ci_started','ci_finished') ORDER BY id DESC LIMIT 1",
                                    (task, head, base)).fetchone()
                if latest and latest['kind'] == 'ci_started':
                    raise CoordinationError('CI interval already open for this revision.')
            db.execute('INSERT INTO events(task,kind,head,base,actor,evidence,merge_sha,observed) '
                       'VALUES(?,?,?,?,?,?,?,?)', (task, kind, head, base, actor, evidence, merge_sha, now))
        return {'recorded': kind, 'source': 'manual_attestation', 'observed_at': now}

    def status(self):
        with self.transaction() as db:
            claims = []
            for row in db.execute('SELECT * FROM claims ORDER BY started'):
                entry = {key: row[key] for key in ('task', 'owner', 'worktree', 'started', 'expires', 'status')}
                declared = contract(json.loads(row['contract']))
                entry.update(scope=declared['scope'], requirement=declared['requirement'])
                claims.append(entry)
            integration = db.execute('SELECT * FROM integration').fetchone()
        now = time.time()
        for row in claims:
            row['expired'] = row['status'] == 'active' and row['expires'] <= now
        return {'claims': claims, 'integration': dict(integration) if integration else None,
                'scope': 'single-host cooperative ownership, not remote authority or a sandbox'}

    def report(self):
        with self.transaction() as db:
            claims = db.execute('SELECT task,started FROM claims ORDER BY started').fetchall()
            events = db.execute('SELECT * FROM events ORDER BY id').fetchall()
        tasks = []
        for claim in claims:
            records = [e for e in events if e['task'] == claim['task']]
            merges = [e for e in records if e['kind'] == 'merged']
            intervals, pending = [], {}
            for event in records:
                key = (event['head'], event['base'])
                if event['kind'] == 'ci_started':
                    pending[key] = event['observed']
                elif event['kind'] == 'ci_finished' and key in pending:
                    intervals.append(max(0, event['observed'] - pending.pop(key)))
            tasks.append({'task': claim['task'],
                          'start_to_merge_seconds': max(0, merges[0]['observed'] - claim['started']) if merges else None,
                          'recorded_ci_wait_seconds': sum(intervals) if intervals else None,
                          'ci_observation_incomplete': bool(pending),
                          'review_rework_count': sum(e['kind'] == 'review_changes' for e in records),
                          'escaped_defect_observations': sum(e['kind'] == 'escaped_defect' for e in records),
                          'verified_user_outcomes': int(bool(merges) and any(
                              e['kind'] == 'outcome_verified' and
                              (e['head'], e['base']) == (merges[0]['head'], merges[0]['base'])
                              for e in records))})
        return {'tasks': tasks, 'basis': 'Local wall-clock observations around manual attestations; absent durations are null, not zero. Counts are recorded observations, not proof of no defects.'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('status', 'report'):
        commands.add_parser(name)
    claim_parser = commands.add_parser('claim')
    claim_parser.add_argument('--contract', type=Path, required=True)
    claim_parser.add_argument('--owner', required=True)
    claim_parser.add_argument('--lease-seconds', type=int, default=900)
    for name in ('renew', 'release', 'integrate', 'finish-integration', 'ready', 'record'):
        sub = commands.add_parser(name)
        sub.add_argument('--task', required=True)
        sub.add_argument('--token', required=True)
        if name == 'renew':
            sub.add_argument('--lease-seconds', type=int, default=900)
        if name in ('integrate', 'ready', 'record'):
            sub.add_argument('--head', required=True)
            sub.add_argument('--base', required=True)
        if name == 'record':
            sub.add_argument('--kind', choices=KINDS, required=True)
            sub.add_argument('--actor', required=True)
            sub.add_argument('--evidence', required=True)
            sub.add_argument('--merge-sha')
    sub = commands.add_parser('reconcile')
    sub.add_argument('--task', required=True)
    sub.add_argument('--evidence', required=True)
    args = parser.parse_args(argv)
    try:
        coordinator = Coordinator(args.repo)
        if args.command == 'claim':
            if args.contract.stat().st_size > 65536:
                raise CoordinationError('Contract exceeds 64 KiB.')
            result = coordinator.claim(json.loads(args.contract.read_text()), args.owner, args.lease_seconds)
        elif args.command in ('status', 'report'):
            result = getattr(coordinator, args.command)()
        elif args.command == 'reconcile':
            result = coordinator.reconcile(args.task, args.evidence)
        elif args.command == 'renew':
            result = coordinator.renew(args.task, args.token, args.lease_seconds)
        elif args.command in ('integrate', 'ready'):
            result = getattr(coordinator, args.command)(args.task, args.token, args.head, args.base)
        elif args.command == 'record':
            result = coordinator.record(args.task, args.token, args.kind, args.head, args.base,
                                        args.actor, args.evidence, args.merge_sha)
        else:
            result = getattr(coordinator, args.command.replace('-', '_'))(args.task, args.token)
        print(json.dumps(result, sort_keys=True))
        return 0
    except CoordinationError as error:
        # Only our fixed messages are actionable; raw subprocess/parse/storage errors stay private.
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        return 2
    except (OSError, ValueError, subprocess.TimeoutExpired):
        print(json.dumps({'error': 'Coordination input unavailable or malformed; preserve local state and inspect privately.'}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
