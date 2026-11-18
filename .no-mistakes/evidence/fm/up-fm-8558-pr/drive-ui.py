import os, subprocess, time, pathlib, json, html
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M7P77CBQWD5858KKHBJHWYNE')
frames=[]
report=[]
for version, enabled in [('326',True),('322',True),('326',False)]:
    label=f'{version}-flag-{"on" if enabled else "off"}'
    lab=pathlib.Path(subprocess.check_output(['mktemp','-d',os.environ.get('TMPDIR','/tmp')+'/fm-lab.XXXXXX'],text=True).strip())
    env=dict(os.environ)
    for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDECODE','CLAUDE_CODE_ENABLE_FUNCTION_HOOKS']:
        env.pop(key,None)
    env['TMUX_TMPDIR']=str(lab/'tmux')
    config=ROOT/'.validation'/('config-'+label)
    config.mkdir()
    (config/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True,'theme':'dark'}))
    def tmux(*args,check=True):
        return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=check).stdout
    def screen(): return tmux('capture-pane','-p','-t','primary')
    def capture(name):
        s=screen(); (E/(label+'-'+name+'.txt')).write_text(s); frames.append((label+' '+name,s)); return s
    def wait(pred,description,limit=30):
        end=time.monotonic()+limit
        while time.monotonic()<end:
            s=screen()
            if pred(s): return s
            time.sleep(.2)
        capture('failure')
        raise AssertionError(label+': '+description)
    def send(text):
        tmux('send-keys','-t','primary','-l',text)
        time.sleep(.3)
        tmux('send-keys','-t','primary','Enter')
    try:
        subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,stdout=subprocess.PIPE)
        (lab/'tmux').mkdir()
        (lab/'config'/'calm').write_text('on\n' if not enabled else 'off\n')
        args=['new-session','-d','-s','primary','-x','130','-y','38','-c',str(ROOT),'-e','FM_HOME='+str(lab),'-e','CLAUDE_CONFIG_DIR='+str(config)]
        if enabled: args += ['-e','CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1']
        args += [str(ROOT/f'.validation/native{version}/package/claude')+" --debug-file '"+str(lab/'debug.log')+"'"]
        tmux(*args)
        wait(lambda s:'Yes, I trust this folder' in s,'trust dialog')
        time.sleep(1)
        tmux('send-keys','-t','primary','Down')
        time.sleep(.3)
        tmux('send-keys','-t','primary','Enter')
        wait(lambda s:'Claude Code v2.1.'+version in s and 'trust this folder' not in s,'composer')
        time.sleep(2)
        capture('loaded')
        if enabled:
            wait(lambda s:'❯' in s,'composer')
            tmux('send-keys','-t','primary','-l','/calm')
            wait(lambda s:"Toggle Firstmate's Calm" in s,'registered /calm command')
            capture('command')
            tmux('send-keys','-t','primary','Enter')
            wait(lambda s:(lab/'config'/'calm').read_text().strip()=='on','/calm persists on')
            wait(lambda s:'Calm on' in s,'Calm on toast')
            capture('on')
            send('/calm')
            wait(lambda s:(lab/'config'/'calm').read_text().strip()=='off','/calm persists off')
            wait(lambda s:'Calm off' in s,'Calm off toast')
            capture('off')
            debug=(lab/'debug.log').read_text()
            assert 'hooks module fm@skills-dir loaded' in debug
            report.append(label+': real project auto-load registered /calm; two commands persisted on then off and displayed matching toasts. No model request submitted.')
        else:
            tmux('send-keys','-t','primary','-l','/calm')
            time.sleep(2)
            shot=capture('no-command')
            assert "Toggle Firstmate's Calm" not in shot
            assert (lab/'config'/'calm').read_text().strip()=='on'
            debug=(lab/'debug.log').read_text()
            tmux('send-keys','-t','primary','C-u')
            report.append(label+': with persisted Calm on but activation flag unset, /calm was absent and preference stayed on. Engine rollout may load the module but the mod remains inactive. No model request submitted.')
        # Retain only the mod's own loading/command diagnostics, not unrelated host data.
        lines=[line for line in debug.splitlines() if ('fm@skills-dir' in line or 'hooks modules not loaded' in line)]
        (E/(label+'-module.log')).write_text('\n'.join(lines)+'\n')
        send('/exit')
        time.sleep(1)
    finally:
        tmux('kill-server',check=False)
        subprocess.run(['rm','-rf',str(lab)],check=True)
(E/'ui-results.log').write_text('\n'.join(report)+'\nAll private tmux servers stopped and lab homes removed.\n')
# Render verbatim terminal captures, preserving the terminal's rows and columns.
body=''.join('<section><h2>'+html.escape(title)+'</h2><pre>'+html.escape(frame)+'</pre></section>' for title,frame in frames)
(E/'terminal-captures.html').write_text('<!doctype html><meta charset="utf-8"><title>Calm compatibility — real tmux captures</title><style>body{background:#181818;color:#ddd;font:14px monospace}section{margin:24px}pre{padding:20px;background:#202020;white-space:pre;line-height:1.35}h2{font-size:16px}</style><h1>Verbatim captures of running Claude Code</h1><p>130 × 38 private tmux panes; isolated local configuration; no model requests. Rendered terminal captures, not desktop screenshots.</p>'+body)
print('\n'.join(report))
