import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

SPEC = importlib.util.spec_from_file_location('watchdog', Path(__file__).parents[1] / 'scripts/autofix-watchdog.py')
w = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(w)
NOW = 1793350800


def healthy():
    raw = {name: {'status': 200, 'body': {'healthy': True}} for name in w.PORTS}
    raw['vault'] = {'status': 200, 'body': {
        'tick': {'id': 298, 'ageSeconds': 300, 'frozen': False, 'quarantined': False},
        'risk': {'maxTickAge': 7200}}}
    raw['monitor_status'] = {'status': 200, 'body': {'lastError': '',
        'lastPass': '2026-10-30T09:00:00Z', 'checks': []}}
    return raw


class WatchdogTest(unittest.TestCase):
    def test_healthy_service_needs_no_recovery(self):
        self.assertEqual(w.assess(healthy(), NOW), [])

    def test_stand_warnings_do_not_trigger_restarts(self):
        raw = healthy()
        raw['monitor_status']['body']['checks'] = [{'id': 'governance.base.standMode', 'severity': 'warn'}]
        self.assertEqual(w.assess(raw, NOW), [])

    def test_stale_tick_is_detected_even_when_all_health_endpoints_are_green(self):
        raw = healthy()
        raw['vault']['body']['tick']['ageSeconds'] = 5500
        self.assertEqual(w.targets(w.assess(raw, NOW)), ['operators'])

    def test_missing_first_tick_starts_operators(self):
        raw = healthy()
        raw['vault']['body']['tick'].update(id=0, ageSeconds=None)
        self.assertEqual(w.targets(w.assess(raw, NOW)), ['operators'])

    def test_unavailable_indexer_does_not_restart_signing_services(self):
        raw = healthy()
        raw['indexer'] = {'error': 'ConnectionRefusedError'}
        raw['vault'] = {'error': 'ConnectionRefusedError'}
        self.assertEqual(w.targets(w.assess(raw, NOW)), ['indexer'])

    def test_shared_operator_services_only_restart_once(self):
        raw = healthy()
        for name in ('nav', 'keeper', 'relayer'):
            raw[name]['status'] = 503
        self.assertEqual(w.targets(w.assess(raw, NOW)), ['operators'])

    def test_quarantine_is_reported_without_erasing_monitor_history(self):
        raw = healthy()
        raw['vault']['body']['tick']['quarantined'] = True
        raw['monitor']['status'] = 503
        raw['monitor_status']['body']['checks'] = [{'id': 'tick.quarantine', 'severity': 'crit'}]
        issues = w.assess(raw, NOW)
        self.assertTrue(issues)
        self.assertEqual(w.targets(issues), [])

    def test_stalled_monitor_is_restarted_even_during_an_incident(self):
        raw = healthy()
        raw['monitor']['status'] = 503
        raw['monitor_status']['body'].update(lastPass='1970-01-01T00:00:00Z',
            checks=[{'id': 'tick.quarantine', 'severity': 'crit'}])
        self.assertEqual(w.targets(w.assess(raw, NOW)), ['monitor'])

    def test_bad_vault_response_is_not_accepted_as_healthy(self):
        for age in (None, 'invalid', float('nan'), -1):
            raw = healthy()
            raw['vault']['body']['tick']['ageSeconds'] = age
            self.assertIn('vault.unavailable', [i['code'] for i in w.assess(raw, NOW)])

    def test_autofix_sends_start_and_verified_success(self):
        raw = healthy()
        raw['nav']['status'] = 503
        repair, notify = Mock(), Mock()
        result = w.recover(w.assess(raw), notify, check=healthy, repair=repair, timeout=0)
        repair.assert_called_once_with('operators')
        self.assertTrue(result['healthy'])
        self.assertEqual(notify.call_count, 2)
        self.assertIn('Автофикс автономным ботом', notify.call_args_list[0].args[0])
        self.assertIn('восстановлен без участия человека', notify.call_args_list[1].args[0])

    def test_unresolved_failure_is_bounded_and_never_claims_success(self):
        raw = healthy()
        raw['nav']['status'] = 503
        repair, notify = Mock(), Mock()
        result = w.recover(w.assess(raw), notify, check=lambda: raw, repair=repair, timeout=0)
        self.assertEqual(repair.call_count, 2)
        self.assertFalse(result['healthy'])
        self.assertIn('не устранило сбой', notify.call_args.args[0])

    def test_protocol_incident_does_not_mutate_contracts_or_restart_healthy_services(self):
        issue = [{'code': 'tick.quarantine', 'detail': 'quarantine', 'target': None}]
        repair, notify = Mock(), Mock()
        result = w.recover(issue, notify, repair=repair, timeout=0)
        repair.assert_not_called()
        self.assertFalse(result['healthy'])

    def test_command_failure_is_reported_and_retried(self):
        raw = healthy()
        raw['indexer']['status'] = 503
        repair = Mock(side_effect=[RuntimeError('restart failed'), None])
        probes = iter([raw, healthy()])
        result = w.recover(w.assess(raw), Mock(), check=lambda: next(probes), repair=repair, timeout=0)
        self.assertTrue(result['healthy'])
        self.assertEqual(len(result['errors']), 1)

    def test_recovery_commands_only_target_allowlisted_components(self):
        with patch.object(w.subprocess, 'run', return_value=Mock(returncode=0)) as command:
            w.fix('operators')
            argv = command.call_args.args[0]
            self.assertIn('--no-deps', argv)
            self.assertIn('--no-build', argv)
            self.assertEqual(argv[-1], 'operators')
            w.fix('indexer')
            self.assertEqual(command.call_args.args[0], ['/usr/bin/systemctl', 'restart', 'xc-indexer.service'])
            with self.assertRaises(ValueError):
                w.fix('arbitrary')

    def test_failed_telegram_delivery_is_persisted_and_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            state = {'outbox': []}
            notifier = w.Notifications(directory, state)
            with patch.dict(os.environ, {'TELEGRAM_TOKEN': 'test-token', 'TELEGRAM_CHAT_ID': 'test-chat'}):
                with patch.object(w, 'request_json', side_effect=TimeoutError('test-token')):
                    notifier.send('test message')
                self.assertEqual(json.loads((directory / 'state.json').read_text())['outbox'], ['test message'])
                with patch.object(w, 'request_json', return_value={'status': 200, 'body': {'ok': True}}):
                    notifier.flush()
                self.assertEqual(w.load_state(directory)['outbox'], [])


if __name__ == '__main__':
    unittest.main()
