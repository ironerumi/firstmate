import os, sys, subprocess, time, signal, pathlib, json
root=pathlib.Path.cwd()
work=root/'.test-runtime-bounds'
evidence=pathlib.Path('~/.no-mistakes/evidence/01M8F8QD62H978EA5G1KFND2Y0')
log=[]
results=[]
env=dict(os.environ, FM_LINT_INTERNAL='1')
cli=str(root/'bin/fm-lint.sh')
def record(s):
    print(s,flush=True); log.append(s)
def alive(pid):
    p=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
    return p.returncode==0 and p.stdout.strip() and not p.stdout.strip().startswith('Z')
def run(name,limit,code,expected,deadline=8):
    rss=work/(name+'.rss')
    cmd=['bash',cli,'--internal-timed',str(deadline),'1','bash',cli,'--internal-root',str(rss),'resident',str(limit),sys.executable,'-u','-c',code]
    record('COMMAND '+repr(cmd))
    started=time.monotonic()
    p=subprocess.Popen(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    try:
        output=p.communicate(timeout=deadline+6)[0]
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGKILL); output=p.communicate()[0]; raise AssertionError(name+' exceeded outer safety deadline: '+output)
    elapsed=time.monotonic()-started
    record(output.rstrip())
    record(f'{name}: exit={p.returncode} elapsed={elapsed:.3f}s; memory-record='+ (rss.read_text().strip() if rss.exists() else 'none'))
    assert p.returncode==expected,(name,p.returncode,expected)
    results.append(dict(name=name,rc=p.returncode,elapsed=elapsed,output=output))
    return output,elapsed
sentinel=subprocess.Popen(['sleep','120'])
try:
    record('HOST '+subprocess.check_output(['uname','-s'],text=True).strip())
    run('under-ceiling',524288,'import time; x=bytearray(64*1024*1024); print("64 MiB populated; normal exit 7",flush=True); time.sleep(1); raise SystemExit(7)',7)
    for i in range(3):
        pidfile=work/f'hog-{i}.pid'
        code=f'import os,time,pathlib; x=bytearray(256*1024*1024); pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid())); print("256 MiB populated pid",os.getpid(),flush=True); time.sleep(30)'
        out,elapsed=run('over-ceiling-'+str(i+1),65536,code,98)
        assert 'physical footprint' in out and 'exceeded the per-root limit of 65536 KiB' in out
        if pidfile.exists():
            pid=int(pidfile.read_text()); assert not alive(pid),f'allocator {pid} survived'
        assert sentinel.poll() is None,'unrelated process was killed'
        record('Allocator reaped; unrelated sentinel remains alive')
    # Neither child's allocation alone reaches 192 MiB; together they must exceed it.
    child='import os,time; x=bytearray(112*1024*1024); print("child holds 112 MiB",os.getpid(),flush=True); time.sleep(30)'
    code=f'import subprocess,sys,time; a=subprocess.Popen([sys.executable,"-u","-c",{child!r}]); b=subprocess.Popen([sys.executable,"-u","-c",{child!r}]); time.sleep(30)'
    out,elapsed=run('aggregate-group',196608,code,98)
    assert 'physical footprint' in out
    # Deadline must kill a TERM-ignoring workload and its same-group child.
    pidfile=work/'timeout-child.pid'
    child=f'import os,time,signal,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid())); print("TERM-ignoring descendant",os.getpid(),flush=True); time.sleep(30)'
    code=f'import subprocess,sys,time,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); p=subprocess.Popen([sys.executable,"-u","-c",{child!r}]); print("waiting beyond deadline",flush=True); time.sleep(30)'
    run('wall-deadline',524288,code,124,deadline=2)
    time.sleep(.3)
    assert pidfile.exists() and not alive(int(pidfile.read_text())),'deadline descendant survived'
    assert sentinel.poll() is None
    record('Deadline descendant reaped; unrelated sentinel remains alive')
finally:
    sentinel.terminate(); sentinel.wait()
    (evidence/'runtime-bounds.log').write_text('\n'.join(log)+'\n')
    (evidence/'runtime-results.json').write_text(json.dumps(results,indent=2)+'\n')
