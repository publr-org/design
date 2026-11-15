#!/usr/bin/env python3
"""Pulls a Figma file into a corpus folder: the document, Figma's own renders, its images.

    scripts/pull-figma.py <file-key> <corpus-dir> [--depth 3] [--min 24]

Writes <dir>/file.json, <dir>/images/<ref>, <dir>/renders/<node>@{1,2}.png for every
top-level frame and every frame, component or instance down to --depth below it that is at
least --min px on both sides, then imports it to <dir>/<name>.pubd with `pe`. Needs the token
in ../.figma-token (publr-design/.figma-token).
"""
import json, os, subprocess, sys, urllib.request

here = os.path.dirname(os.path.abspath(__file__))
engine = os.path.dirname(here)
token = open(os.path.join(os.path.dirname(engine), '.figma-token')).read().strip()

def get(url):
    req = urllib.request.Request(url, headers={'X-Figma-Token': token})
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()

def main():
    args = sys.argv[1:]
    key, out = args[0], args[1]
    depth = int(args[args.index('--depth') + 1]) if '--depth' in args else 3
    minsize = float(args[args.index('--min') + 1]) if '--min' in args else 24
    os.makedirs(os.path.join(out, 'renders'), exist_ok=True)
    os.makedirs(os.path.join(out, 'images'), exist_ok=True)

    raw = get(f'https://api.figma.com/v1/files/{key}?geometry=paths')
    open(os.path.join(out, 'file.json'), 'wb').write(raw)
    doc = json.loads(raw)

    ids = []
    def walk(n, d):
        bb = n.get('absoluteBoundingBox') or {}
        big = bb.get('width', 0) >= minsize and bb.get('height', 0) >= minsize
        if n['type'] in ('FRAME', 'COMPONENT', 'COMPONENT_SET', 'INSTANCE', 'SECTION') and big and n.get('visible', True):
            ids.append(n['id'])
        if d < depth:
            for c in n.get('children', []):
                walk(c, d + 1)
    for page in doc['document']['children']:
        for top in page.get('children', []):
            walk(top, 0)
    print(f'{len(ids)} nodes to render')

    for scale in (1, 2):
        for i in range(0, len(ids), 40):
            batch = ids[i:i + 40]
            res = json.loads(get(f'https://api.figma.com/v1/images/{key}?ids={",".join(batch)}&format=png&scale={scale}'))
            for nid, url in (res.get('images') or {}).items():
                if not url:
                    continue
                name = nid.replace(':', '-').replace(';', '_')
                open(os.path.join(out, 'renders', f'{name}@{scale}.png'), 'wb').write(urllib.request.urlopen(url, timeout=300).read())
            print(f'  @{scale}: {min(i + 40, len(ids))}/{len(ids)}', flush=True)

    fills = json.loads(get(f'https://api.figma.com/v1/files/{key}/images'))
    for ref, url in (fills.get('meta', {}).get('images') or {}).items():
        if url:
            open(os.path.join(out, 'images', ref), 'wb').write(urllib.request.urlopen(url, timeout=300).read())

    name = os.path.basename(os.path.normpath(out))
    pe = os.path.join(engine, 'zig-out', 'bin', 'pe')
    subprocess.run([pe, 'import-figma', os.path.join(out, 'file.json'), os.path.join(out, 'images'), os.path.join(out, name + '.pubd')], check=True)

main()
