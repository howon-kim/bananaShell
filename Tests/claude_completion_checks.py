"""Exercise launcher settings and completion hook without launching Claude."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

support = Path(__file__).resolve().parents[1] / 'Sources/PromptSupport'
with tempfile.TemporaryDirectory(prefix='banana completion ') as temp:
    root = Path(temp)
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(root / 'config'),
               BANANA_LIMITS_BASE=str(root / 'limits-12345678-1234-1234-1234-123456789ABC'))
    fake = root / 'fake-claude'
    fake.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
    fake.chmod(0o700)
    def launch(*args):
        return json.loads(subprocess.check_output(['/bin/sh', str(support / 'claude-launch.sh'), str(fake), *args], env=env, cwd=root))
    args = launch('hello')
    settings = json.loads(args[1])
    assert 'Stop' in settings['hooks'] and 'statusLine' in settings
    (root / 'config').mkdir()
    (root / 'config/settings.json').write_text('{"statusLine":{"type":"command","command":"custom"}}')
    assert 'statusLine' not in json.loads(launch()[1])
    assert 'Stop' in json.loads(launch()[1])['hooks']
    for args in [('--settings', 'custom.json'), ('--print', 'hello'), ('--bare',), ('--version',)]:
        assert launch(*args) == list(args)
    def hook(payload):
        result = subprocess.run(['/bin/sh', str(support / 'claude-completed.sh')], input=payload, text=True, env=env, capture_output=True)
        assert result.returncode == 0 and not result.stdout
    hook('invalid')
    hook(json.dumps({'hook_event_name':'StopFailure'}))
    hook(json.dumps({'hook_event_name':'Stop', 'background_tasks':[{'status':'running'}]}))
    assert not (root / 'completions').exists()
    for _ in range(2):
        hook(json.dumps({'hook_event_name':'Stop', 'last_assistant_message':'private response'}))
    files = list((root / 'completions').glob('*.json'))
    assert len(files) == 2
    for file in files:
        event = json.loads(file.read_text())
        assert set(event) == {'pane','timestamp','source','summary'}
        assert event['source'] == 'claude' and event['summary'] == 'private response'
        assert file.stat().st_mode & 0o777 == 0o600
    for file in files: file.unlink()
    hook(json.dumps({'hook_event_name':'Stop', 'last_assistant_message':'## 제목\n\n**굵게** `code` [링크](http://x)\n```sh\nls\n```\n' + '가' * 300}))
    event = json.loads(next((root / 'completions').glob('*.json')).read_text())
    assert event['summary'].startswith('제목 굵게 code 링크 ls 가') and len(event['summary']) == 200
    next((root / 'completions').glob('*.json')).unlink()
    hook(json.dumps({'hook_event_name':'Stop'}))
    assert 'summary' not in json.loads(next((root / 'completions').glob('*.json')).read_text())
    env['BANANA_COMPLETION_SOURCE'] = 'test'
    hook(json.dumps({'hook_event_name':'Stop'}))
    assert any(json.loads(f.read_text())['source'] == 'test' for f in (root / 'completions').glob('*.json'))
print('Claude hook checks passed: existing status line, explicit settings, skipped modes, invalid events, background work, reply preview, simultaneous completions.')
