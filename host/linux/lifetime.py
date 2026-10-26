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
from containment import install_containment


def supervise(reader, ready, argv):
    os.set_inheritable(reader, False)
    os.set_inheritable(ready, False)
    # Catch rather than ignore TERM: exec resets a caught disposition for the engine.
    signal.signal(signal.SIGTERM, lambda *_: None)
    try:
        if select.select([reader], [], [], 0)[0] and not os.read(reader, 1):
            return 1
        # This interpreter has no worker threads. Its direct child's preexec
        # function is safe here and Popen's exec-error pipe confirms that both
        # inherited enforcement and exec succeeded before acknowledging start.
        child = subprocess.Popen(argv, close_fds=True, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 preexec_fn=install_containment)
        os.write(ready, b'R')
        os.close(ready)
        ready = None
        while True:
            if select.select([reader], [], [], 0.1)[0] and not os.read(reader, 1):
                break
            if child.poll() is not None:
                break
    finally:
        if ready is not None:
            try: os.write(ready, b'F')
            except OSError: pass
            os.close(ready)
        # Enforcement forbids new processes and group/session/namespace moves.
        # The GUI retains our unreaped PID until its stop finishes, so this group
        # cannot be reused between observing exit and signaling its members.
        os.killpg(os.getpgrp(), signal.SIGKILL)
    return 1


if __name__ == '__main__':
    supervise(int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:])
