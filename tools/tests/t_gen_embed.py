#!/usr/bin/env python3
"""ios/tools/gen_embed.py: the assembly that puts a rewritten module's image into the app's executable. On a scratch product (TEXT_END 0x2000, the
key page at 0x8000, PATCH_OFF 0x10000, an image of 0x14400 bytes): three sections that include the product's own image, the original text up to the
next 16 KiB boundary, the writable part up to PATCH_OFF and the patch area, the last one padded to 16 KiB; the writable segment's link flag on
stdout; a product whose key page lies past its patch area stops the build."""
import os, subprocess, sys, tempfile
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
TOOL = os.path.join(ROOT, 'ios', 'tools', 'gen_embed.py')
fails = total = 0
def check(name, ok, detail=''):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<92} {"✓" if ok else "✗"}' + (f'\n    {detail}' if detail and not ok else ''))
def product(d, key=0x8000):
    os.makedirs(d, exist_ok=True)
    open(f'{d}/m.patched.bin', 'wb').write(bytes(0x14400))
    open(f'{d}/m.fixups.tsv', 'w').write(f'# PATCH_OFF\t0x10000\n# KEY_PAGE_OFF\t{key:#x}\n# KEY_PAGE_SIZE\t0x4000\n# TEXT_END\t0x2000\n')
def run(d, out):
    r = subprocess.run([sys.executable, '-I', TOOL, d, out, 'm'], capture_output=True, text=True); return r.returncode, r.stdout, r.stderr
with tempfile.TemporaryDirectory() as td:
    p, g = os.path.join(td, 'prod'), os.path.join(td, 'gen'); os.makedirs(g); product(p)
    code, so, se = run(p, os.path.join(g, 'embed.S'))
    S = open(os.path.join(g, 'embed.S')).read() if code == 0 else ''
    img = os.path.abspath(f'{p}/m.patched.bin')
    def sect(name):   # the lines of one section
        i = S.find(f'.section {name}\n'); j = S.find('.section ', i + 1)
        return S[i:j if j > 0 else len(S)] if i >= 0 else ''
    check('built: exit 0, the writable segment\'s link flag on stdout', code == 0 and so.split() == ['-Wl,-segprot,__DMmW,rw,rw'], (so + se).strip()[-300:])
    check('the original text: the product\'s image from 0 to the 16 KiB boundary after TEXT_END', f'.incbin "{img}", 0x0, 0x4000' in sect('__TEXT,__dmmx0'), sect('__TEXT,__dmmx0'))
    check('the writable part in a segment of its own: from there to PATCH_OFF', f'.incbin "{img}", 0x4000, 0xc000' in sect('__DMmW,__img'), sect('__DMmW,__img'))
    x1 = sect('__TEXT,__dmmx1')
    check('the patch area: from PATCH_OFF to the image\'s end, padded to 16 KiB', f'.incbin "{img}", 0x10000, 0x4400' in x1 and '.space 0x3c00' in x1, x1)
    check('every section starts and ends on 16 KiB', S.count('.p2align 14') == 6, str(S.count('.p2align 14')))
    p2 = os.path.join(td, 'prod2'); product(p2, key=0x10000)
    code, so, se = run(p2, os.path.join(g, 'embed2.S'))
    check('a key page past the patch area: the build stops', code != 0 and not os.path.exists(os.path.join(g, 'embed2.S')), (so + se).strip()[-200:])
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
