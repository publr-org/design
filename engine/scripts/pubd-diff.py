#!/usr/bin/env python3
"""Compares two Pubd documents node by node (same ids) and lists what differs.

    scripts/pubd-diff.py a.pubd b.pubd [--field FIELD]... [--show N] [--tol 0.001]

Prints, per field, how many nodes differ and the first few examples; then nodes only in
one of the two. Numbers compare within --tol; colours given as hex or [r, g, b(, a)]
compare as numbers. Made to check the .fig importer against the REST importer.
"""
import json, sys, os, argparse, collections, re

def load(p):
    if os.path.isdir(p):
        p = os.path.join(p, 'document.json')
    with open(p) as f:
        return json.load(f)

def walk(nodes, out, parent=None):
    for i, n in enumerate(nodes):
        out[n['id']] = (n, parent, i)
        walk(n.get('children', []), out, n['id'])

def hexcolor(s):
    s = s.lstrip('#')
    vals = [int(s[i:i + 2], 16) / 255 for i in range(0, len(s), 2)]
    if len(vals) == 3:
        vals.append(1.0)
    return vals

NUM = re.compile(r'-?\d+(?:\.\d+)?(?:e-?\d+)?')

def norm(v):
    """Turns colours into number lists and SVG paths into number lists plus letters."""
    if isinstance(v, str) and re.fullmatch(r'#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?', v):
        return hexcolor(v)
    if isinstance(v, list) and len(v) in (3, 4) and all(isinstance(x, (int, float)) for x in v):
        return list(v) + ([1.0] if len(v) == 3 else [])
    if isinstance(v, dict):
        return {k: norm(x) for k, x in v.items()}
    if isinstance(v, list):
        return [norm(x) for x in v]
    return v

def same(a, b, tol):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and not isinstance(b, bool):
        return abs(a - b) <= tol * max(1, abs(a), abs(b))
    if isinstance(a, str) and isinstance(b, str) and (a[:1] in 'MLCQZ' and b[:1] in 'MLCQZ'):
        # SVG path data: same commands, numbers within tolerance (REST rounds to 6 digits).
        ca, cb = re.sub(NUM, '#', a).replace(' ', ''), re.sub(NUM, '#', b).replace(' ', '')
        if ca != cb:
            return False
        na, nb = [float(x) for x in NUM.findall(a)], [float(x) for x in NUM.findall(b)]
        return len(na) == len(nb) and all(abs(x - y) <= max(tol, 1e-3) * max(1, abs(x)) for x, y in zip(na, nb))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k], tol) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y, tol) for x, y in zip(a, b))
    return a == b

def short(v, n=160):
    s = json.dumps(v)
    return s if len(s) <= n else s[:n] + '...'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a')
    ap.add_argument('b')
    ap.add_argument('--field', action='append', default=None)
    ap.add_argument('--show', type=int, default=3)
    ap.add_argument('--tol', type=float, default=1e-4)
    args = ap.parse_args()
    A, B = {}, {}
    walk(load(args.a)['pages'], A)
    walk(load(args.b)['pages'], B)
    diffs = collections.defaultdict(list)
    for nid, (na, pa, ia) in A.items():
        if nid not in B:
            continue
        nb, pb, ib = B[nid]
        if pa != pb:
            diffs['(parent)'].append((nid, pa, pb))
        elif ia != ib:
            diffs['(order)'].append((nid, ia, ib))
        keys = set(na) | set(nb)
        keys.discard('children')
        for k in sorted(keys):
            if args.field and k not in args.field:
                continue
            va, vb = norm(na.get(k)), norm(nb.get(k))
            if not same(va, vb, args.tol):
                diffs[k].append((nid, na.get(k), nb.get(k)))
    print(f'{len(A)} nodes in {args.a}, {len(B)} in {args.b}, {len(set(A) & set(B))} shared')
    for k in sorted(diffs, key=lambda k: -len(diffs[k])):
        print(f'\n{k}: {len(diffs[k])} nodes differ')
        for nid, va, vb in diffs[k][:args.show]:
            print(f'  {nid}  ({A[nid][0].get("type")} {A[nid][0].get("name", "")[:30]!r})')
            print(f'    a: {short(va)}')
            print(f'    b: {short(vb)}')
    only_a = [i for i in A if i not in B]
    only_b = [i for i in B if i not in A]
    for label, ids, src in (('only in a', only_a, A), ('only in b', only_b, B)):
        if ids:
            print(f'\n{label}: {len(ids)}')
            for i in ids[:args.show * 3]:
                print(f'  {i} {src[i][0].get("type")} {src[i][0].get("name", "")[:40]!r}')
    if not diffs and not only_a and not only_b:
        print('identical on every compared field')

if __name__ == '__main__':
    main()
