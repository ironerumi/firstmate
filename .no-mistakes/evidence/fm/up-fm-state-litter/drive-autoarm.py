import os,pathlib,subprocess as sp,time,signal,json
R=pathlib.Path.cwd(); H=R/'.l'; S=H/'state'; E=pathlib.Path('~/.no-mistakes/evidence/01M8EE1CA2NYD28YPEVKHJYED9')
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
env['TMUX_TMPDIR']=str(H/'tmux');env['FM_HOME']=str(H)
def tm(*args,check=True):return sp.run(['tmux','-L','fm-lab',*args],env=env,text=True,capture_output=True,check=check)
def tree():
    rows=sp.check_output(['ps','-axo','pid=,ppid=,stat=,command='],text=True).splitlines()
    return [(int(x[0]),int(x[1]),x[2],x[3]) for row in rows if len(x:=row.split(None,3))==4]
def waitfor(fn,seconds):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        v=fn()
        if v:return v
        time.sleep(.03)
    raise RuntimeError('timed out waiting for autoarm')
marker=R/'.fm-secondmate-home'; assert not marker.exists()
owned=set(); record={}
try:
    marker.write_text('fm-lab-state-litter\n')
    (H/'config/supervision-host-off').touch()
    (S/'lab-synthetic.meta').write_text('TASK_ID=lab-synthetic\n')
    # Clear old session identity only inside the disposable lab.
    for n in ['.lock','.lock-session','.claude-autoarm-epoch','.claude-autoarm-failure-notified']:
        (S/n).unlink(missing_ok=True)
    cmd='claude -p "Validation lab only: use Bash to run bin/fm-lock.sh && bin/fm-claude-stop-autoarm.sh </dev/null exactly once. It is expected to block. Do not run other commands or change files." --tools Bash --permission-mode bypassPermissions --max-turns 2'
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(R),'-e','FM_HOME='+str(H),cmd)
    tm('set-option','-t','primary','remain-on-exit','on')
    files=waitfor(lambda:list(S.glob('.claude-autoarm-output.*')),90)
    out=files[0]; auto=int(out.name.split('.')[2]);owned.add(auto)
    arm=waitfor(lambda:next((pid for pid,ppid,stat,cmd in tree() if ppid==auto and 'fm-watch-arm.sh' in cmd),None),10)
    owned.add(arm)
    os.kill(arm,signal.SIGSTOP)
    for pid,ppid,stat,cmd in tree():
        if ppid==arm:owned.add(pid)
    record={'autoarm_pid':auto,'arm_pid':arm,'capture_before_TERM':out.name,'capture_exists_before_TERM':out.exists()}
    assert out.exists()
    armstat=next(stat for pid,ppid,stat,cmd in tree() if pid==arm)
    assert 'T' in armstat,armstat
    record['arm_status_before_TERM']=armstat
    os.kill(auto,signal.SIGTERM)
    waitfor(lambda:not out.exists(),8)
    os.kill(auto,signal.SIGKILL)
    record.update({'capture_removed_before_KILL':not out.exists(),'escalated_to_SIGKILL':True,'capture_remains_after_escalation':out.exists()})
    assert not out.exists()
    print(json.dumps(record,indent=2))
finally:
    # Discover all remaining descendants before killing their parents.
    rows=tree()
    for _ in range(8):
        owned.update(pid for pid,ppid,stat,cmd in rows if ppid in owned)
    for pid in owned:
        try:os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:pass
    tm('kill-server',check=False)
    marker.unlink(missing_ok=True)
    (E/'autoarm-signal-result.json').write_text(json.dumps(record,indent=2)+'\n')
    time.sleep(.5)
    remaining=[(pid,stat,cmd) for pid,ppid,stat,cmd in tree() if pid in owned and 'Z' not in stat]
    assert not remaining,remaining
