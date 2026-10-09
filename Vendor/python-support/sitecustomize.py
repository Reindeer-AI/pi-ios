"""Connects Python to the iOS shell (ios_system) it runs in.

CPython's iOS build loads compiled modules (ctypes, ssl, sqlite3, ...) from the app's Frameworks folder, which it finds
next to sys.executable. Run as a shell command, sys.executable is just "python3", so it is set to the app's executable,
which the app passes as PYTHONEXECUTABLE (CPython's iOS build does not read that variable itself).

Python runs inside the app as an ios_system command, so the process's descriptors 0-2 belong to the app, not to the
command. Point sys.stdin, sys.stdout, and sys.stderr at the running command's own streams (including pipeline
streams), so print(), pipes, and tracebacks reach the caller. Also puts the bundled pip wheel on sys.path, which makes
`python3 -m pip install --user <package>` work for pure-Python packages.
"""

import os
import sys


def _locate_executable():
    sys.executable = sys._base_executable = os.environ["PYTHONEXECUTABLE"]


def _connect_streams():
    import ctypes

    process = ctypes.CDLL(None)
    for function in ("ios_stdin", "ios_stdout", "ios_stderr"):
        getattr(process, function).restype = ctypes.c_void_p
    process.fileno.argtypes = [ctypes.c_void_p]
    for function, name, mode in (
        ("ios_stdin", "stdin", "r"),
        ("ios_stdout", "stdout", "w"),
        ("ios_stderr", "stderr", "w"),
    ):
        stream = getattr(process, function)()
        if not stream:
            continue
        descriptor = os.dup(process.fileno(stream))
        wrapper = os.fdopen(descriptor, mode, buffering=1, encoding="utf-8", errors="backslashreplace")
        setattr(sys, name, wrapper)
        setattr(sys, f"__{name}__", wrapper)


def _add_bundled_pip():
    import glob

    bundled = os.path.join(os.path.dirname(os.__file__), "ensurepip", "_bundled")
    sys.path.extend(sorted(glob.glob(os.path.join(bundled, "pip-*.whl"))))


if sys.platform == "ios":
    _locate_executable()
    try:
        _connect_streams()
    except Exception as error:  # Never block startup; fall back to the app's descriptors.
        print(f"sitecustomize: cannot connect streams: {error}", file=sys.__stderr__)
    _add_bundled_pip()
