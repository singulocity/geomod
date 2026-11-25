"""Repair only static luxels inside/touching GeoMod using a shadowless second bake.

Input geometry, entities, visibility, ambient probes and unrelated lighting remain
byte-for-byte intact in the output. VRAD runs only on a disposable BSP copy.
"""
import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from geomod_env import ensure_numpy, find_garrysmod

ensure_numpy()
import numpy as np

WORK = Path(tempfile.gettempdir()) / 'geomod-reveal-lighting'


def sha(data):
    return hashlib.sha256(data).hexdigest()


class BSP:
    def __init__(self, data):
        self.data = data
        assert data[:4] == b'VBSP' and struct.unpack_from('<i', data, 4)[0] == 20
        self.headers = [struct.unpack_from('<4i', data, 8 + i * 16) for i in range(64)]

    def lump(self, index):
        start, size, _, compressed = self.headers[index]
        if compressed:
            raise ValueError('Compressed lumps are not supported')
        return self.data[start:start + size]


def entities(bsp):
    for block in re.findall(rb'\{[^{}]*\}', bsp.lump(0)):
        yield block, {k.decode(): v.decode() for k, v in re.findall(rb'"([^"]*)"\s*"([^"]*)"', block)}


def geomod_solids(bsp):
    models = list(struct.iter_unpack('<9f3i', bsp.lump(14)))
    planes = np.array(list(struct.iter_unpack('<4fi', bsp.lump(1))))[:, :4]
    nodes, leaves = bsp.lump(5), bsp.lump(10)
    leaf_stride = 56 if bsp.headers[10][2] == 0 else 32
    leafbrushes = bsp.lump(17)
    brushes, sides = bsp.lump(18), bsp.lump(19)
    result = []
    for _, ent in entities(bsp):
        if ent.get('classname') != 'func_geomod':
            continue
        shadow=ent.get('vrad_brush_cast_shadows','0')
        if shadow=='0':
            continue
        if shadow!='1':
            raise ValueError('Expected a 0/1 GeoMod shadow flag')
        if any(float(v) != 0 for v in ent.get('angles', '0 0 0').split()):
            raise ValueError('Rotated GeoMod requires an explicit transform before baking')
        origin = np.array(list(map(float, ent.get('origin', '0 0 0').split())))
        model = models[int(ent['model'][1:])]
        pending, visited, ids = [model[-3]], set(), set()
        while pending:
            node = pending.pop()
            if node in visited:
                continue
            visited.add(node)
            if node >= 0:
                pending.extend(struct.unpack_from('<2i', nodes, node * 32 + 4))
            else:
                first, count = struct.unpack_from('<2H', leaves, (-node - 1) * leaf_stride + 24)
                ids.update(struct.unpack_from('<H', leafbrushes, 2 * i)[0] for i in range(first, first + count))
        for index in ids:
            first, count, contents = struct.unpack_from('<3i', brushes, index * 12)
            if not contents & 1:
                continue
            ids = [struct.unpack_from('<H', sides, i * 8)[0] for i in range(first, first + count)]
            p = planes[ids].copy()
            p[:, 3] += p[:, :3] @ origin
            result.append((p[:, :3], p[:, 3]))
    return result


def covered(points, solids, footprint=None):
    """Require the entire bilinear sample footprint to stay under a brush.

    A changed luxel contributes up to one lightmap step in both directions.
    Testing its center alone illuminates exposed surfaces around brush corners.
    Coplanar contact is still allowed: in-plane steps have no extent along that
    contact plane's normal. Containment in one convex brush is conservative at
    joins between brushes, preserving the main bake there.
    """
    mask = np.zeros(len(points), dtype=bool)
    for normal, distance in solids:
        inset = 0 if footprint is None else np.abs(normal @ footprint).sum(axis=1)
        mask |= np.all(points @ normal.T <= distance + .05 - inset, axis=1)
    return mask


