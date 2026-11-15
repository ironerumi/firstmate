"""Real extension-host lifecycle cleanup through the inherited-lock executable boundary."""
import os
from pathlib import Path
import shutil
import subprocess as sp
root=Path.cwd(); lab=root/'.validation-tmp/extension-cli'; lab.mkdir()
e=dict(os.environ)
for k in ('FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','NODE_OPTIONS'):
    e.pop(k,None)
try:
    sp.run([root/'bin/fm-lab-home.sh','create',lab/'home'],check=True,env=e)
    bin=lab/'bin'; bin.mkdir()
    (bin/'ln').write_text('#!/usr/bin/env bash\nif [ "$1" = -s ]; then exec cp -R "$2" "$3"; fi\nexec '+shutil.which('ln')+' "$@"\n')
    (bin/'ln').chmod(0o755)
    e.update(FM_HOME=str(lab/'home'),PATH=str(bin)+':'+e['PATH'])
    lock=lab/'home/state/procevent/.extension-binding-lifecycle.lock'; lock.parent.mkdir()
    for iteration in (1,2):
        p=sp.run(['bash','-c','''
. "$1"
fm_lock_try_acquire "$2" || exit 90
[ ! -L "$2" ] && [ -f "$2/pid-start" ] || exit 91
printf 'REAL HOST ENTER: pid=%s recorded-start=%s generation=%s\\n' "$(cat "$2/pid")" "$(cat "$2/pid-start")" "$FM_LOCK_OWNER_DIR"
printf '%s\\n' "$$" > "$2/pid.tmp.$$"
FM_EXTENSION_RETIREMENT_MODE=bind FM_EXTENSION_LIFECYCLE_LOCK="$2" FM_EXTENSION_LIFECYCLE_OWNER="$FM_LOCK_OWNER_DIR" exec "$3" not-a-lifecycle-command
''','_',str(root/'bin/fm-wake-lib.sh'),str(lock),str(root/'bin/fm-extension.mjs')],env=e,capture_output=True,text=True,timeout=15)
        print('Real host invocation',iteration,'exit',p.returncode,p.stdout,p.stderr,flush=True)
        assert p.returncode==1 and 'error[lifecycle-lock-invalid]' in p.stderr
        assert not list(lock.parent.iterdir()), list(lock.parent.iterdir())
        print('PASS: recorded pid-start and interrupted handoff temp retired; no lock residue; '+('reacquisition proved' if iteration==2 else 'ready to reacquire'),flush=True)
finally:
    shutil.rmtree(lab)
