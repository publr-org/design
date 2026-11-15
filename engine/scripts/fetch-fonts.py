#!/usr/bin/env python3
"""Fetches every font family a corpus file uses, and checks each against Figma's metrics.

    scripts/fetch-fonts.py <corpus-dir> [<corpus-dir> ...]

For each family in <dir>/file.json without a folder in corpus/fonts/, downloads the full
font files from the google/fonts repository (not the trimmed Google Fonts API copies) into
corpus/fonts/<Family>/. Then, for every family, compares Figma's automatic line height
(`lineHeightPx` of text with intrinsic line height) with the font's own metrics: a mismatch
means Figma uses a different version of the font (as with Inter, where Figma has 3.x).
"""
import json, os, struct, sys, urllib.request, urllib.parse

here = os.path.dirname(os.path.abspath(__file__))
fonts_dir = os.path.join(os.path.dirname(here), 'corpus', 'fonts')
raw = 'https://raw.githubusercontent.com/google/fonts/main/'


def get(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def tree():
    data = json.loads(get('https://api.github.com/repos/google/fonts/git/trees/main?recursive=1'))
    return [x['path'] for x in data['tree']]


def metrics(path):
    """(units per em, ascender, descender, line gap) as Figma's auto line height uses them."""
    b = open(path, 'rb').read()
    n = struct.unpack('>H', b[4:6])[0]
    t = {}
    for i in range(n):
        tag, _, off, ln = struct.unpack('>4sIII', b[12 + 16 * i:28 + 16 * i])
        t[tag.decode('latin1')] = off
    upem = struct.unpack('>H', b[t['head'] + 18:t['head'] + 20])[0]
    asc, desc, gap = struct.unpack('>hhh', b[t['hhea'] + 4:t['hhea'] + 10])
    if 'OS/2' in t:
        o = t['OS/2']
        sel = struct.unpack('>H', b[o + 62:o + 64])[0]
        if sel & 128:
            asc, desc, gap = struct.unpack('>hhh', b[o + 68:o + 74])
    return upem, asc, desc, gap


def used(corpus):
    """Family -> set of styles, and family -> list of (size, lineHeightPx) for auto line heights."""
    d = json.load(open(os.path.join(corpus, 'file.json')))
    fams, lh = {}, {}

    def add(st):
        f = st.get('fontFamily')
        if not f:
            return
        fams.setdefault(f, set()).add(st.get('fontStyle', 'Regular'))
        if st.get('lineHeightUnit') == 'INTRINSIC_%' and st.get('lineHeightPx') and st.get('fontSize'):
            lh.setdefault(f, []).append((st['fontSize'], st['lineHeightPx']))

    def walk(n):
        if n['type'] == 'TEXT':
            add(n['style'])
            for o in (n.get('styleOverrideTable') or {}).values():
                add(o)
        for c in n.get('children', []):
            walk(c)
    walk(d['document'])
    return fams, lh


def main():
    fams, lh = {}, {}
    for corpus in sys.argv[1:]:
        f, l = used(corpus)
        for k, v in f.items():
            fams.setdefault(k, set()).update(v)
        for k, v in l.items():
            lh.setdefault(k, []).extend(v)

    paths = None
    for fam in sorted(fams):
        folder = os.path.join(fonts_dir, fam.replace(' ', ''))
        if not os.path.isdir(folder):
            paths = paths or tree()
            key = fam.lower().replace(' ', '')
            files = [p for p in paths if p.split('/')[1:2] == [key] and p.endswith(('.ttf', '.otf'))]
            if not files:
                print(f'{fam}: not in google/fonts; add it by hand to {folder}')
                continue
            os.makedirs(folder)
            for p in files:
                url = raw + urllib.parse.quote(p)
                open(os.path.join(folder, os.path.basename(p)), 'wb').write(get(url))
            print(f'{fam}: fetched {len(files)} files from {os.path.dirname(files[0])}')

        # Check the version: Figma's auto line height against the font's metrics.
        files = [os.path.join(folder, x) for x in sorted(os.listdir(folder)) if x.endswith(('.ttf', '.otf'))]
        if not files or fam not in lh:
            print(f'{fam}: {sorted(fams[fam])} (no auto line heights to check)')
            continue
        upem, asc, desc, gap = metrics(files[0])
        ratio = (asc - desc + gap) / upem
        worst = max(abs(size * ratio - px) for size, px in lh[fam])
        verdict = 'matches Figma' if worst < 0.002 else f'DIFFERS from Figma by up to {worst:.4f}px: Figma has another version'
        print(f'{fam}: {sorted(fams[fam])}; line height ratio {ratio:.6f} ({upem} upem): {verdict}')


main()
