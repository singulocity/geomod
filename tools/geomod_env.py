"""Shared setup for the GeoMod Hammer tools: NumPy and the Garry's Mod install.

Nothing here depends on a particular project checkout.
"""
import importlib
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_GAME = Path('C:/Program Files (x86)/Steam/steamapps/common/GarrysMod')


def ensure_numpy():
    """Import NumPy, installing it with pip first when it is missing."""
    try:
        import numpy
        return numpy
    except ImportError:
        pass
    print('GeoMod: NumPy is not installed. Installing it with pip (one time)...', flush=True)
    install = [sys.executable, '-m', 'pip', 'install', '--disable-pip-version-check', 'numpy']
    # A virtual environment is not allowed to use --user.
    if sys.prefix == getattr(sys, 'base_prefix', sys.prefix):
        install.insert(4, '--user')
    result = subprocess.run(install)
    if result.returncode != 0:
        # Some Python builds ship without pip. Bootstrap it and retry once.
        subprocess.run([sys.executable, '-m', 'ensurepip', '--default-pip'])
        result = subprocess.run(install)
    if result.returncode != 0:
        raise SystemExit(
            'GeoMod could not install NumPy automatically.\n'
            'Run this yourself, then compile again:\n'
            f'    "{sys.executable}" -m pip install numpy\n'
            f'If pip reports no matching version, Python {sys.version_info.major}.{sys.version_info.minor} '
            'may be too new for NumPy wheels; install Python 3.12 or 3.13 from python.org.')
    importlib.invalidate_caches()
    try:
        import site
        user = site.getusersitepackages()
        if user not in sys.path and os.path.isdir(user):
            sys.path.append(user)
    except Exception:
        pass
    import numpy
    print(f'GeoMod: NumPy {numpy.__version__} installed.', flush=True)
    return numpy


def _steam_libraries():
    roots = []
    try:
        import winreg
        for hive, key in ((winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam'),
                          (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Valve\Steam')):
            try:
                with winreg.OpenKey(hive, key) as handle:
                    value = winreg.QueryValueEx(handle, 'SteamPath' if hive == winreg.HKEY_CURRENT_USER else 'InstallPath')[0]
                    roots.append(Path(value))
            except OSError:
                pass
    except ImportError:
        pass
    roots.append(Path('C:/Program Files (x86)/Steam'))
    libraries = []
    for root in roots:
        libraries.append(root)
        manifest = root / 'steamapps/libraryfolders.vdf'
        if manifest.is_file():
            for path in re.findall(r'"path"\s+"([^"]+)"', manifest.read_text(errors='replace')):
                # Steam's VDF escapes each backslash as two.
                libraries.append(Path(path.replace(chr(92) * 2, chr(92))))
    return libraries


def find_garrysmod(game_dir=None):
    """Return the Garry's Mod install folder (the one holding bin/win64/vrad.exe).

    `game_dir` may be that folder or its `garrysmod` subfolder, as Hammer's
    $gamedir macro supplies. The GMOD_DIR environment variable is also honored.
    """
    candidates = []
    for value in (game_dir, os.environ.get('GMOD_DIR')):
        if value:
            path = Path(value)
            candidates += [path, path.parent]
    candidates += [library / 'steamapps/common/GarrysMod' for library in _steam_libraries()]
    candidates.append(DEFAULT_GAME)
    for candidate in candidates:
        if (candidate / 'bin/win64/vrad.exe').is_file() and (candidate / 'garrysmod').is_dir():
            return candidate.resolve()
    raise SystemExit("Could not find Garry's Mod. Pass --game-dir or set GMOD_DIR to the "
                     'GarrysMod folder (the one containing bin/win64/vrad.exe).')
