"""GeoMod step run by Hammer++ after VRAD.

Makes sure NumPy is available (installing it if needed), then repairs the
lighting on surfaces that cutting will reveal inside GeoMod brushes.
"""
import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from geomod_env import ensure_numpy, find_garrysmod


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bsp', type=Path, nargs='?', help='Compiled BSP to repair in place')
    parser.add_argument('--game-dir', type=Path, help="Garry's Mod or garrysmod folder (Hammer's $gamedir)")
    parser.add_argument('--search-path', type=Path, action='append', default=[],
                        help='Extra addon folder whose materials the lighting pass should see')
    parser.add_argument('--check', action='store_true',
                        help='Only verify Python, NumPy and the Garry\'s Mod install, then exit')
    args = parser.parse_args()
    ensure_numpy()
    game = find_garrysmod(args.game_dir)
    if args.check:
        print(f'GeoMod tools ready: Python {sys.version.split()[0]}, Garry\'s Mod at {game}')
        return
    if args.bsp is None:
        parser.error('a BSP path is required unless --check is used')
    bsp = args.bsp.resolve(strict=True)
    with bsp.open('rb') as handle:
        if handle.read(8) != b'VBSP\x14\0\0\0':
            raise SystemExit('Expected an uncompressed Source BSP version 20: ' + str(bsp))
    command = [sys.executable, str(Path(__file__).with_name('prepare_geomod_reveal_lighting.py')),
               str(bsp), str(bsp), '--allow-unchanged', '--game-dir', str(game)]
    for path in args.search_path:
        command += ['--search-path', str(path)]
    subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
