import os, pathlib, subprocess, time, signal
ROOT=pathlib.Path.cwd()
LAB=ROOT/'.gate-test-tmp/session-native-lab'
subprocess.run(['bin/fm-lab-home.sh','create',str(LAB)],check=True)
B=LAB/'fakebin'; B.mkdir()
log=LAB/'publish.log'
(B/'ln').write_text('#!/bin/bash\n/bin/ln "$@" || exit $?\nif [ -L "$3" ]; then printf "real symlink %s -> %s\\n" "$3" "$(/usr/bin/readlink "$3")" >> "$FM_LIVE_LOG"; fi\n')
(B/'perl').write_text('''#!/bin/bash
/usr/bin/perl "$@" || exit $?
last=${!#}
if [ -d "$last" ] && [ ! -L "$last" ]; then
 printf 'published directory %s pid=' "$last" >> "$FM_LIVE_LOG"
 /bin/cat "$last/pid" >> "$FM_LIVE_LOG"
 /bin/ls -a "$last" >> "$FM_LIVE_LOG"
fi
''')
for p in B.iterdir():p.chmod(0o755)
env=dict(os.environ)
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:
 env.pop(k,None)
env.update(FM_HOME=str(LAB),PATH=str(B)+':'+env['PATH'],FM_LIVE_LOG=str(log))
def cli(*args):
 p=subprocess.run([str(ROOT/'bin/fm-lock.sh'),*args],env=env,text=True,capture_output=True,timeout=15)
 print('$ bin/fm-lock.sh '+' '.join(args));print(p.stdout,end='');print(p.stderr,end='');print('exit:',p.returncode)
 assert p.returncode==0
 return p.stdout
try:
 cli(); first=(LAB/'state/.lock').read_text().strip()
 assert first.isdigit()
 cli('status');cli()
 assert (LAB/'state/.lock').read_text().strip()==first
 assert not (LAB/'state/.lock.acquire').exists()
 # A real competing process holds the lock while the public CLI waits.
 (LAB/'state/.lock').unlink()
 holder=subprocess.Popen(['bash','-c','. "$1"; fm_lock_try_acquire "$2" || exit 10; echo held; read -r go; fm_lock_release "$2"','_',str(ROOT/'bin/fm-wake-lib.sh'),str(LAB/'state/.lock.acquire')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 assert holder.stdout.readline().strip()=='held'
 waiter=subprocess.Popen([str(ROOT/'bin/fm-lock.sh')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 time.sleep(1)
 assert waiter.poll() is None and not (LAB/'state/.lock').exists()
 print('Observed: public session acquire waits without publishing while a live directory claim lock is held; pid='+str(holder.pid))
 holder.communicate('go\n',timeout=10);assert holder.returncode==0
 out,err=waiter.communicate(timeout=15); print(out,end='');print(err,end='');assert waiter.returncode==0
 assert (LAB/'state/.lock').read_text().strip()==first
 assert not (LAB/'state/.lock.acquire').exists()
 # Dead session plus dead claim-lock generation: the public acquire reclaims both.
 (LAB/'state/.lock').write_text('99999999\n')
 claim=LAB/'state/.lock.acquire';claim.mkdir();g=claim/'.owner.dead-fixture';g.mkdir()
 (claim/'pid').write_text('99999999\n');(g/'pid').write_text('99999999\n')
 cli();assert (LAB/'state/.lock').read_text().strip()==first
 assert not claim.exists()
 print('Observed: stale session and dead directory claim lock reclaimed; real harness pid='+first)
 print('--- actual publication records ---');print(log.read_text())
finally:
 import shutil
 shutil.rmtree(LAB)
