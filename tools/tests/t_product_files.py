#!/usr/bin/env python3
"""ios/tools/product_files.py (plan item 62l): the app carries each module's fixups and gates, and its code option list when the product has
one, so host/runtime/options.c knows the options built into the image; a module's missing fixups or gates are reported. The option lists
left out (T_PRODUCT_FILES_NO_OPTIONS=1, the broken variant: as ios/run.sh copied before): 2 fail."""
import os, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
sys.path.insert(0, os.path.join(ROOT, 'ios', 'tools')); import product_files as pf
fails = total = 0
def check(name, ok, detail=''):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<100} {"✓" if ok else "✗"}' + (f'\n    {detail}' if detail and not ok else ''))
def fs(names): return lambda p: os.path.basename(p) in names
base = {f'{m}.{k}.tsv' for m in ('main', 'sdk') for k in ('fixups', 'gates')}
paths, bad = pf.files('/p', ['main', 'sdk'], fs(base))
check('a product without options: fixups and gates of each module, nothing missing', sorted(map(os.path.basename, paths)) == sorted(base) and not bad, (paths, bad))
paths, bad = pf.files('/p', ['main', 'sdk'], fs(base | {'main.options.tsv', 'sdk.options.tsv'}))
names = set(map(os.path.basename, paths))
check('a product with options: main.options.tsv carried', 'main.options.tsv' in names, paths)
check('... sdk.options.tsv carried', 'sdk.options.tsv' in names, paths)
paths, bad = pf.files('/p', ['main'], fs({'main.fixups.tsv'}))
check('main.gates.tsv missing: reported', [os.path.basename(p) for p in bad] == ['main.gates.tsv'], bad)
print(f'== {total} checks, {fails} failed ==')
sys.exit(fails != 0)
