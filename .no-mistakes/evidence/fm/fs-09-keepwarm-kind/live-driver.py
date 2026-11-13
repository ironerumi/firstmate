import subprocess as sp, pathlib, json, time, os, html, shutil
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M7ATGKWEZ99WQT3239W8WN55'); lab=root/'.test-keepwarm-lab'; lab.mkdir(); transcript=[]
def cli(args, text):
 p=sp.run([str(root/'bin/fm-operational-input.sh'),*args],input=text,text=True,capture_output=True); transcript.append({'command':'fm-operational-input.sh '+' '.join(args),'input':text,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}); return p
try:
 for kind in ['session-start','watcher','turn-end-guard','away-supervisor','launch-brief','branch-outcome','from-firstmate']:
  p=cli(['encode',kind],'synthetic CLI payload'); assert p.returncode==0
  q=cli(['kind'],p.stdout); assert q.returncode==0 and q.stdout.strip()==kind
 p=cli(['encode','keep-warm'],'synthetic heartbeat'); assert p.returncode!=0 and not p.stdout
 old='\u2063FIRSTMATE_OP: v1 keep-warm: OBSOLETE_KIND_VISIBLE'
 p=cli(['kind'],old); assert not p.stdout
 p=cli(['classify'],old); assert p.stdout.strip()=='legacy-operational'
 (evidence/'cli-transcript.json').write_text(json.dumps(transcript,indent=2))
 home=lab/'home'; config=lab/'pi'; (home/'config').mkdir(parents=True); config.mkdir(); (home/'config/calm').write_text('on\n'); (config/'settings.json').write_text('{}')
 messages=['CAPTAIN_VISIBLE', '\u2063FIRSTMATE_OP: v1 watcher: RETAINED_WATCHER_HIDDEN',old,'END_OF_SYNTHETIC_TRANSCRIPT']
 lines=[{'type':'session','version':3,'id':'11111111-1111-4111-8111-111111111111','timestamp':'2026-11-13T00:00:00.000Z','cwd':str(root)}]
 for i,text in enumerate(messages): lines.append({'type':'message','id':f'a{i:07d}','parentId':f'a{i-1:07d}' if i else None,'timestamp':'2026-11-13T00:00:00.000Z','message':{'role':'user','content':[{'type':'text','text':text}],'timestamp':i+1}})
 session=lab/'session.jsonl'; session.write_text('\n'.join(map(json.dumps,lines))+'\n'); sock=pathlib.Path('.test-keepwarm-lab/tmux.sock')
 def tmux(*args): return sp.run(['tmux','-S',str(sock),*args],text=True,capture_output=True,check=True).stdout
 env=os.environ.copy(); env.update(FM_HOME=str(home),PI_CODING_AGENT_DIR=str(config),PI_OFFLINE='1',FM_OPERATIONAL_INPUT_SCRIPT=str(root/'bin/fm-operational-input.sh'))
 command=['tmux','-S',str(sock),'new-session','-d','-s','keepwarm','-x','160','-y','44','-c',str(root),'pi','--tui-mode','regular','--approve','--no-skills','--no-prompt-templates','--no-context-files','--no-extensions','-e',str(root/'.pi/extensions/fm-calm.ts'),'--session',str(session)]
 started=sp.run(command,env=env,text=True,capture_output=True)
 if started.returncode: raise RuntimeError(started.stderr)
 try:
  deadline=time.monotonic()+40
  while time.monotonic()<deadline:
   screen=tmux('capture-pane','-p','-t','keepwarm','-S','-200')
   if 'END_OF_SYNTHETIC_TRANSCRIPT' in screen and 'OBSOLETE_KIND_VISIBLE' in screen: break
   time.sleep(.2)
  (evidence/'pi-calm-screen.txt').write_text(screen)
  (evidence/'pi-calm-screen.html').write_text('<!doctype html><meta charset="utf-8"><title>Actual Pi Calm terminal capture</title><body style="background:#121212;color:#eee"><h2>Pi 1.5.2 Calm on — synthetic persisted user rows</h2><p>Actual 160×44 tmux capture, not a reconstructed UI. Obsolete keep-warm remains visible; watcher row is hidden.</p><pre style="font:14px monospace">'+html.escape(screen)+'</pre>')
  assert 'CAPTAIN_VISIBLE' in screen and 'OBSOLETE_KIND_VISIBLE' in screen and 'END_OF_SYNTHETIC_TRANSCRIPT' in screen
  assert 'RETAINED_WATCHER_HIDDEN' not in screen
  print('PASS: real CLI round-trips seven supported kinds; rejects keep-warm; old envelope is legacy-only. Real Pi Calm shows obsolete keep-warm and captain rows while hiding retained watcher.')
 finally:
  sp.run(['tmux','-S',str(sock),'kill-server'],capture_output=True)
finally:
 shutil.rmtree(lab)
