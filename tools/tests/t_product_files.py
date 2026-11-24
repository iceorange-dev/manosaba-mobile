#!/usr/bin/env python3
"""ios/tools/product_files.py (plan item 62l): the app carries each module's fixups and gates beside its embedded code, nothing else of the
product; a module's missing fixups or gates are reported."""
import os, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
sys.path.insert(0, os.path.join(ROOT, 'ios', 'tools')); import product_files as pf
fails = total = 0
def check(name, ok, detail=''):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<100} {"✓" if ok else "✗"}' + (f'\n    {detail}' if detail and not ok else ''))
def fs(names): return lambda p: os.path.basename(p) in names
base = {f'{m}.{k}.tsv' for m in ('main', 'sdk') for k in ('fixups', 'gates')}
paths, bad = pf.files('/p', ['main', 'sdk'], fs(base | {'main.sites.tsv', 'main.cuts.tsv', 'sdk.acq.tsv'}))
check('fixups and gates of each module, nothing missing, the product\'s other tables left', sorted(map(os.path.basename, paths)) == sorted(base) and not bad, (paths, bad))
paths, bad = pf.files('/p', ['main'], fs({'main.fixups.tsv'}))
check('main.gates.tsv missing: reported', [os.path.basename(p) for p in bad] == ['main.gates.tsv'], bad)
paths, bad = pf.files('/p', ['main', 'sdk'], fs({'main.fixups.tsv', 'main.gates.tsv', 'sdk.gates.tsv'}))
check('sdk.fixups.tsv missing: reported, the three others listed', [os.path.basename(p) for p in bad] == ['sdk.fixups.tsv'] and len(paths) == 3, (paths, bad))
print(f'== {total} checks, {fails} failed ==')
sys.exit(fails != 0)
