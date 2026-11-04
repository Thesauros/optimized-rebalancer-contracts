#!/usr/bin/env python3
"""Bounded, autonomous cross-chain recovery; standard library only."""
import argparse
import concurrent.futures
import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.request

REPO = Path('/root/optimized-rebalancer-contracts')
STATE = Path('/var/lib/xc-watchdog')
PORTS = {'nav': 8081, 'keeper': 8082, 'relayer': 8083, 'monitor': 8084, 'indexer': 8085}
TARGETS = {'nav': 'operators', 'keeper': 'operators', 'relayer': 'operators',
           'monitor': 'monitor', 'indexer': 'indexer'}
HEADER = '[thesauros crosschain] Автофикс автономным ботом'


def utcnow():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def clean(text):
    text = re.sub(r'https?://\S+', '[URL]', str(text))
    text = re.sub(r'0x[0-9a-fA-F]{64}\b', '[HASH]', text)
    return text[:1200]


def request_json(url, payload=None, timeout=8):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers={
        'Content-Type': 'application/json', 'User-Agent': 'thesauros-xc-watchdog/1'})
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return {'status': response.status, 'body': json.loads(response.read(2_000_000))}


def probe():
    endpoints = {name: f'http://127.0.0.1:{port}/health' for name, port in PORTS.items()}
    endpoints.update({'monitor_status': 'http://127.0.0.1:8084/status',
                      'vault': 'http://127.0.0.1:8085/v1/vault'})

    def get(item):
        name, url = item
        try:
            return name, request_json(url)
        except Exception as error:
            return name, {'error': type(error).__name__}

    with concurrent.futures.ThreadPoolExecutor(max_workers=7) as pool:
        return dict(pool.map(get, endpoints.items()))


def assess(raw, now=None):
    now = time.time() if now is None else now
    issues = []

    def add(code, detail, target=None):
        issues.append({'code': code, 'detail': detail, 'target': target})

    def body(name):
        value = raw.get(name, {}).get('body', {})
        return value if isinstance(value, dict) else {}

    monitor = body('monitor_status')
    critical = [c for c in monitor.get('checks', []) if c.get('severity') == 'crit']
    if raw.get('monitor_status', {}).get('status') != 200:
        add('monitor.status', 'Недоступен подробный статус монитора', 'monitor')
    for name in PORTS:
        result = raw.get(name, {})
        if result.get('status') == 200 and body(name).get('healthy') is True:
            continue
        # A working monitor is deliberately unhealthy during an on-chain incident.
        # Restarting it would erase its incident history without fixing the cause.
        if name == 'monitor' and critical and not monitor.get('lastError'):
            try:
                last = dt.datetime.fromisoformat(monitor['lastPass'].replace('Z', '+00:00')).timestamp()
                if 0 <= now - last < 600:
                    continue
            except (ValueError, KeyError, TypeError):
                pass
        add(f'health.{name}', f'{name}: health не в норме', TARGETS[name])

    vault = body('vault')
    try:
        if raw['vault']['status'] != 200:
            raise ValueError('HTTP')
        tick = vault['tick']
        max_age = float(vault['risk']['maxTickAge'])
        # Recover before the hard 120-minute settlement limit when possible.
        age = 0 if int(tick['id']) == 0 else float(tick['ageSeconds'])
        if not math.isfinite(max_age) or not math.isfinite(age) or max_age <= 0 or age < 0:
            raise ValueError('age')
        if int(tick['id']) == 0 or age > max_age * 0.75:
            add('tick.age', f'Тик №{int(tick["id"])}: возраст {round(age / 60)} мин', 'operators')
        for flag in ('frozen', 'quarantined'):
            if tick.get(flag):
                add(f'tick.{flag}', f'Контракт: {flag}')
    except (KeyError, ValueError, TypeError, OverflowError):
        add('vault.unavailable', 'Не удалось проверить свежесть оценки', 'indexer')
    for check in critical:
        code = check.get('id', 'unknown')
        if not any(item['code'] == code for item in issues):
            add(code, f'Монитор: {code}', 'operators' if code == 'tick.age' else None)
    return issues


def targets(issues):
    return [target for target in ('operators', 'indexer', 'monitor')
            if any(issue.get('target') == target for issue in issues)]


def fix(target):
    if target in ('operators', 'monitor'):
        command = ['/usr/bin/docker', 'compose', '-f', 'ops/docker-compose.yml',
                   '--profile', 'stand', 'up', '-d', '--no-deps', '--no-build',
                   '--pull', 'never', '--force-recreate', target]
    elif target == 'indexer':
        command = ['/usr/bin/systemctl', 'restart', 'xc-indexer.service']
    else:
        raise ValueError('unknown recovery target')
    result = subprocess.run(command, cwd=REPO, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f'{target}: exit {result.returncode}; {clean(result.stderr)}')


def load_state(directory):
    try:
        state = json.loads((directory / 'state.json').read_text())
        if not isinstance(state, dict):
            raise ValueError('invalid state')
        return state
    except (FileNotFoundError, ValueError):
        return {'outbox': []}


def save_state(directory, state):
    temporary = directory / 'state.tmp'
    temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(directory / 'state.json')


