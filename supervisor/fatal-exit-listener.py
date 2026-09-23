#!/usr/bin/env python3
"""Supervisor eventlistener: fail loud, per the estate's field guide.

The platform never restarts a running container for a failing health check on its own (verified
platform behaviour). So if gunicorn or redis crash-loops into FATAL, a container that kept
running would sit "green" while serving 502s indefinitely. This listener turns any
PROCESS_STATE_FATAL into a full supervisord shutdown: the container exits, the platform sees a
dead container, and the failure is visible instead of silent.

stdout is the eventlistener protocol channel and carries nothing else; diagnostics go to
stderr, which supervisord forwards to the container log.
"""

import subprocess
import sys

SUPERVISOR_CONF = '/app/code/supervisor/supervisord.conf'


def write_stdout(s):
    sys.stdout.write(s)
    sys.stdout.flush()


def log(msg):
    sys.stderr.write('==> [fatal-listener] %s\n' % msg)
    sys.stderr.flush()


def main():
    while True:
        write_stdout('READY\n')
        line = sys.stdin.readline()
        if not line:
            return
        headers = dict(token.split(':', 1) for token in line.split())
        payload = sys.stdin.read(int(headers['len']))
        if headers.get('eventname') == 'PROCESS_STATE_FATAL':
            data = dict(token.split(':', 1) for token in payload.split())
            log(
                'process %s entered FATAL; shutting supervisord down so the container '
                'exits and the platform sees the failure' % data.get('processname', '?')
            )
            # stdout here is the eventlistener protocol channel: supervisorctl's own output
            # ("Shut down") must never reach it, or supervisord logs a protocol violation
            # (observed live 2026-08-01). Discard both streams.
            subprocess.run(
                ['supervisorctl', '-c', SUPERVISOR_CONF, 'shutdown'],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        write_stdout('RESULT 2\nOK')


if __name__ == '__main__':
    main()
