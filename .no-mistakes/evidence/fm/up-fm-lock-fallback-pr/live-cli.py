"""Disposable local CLI evidence. Oracle: durable notes, exclusive replies, bounded refusal.
ln is the sole emulated OS boundary: MSYS copies instead of making symlinks.
All firstmate executables, locks, filesystem mutations and processes are real.
"""
import concurrent.futures as cf
import json
import os
from pathlib import Path
import shutil
import subprocess as sp
import time

root = Path.cwd()
lab = root / '.validation-tmp' / 'live-cli'
lab.mkdir()
base = dict(os.environ)
for k in ('FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_HOME', 'NODE_OPTIONS'):
    base.pop(k, None)
shim = lab / 'bin'
shim.mkdir()
ln = shutil.which('ln')
(shim / 'ln').write_text('#!/usr/bin/env bash\nif [ "$1" = -s ]; then printf "copied %s\\n" "$2" >> "$FM_COPY_LOG"; exec cp -R "$2" "$3"; fi\nexec ' + ln + ' "$@"\n')
(shim / 'ln').chmod(0o755)

def environment(home, copied=True):
    e = dict(base, FM_HOME=str(home), FM_COPY_LOG=str(lab / 'copied.log'))
    if copied:
        e['PATH'] = str(shim) + ':' + base['PATH']
    return e

def run(args, e, timeout=30):
    p = sp.run([str(a) for a in args], env=e, capture_output=True, text=True, timeout=timeout)
    print('$', ' '.join(str(a) for a in args), '\nexit=', p.returncode, '\n', p.stdout, p.stderr, flush=True)
    return p

inbox = root / 'bin/fm-inbox.sh'
lib = root / 'bin/fm-wake-lib.sh'
try:
    for copied in (True, False):
        home = lab / ('copied' if copied else 'native')
        assert run([root/'bin/fm-lab-home.sh', 'create', home], base).returncode == 0
        e = environment(home, copied)
        # End-user notes and replies: 8 writers contend on the real queue and reply locks.
        def note(i):
            p = run([inbox, 'note', '--json', '--request-id', f'request-{i}', f'local synthetic note {i}'], e)
            assert p.returncode == 0
            return json.loads(p.stdout)['id']
        with cf.ThreadPoolExecutor(max_workers=8) as pool:
            ids = list(pool.map(note, range(8)))
        assert len(set(ids)) == 8
        def reply(id):
            return run([inbox, 'reply', '--json', id, 'local synthetic answer'], e)
        with cf.ThreadPoolExecutor(max_workers=8) as pool:
            replies = list(pool.map(reply, ids))
        assert all(p.returncode == 0 for p in replies)
        seqs = []
        for id in ids:
            record = (home/'state/inbox/.replies'/id).read_text()
            print('DURABLE REPLY', id, record, flush=True)
            seqs.append(int(next(s[4:] for s in record.splitlines() if s.startswith('seq='))))
        assert sorted(seqs) == list(range(1, 9)), seqs
        # Active competitors for one unreplied note must publish exactly one answer.
        special = note(9)
        with cf.ThreadPoolExecutor(max_workers=8) as pool:
            attempts = list(pool.map(lambda _: reply(special), range(8)))
        assert sum(p.returncode == 0 for p in attempts) == 1
        assert all('reply already recorded' in p.stderr for p in attempts if p.returncode)
        # Kill-free dead publisher: process exited, retaining a real complete queue lock.
        lock = home/'state/.wake-queue.lock'
        p = run(['bash', '-c', '. "$1"; fm_lock_try_create "$2"', '_', lib, lock], e)
        assert p.returncode == 0
        assert lock.is_symlink() != copied
        print('DEAD RECORD', 'symlink' if lock.is_symlink() else 'directory', sorted(x.name for x in lock.iterdir()), flush=True)
        recovered = note(10)
        assert recovered and not lock.exists()
        assert not (home/'state/inbox/.replies.lock').exists()
        print('PASS:', 'copied-link' if copied else 'native-link', 'CLI concurrent durable writes, single-answer refusal, dead-owner recovery and complete release', flush=True)
    # Executed watcher startup, not a sourced function: marker deadline must name live blocker.
    home = lab/'watcher'
    assert run([root/'bin/fm-lab-home.sh', 'create', home], base).returncode == 0
    (home/'config/supervision-host').touch()
    e = environment(home)
    e['FM_WATCHER_STARTUP_LOCK_BOUND'] = '1'
    assert run(['bash', '-c', '. "$1"; fm_lock_try_create "$STATE/.watch.lock"', '_', lib], e).returncode == 0
    holder = sp.Popen(['bash', '-c', '. "$1"; fm_lock_try_create "$STATE/.watcher-down.lock" || exit 1; echo ready; read -r _; fm_lock_release "$STATE/.watcher-down.lock"', '_', str(lib)], env=e, stdin=sp.PIPE, stdout=sp.PIPE, text=True)
    try:
        assert holder.stdout.readline().strip() == 'ready'
        start = time.monotonic()
        p = run([root/'bin/fm-watch.sh'], e, timeout=15)
        elapsed = time.monotonic() - start
        expected = f'watcher: FAILED - startup lock {home}/state/.watcher-down.lock held by live pid {holder.pid}'
        assert p.returncode == 1 and expected in p.stdout, (p.returncode, p.stdout, p.stderr)
        assert elapsed < 15
        print('PASS: real watcher bounded startup refusal after', round(elapsed, 2), 'seconds; live blocking pid=', holder.pid, flush=True)
    finally:
        holder.communicate('release\n', timeout=15)
        assert holder.returncode == 0
    # Try the actual session-lock executable under this authentic agent ancestry.
    home = lab/'session'
    assert run([root/'bin/fm-lab-home.sh', 'create', home], base).returncode == 0
    e = environment(home)
    session = run([root/'bin/fm-lock.sh'], e)
    print('SESSION REAL ANCESTRY RESULT:', session.returncode, flush=True)
    if session.returncode == 0:
        assert not (home/'state/.lock.acquire').exists()
        assert run([root/'bin/fm-lock.sh', 'status'], e).returncode == 0
        # A stale saved session record should be replaced by this real harness.
        (home/'state/.lock').write_text('2147483647\n')
        assert run([root/'bin/fm-lock.sh'], e).returncode == 0
        # Refuse aged unknown contents, leaving the owned contents intact.
        lock = home/'state/.lock.acquire'
        lock.mkdir()
        (lock/'unknown').write_text('preserve this\n')
        os.utime(lock, (1,1))
        refused = run([root/'bin/fm-lock.sh'], e, timeout=15)
        assert refused.returncode == 1 and f'cannot reclaim lock directory {lock}' in refused.stderr
        assert (lock/'unknown').read_text() == 'preserve this\n'
        print('PASS: session CLI acquires, reclaims dead session, refuses unknown husk without deletion', flush=True)
    assert (lab/'copied.log').stat().st_size > 0
finally:
    shutil.rmtree(lab)