def transfer(original, alternate, restore_boundary=False):
    solids = geomod_solids(original)
    models = list(struct.iter_unpack('<9f3i', original.lump(14)))
    first, count = models[0][-2:]
    planes = np.array(list(struct.iter_unpack('<4fi', original.lump(1))))[:, :4]
    texinfo = original.lump(6)
    output = bytearray(original.data)
    changed = []
    eligible = 0
    for face_lump, light_lump in ((7, 8), (58, 53)):
        if not original.headers[light_lump][1]:
            continue
        old_faces, new_faces = original.lump(face_lump), alternate.lump(face_lump)
        old_light, new_light = original.lump(light_lump), alternate.lump(light_lump)
        assert len(old_faces) == len(new_faces), 'VRAD changed the face count'
        protected=np.zeros(len(old_light),dtype=bool)
        for model in models[1:]:
            for face in range(model[-2],model[-2]+model[-1]):
                at=face*56
                offset=struct.unpack_from('<i',old_faces,at+20)[0]
                if offset<0:
                    continue
                w,h=struct.unpack_from('<2i',old_faces,at+36)
                tex=struct.unpack_from('<h',old_faces,at+10)[0]
                flags=struct.unpack_from('<i',texinfo,tex*72+64)[0]
                styles=sum(v!=255 for v in old_faces[at+16:at+20])
                length=(w+1)*(h+1)*4*styles*(4 if flags&0x800 else 1)
                protected[offset:offset+length]=True
        for face in range(first, first + count):
            at = face * 56
            plane, side, _, _, _, texture = struct.unpack_from('<HBBihh', old_faces, at)
            old_offset = struct.unpack_from('<i', old_faces, at + 20)[0]
            new_offset = struct.unpack_from('<i', new_faces, at + 20)[0]
            if min(old_offset, new_offset) < 0:
                continue
            # Only illumination may differ; indices, shape and UV layout must match.
            assert old_faces[at:at + 16] == new_faces[at:at + 16]
            assert old_faces[at + 28:at + 56] == new_faces[at + 28:at + 56]
            assert old_faces[at + 16:at + 20] == new_faces[at + 16:at + 20]
            smin, tmin, w, h = struct.unpack_from('<4i', old_faces, at + 28)
            w, h = w + 1, h + 1
            n, d = planes[plane, :3], planes[plane, 3]
            if side:
                n, d = -n, -d
            u0, u1, u2, uoff, v0, v1, v2, voff = struct.unpack_from('<8f', texinfo, texture * 72 + 32)
            system = np.array([[u0, u1, u2], [v0, v1, v2], n])
            if abs(np.linalg.det(system)) < 1e-12:
                continue
            y, x = np.mgrid[:h, :w]
            rhs = np.stack((x.ravel() + smin - uoff, y.ravel() + tmin - voff, np.full(w * h, d)))
            points = np.linalg.solve(system, rhs).T
            # Columns are world-space displacements for one lightmap step.
            footprint = np.linalg.inv(system)[:, :2]
            safe = covered(points, solids, footprint)
            mask = covered(points, solids) & ~safe if restore_boundary else safe
            if not np.any(mask):
                continue
            eligible += int(mask.sum())
            flags = struct.unpack_from('<i', texinfo, texture * 72 + 64)[0]
            styles = sum(v != 255 for v in old_faces[at + 16:at + 20])
            blocks = styles * (4 if flags & 0x800 else 1)
            indices = np.flatnonzero(mask)
            changed_pixels = 0
            for block in range(blocks):
                for index in indices:
                    a = old_offset + (block * w * h + int(index)) * 4
                    b = new_offset + (block * w * h + int(index)) * 4
                    replacement = new_light[b:b + 4]
                    assert len(replacement) == 4
                    if replacement != old_light[a:a + 4]:
                        if np.any(protected[a:a+4]):
                            raise ValueError('Shared world/brush light samples would change intact brush lighting')
                        target = original.headers[light_lump][0] + a
                        output[target:target + 4] = replacement
                        changed_pixels += 1
            if changed_pixels:
                changed.append({'face': face, 'lighting_lump': light_lump, 'luxels': changed_pixels})
    result = BSP(bytes(output))
    untouched = [i for i in range(64) if i not in (8, 53)]
    assert all(original.lump(i) == result.lump(i) for i in untouched)
    return bytes(output), {'solids': len(solids), 'eligible_luxels': eligible, 'changed_faces': changed,
                           'all_nonlighting_lumps_identical': True, 'uncovered_light_samples_preserved': True,
                           'brush_model_lightmaps_preserved':True,
                           'mask': 'old_boundary_only' if restore_boundary else 'bilinear_footprint_inside_brush'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--restore-boundary', action='store_true',
                        help='Repair an earlier center-mask output: restore only its unsafe border from a shadow-casting bake.')
    parser.add_argument('--allow-unchanged', action='store_true',
                        help='Allow a custom map with no GeoMod lighting samples to update.')
    parser.add_argument('--game-dir', type=Path,
                        help="Garry's Mod folder, or its garrysmod subfolder (Hammer's $gamedir). Default: auto-detect.")
    parser.add_argument('--search-path', type=Path, action='append', default=[],
                        help='Extra mounted folder (an addon) whose materials VRAD should see. May be repeated.')
    args = parser.parse_args()
    game = find_garrysmod(args.game_dir)
    original = BSP(args.input.read_bytes())
    data = original.data
    for block, ent in entities(original):
        if not args.restore_boundary and ent.get('classname') == 'func_geomod':
            replacement = block.replace(b'"vrad_brush_cast_shadows" "1"', b'"vrad_brush_cast_shadows" "0"')
            assert len(replacement) == len(block)
            if ent.get('vrad_brush_cast_shadows')=='1' and replacement==block:
                raise ValueError('Unrecognized shadow flag formatting; preserve this BSP')
            data = data.replace(block, replacement, 1)
    if args.allow_unchanged and not args.restore_boundary and data == original.data:
        if args.output.resolve() != args.input.resolve():
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(original.data)
        print('No shadow-casting GeoMod brushes. Using Hammer lighting.', flush=True)
        return
    work = WORK
    build = work / 'build'
    build.mkdir(parents=True, exist_ok=True)
    mounts = ''.join('"Game" "' + p.resolve().as_posix() + '" ' for p in args.search_path)
    (build / 'gameinfo.txt').write_text('"GameInfo" { "game" "GeoMod reveal lighting" "FileSystem" { "SteamAppId" "4000" "SearchPaths" { "Game" "|gameinfo_path|." '
                                        + mounts + '"Game" "' + (game / 'garrysmod').as_posix() + '" } } }')
    alternate = work / ('shadowed.bsp' if args.restore_boundary else 'shadowless.bsp')
    alternate.write_bytes(data)
    mode = '-both' if original.headers[53][1] and original.headers[8][1] else '-hdr' if original.headers[53][1] else '-ldr'
    log = work / 'vrad.log'
    print('Running a ' + ('shadow-casting boundary repair' if args.restore_boundary else 'shadowless reveal') +
          ' lighting pass on a disposable BSP; main geometry/bake are preserved.', flush=True)
    with log.open('w') as output:
        completed = subprocess.run([str(game / 'bin/win64/vrad.exe'), '-game', str(build), mode,
                                    '-bounce', '4', '-threads', '4', str(alternate)], stdout=output, stderr=subprocess.STDOUT, cwd=game)
    if completed.returncode:
        raise RuntimeError('Secondary VRAD pass failed: ' + str(log))
    fixed, report = transfer(original, BSP(alternate.read_bytes()), args.restore_boundary)
    if not report['changed_faces']:
        if not args.allow_unchanged or args.restore_boundary:
            raise ValueError('No covered static lighting samples changed')
        print('No covered static lighting samples changed. Using Hammer lighting.', flush=True)
        if args.output.resolve() == args.input.resolve():
            return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(fixed)
    report.update(input=str(args.input), output=str(args.output), input_sha256=sha(original.data), output_sha256=sha(fixed), secondary_bounces=4)
    (work / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'changed_face_lump_records':len(report['changed_faces']),
                      'eligible_luxels':report['eligible_luxels'],
                      'all_nonlighting_lumps_identical':True,'output':str(args.output)}), flush=True)


if __name__ == '__main__':
    main()
