import os, sys, subprocess, pathlib, json, time, signal
ROOT = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M8EZPGA066RCWQCJF9CTSPYC')
SCRIPT = str(ROOT / 'bin/fm-lint.sh')
ENV = dict(os.environ, FM_LINT_INTERNAL='1')
results = []
# Real allocations and real child processes, not a ShellCheck replacement.
allocator = r'''
import ctypes, os, subprocess, sys, time
b = bytearray(256*1024*1024)
for i in range(0,len(b),4096): b[i] = 97
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
buf = ctypes.create_string_buffer(232)
rc = lib.proc_pid_rusage(os.getpid(), 0, ctypes.byref(buf))
import struct
footprint = struct.unpack_from('Q',buf,72)[0]//1024 if rc == 0 else -1
rss = subprocess.check_output(['ps','-o','rss=','-p',str(os.getpid())],text=True).strip()
print('allocation_pid=%d populated_MiB=256 independent_proc_pid_rusage_footprint_KiB=%d ps_rss_KiB=%s' % (os.getpid(),footprint,rss),flush=True)
time.sleep(float(sys.argv[1]))
'''
(E/'allocator.py').write_text(allocator)
def run(name, limit, payload, deadline=10):
    rss = E/(name+'.rss.txt')
    cmd = ['bash', SCRIPT, '--internal-timed', str(deadline), '1', 'bash', SCRIPT, '--internal-root',str(rss),'resident',str(limit)] + payload
    start = time.monotonic()
    p = subprocess.Popen(cmd,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
        out,err = p.communicate(timeout=deadline+8)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGKILL)
        out,err=p.communicate()
        raise RuntimeError(name+' exceeded driver safety deadline')
    result = dict(name=name,command=cmd,rc=p.returncode,elapsed=round(time.monotonic()-start,3),stdout=out,stderr=err,rss=rss.read_text() if rss.exists() else '')
    results.append(result)
    (E/'runtime-results.json').write_text(json.dumps(results,indent=2))
    print(json.dumps(result),flush=True)
    return result
control=run('below-ceiling',6291456,[sys.executable,str(E/'allocator.py'),'1'])
assert control['rc']==0 and 'populated_MiB=256' in control['stdout']
forward=run('exit-forwarding',6291456,['bash','-c','echo payload-status-7; exit 7'])
assert forward['rc']==7 and 'payload-status-7' in forward['stdout']
sentinel=subprocess.Popen(['sleep','120'])
try:
    for i in range(1,4):
        r=run('over-ceiling-'+str(i),65536,[sys.executable,str(E/'allocator.py'),'30'],5)
        assert r['rc']==98, r
        assert 'physical footprint' in r['stderr'] and 'exceeded the per-root limit of 65536 KiB' in r['stderr']
        peak=int(r['rss'].strip().split('=')[1]); assert peak>65536
        assert sentinel.poll() is None
        import re
        m=re.search(r'allocation_pid=(\d+)',r['stdout']); assert m
        pid=int(m[1])
        # A killed descendant may briefly be a zombie until reparenting/reaping.
        for retry in range(20):
            status=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True)
            if status.returncode != 0 or status.stdout.strip().startswith('Z'): break
            time.sleep(.1)
        else: raise AssertionError('allocator survived monitor kill: '+str(pid))
finally:
    sentinel.terminate(); sentinel.wait(timeout=5)
deadline=run('deadline',6291456,['bash','-c','trap "" TERM; echo deadline-payload-started; exec sleep 30'],1)
assert deadline['rc'] in (124,137) and deadline['elapsed']<6
print('All runtime assertions passed; sentinel stopped and all direct children awaited.')
