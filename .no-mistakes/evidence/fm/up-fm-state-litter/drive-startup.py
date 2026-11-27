import os, pathlib, subprocess as sp, time, json
R=pathlib.Path.cwd(); H=R/'.l'; S=H/'state'; E=pathlib.Path('~/.no-mistakes/evidence/01M8EE1CA2NYD28YPEVKHJYED9')
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
env['TMUX_TMPDIR']=str(H/'tmux'); env['FM_HOME']=str(H)
def tm(*args,check=True): return sp.run(['tmux','-L','fm-lab',*args],env=env,text=True,capture_output=True,check=check)
dead=sp.Popen(['true']); dead.wait(); dead=dead.pid
removed=[S/f'.watch-arm-output.{dead}.startup',S/'inbox'/f'.replies.lock.owner.{dead}.startup',S/f'.claude-autoarm-epoch.tmp.{dead}']
kept=[S/f'.watch-arm-output.{os.getpid()}.startup',S/'inbox'/f'.replies.lock.owner.{os.getpid()}.startup']
for p in removed+kept:
    p.parent.mkdir(parents=True,exist_ok=True)
    if '.owner.' in p.name:p.mkdir()
    else:p.touch()
try:
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(R),'-e','FM_HOME='+str(H),'claude -p "Validation lab only: use Bash to run bin/fm-session-start.sh --source startup exactly once, with inherited FM_HOME. Do not run other commands or change any files. Then reply done." --tools Bash --permission-mode bypassPermissions --max-turns 2')
    tm('set-option','-t','primary','remain-on-exit','on')
    end=time.monotonic()+140
    while time.monotonic()<end:
        pane=tm('capture-pane','-p','-S','-300','-t','primary').stdout
        if (S/'.session-start-complete').exists() or 'Pane is dead' in pane:break
        time.sleep(1)
    pane=tm('capture-pane','-p','-S','-500','-t','primary').stdout
    (E/'primary-startup-pane.txt').write_text(pane)
    result={'dead_pid':dead,'live_pid':os.getpid(),'removed':{str(p.relative_to(S)):not p.exists() for p in removed},'preserved':{str(p.relative_to(S)):p.exists() for p in kept},'session_start_complete':(S/'.session-start-complete').exists(),'session_lock':(S/'.lock').read_text() if (S/'.lock').is_file() else None,'pane':pane}
    print(json.dumps(result,indent=2))
    (E/'primary-startup-result.json').write_text(json.dumps(result,indent=2)+'\n')
finally:
    tm('kill-server',check=False)
