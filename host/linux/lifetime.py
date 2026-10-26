# SPDX-License-Identifier: GPL-3.0-only
"""Own one restricted process group until the GUI's lifetime pipe closes.

The GUI retains the writer across short-lived worker threads. Neither the engine
nor any exec'd descendant inherits it. No PID lookup or parent-death signal is
used: those bind to a creator thread and can fail on capability-bearing exec.
"""
import os
import select
import signal
import subprocess
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from containment import ContainmentUnavailable, install_containment


def spawn_restricted(argv):
    """Distinguish an authored enforcement refusal from other startup errors."""
    reader, writer = os.pipe2(os.O_CLOEXEC)
    try:
        def restrict():
            try:
                install_containment()
            except ContainmentUnavailable:
                os.write(writer, b'C')
                raise
            finally:
                os.close(writer)
        try:
            return subprocess.Popen(argv, close_fds=True, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    pass_fds=(writer,), preexec_fn=restrict)
        except subprocess.SubprocessError:
            # Popen hides the preexec exception type. Only our child's explicit
            # marker permits attributing this failure to containment. Ordinary
            # exec errors and unexpected preexec errors keep the neutral status.
            os.close(writer); writer = None
            if os.read(reader, 1) == b'C':
                raise ContainmentUnavailable('Kernel containment unavailable') from None
            raise
    finally:
        os.close(reader)
        if writer is not None: os.close(writer)


def supervise(reader, ready, argv):
    os.set_inheritable(reader, False)
    os.set_inheritable(ready, False)
    # Catch rather than ignore TERM: exec resets a caught disposition for the engine.
    signal.signal(signal.SIGTERM, lambda *_: None)
    failure = b'F'
    try:
        if select.select([reader], [], [], 0)[0] and not os.read(reader, 1):
            return 1
        # This interpreter has no worker threads. Its direct child's preexec
        # function is safe here and Popen's exec-error pipe confirms that both
        # inherited enforcement and exec succeeded before acknowledging start.
        child = spawn_restricted(argv)
        os.write(ready, b'R')
        os.close(ready)
        ready = None
        while True:
            if select.select([reader], [], [], 0.1)[0] and not os.read(reader, 1):
                break
            if child.poll() is not None:
                break
    except ContainmentUnavailable:
        failure = b'C'
    finally:
        if ready is not None:
            try: os.write(ready, failure)
            except OSError: pass
            os.close(ready)
        # Enforcement forbids new processes and group/session/namespace moves.
        # The GUI retains our unreaped PID until its stop finishes, so this group
        # cannot be reused between observing exit and signaling its members.
        os.killpg(os.getpgrp(), signal.SIGKILL)
    return 1


if __name__ == '__main__':
    supervise(int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:])
