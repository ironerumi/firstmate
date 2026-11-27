import os, sys, pathlib, subprocess as sp, time, signal, json
ROOT=pathlib.Path.cwd(); HOME=ROOT/'.l'; STATE=HOME/'state'
EVID=pathlib.Path('~/.no-mistakes/evidence/01M8EE1CA2NYD28YPEVKHJYED9')
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:
    env.pop(k,None)
env['FM_HOME']=str(HOME)
lib=str(ROOT/'bin/fm-wake-lib.sh')
children=[]; records=[]
def log(x):
    print(x,flush=True); records.append(x)
def call(body,*args,timeout=30):
    p=sp.run(['/bin/bash','-c','. "$1"; '+body,'_',lib,*map(str,args)],env=env,text=True,capture_output=True,timeout=timeout)
    if p.returncode: raise RuntimeError((p.returncode,p.stdout,p.stderr))
    return p.stdout
def launch(body,*args):
    p=sp.Popen(['/bin/bash','-c','. "$1"; '+body,'_',lib,*map(str,args)],env=env,stdout=sp.DEVNULL,stderr=sp.DEVNULL,start_new_session=True)
    children.append(p); return p
def stop(p):
    if p.poll() is None:
        try: os.killpg(p.pid,signal.SIGKILL)
        except ProcessLookupError: pass
    p.wait(timeout=5)
def waitfor(f,seconds=10):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if f(): return
        time.sleep(.001)
    raise RuntimeError('timed out waiting for product state')
def sweep(): call('fm_state_reap_orphans "$2"',STATE)
try:
    # Real refresh, killed only after both actual output files exist. No fake producer.
    p=sp.Popen([str(ROOT/'bin/fm-home-summary-refresh.sh'),'--_worker'],env=env,stdout=sp.DEVNULL,stderr=sp.DEVNULL,start_new_session=True); children.append(p)
    waitfor(lambda: list(STATE.glob('.home-summary-error.*')))
    os.killpg(p.pid,signal.SIGSTOP)
    before=sorted(x.name for x in STATE.glob('.home-summary*') if x.is_file())
    stop(p)
    log('SIGKILL real fm-home-summary-refresh worker pid='+str(p.pid)+' exit='+str(p.returncode)+' stranded='+repr(before))
    assert list(STATE.glob('.home-summary.json.*')) and list(STATE.glob('.home-summary-error.*'))
    sweep()
    assert not list(STATE.glob('.home-summary.json.*')) and not list(STATE.glob('.home-summary-error.*'))
    log('RECOVERY: real refresh temporary files removed; published lock owner retained for ordinary lock recovery')

    # Real lock contention/acquisition, OS process signals, no command stubs.
    for kind,name in [('session','.lock.acquire'),('registry','public-followup/.registry-demo.lock'),('reply','inbox/.replies.lock'),('extension','procevent/.extension-binding-lifecycle.lock'),('presentation','.status-presentation-lock'),('inbox','demo.inbox/.seq.lock'),('future','arbitrary/deeper/.future-mutex')]:
      for shape in ['live-holder','dead-holder']:
        lock=STATE/name; lock.parent.mkdir(parents=True,exist_ok=True)
        ready=lock.parent/('ready-'+kind)
        holder=launch('fm_lock_try_acquire "$2" || exit 2; touch "$3"; while :; do sleep 1; done',lock,ready)
        waitfor(ready.exists); ready.unlink()
        published=pathlib.Path(os.readlink(lock))
        if shape=='dead-holder': stop(holder)
        acq=launch('fm_lock_acquire_wait "$2"',lock)
        # Stop the complete process group once mktemp has made staging. The
        # real mktemp child and acquiring shell are both frozen before inspection.
        staged=[]
        end=time.monotonic()+15
        while time.monotonic()<end:
            candidates=[x for x in lock.parent.glob(lock.name+'.*.owner.*' if shape=='dead-holder' else lock.name+'.owner.*') if x.is_dir() and x!=published]
            if not candidates: continue
            os.killpg(acq.pid,signal.SIGSTOP)
            staged=[x for x in candidates if x.is_dir() and not any(y.is_symlink() and y.resolve()==x.resolve() for y in [lock,pathlib.Path(str(lock)+'.steal')])]
            if staged: break
            os.killpg(acq.pid,signal.SIGCONT)
        assert staged, (kind,shape,'no unpublished staging observed')
        stop(acq)
        # A pending mktemp may finish while signals race; inspect persisted state.
        staged=[x for x in staged if x.exists()]
        assert staged
        log('KILLED '+kind+' '+shape+' pid='+str(acq.pid)+' status='+str(acq.returncode)+' unpublished='+repr([str(x.relative_to(STATE)) for x in staged]))
        sweep()
        assert all(not x.exists() for x in staged)
        assert lock.is_symlink() and published.is_dir() and lock.resolve()==published
        log('RECOVERY '+kind+' '+shape+': zero stranded owners; referenced holder preserved')
        if shape=='live-holder': stop(holder)
        call('fm_lock_try_acquire "$2" || exit 3; fm_lock_release "$2"',lock)

    # Independent contract fixtures: all seven temp formats, live pid, handoff,
    # publication, unknown content, old names, tombstones and symlink boundaries.
    dead=p.pid
    for prefix in ['home-summary.json','home-summary-error','claude-autoarm-output','watch-arm-output','fm-check-output','fm-custom-check','claude-autoarm-epoch.tmp']:
        for pid in [dead,os.getpid()]: (STATE/('.'+prefix+'.'+str(pid)+('.AbCdEf' if prefix!='claude-autoarm-epoch.tmp' else ''))).touch()
    guards=[]
    def directory(name):
        d=STATE/name; d.mkdir(parents=True,exist_ok=True); return d
    for name in [f'.guard.owner.{os.getpid()}.staging',f'.guard.owner.{dead}.handoff',f'.guard.owner.{dead}.unknown',f'.guard.owner.{dead}.x.reaped.{dead}', '.guard.owner.legacy']:
        guards.append(directory(name))
    (guards[1]/'pid').write_text(str(os.getpid())+'\n'); (guards[2]/'foreign').touch()
    outside=HOME/'outside'; outside.mkdir(); foreign=outside/f'.foreign.owner.{dead}.staging'; foreign.mkdir()
    (STATE/'linked-directory').symlink_to(outside,target_is_directory=True)
    (STATE/f'.fm-check-output.{dead}.link').symlink_to(outside/'nonexistent')
    sweep()
    for prefix in ['home-summary.json','home-summary-error','claude-autoarm-output','watch-arm-output','fm-check-output','fm-custom-check','claude-autoarm-epoch.tmp']:
        suffix='.AbCdEf' if prefix!='claude-autoarm-epoch.tmp' else ''
        assert not (STATE/f'.{prefix}.{dead}{suffix}').exists()
        assert (STATE/f'.{prefix}.{os.getpid()}{suffix}').exists()
    assert all(x.is_dir() for x in guards) and foreign.is_dir()
    assert (STATE/f'.fm-check-output.{dead}.link').is_symlink()
    log('BOUNDARIES: all seven dead-pid temporary formats removed; live temp files, live owners, recorded live handoff, foreign content, legacy name, tombstone and symlinks preserved')
    log('ALL LOCAL RECOVERY SCENARIOS PASSED')
finally:
    for p in children: stop(p)
    (EVID/'state-litter-transcript.txt').write_text('\n'.join(records)+'\n')
