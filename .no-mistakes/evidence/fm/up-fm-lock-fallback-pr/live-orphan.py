"""Actual inbox CLI husk-recovery race; only external commands are paused, never product functions."""
import os
from pathlib import Path
import shutil
import signal
import subprocess as sp
import time
root=Path.cwd(); lab=root/'.validation-tmp/orphan-cli'; lab.mkdir()
e=dict(os.environ)
for k in ('FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','NODE_OPTIONS'):
    e.pop(k,None)
bin=lab/'bin'; bin.mkdir(); home=lab/'home'
sp.run([root/'bin/fm-lab-home.sh','create',home],check=True,env=e)
e.update(FM_HOME=str(home),PATH=str(bin)+':'+e['PATH'],RACE_DIR=str(lab))
real={c:shutil.which(c) for c in ('ln','mv','rmdir')}
(bin/'ln').write_text('#!/usr/bin/env bash\nif [ "$1" = -s ]; then exec cp -R "$2" "$3"; fi\nexec '+real['ln']+' "$@"\n')
(bin/'rmdir').write_text('''#!/usr/bin/env bash
if [ "${RACE_SUBJECT:-}" = a ] && [ "$1" = "$FM_HOME/state/inbox/.replies.lock" ]; then
  printf '%s\\n' "$$" > "$RACE_DIR/orphan.pid"
  touch "$RACE_DIR/a.ready"
  while [ ! -e "$RACE_DIR/a.go" ]; do sleep 0.02; done
  '''+real['rmdir']+''' "$@"; rc=$?
  printf '%s\\n' "$rc" > "$RACE_DIR/a.done"
  exit "$rc"
fi
exec '''+real['rmdir']+' "$@"\n')
(bin/'mv').write_text('''#!/usr/bin/env bash
if [ "${RACE_SUBJECT:-}" = b ] && [ "${@: -1}" = "$FM_HOME/state/inbox/.replies/.seq" ]; then
  touch "$RACE_DIR/b.ready"
  while [ ! -e "$RACE_DIR/b.go" ]; do sleep 0.02; done
fi
exec '''+real['mv']+' "$@"\n')
for p in bin.iterdir(): p.chmod(0o755)
cli=root/'bin/fm-inbox.sh'; jobs=[]
def wait_file(p):
    end=time.monotonic()+15
    while time.monotonic()<end:
        if p.exists(): return
        time.sleep(.02)
    raise RuntimeError('deadline waiting for '+str(p))
def run(*args):
    p=sp.run([cli,*args],env=e,capture_output=True,text=True,timeout=20)
    print('CLI',args,'exit',p.returncode,p.stdout,p.stderr,flush=True)
    assert p.returncode==0
    return p
try:
    import json
    a_id=json.loads(run('note','--json','orphan recovery note A').stdout)['id']
    b_id=json.loads(run('note','--json','successor note B').stdout)['id']
    lock=home/'state/inbox/.replies.lock'; lock.mkdir(); os.utime(lock,(1,1))
    a=sp.Popen([cli,'reply',a_id,'answer A'],env=dict(e,RACE_SUBJECT='a'),stdout=sp.PIPE,stderr=sp.PIPE,text=True,start_new_session=True); jobs.append(a)
    wait_file(lab/'a.ready')
    orphan=int((lab/'orphan.pid').read_text()); print('A classified aged husk; rmdir child',orphan,'paused; killing actual inbox parent',a.pid,flush=True)
    a.kill()
    # stdout remains open in the orphan until it finishes; wait for the parent only.
    assert a.wait(timeout=3)==-signal.SIGKILL
    b=sp.Popen([cli,'reply',b_id,'answer B'],env=dict(e,RACE_SUBJECT='b'),stdout=sp.PIPE,stderr=sp.PIPE,text=True,start_new_session=True); jobs.append(b)
    wait_file(lab/'b.ready')
    def snapshot(): return {str(p.relative_to(lock)):p.read_bytes().hex() for p in lock.rglob('*') if p.is_file()}
    before=snapshot(); pid=(lock/'pid').read_text().strip()
    assert pid==str(b.pid) and any(n.startswith('.owner.') for n in before)
    print('B acquired after orphan parent died; successor record:',before,flush=True)
    (lab/'a.go').touch(); wait_file(lab/'a.done')
    assert (lab/'a.done').read_text().strip()=='1'
    after=snapshot(); assert before==after
    print('Resumed orphan rmdir refused nonempty successor; pid and generation bytes unchanged:',after,flush=True)
    (lab/'b.go').touch(); out,err=b.communicate(timeout=15)
    print('Successor actual CLI exit',b.returncode,out,err,flush=True)
    assert b.returncode==0 and not lock.exists()
    out,err=a.communicate(timeout=5)
    assert (home/'state/inbox/.replies'/b_id).exists()
    # Finish A's original user action now that B released.
    run('reply',a_id,'answer A retry')
    print('PASS: orphan husk cleanup preserves a live successor and both user replies remain possible',flush=True)
finally:
    (lab/'a.go').touch(); (lab/'b.go').touch()
    for job in jobs:
        if job.poll() is None:
            os.killpg(job.pid,signal.SIGKILL)
        job.wait(timeout=5)
        try: os.killpg(job.pid,signal.SIGKILL)
        except ProcessLookupError: pass
    shutil.rmtree(lab)
