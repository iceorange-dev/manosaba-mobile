#!/usr/bin/env python3
"""The files of a product the app carries beside its embedded code (ios/run.sh copies them into Gen/dm/): per module the loader's fixups and
gates (host/runtime/loader.c).
Usage: product_files.py <product dir> <module...>: the paths, one a line; exit 1 when a module's fixups or gates are missing."""
import os, sys

def files(out, mods, exists=os.path.exists):
    """(paths, problems) for the modules mods of the product directory out"""
    paths, bad = [], []
    for m in mods:
        for kind in ('fixups', 'gates'):
            p = os.path.join(out, f'{m}.{kind}.tsv')
            (paths if exists(p) else bad).append(p)
    return paths, bad

if __name__ == '__main__':
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    paths, bad = files(sys.argv[1], sys.argv[2:])
    if bad: print('\n'.join(f'[red] missing {p}' for p in bad), file=sys.stderr); sys.exit(1)
    print('\n'.join(paths))
