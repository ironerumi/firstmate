import json, os, pathlib, select, shutil, subprocess, tempfile, time
root = pathlib.Path(tempfile.mkdtemp(prefix='.pi-validation-', dir=os.getcwd()))
p = None
try:
    env = dict(os.environ, HOME=str(root), PI_CODING_AGENT_DIR=str(root / 'agent'))
    version = subprocess.check_output(['pi', '--version'], env=env, text=True).strip()
    assert version == '1.4.0', version
    command = ['pi', '--mode', 'rpc', '--no-mcp', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--session-dir', str(root / 'sessions')]
    print('Pi version:', version, flush=True)
    print('Command: pi --mode rpc --no-mcp --no-extensions --no-skills --no-prompt-templates --no-themes --session-dir <disposable worktree directory>', flush=True)
    p = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    p.stdin.write(json.dumps({'id': 'pin-compatibility', 'type': 'get_state'}) + '\n')
    p.stdin.flush()
    deadline = time.monotonic() + 30
    response = None
    while time.monotonic() < deadline:
        if select.select([p.stdout], [], [], 1)[0]:
            line = p.stdout.readline()
            if not line:
                break
            print(line.rstrip(), flush=True)
            item = json.loads(line)
            if item.get('id') == 'pin-compatibility':
                response = item
                break
    assert response is not None, 'No get_state response; process exit: ' + str(p.poll())
    assert response.get('success') is True and response.get('command') == 'get_state', response
    print('Real Pi 1.4.0 accepted --no-mcp and successfully answered RPC get_state without credentials or model calls.', flush=True)
finally:
    if p is not None:
        p.terminate()
        try:
            _, err = p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
            _, err = p.communicate()
        if err:
            print('stderr:', err)
    shutil.rmtree(root)
