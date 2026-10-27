import os,pathlib,subprocess,time,signal,shutil,json
R=pathlib.Path.cwd(); L=R/'.gate-test-tmp/husk-cli-lab'
subprocess.run(['bin/fm-lab-home.sh','create',str(L)],check=True)
B=L/'bin';B.mkdir(); lock=L/'state/.lock.acquire'
(B/'ln').write_text('#!/bin/bash\nexec cp -R "$2" "$3"\n')
(B/'rmdir').write_text('''#!/bin/bash
if [ "$1" = "$FM_RACE_LOCK" ]; then
 case "$FM_RACE_ROLE" in
  releaser) echo "crashed releaser husk: $1"; kill -KILL "$PPID"; exit 1 ;;
  orphan)
    printf '%s\\n' "$$" > "$FM_RACE_LAB/orphan.pid"
    read -r go < "$FM_RACE_LAB/resume-a"
    /bin/rmdir "$@" 2> "$FM_RACE_LAB/orphan.err"; rc=$?
    printf '%s\\n' "$rc" > "$FM_RACE_LAB/orphan.rc"
    exit "$rc" ;;
 esac
fi
exec /bin/rmdir "$@"
''')
(B/'perl').write_text('''#!/bin/bash
/usr/bin/perl "$@" || exit $?
if [ "$FM_RACE_ROLE" = successor ] && [ "${!#}" = "$FM_RACE_LOCK" ]; then
 echo "$PPID" > "$FM_RACE_LAB/successor.ready"
 read -r go < "$FM_RACE_LAB/resume-b"
fi
''')
for p in B.iterdir():p.chmod(0o755)
for f in ['resume-a','resume-b']:os.mkfifo(L/f)
fds=[os.open(L/f,os.O_RDWR) for f in ['resume-a','resume-b']]
e=dict(os.environ)
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:e.pop(k,None)
e.update(FM_HOME=str(L),PATH=str(B)+':'+e['PATH'],FM_RACE_LOCK=str(lock),FM_RACE_LAB=str(L))
procs=[]
def start(role):
 env=dict(e,FM_RACE_ROLE=role)
 f=open(L/(role+'.log'),'w')
 p=subprocess.Popen([str(R/'bin/fm-lock.sh')],env=env,stdout=f,stderr=subprocess.STDOUT)
 procs.append(p);f.close();return p
def waitfile(name):
 p=L/name
 for _ in range(600):
  if p.exists() and p.stat().st_size:return p.read_text().strip()
  time.sleep(.05)
 raise RuntimeError('no event '+name)
try:
 c=start('releaser');assert c.wait(timeout=20)==-signal.SIGKILL
 assert lock.is_dir() and list(lock.iterdir())==[]
 print('Public session acquire: releaser killed after deleting its generation; persisted empty claim-lock husk.')
 os.utime(lock,(946684800,946684800))
 a=start('orphan');orphan=int(waitfile('orphan.pid'))
 print(f'Acquirer A={a.pid}: paused its real rmdir child={orphan} at aged-husk removal.')
 a.kill();a.wait(timeout=5);os.kill(orphan,0)
 b=start('successor');assert int(waitfile('successor.ready'))==b.pid
 pid=(lock/'pid').read_text().strip();g=list(lock.glob('.owner.*'));assert len(g)==1
 assert pid==str(b.pid) and (g[0]/'pid').read_text().strip()==pid
 before={str(p.relative_to(lock)):p.read_text() if p.is_file() else '<directory>' for p in lock.rglob('*')}
 print(f'Public acquirer B={b.pid}: recovered A\'s dead steal mutex and published a complete live generation {g[0].name}.')
 os.write(fds[0],b'go\n');rc=waitfile('orphan.rc')
 assert rc=='1',rc
 after={str(p.relative_to(lock)):p.read_text() if p.is_file() else '<directory>' for p in lock.rglob('*')}
 assert before==after
 print('Orphan resumed: '+(L/'orphan.err').read_text().strip())
 print('Successor persisted state after orphan resumed: '+json.dumps(after,sort_keys=True))
 os.write(fds[1],b'go\n');assert b.wait(timeout=20)==0
 print((L/'successor.log').read_text().strip())
 assert not lock.exists()
 print('Observed: live successor pid and generation survived byte-identically; public acquire completed and released its claim lock.')
finally:
 for fd in fds:
  try:os.write(fd,b'go\n')
  except OSError:pass
 for p in procs:
  if p.poll() is None:p.kill();p.wait()
 for fd in fds:os.close(fd)
 shutil.rmtree(L)