class Notifications:
    def __init__(self, directory, state):
        self.directory = directory
        self.state = state
        self.state.setdefault('outbox', [])

    def send(self, text):
        self.state['outbox'].append(text[:3500])
        save_state(self.directory, self.state)
        self.flush()

    def flush(self):
        pending = self.state['outbox']
        if not pending:
            return
        token, chat = os.environ.get('TELEGRAM_TOKEN'), os.environ.get('TELEGRAM_CHAT_ID')
        if not token or not chat:
            raise RuntimeError('Telegram configuration missing')
        while pending:
            try:
                result = request_json(f'https://api.telegram.org/bot{token}/sendMessage', {
                    'chat_id': chat, 'text': pending[0], 'disable_web_page_preview': True}, timeout=15)
                if result.get('status') != 200 or result.get('body', {}).get('ok') is not True:
                    raise RuntimeError('Telegram rejected the message')
            except Exception as error:
                # Retain for retry on the next invocation. Never log token-bearing URLs.
                print(json.dumps({'telegram': 'queued', 'error': type(error).__name__}), flush=True)
                break
            pending.pop(0)
            save_state(self.directory, self.state)


def summary(issues):
    return '; '.join(issue['detail'] for issue in issues)[:1200]


def recover(initial, notify, check=probe, repair=fix, sleep=time.sleep,
            monotonic=time.monotonic, timeout=480, interval=20):
    """Two bounded recovery attempts; every outcome includes a fresh health check."""
    current, actions, errors = initial, [], []
    notify(f'🛠 {HEADER}\nОбнаружен сбой: {summary(current)}.\n'
           'Восстановление запущено автоматически, без участия человека.')
    for attempt in (1, 2):
        planned = targets(current)
        if not planned:
            break
        for target in planned:
            try:
                repair(target)
                actions.append({'attempt': attempt, 'target': target, 'ok': True})
            except Exception as error:
                detail = clean(str(error))
                errors.append(detail)
                actions.append({'attempt': attempt, 'target': target, 'ok': False, 'error': detail})
        deadline = monotonic() + timeout
        while True:
            current = assess(check())
            if not current:
                changed = ', '.join(sorted({a['target'] for a in actions if a['ok']})) or 'самовосстановление'
                notify(f'✅ {HEADER}\nСервис восстановлен без участия человека.\n'
                       f'Действия: {changed}. Health и свежесть принятого тика проверены.')
                return {'healthy': True, 'actions': actions, 'issues': [], 'errors': errors}
            if monotonic() >= deadline:
                break
            sleep(min(interval, max(0, deadline - monotonic())))
    notify(f'🔴 {HEADER}\nАвтоматическое восстановление не устранило сбой.\n'
           f'Осталось: {summary(current)}. Попыток: {max([a["attempt"] for a in actions], default=0)}.\n'
           'Результат сохранён; следующая проверка по расписанию через 2 часа.')
    return {'healthy': False, 'actions': actions, 'issues': current, 'errors': errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Read-only health check; no notifications or fixes')
    parser.add_argument('--test-notification', action='store_true', help='Send an explicitly labelled test notification')
    parser.add_argument('--state-dir', type=Path, default=STATE)
    args = parser.parse_args()
    os.umask(0o077)
    if args.check:
        issues = assess(probe())
        print(json.dumps({'at': utcnow(), 'healthy': not issues, 'issues': issues}, ensure_ascii=False))
        return int(bool(issues))
    args.state_dir.mkdir(parents=True, exist_ok=True)
    with (args.state_dir / 'run.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('{"skipped":"another watchdog run is active"}')
            return 0
        state = load_state(args.state_dir)
        notifier = Notifications(args.state_dir, state)
        try:
            if not os.environ.get('TELEGRAM_TOKEN') or not os.environ.get('TELEGRAM_CHAT_ID'):
                raise RuntimeError('Telegram configuration missing')
            notifier.flush()
            if args.test_notification:
                notifier.send(f'🧪 {HEADER}\nТЕСТ уведомлений. Проверка каждые 2 часа.\n'
                              'При сбое бот автономно запускает автофикс и сообщает результат.')
                return int(bool(state['outbox']))
            issues = assess(probe())
            if issues:
                # Confirm transient failures before interrupting a running service.
                time.sleep(10)
                issues = assess(probe())
            state.update({'startedAt': utcnow(), 'phase': 'repairing' if issues else 'healthy'})
            save_state(args.state_dir, state)
            result = recover(issues, notifier.send) if issues else {'healthy': True, 'actions': [], 'issues': []}
            state.update(result, checkedAt=utcnow(), phase='healthy' if result['healthy'] else 'unresolved')
            save_state(args.state_dir, state)
            print(json.dumps({k: v for k, v in state.items() if k != 'outbox'}, ensure_ascii=False), flush=True)
            return int(not result['healthy'] or bool(state['outbox']))
        except Exception as error:
            state.update(phase='failed', checkedAt=utcnow(), error=clean(str(error)))
            save_state(args.state_dir, state)
            try:
                notifier.send(f'🔴 {HEADER}\nWatchdog завершился с ошибкой: {clean(str(error))}')
            except Exception:
                pass
            print(json.dumps({'healthy': False, 'error': clean(str(error))}), flush=True)
            return 1


if __name__ == '__main__':
    raise SystemExit(main())
