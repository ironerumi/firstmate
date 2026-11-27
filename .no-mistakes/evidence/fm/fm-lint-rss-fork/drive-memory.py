import os, pathlib, signal, subprocess, sys, tempfile, time
root = pathlib.Path.cwd()
product = str(root / 'bin/fm-lint.sh')
env = dict(os.environ, FM_LINT_INTERNAL='1')
# Synthetic allocations are inputs to the actual product memory monitor, not a replacement monitor.
allocator = 'import os,time; x=bytearray(256*1024*1024); print("allocated_bytes=268435456 pid="+str(os.getpid()),flush=True); time.sleep(float(__import__("sys").argv[1]))'
sentinel = subprocess.Popen(['sleep', '60'], start_new_session=True)
try:
    with tempfile.TemporaryDirectory(prefix='.memory-live-', dir=root) as td:
        for name, limit, hold, expected in [('below-ceiling-control',2097152,1,0), ('over-ceiling-1',65536,8,98), ('over-ceiling-2',65536,8,98), ('over-ceiling-3',65536,8,98)]:
            print('scenario='+name, flush=True)
            rss = pathlib.Path(td)/('rss-'+name)
            p = subprocess.Popen(['bash',product,'--internal-root',str(rss),'resident',str(limit),sys.executable,'-c',allocator,str(hold)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            try:
                output,_ = p.communicate(timeout=15)
            except BaseException:
                os.killpg(p.pid,signal.SIGKILL); p.communicate(); raise
            finally:
                try: os.killpg(p.pid,signal.SIGKILL)
                except ProcessLookupError: pass
            print(output, end='')
            print('exit='+str(p.returncode)+' expected='+str(expected))
            if rss.exists(): print(rss.read_text())
            assert p.returncode == expected
            assert 'allocated_bytes=268435456' in output
            if expected == 98:
                assert 'exceeded the per-root limit of 65536 KiB' in output
                assert 'physical footprint' in output if sys.platform == 'darwin' else 'resident memory' in output
                peak=int(rss.read_text().strip().split('=')[1]); assert peak>limit
                import re
                child=int(re.search(r'pid=(\d+)',output).group(1))
                try: os.kill(child,0)
                except ProcessLookupError: print('allocator_reaped=true')
                else: raise AssertionError('allocator survived')
            assert sentinel.poll() is None
            print('unrelated_sentinel_alive=true', flush=True)
finally:
    sentinel.terminate(); sentinel.wait()
print('All direct memory guard scenarios passed; all children stopped.')
