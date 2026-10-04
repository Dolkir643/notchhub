#!/usr/bin/env python3
"""Run the production watchdog with fake processes, clock and power tools.

No administrator authorization or real power command is executed. The harness
rejects unexpected external commands before running the substituted shell.
Run from any directory: python3 Tests/KeepAwakeWatchdogTests.py
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
import unittest


MOCK = r'''
import json
from pathlib import Path
import sys
root = Path(__file__).parent
state = json.loads((root / 'state.json').read_text())
args, command = sys.argv[1:], Path(sys.argv[0]).name
status = 0
if command == 'ps':
    pid = args[1]
    if pid == '23' and state['tick'] >= state['lease_ends']:
        status = 1
    elif args[-1] == 'stat=':
        print('S')
    elif args[-1] == 'lstart=':
        if pid == '22' and state['app_replaced']:
            print('Sun Oct 4 12:00:01 2026')
        else:
            print('Sun Oct 4 12:00:00 2026')
    elif args[-1] == 'ppid=':
        print(state['lease_parent'])
    else:
        raise AssertionError(args)
elif command == 'date':
    print(1000 + state['tick'])
elif command == 'sleep':
    state['tick'] += int(args[0])
elif command == 'ioreg':
    print('  "AppleClamshellState" = ' + state['closed'])
    print('  "AppleClamshellCausesSleep" = ' + state['causes'])
elif command == 'pmset':
    if args == ['-g']:
        print('SleepDisabled ' + str(state['disabled']))
    elif args == ['-g', 'batt']:
        print("Now drawing from '" + state['power'] + "'")
        print(' -InternalBattery-0 (id=1)\t' + str(state['percent']) +
              '%; discharging; 1:00 remaining present: true')
    elif args == ['-g', 'assertions']:
        print('PreventSystemSleep ' + str(state['foreign']))
        print('PreventUserIdleSystemSleep 0')
    elif args[0] == 'disablesleep':
        value = int(args[1])
        state['writes'].append(value)
        if value == 0 and state['fail_restore']:
            status = 1
        else:
            state['disabled'] = value
    elif args == ['sleepnow']:
        state['sleepnow'] += 1
    else:
        raise AssertionError(args)
else:
    raise AssertionError(command)
(root / 'state.json').write_text(json.dumps(state))
sys.exit(status)
'''


def production_script():
    source = (Path(__file__).resolve().parents[1] /
              'Sources/NotchHub/Services/KeepAwakePolicy.swift').read_text()
    # Extract only the literal from KeepAwakeWatchdog.script, not AppleScript.
    source = source.split('func script(now: Int)', 1)[1]
    body = source.split('        return """\n', 1)[1].split('        """', 1)[0]
    body = '\n'.join(line[8:] if line.startswith('        ') else line
                     for line in body.splitlines())
    for old, new in [
        (r'\(appPID)', '22'), (r'\(leasePID)', '23'),
        (r'\(appStarted)', 'Sun Oct 4 12:00:00 2026'),
        (r'\(leaseStarted)', 'Sun Oct 4 12:00:00 2026'),
        (r'\(deadline)', '1030'), (r'\(powerOnly ? 1 : 0)', '0'),
    ]:
        body = body.replace(old, new)
    if re.search(r'(?<!\\)\\\(', body):
        raise AssertionError('New Swift interpolation must be handled explicitly')
    return body.replace('\\\\', '\\') + '\n'


class WatchdogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='notchhub-watchdog-')
        cls.root = Path(cls.temporary.name)
        mock = cls.root / 'mock'
        mock.write_text('#!' + sys.executable + '\n' + MOCK)
        mock.chmod(0o755)
        script = production_script()
        # Real external tools are limited to text processing. Every process,
        # clock, sleep and system-power observation/mutation is replaced.
        replacements = ['/usr/bin/pmset', '/usr/sbin/ioreg', '/bin/ps',
                        '/bin/date', '/bin/sleep']
        external = set(re.findall(r'/(?:usr/)?s?bin/[A-Za-z0-9_-]+', script))
        allowed = set(replacements + ['/usr/bin/sed', '/usr/bin/awk',
                                      '/usr/bin/head', '/usr/bin/tr'])
        if not external <= allowed:
            raise AssertionError('Unmocked command: ' + repr(external - allowed))
        for path in replacements:
            replacement = cls.root / Path(path).name
            replacement.symlink_to(mock)
            script = script.replace(path, str(replacement))
        stripped = script
        for path in replacements:
            if path in script:
                raise AssertionError('System command was not replaced: ' + path)
            stripped = stripped.replace(str(cls.root / Path(path).name), '')
        executable_lines = '\n'.join(line for line in stripped.splitlines()
                                     if not line.lstrip().startswith('#'))
        if re.search(r'\b(?:sudo|osascript|pmset|ioreg)\b', executable_lines):
            raise AssertionError('Unexpected power/authorization invocation')
        cls.script = cls.root / 'watchdog.sh'
        cls.script.write_text(script)
        subprocess.run(['/bin/sh', '-n', str(cls.script)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_watchdog(self, **changes):
        state = dict(tick=0, lease_ends=2, disabled=0, power='AC Power',
                     percent=80, closed='No', causes='Yes', foreign=0,
                     writes=[], sleepnow=0, fail_restore=False,
                     app_replaced=False, lease_parent='22')
        state.update(changes)
        (self.root / 'state.json').write_text(json.dumps(state))
        result = subprocess.run(['/bin/sh', str(self.script)],
                                capture_output=True, text=True, timeout=20)
        return json.loads((self.root / 'state.json').read_text()), result

    def test_lease_end_restores(self):
        state, result = self.run_watchdog()
        self.assertEqual(state['writes'], [1, 0])
        self.assertEqual(state['disabled'], 0)
        self.assertEqual(state['sleepnow'], 0)
        self.assertEqual(result.returncode, 0)

    def test_preexisting_override_is_untouched(self):
        state, result = self.run_watchdog(disabled=1)
        self.assertEqual(state['writes'], [])
        self.assertEqual(state['disabled'], 1)
        self.assertIn('NOTCHHUB_PREEXISTING_SLEEP_OVERRIDE', result.stderr)

    def test_authorization_accepted_after_cancel_does_nothing(self):
        state, result = self.run_watchdog(lease_ends=0)
        self.assertEqual(state['writes'], [])
        self.assertIn('NOTCHHUB_LEASE_ENDED', result.stderr)

    def test_reused_app_pid_is_rejected(self):
        state, result = self.run_watchdog(app_replaced=True)
        self.assertEqual(state['writes'], [])
        self.assertIn('NOTCHHUB_LEASE_ENDED', result.stderr)

    def test_orphaned_lease_is_rejected(self):
        state, result = self.run_watchdog(lease_parent='1')
        self.assertEqual(state['writes'], [])
        self.assertIn('NOTCHHUB_LEASE_ENDED', result.stderr)

    def test_low_battery_blocks_start(self):
        state, result = self.run_watchdog(power='Battery Power', percent=15)
        self.assertEqual(state['writes'], [])
        self.assertIn('NOTCHHUB_LEASE_ENDED', result.stderr)

    def test_closed_lid_safely_requests_sleep(self):
        state, result = self.run_watchdog(closed='Yes')
        self.assertEqual(state['writes'], [1, 0])
        self.assertEqual(state['sleepnow'], 1)
        self.assertEqual(result.returncode, 0)

    def test_external_display_foreign_assertions_and_unknown_state_prevent_forced_sleep(self):
        for changes in [dict(causes='No'), dict(foreign=1), dict(causes='unknown')]:
            with self.subTest(changes=changes):
                state, _ = self.run_watchdog(closed='Yes', **changes)
                self.assertEqual(state['writes'], [1, 0])
                self.assertEqual(state['sleepnow'], 0)

    def test_deadline_restores_while_app_and_lease_live(self):
        state, result = self.run_watchdog(lease_ends=100)
        self.assertEqual(state['writes'], [1, 0])
        self.assertGreaterEqual(state['tick'], 30)
        self.assertEqual(result.returncode, 0)

    def test_failed_restore_is_bounded_and_reported_without_sleep_request(self):
        state, result = self.run_watchdog(fail_restore=True, closed='Yes')
        self.assertEqual(state['writes'], [1, 0, 0, 0, 0, 0])
        self.assertEqual(state['disabled'], 1)
        self.assertEqual(state['sleepnow'], 0)
        self.assertEqual(result.returncode, 73)
        self.assertIn('NOTCHHUB_RESTORE_FAILED', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
