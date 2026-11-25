"""Generate an importable Hammer++ Expert compile preset for GeoMod maps.

The preset runs VBSP, VVIS and VRAD, then GeoMod's lighting repair, then copies
the BSP and launches the game. Import the result through Run Map > Expert >
Edit > Import. Optional --install updates only this preset in a closed Hammer
configuration; other presets remain intact.
"""
import argparse
import os
import re
import subprocess
from pathlib import Path


PRESET = 'GeoMod - Full'
TOOLS = Path(__file__).resolve().parent


def quoted(value):
    # Source KeyValues escape embedded command-line quotes. Use forward slashes
    # for literal paths; preserve Hammer's stock macro spelling and separators.
    return '"' + value.replace('"', '\\"') + '"'


def configuration(portable=False):
    """Build the preset text.

    A portable preset finds the tools through Hammer's $gamedir macro, so it works
    on any machine where this repository is installed as garrysmod/addons/geomod.
    Otherwise it records the absolute path of this checkout.
    """
    script = TOOLS / 'geomod_post_compile.ps1'
    # Hammer quotes expanded $path/$file arguments itself, as in the Default
    # preset. Do not wrap those macros in an extra pair of quotes.
    location = r'$gamedir\addons\geomod\tools\geomod_post_compile.ps1' if portable else subprocess.list2cmdline([script.as_posix()])
    parms = '-NoProfile -ExecutionPolicy Bypass -File ' + location + r' -BspPath $path\$file.bsp -GameDir $gamedir'
    # Windows PowerShell 5.1 lives in the same place on every installation.
    powershell = Path('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe') if portable else         Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    commands = [
        {'run': '$bsp_exe', 'parms': r'-game $gamedir $path\$file'},
        {'run': '$vis_exe', 'parms': r'-game $gamedir $path\$file'},
        {'run': '$light_exe', 'parms': r'-game $gamedir $path\$file'},
        {'run': powershell.as_posix(), 'parms': parms},
        {'specialcmd': '257', 'parms': r'$path\$file.bsp $bspdir\$file.bsp'},
        {'run': '$game_exe', 'parms': '-dev -console -allowdebug -hijack -game $gamedir +map $file'},
    ]
    lines = ['"Command Sequences"', '{', '\t"' + PRESET + '"','\t{']
    for index, command in enumerate(commands):
        lines.extend(['\t\t' + quoted(str(index)), '\t\t{'])
        fields = {'enable': '1', 'specialcmd': '0', **command}
        lines.extend('\t\t\t' + quoted(k) + '\t\t' + quoted(v) for k, v in fields.items())
        lines.append('\t\t}')
    return '\n'.join(lines + ['\t}', '}', ''])


def sequence_range(text):
    matches = list(re.finditer('"' + re.escape(PRESET) + r'"\s*\{', text))
    if len(matches) != 1:
        raise ValueError('Expected exactly one '+PRESET+' preset; import the generated CFG instead')
    start = matches[0].start()
    depth = 1
    for token in re.finditer(r'"(?:\\.|[^"\\])*"|[{}]', text[matches[0].end():]):
        if token[0] == '{':
            depth += 1
        elif token[0] == '}':
            depth -= 1
            if depth == 0:
                return start, matches[0].end() + token.end()
    raise ValueError('Unclosed GeoMod compile preset')


def replace_sequence(original, generated):
    start, end = sequence_range(original)
    first, last = sequence_range(generated)
    replacement = generated[first:last]
    if '\r\n' in original:
        replacement = replacement.replace('\n', '\r\n')
    return original[:start] + replacement + original[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=None)
    parser.add_argument('--portable', action='store_true',
                        help='Write the shareable preset that locates the tools through $gamedir '
                             '(repository installed as garrysmod/addons/geomod)')
    parser.add_argument('--install', type=Path, help='Replace only an existing GeoMod preset in a closed Hammer configuration')
    args = parser.parse_args()
    generated = configuration(args.portable)
    if args.output is None:
        args.output = TOOLS.parent / 'hammer/geomod_full.cfg' if args.portable else Path('geomod_compile.cfg')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding='utf-8')
    if args.install:
        for app in ('hammer.exe', 'hammerplusplus.exe'):
            tasks = subprocess.check_output(['tasklist', '/FI', f'IMAGENAME eq {app}', '/FO', 'CSV', '/NH'], text=True)
            if f'"{app}"' in tasks.lower():
                raise RuntimeError('Close Hammer before updating its saved preset; the import file is ready')
        original = args.install.read_bytes()
        updated = replace_sequence(original.decode('utf-8'), generated).encode('utf-8')
        if args.install.read_bytes() != original:
            raise RuntimeError('Hammer configuration changed during preparation')
        args.install.write_bytes(updated)
        assert args.install.read_bytes() == updated
        print('Updated only ' + PRESET + ' in', args.install)
    print('Import in Hammer++: Run Map > Expert > Edit > Import')
    print(args.output.resolve())


if __name__ == '__main__':
    main()
