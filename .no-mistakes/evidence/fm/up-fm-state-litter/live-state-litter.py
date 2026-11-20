import os, sys, time, json, signal, subprocess, pathlib, shutil
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M7VPY5YT5FK0HETNDQTC482Q')
H=R/'.test-tmp/live-home'; subprocess.run(['bin/fm-lab-home.sh','create',str(H)],check=True)
env=os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX']:
    env.pop(key,None)
env.update(FM_HOME=str(H),PATH=str(R/'.test-tmp/tools')+':/usr/bin:/bin',TMPDIR=str(R/'.test-tmp'),FM_STARTUP_NETWORK_TIMEOUT='5',FM_SESSION_START_TIMEOUT='45')
S=H/'state'; LIB=str(R/'bin/fm-wake-lib.sh'); children=[]; report=[]
def log(message):
    print(message,flush=True); report.append(message)
def shell(code,*args,wait=True):
    p=subprocess.Popen(['/bin/bash','-c',code,'_',LIB,*map(str,args)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,text=True); children.append(p)
    if not wait:return p
    out,err=p.communicate(timeout=30)
    assert p.returncode==0,(p.returncode,out,err)
    return out
def kill_tree(p):
    rows=subprocess.check_output(['/bin/ps','-axo','pid=,ppid='],text=True)
    pairs=[tuple(map(int,row.split())) for row in rows.splitlines() if len(row.split())==2]
    descendants={p.pid}
    for _ in range(20):
        expanded=descendants|{pid for pid,ppid in pairs if ppid in descendants}
        if expanded==descendants:break
        descendants=expanded
    for pid in reversed(sorted(descendants)):
        try:os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:pass
        except PermissionError:
            if p.poll() is None:raise

def stop(p):
    if p.poll() is None:
        kill_tree(p)
    try:p.communicate(timeout=10)
    except subprocess.TimeoutExpired:raise AssertionError('child did not stop')
def startup(label,extra=[]):
    p=subprocess.run([str(R/'bin/fm-session-start.sh'),*extra],env=env,capture_output=True,text=True,timeout=65)
    (E/(label+'.log')).write_text(p.stdout+p.stderr)
    assert p.returncode==0,(label,p.returncode,p.stderr)
    assert 'READ-ONLY SESSION' not in p.stdout,p.stdout[:1500]
    log(label+': acquired real harness session lock; exit 0')
def owners(parent):return sorted(str(p.relative_to(H)) for p in parent.glob('.*.owner.*') if p.is_dir())
try:
    # Public summary writer, real local snapshot producer, no external-boundary mocks.
    p=subprocess.run([str(R/'bin/fm-home-summary-refresh.sh')],env=env,capture_output=True,text=True,timeout=30)
    assert p.returncode==0,p.stderr
    before=(S/'home-summary.json').read_bytes(); json.loads(before)
    stranded=[]
    for attempt in range(8):
        p=subprocess.Popen([str(R/'bin/fm-home-summary-refresh.sh')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,text=True); children.append(p)
        deadline=time.monotonic()+5
        while p.poll() is None and time.monotonic()<deadline:
            candidates=list(S.glob('.home-summary.json.*'))
            if candidates:
                kill_tree(p); break
            time.sleep(.0005)
        stop(p)
        stranded=list(S.glob('.home-summary.json.*'))+list(S.glob('.home-summary-error.*'))
        if stranded:break
    assert stranded,'could not interrupt the real writer'
    assert (S/'home-summary.json').read_bytes()==before,'SIGKILL damaged published ledger'
    log('SIGKILL public summary writer: prior JSON ledger byte-identical; stranded '+str([p.name for p in stranded]))
    startup('writer-recovery-session')
    assert all(not p.exists() for p in stranded),'session start retained killed writer temporary'
    json.loads((S/'home-summary.json').read_bytes())
    log('Next session start removed killed writer files and published valid summary JSON')

    # Real spinning lock primitives and inbox enqueue; SIGKILL delivered by the
    # observer, without substituting mktemp/ps/ln or any product executable.
    for label,relative,inbox,dead_holder in [('top-lock','.meta-lab.lock',False,False),('top-steal','.meta-steal.lock',False,True),('inbox-lock','demo.inbox/.seq.lock',True,False),('inbox-steal','steal.inbox/.seq.lock',True,True)]:
        lock=S/relative; lock.parent.mkdir(exist_ok=True)
        holder=shell('. "$1"; fm_lock_try_acquire "$2" || exit 9; echo held; exec sleep 120',lock,wait=False)
        assert holder.stdout.readline().strip()=='held'
        published=os.readlink(lock); found=[]
        if dead_holder:stop(holder)
        stage_pattern=lock.name+('.steal.owner.*' if dead_holder else '.owner.*')
        for attempt in range(40):
            code='. "$1"; fm_lock_acquire_wait "$2"'
            args=[lock]
            if inbox:
                code='. "$1"; . "$3"; fm_task_inbox_write "$2" "$4" "synthetic interrupted delivery"'
                args=[S,R/'bin/fm-task-inbox-lib.sh',lock.parent.name.removesuffix('.inbox')]
            acq=shell(code,*args,wait=False)
            deadline=time.monotonic()+2
            while acq.poll() is None and time.monotonic()<deadline:
                candidates=[p for p in lock.parent.glob(stage_pattern) if str(p)!=published]
                if candidates:
                    os.kill(acq.pid,signal.SIGSTOP)
                    kill_tree(acq); break
                time.sleep(.0002)
            stop(acq)
            found=[p for p in lock.parent.glob(stage_pattern) if str(p)!=published and p.is_dir()]
            if found:break
        assert found,label+': could not strand a real owner'
        log(label+': killed actual '+('inbox enqueue' if inbox else 'spinning acquirer')+'; before session '+str(owners(lock.parent)))
        startup(label+'-recovery-session')
        assert all(not p.exists() for p in found),'orphan owner survived'
        assert os.readlink(lock)==published and pathlib.Path(published).is_dir(),'live published owner lost'
        log(label+': session reaped all interrupted staging; '+('dead' if dead_holder else 'live')+' published holder preserved')
        stop(holder)
        # Dead published holders must stay too; these are normal recovery evidence.
        startup(label+'-dead-holder-session')
        assert os.readlink(lock)==published and pathlib.Path(published).is_dir(),'dead published owner lost'
        log(label+': dead published owner also preserved for ordinary lock recovery')

    # Independent safety oracle: only dead-pid known litter may go.
    dead=subprocess.Popen(['/usr/bin/true']); dead.wait(); dead=dead.pid; live=os.getpid()
    families=['home-summary.json','home-summary-error','claude-autoarm-output','watch-arm-output','fm-check-output','fm-custom-check','claude-autoarm-epoch.tmp']
    remove=[]; keep=[]
    for family in families:
        for pid,target in [(dead,remove),(live,keep)]:
            p=S/('.'+family+'.'+str(pid)+'.boundary');p.touch();target.append(p)
    for parent in [S,S/'demo.inbox']:
        for suffix in ['lock','lock.steal']:
            p=parent/('.guard.'+suffix+'.owner.'+str(dead)+'.dead');p.mkdir();remove.append(p)
        for tag in ['live','handoff','unknown','legacy','tombstone']:
            tail={'live':str(live)+'.staging','handoff':str(dead)+'.handoff','unknown':str(dead)+'.unknown','legacy':'oldformat','tombstone':str(dead)+'.x.reaped.'+str(dead)}[tag]
            p=parent/('.guard.lock.owner.'+tail);p.mkdir();keep.append(p)
            if tag=='handoff':(p/'pid').write_text(str(live))
            if tag=='unknown':(p/'foreign').write_text('preserve')
    symlink=S/('.fm-check-output.'+str(dead)+'.link');symlink.symlink_to(S/'home-summary.json');keep.append(symlink)
    target=S/'not-an-inbox'; target.mkdir(); nested=target/('.seq.lock.owner.'+str(dead)+'.stay');nested.mkdir();keep.append(nested)
    (S/'linked.inbox').symlink_to(target,target_is_directory=True)
    before_names=sorted(str(p.relative_to(S)) for p in remove+keep)
    log('Boundary fixture before startup: '+json.dumps(before_names))
    startup('reemit-preserves-litter',['--reemit'])
    assert all(p.exists() for p in remove+keep),'reemit unexpectedly swept state'
    startup('guarded-sweep-session')
    assert all(not p.exists() for p in remove),'known dead-pid litter survived'
    assert all(p.exists() for p in keep),'protected entry removed'
    log('Guarded full startup removed all seven dead-pid temp families plus top-level/inbox lock and steal staging; preserved live pids, live recorded holder, unknown contents, legacy names, tombstones, symlinks and symlinked inbox contents. Reemit performed no sweep.')

    # Exercise the actual hook and real supervision host locally with a synthetic
    # Stop payload on the plain-arm path. The enclosing real Pi harness owns the disposable session;
    # this proves signal-handler filesystem ordering, not Claude delivery/login.
    (H/'bin').symlink_to(R/'bin',target_is_directory=True)
    (H/'AGENTS.md').symlink_to(R/'AGENTS.md')
    (H/'.fm-secondmate-home').write_text('state-litter-lab\n')
    (H/'config/supervision-host-off').touch()
    (S/'signal-lab.meta').write_text('window=missing-lab-only\nharness=claude\nkind=ship\n')
    hook_env=env.copy();hook_env['FM_ROOT_OVERRIDE']=str(H)
    hook=subprocess.Popen([str(R/'bin/fm-claude-stop-autoarm.sh')],env=hook_env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);children.append(hook)
    hook.stdin.write(json.dumps({'hook_event_name':'Stop','session_id':'local-synthetic-stop'}));hook.stdin.close();hook.stdin=None
    parked=None; capture=None; deadline=time.monotonic()+20
    while time.monotonic()<deadline and hook.poll() is None:
        captures=list(S.glob('.claude-autoarm-output.'+str(hook.pid)+'.*'))
        if captures:
            rows=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,args='],text=True)
            for row in rows.splitlines():
                fields=row.split(None,2)
                if len(fields)==3 and fields[1]==str(hook.pid) and ('fm-supervision-host.sh' in fields[2] or 'fm-watch-arm.sh' in fields[2]):
                    parked=int(fields[0]);capture=captures[0]
                    os.kill(parked,signal.SIGSTOP);break
            if parked:break
        time.sleep(.002)
    assert parked and capture,'real hook did not enter its arm/host child: '+str(hook.poll())
    assert capture.exists(),'capture not present before interruption'
    log('Local real Stop hook: capture exists; stopped real arm/host child pid '+str(parked))
    os.kill(hook.pid,signal.SIGTERM)
    deadline=time.monotonic()+5
    while capture.exists() and time.monotonic()<deadline:time.sleep(.01)
    assert not capture.exists(),'TERM failed to remove capture before waiting on stopped arm'
    assert hook.poll() is None,'hook did not remain waiting for stopped arm'
    log('TERM removed output while hook was still waiting for its SIGSTOPed real arm; subsequent SIGKILL cannot strand that output')
    kill_tree(hook);stop(hook)
    assert not capture.exists(),'KILL stranded capture after TERM'
    log('Local signal-cleanup ordering passed (synthetic Stop event; no Claude harness delivery claim)')
finally:
    for p in children:stop(p)
    # Startup network workers are bounded; await all processes naming this fixture.
    for _ in range(120):
        rows=subprocess.check_output(['/bin/ps','-axo','pid=,args='],text=True)
        active=[row for row in rows.splitlines() if str(H) in row and ('/bin/bash ' in row or '/bin/sh ' in row)]
        if not active:break
        time.sleep(.1)
    else:raise AssertionError('fixture workers still active: '+str(active))
    shutil.rmtree(H)
    (E/'live-state-litter.log').write_text('\n'.join(report)+'\n')
