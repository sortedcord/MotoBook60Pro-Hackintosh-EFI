#!/usr/bin/env python3
"""Build the patched DSDT and MADT this EFI needs from your own Moto Book 60 Pro (Core Ultra 200H) firmware.

The tables are Lenovo firmware code, so they are not shipped in this repository. Run this on Linux, booted
directly from the firmware (not through OpenCore, or you dump the already-injected tables):

    sudo python3 tools/make_acpi_tables.py --efi /path/to/EFI          # dump, patch, compile, install
    python3 tools/make_acpi_tables.py --input-dir ./dump --out ./out    # from an existing `acpidump -b` folder

Needs: iasl and acpidump (Arch: acpica), Python 3.8+.

Python port, for Linux, of acpi/make-acpi-tables.ps1 from samwu07/xegfx-thinkbook14plus-mtl (BSD-2-Clause), which did
the same job for the ThinkBook 14+ 2024 (Meteor Lake). Arrow Lake-H firmware from the same Lenovo code base
(OEM Table ID "CB-01") has the same problems. The changes, each found by structure, not by line number:

  MADT  The firmware lists the CPUs only as x2APIC (type 9) entries, which macOS ignores. Rewritten in VedCloud's
        layout: 48 Local APIC (type 0) entries, ProcessorId 0..47 to match SSDT-PLUG-ALT's C000..C02F. Slot 0 is the
        boot CPU, then the other P-core threads, then E- and LP E-cores (each ascending); unused slots disabled.
  DSDT  C1  External() of method-local objects -> root External() (iasl error 6163 on recompile)
        C2  module-level Scope() whose target is only defined inside a module-level If: wrapped in If (One)
            (macOS's ACPICA runs module-level If blocks after the table load)
        C3  every If ((PCHS != 0x04)) unwrapped (PCHS lives in PCH NVS, and the XHCI/I2C devices sit inside it)
        C4  Name (_DEP, ...) removed (forward references that abort the load; macOS does not use _DEP)
        C5  PC00._CRS static: GPCL () -> constant (no PCI config reads before the root bridge is up),
            If (^MC.xxx) root-port window blanking removed
        C6  PC00.XHCI / RHUB _PSx: If ((DVID == 0xFFFF)) -> If (Zero) so the PCH xHCI reaches D0
        C7  root Fields PU2C/PU3C -> Name() with the real port counts; XHCI's local copies renamed XU2C/XU3C
        C8  IMxx = One for each I2C controller with a PNP0C50 (HID over I2C) device -> _PS0/_PS3/_DSM exist
        C9  OSYS default 0x03E8 -> 0x07E5 in _INI, so the touchpad _CRS returns its GpioInt
        C10 PS2K _STA -> XSTA, for SSDT-PS2VIS (which returns 0x0F on Darwin)
"""
import argparse, datetime, glob, os, plistlib, re, shutil, struct, subprocess, sys

VERSION = '1.0'
DSDT_OUT = 'DSDT-ARLH.aml'
APIC_OUT = 'APIC-ARLH.aml'
MADT_SLOTS = 48
SHIPPED_MAX_BUS = 0x3E

changes, warnings, facts = [], [], []


def say(m): print('   ' + m)
def step(m): print('\n== ' + m)
def warn(m): print('   WARNING: ' + m); warnings.append(m)
def fail(m): print('\nFAILED: ' + m); sys.exit(1)
def change(cid, what, status, detail): changes.append((cid, what, status, detail)); say(f'{cid:<4} {what}: {status} - {detail}')
def hx(v, w=2): return '0x' + format(v, '0%dX' % w)


def table_ok(b, sig):
    return b and len(b) >= 36 and b[:4] == sig.encode() and struct.unpack_from('<I', b, 4)[0] == len(b) and sum(b) & 0xFF == 0


def set_checksum(b):
    b[9] = 0
    b[9] = (-sum(b)) & 0xFF


def describe(b):
    return f'{b[:4].decode()} rev {b[8]}, OEM "{b[10:16].decode(errors="replace").strip()}" / "{b[16:24].decode(errors="replace")}", {len(b)} bytes'


# ---------------------------------------------------------------------------------------------------- ASL model
NS_KINDS = {'Scope', 'Device', 'Method', 'Processor', 'ThermalZone', 'PowerResource'}
COND_KINDS = {'If', 'Else', 'ElseIf', 'While', 'Switch', 'Case', 'Default'}
HEAD = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\((.*))?$')


def strip_code(lines):
    """Code part of each line: comments removed, string contents blanked."""
    res, in_block = [], False
    for s in lines:
        out, in_str, j = [], False, 0
        while j < len(s):
            c = s[j]
            if in_block:
                if c == '*' and s[j + 1:j + 2] == '/': in_block = False; j += 1
                j += 1; continue
            if in_str:
                if c == '\\' and j + 1 < len(s): out.append('_'); j += 2; continue
                if c == '"': in_str = False; out.append('"')
                else: out.append('_')
                j += 1; continue
            if c == '"': in_str = True; out.append('"'); j += 1; continue
            if c == '/' and s[j + 1:j + 2] == '/': break
            if c == '/' and s[j + 1:j + 2] == '*': in_block = True; j += 2; continue
            out.append(c); j += 1
        res.append(''.join(out))
    return res


def seg(s):
    s = s.strip().upper()
    return (s + '____')[:4] if len(s) < 4 else s


def resolve(scope, name):
    name = name.strip()
    segs = []
    if name.startswith('\\'):
        name = name[1:]
    else:
        if len(scope) > 1: segs = scope[1:].split('.')
        while name.startswith('^'):
            if segs: segs.pop()
            name = name[1:]
    segs += [seg(x) for x in name.split('.') if x.strip()]
    return '\\' + '.'.join(segs)


class Block:
    __slots__ = ('header', 'open', 'close', 'parent', 'kind', 'name', 'path', 'code', 'in_method', 'in_cond')

    def __init__(self):
        self.header = -1; self.open = 0; self.close = -1; self.parent = -1
        self.kind = ''; self.name = ''; self.path = '\\'; self.code = ''; self.in_method = False; self.in_cond = False


class AslDoc:
    def __init__(self, lines):
        self.lines = lines
        self.code = strip_code(lines)
        self.blocks = []
        st, last_sig = [], -1
        for i, c in enumerate(self.code):
            for j, ch in enumerate(c):
                if ch == '{':
                    b = Block(); b.open = i
                    b.header = i if c[:j].strip() else last_sig
                    b.parent = st[-1] if st else -1
                    b.code = self.code[b.header].strip() if b.header >= 0 else ''
                    self.blocks.append(b); st.append(len(self.blocks) - 1)
                elif ch == '}':
                    if st: self.blocks[st.pop()].close = i
            t = c.strip()
            if t and t != '{' and not t.startswith('}'): last_sig = i
        self.kids = [[] for _ in self.blocks]
        self.by_key = {}
        for i, b in enumerate(self.blocks):
            m = HEAD.match(b.code)
            if m: b.kind = m.group(1)
            p = self.blocks[b.parent] if b.parent >= 0 else None
            scope = p.path if p else '\\'
            if p:
                self.kids[b.parent].append(i)
                b.in_method = p.in_method or p.kind == 'Method'
                b.in_cond = p.in_cond or p.kind in COND_KINDS
            if b.kind in NS_KINDS and m and m.group(2) is not None:
                a = m.group(2)
                k = min([x for x in (a.find(','), a.find(')')) if x >= 0], default=-1)
                b.name = (a[:k] if k >= 0 else a).strip()
                b.path = resolve(scope, b.name)
            else:
                b.path = scope
            self.by_key.setdefault(b.kind + '|' + b.path, []).append(i)

    def find(self, kind, path): return self.by_key.get(kind + '|' + path, [])

    def next_code_line(self, frm):
        for i in range(frm, len(self.code)):
            if self.code[i].strip(): return i
        return -1

    def forward_scopes(self):
        cond, uncond = set(), set()
        for b in self.blocks:
            if b.in_method: continue
            if b.kind in ('Device', 'Processor', 'ThermalZone', 'PowerResource'):
                (cond if b.in_cond else uncond).add(b.path)
        wrap, wrapped = [], set()
        for i, b in enumerate(self.blocks):
            if b.kind != 'Scope' or b.in_method or b.in_cond or b.path == '\\': continue
            p, inside = b.parent, False
            while p >= 0:
                if p in wrapped: inside = True; break
                p = self.blocks[p].parent
            if inside: continue
            segs = b.path[1:].split('.')
            pre = ''
            for k, s in enumerate(segs):
                pre = '\\' + s if k == 0 else pre + '.' + s
                if pre in cond and pre not in uncond:
                    wrap.append(i); wrapped.add(i); break
        return wrap

    def method_local_externals(self):
        methods = {b.path for b in self.blocks if b.kind == 'Method'}
        ext = re.compile(r'^\s*External\s*\(\s*([\\^A-Za-z0-9_.]+)')
        r = []
        for i, c in enumerate(self.code):
            m = ext.match(c)
            if not m: continue
            p = resolve('\\', m.group(1))
            dot = p.rfind('.')
            while dot > 0:
                p = p[:dot]
                if p in methods: r.append(i); break
                dot = p.rfind('.')
        return r


# ---------------------------------------------------------------------------------------------------- helpers
def run(argv, cwd=None):
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def linux_topology():
    """[(logical cpu, apic id, core type)] from /proc/cpuinfo + /sys (type 0x40 = P-core, 0x20 = E/LP E-core)."""
    apic = {}
    cur = None
    for line in open('/proc/cpuinfo'):
        k, _, v = line.partition(':')
        k = k.strip()
        if k == 'processor': cur = int(v)
        elif k == 'apicid' and cur is not None: apic[cur] = int(v)
    def cpus(path):
        try: s = open(path).read().strip()
        except OSError: return set()
        out = set()
        for part in s.split(','):
            a, _, b = part.partition('-')
            out.update(range(int(a), int(b or a) + 1))
        return out
    core = cpus('/sys/devices/cpu_core/cpus')
    atom = cpus('/sys/devices/cpu_atom/cpus')
    return [(c, apic[c], 0x40 if c in core else 0x20 if c in atom else 0) for c in sorted(apic)]


def usb_port_counts(xhci_bdf):
    """(usb2 ports, usb3 ports) of the root hubs of one xHCI controller, from sysfs."""
    u2 = u3 = None
    for hub in glob.glob(f'/sys/bus/pci/devices/{xhci_bdf}/usb*'):
        try:
            n = int(open(hub + '/maxchild').read())
            speed = open(hub + '/speed').read().strip()
        except OSError:
            continue
        if speed in ('480', '12', '1.5'): u2 = n
        else: u3 = n
    return u2, u3


# ---------------------------------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--input-dir', help='folder with acpidump -b output (dsdt.dat, apic.dat ...); default: dump now')
    ap.add_argument('--out', default='acpi-out', help='output folder (default ./acpi-out)')
    ap.add_argument('--efi', help='EFI folder (containing OC/config.plist): copy the tables in and enable them')
    ap.add_argument('--bsp-apic-id', type=int, default=-1, help='APIC ID of the boot CPU (default: Linux CPU 0)')
    ap.add_argument('--pu2c', type=int, default=-1); ap.add_argument('--pu3c', type=int, default=-1)
    ap.add_argument('--max-bus', type=int, default=-1, help=f'highest PCI bus in the static _CRS (default {hx(SHIPPED_MAX_BUS)})')
    ap.add_argument('--touchpad-i2c', help='I2C controller number(s) with the touchpad, e.g. 0 (default: from Linux sysfs)')
    ap.add_argument('--force', action='store_true', help='continue on tables that look patched / compile warnings')
    a = ap.parse_args()

    out = os.path.abspath(a.out)
    work, dump = os.path.join(out, 'work'), os.path.join(out, 'dump')
    os.makedirs(work, exist_ok=True); os.makedirs(dump, exist_ok=True)
    iasl = shutil.which('iasl') or fail('iasl not found (Arch: pacman -S acpica; Debian: apt install acpica-tools)')
    print(f'make_acpi_tables {VERSION}')

    # ------------------------------------------------------------------------------------------ 1. tables
    step('ACPI tables')
    src = a.input_dir
    if not src:
        if os.geteuid() != 0: fail('run as root to dump the tables (or pass --input-dir)')
        shutil.which('acpidump') or fail('acpidump not found (acpica)')
        src = dump
        code, txt = run(['acpidump', '-b'], cwd=dump)
        if code: fail('acpidump -b failed: ' + txt)
        facts.append('Tables: acpidump -b on the running firmware')
    else:
        facts.append('Tables: from --input-dir')
    dsdt = apic = None
    for f in sorted(glob.glob(os.path.join(src, '*'))):
        if not f.lower().endswith(('.dat', '.aml', '.bin')): continue
        b = open(f, 'rb').read()
        if b[:4] == b'DSDT' and dsdt is None: dsdt = b; say('DSDT <- ' + os.path.basename(f))
        elif b[:4] == b'APIC' and apic is None: apic = b; say('APIC <- ' + os.path.basename(f))
    for name, b in (('DSDT', dsdt), ('APIC', apic)):
        if not table_ok(b, name): fail(f'no valid {name} table (missing, wrong length or bad checksum)')
        say(describe(b)); facts.append(f'{name}: ' + describe(b))

    # parse the MADT
    enabled, copy, types, nmi = [], [], {}, None
    o = 44
    while o + 2 <= len(apic):
        t, l = apic[o], apic[o + 1]
        if l < 2 or o + l > len(apic): fail(f'MADT entry at offset {o} is malformed')
        e = apic[o:o + l]
        types[t] = types.get(t, 0) + 1
        if t == 0:
            if e[4] & 1: enabled.append(e[3])
        elif t == 9:
            if struct.unpack_from('<I', e, 8)[0] & 1: enabled.append(struct.unpack_from('<I', e, 4)[0])
        elif t in (1, 2, 3, 5): copy.append(bytes(e))
        elif t == 4:
            if nmi is None: nmi = dict(flags=struct.unpack_from('<H', e, 3)[0], lint=e[5], all=e[2] == 0xFF)
        elif t == 10:
            if nmi is None: nmi = dict(flags=struct.unpack_from('<H', e, 2)[0], lint=e[8], all=struct.unpack_from('<I', e, 4)[0] == 0xFFFFFFFF)
        else: warn(f'MADT entry type {t} (length {l}) is not carried over')
        o += l
    tl = ', '.join(f'type {k} x{v}' for k, v in sorted(types.items()))
    say(f'MADT entries: {tl}; enabled CPUs: {len(enabled)} (APIC IDs {sorted(enabled)})')
    facts.append(f'MADT: {tl}; enabled CPUs {len(enabled)}')
    looks = []
    if 9 not in types and types.get(0) == MADT_SLOTS: looks.append(f'MADT already has {MADT_SLOTS} type 0 entries and no x2APIC')
    for mark in (b'XU2C', b'XU3C'):
        if mark in dsdt: looks.append('DSDT already contains ' + mark.decode())
    if looks:
        msg = 'tables look already patched (' + '; '.join(looks) + '). Booted through OpenCore? Boot Linux from the firmware boot menu.'
        if not a.force: fail(msg)
        warn(msg)

    # ------------------------------------------------------------------------------------------ 2. CPU topology
    step('Boot CPU and core types')
    topo = linux_topology() if not a.input_dir or a.bsp_apic_id < 0 else []
    type_of = {}
    if topo and sorted(x[1] for x in topo) == sorted(enabled):
        for _, ap_id, ty in topo: type_of[ap_id] = ty
        bsp = topo[0][1] if topo[0][0] == 0 else -1
        bsp_src = 'Linux CPU 0 (/proc/cpuinfo)'; type_src = '/sys/devices/cpu_core, cpu_atom'
    else:
        if topo: warn('the running CPUs do not match this MADT (tables from another machine?); not using them')
        bsp, bsp_src = -1, ''
        for x in enabled: type_of[x] = 0x40 if (x ^ 1) in enabled else 0x20
        type_src = 'SMT pairs in the MADT (guess)'
    if a.bsp_apic_id >= 0: bsp, bsp_src = a.bsp_apic_id, '--bsp-apic-id'
    if bsp < 0: fail('cannot tell the boot CPU: run on the machine itself, or pass --bsp-apic-id')
    if bsp not in enabled: fail(f'APIC ID {bsp} is not an enabled CPU in this MADT')
    if len(enabled) > MADT_SLOTS: fail(f'{len(enabled)} CPUs do not fit {MADT_SLOTS} slots')
    if any(x > 254 for x in enabled): fail('an APIC ID does not fit a type 0 MADT entry')
    if not any(v == 0x40 for v in type_of.values()):
        for x in enabled: type_of[x] = 0x40 if (x ^ 1) in enabled else type_of[x]
    srt = sorted(enabled)
    order = [bsp] + [x for x in srt if x != bsp and (x >> 1) == (bsp >> 1)]
    order += [x for x in srt if x not in order and type_of.get(x) == type_of.get(bsp)]
    order += [x for x in srt if x not in order]
    pcount = sum(1 for x in enabled if type_of.get(x) == 0x40)
    say(f'boot CPU APIC ID {bsp} ({bsp_src})')
    say(f'MADT order (ProcessorId 0..{len(order) - 1}): {order}')
    facts.append(f'Boot CPU APIC {bsp} from {bsp_src}; {pcount} P-core threads, {len(enabled) - pcount} E/LP-E ({type_src})')

    # ------------------------------------------------------------------------------------------ 3. MADT
    step('MADT -> ' + APIC_OUT)
    if nmi is None: nmi = dict(flags=0x000D, lint=1, all=True); warn('no NMI entry in the MADT; using flags 0x000D, LINT1')
    body = bytearray()
    for slot in range(MADT_SLOTS):
        body += bytes((0, 8, slot, order[slot], 1, 0, 0, 0)) if slot < len(order) else bytes((0, 8, slot, 0xFF, 0, 0, 0, 0))
    for e in copy: body += e
    body += bytes((4, 6, 0xFF)) + struct.pack('<H', nmi['flags']) + bytes((nmi['lint'],))
    new_apic = bytearray(apic[:44]) + body
    struct.pack_into('<I', new_apic, 4, len(new_apic))
    set_checksum(new_apic)
    open(os.path.join(out, APIC_OUT), 'wb').write(new_apic)
    say(f'{len(new_apic)} bytes: {MADT_SLOTS} type 0 ({len(order)} enabled), {len(copy)} IOAPIC/override entries, '
        f'1 LAPIC NMI (flags {hx(nmi["flags"], 4)}, LINT{nmi["lint"]})')

    # ------------------------------------------------------------------------------------------ 4. DSDT
    step('DSDT: decompile')
    open(os.path.join(work, 'DSDT.aml'), 'wb').write(dsdt)
    dsl_in = os.path.join(work, 'DSDT.dsl')
    if os.path.exists(dsl_in): os.remove(dsl_in)
    code, txt = run([iasl, '-d', 'DSDT.aml'], cwd=work)
    open(os.path.join(work, 'iasl-decompile.log'), 'w').write(txt)
    if not os.path.exists(dsl_in): fail('iasl -d produced no DSDT.dsl (see work/iasl-decompile.log)')
    lines = open(dsl_in, encoding='latin-1').read().split('\n')
    if lines and lines[-1] == '': lines.pop()
    doc = AslDoc(lines)
    B = doc.blocks
    say(f'{len(lines)} lines, {len(B)} blocks')

    dele = [False] * len(lines)
    before, after = {}, {}
    def add_before(i, text): before.setdefault(i, []).extend(text)
    def add_after(i, text): after.setdefault(i, []).extend(text)
    def remove_block(bi):
        for i in range(B[bi].header, B[bi].close + 1): dele[i] = True
    def set_line(i, text): lines[i] = text; doc.code[i] = strip_code([text])[0]
    def indent(i): return re.match(r'^\s*', lines[i]).group(0)
    def get_one(kind, path):
        f = doc.find(kind, path)
        return f[0] if len(f) == 1 else -1
    def child_of(parent, kind, name): return [k for k in doc.kids[parent] if B[k].kind == kind and seg(B[k].name) == name]
    def lines_matching(bi, pat):
        rx = re.compile(pat)
        return [i for i in range(B[bi].open, B[bi].close + 1) if not dele[i] and rx.search(doc.code[i])]

    step('DSDT: changes')
    # C1
    bad = doc.method_local_externals()
    root_ext = {}
    for i in bad:
        dele[i] = True
        m = re.search(r'External\s*\(\s*([\\^A-Za-z0-9_.]+)\s*(,\s*(\w+))?', doc.code[i])
        leaf = m.group(1).split('.')[-1]
        if not doc.find('Method', '\\' + seg(leaf)): root_ext[leaf] = m.group(3) or 'UnknownObj'
    if root_ext: add_after(bad[-1], [f'    External (\\{k}, {v}) // replaces method-local External()s' for k, v in root_ext.items()])
    change('C1', 'compile fix', 'applied' if bad else 'none',
           f'replaced {len(bad)} method-local External() by root External() for {", ".join(root_ext)}' if bad else 'no method-local External()')

    # C2
    fwd = doc.forward_scopes()
    for bi in fwd:
        ind = indent(B[bi].header)
        add_before(B[bi].header, [f'{ind}If (One) // deferred: target defined in a module-level If', f'{ind}{{'])
        add_after(B[bi].close, [f'{ind}}}'])
    change('C2', 'deferred forward Scopes', 'applied' if fwd else 'none',
           f'wrapped {len(fwd)} in If (One): ' + ', '.join(B[x].path for x in fwd) if fwd else 'none needed')

    # C3
    pchs, elses = [], 0
    for bi, b in enumerate(B):
        if b.kind != 'If' or not re.match(r'^If \(\(PCHS != (0x04|PCHX)\)\)$', b.code): continue
        pchs.append(bi)
        dele[b.header] = dele[b.open] = dele[b.close] = True
        n = doc.next_code_line(b.close + 1)
        while n >= 0 and re.match(r'^Else(If)?\b', doc.code[n].strip()):
            eb = [k for k in (doc.kids[b.parent] if b.parent >= 0 else range(len(B))) if B[k].header == n]
            if len(eb) != 1: break
            remove_block(eb[0]); elses += 1
            n = doc.next_code_line(B[eb[0]].close + 1)
    ml = sum(1 for x in pchs if not B[x].in_method)
    change('C3', 'PCHS guards', 'applied' if pchs else 'not found',
           f'unwrapped {len(pchs)} If ((PCHS != 0x04)) ({ml} module-level)' + (f', dropped {elses} Else' if elses else ''))

    # C4
    deps = 0
    for bi, b in enumerate(B):
        if b.code.startswith('Name (_DEP,'): remove_block(bi); deps += 1
    for i in range(len(lines)):
        if not dele[i] and re.match(r'^\s*Name \(_DEP,.*\)\s*$', doc.code[i]): dele[i] = True; deps += 1
    change('C4', '_DEP removed', 'applied' if deps else 'none', f'removed {deps}')

    # C5
    pc00 = get_one('Device', '\\_SB_.PC00')
    crs = child_of(pc00, 'Method', '_CRS') if pc00 >= 0 else []
    bus_max = a.max_bus if a.max_bus >= 0 else SHIPPED_MAX_BUS
    if len(crs) == 1:
        ecam = (bus_max + 2) * 0x100000          # firmware: PBMX = (GPCL () >> 20) - 2
        g = lines_matching(crs[0], r'GPCL \(\)')
        for i in g: set_line(i, lines[i].replace('GPCL ()', f'{hx(ecam, 8)} /* static (was GPCL ()): bus 0..{hx(bus_max)} */'))
        mc = [k for k in doc.kids[crs[0]] if B[k].kind == 'If' and re.search(r'\^MC\.', B[k].code)]
        for k in mc: remove_block(k)
        left = lines_matching(crs[0], r'\^MC\.|GPCL|DVID|PCI_Config')
        det = f'GPCL () -> {hx(ecam, 8)} (bus 0..{hx(bus_max)}) in {len(g)} place(s); removed {len(mc)} If (^MC.xxx)'
        change('C5', 'static PC00._CRS', 'partial' if left else 'applied' if g or mc else 'none',
               det + (f'; still reads PCI config at lines {[x + 1 for x in left]}' if left else ''))
    else:
        change('C5', 'static PC00._CRS', 'not found', f'PC00 {pc00 >= 0}, _CRS {len(crs)}')

    # C6
    xhci = get_one('Device', '\\_SB_.PC00.XHCI')
    xhci_adr = -1
    if xhci >= 0:
        ad = lines_matching(xhci, r'^\s*Name \(_ADR, (0x[0-9A-Fa-f]+|Zero)\)')
        if ad:
            v = re.search(r'Name \(_ADR, (0x[0-9A-Fa-f]+|Zero)\)', doc.code[ad[0]]).group(1)
            xhci_adr = 0 if v == 'Zero' else int(v, 16)
        targets = [(f'XHCI.{nm}', k) for nm in ('_PS0', '_PS3') for k in child_of(xhci, 'Method', nm)]
        rhub = child_of(xhci, 'Device', 'RHUB')
        if len(rhub) == 1: targets += [(f'XHCI.RHUB.{nm}', k) for nm in ('_PS0', '_PS2', '_PS3') for k in child_of(rhub[0], 'Method', nm)]
        done, odd = [], []
        for label, k in targets:
            hits = lines_matching(k, r'^\s*If \(\(DVID == 0xFFFF\)\)\s*$')
            if len(hits) == 1:
                set_line(hits[0], lines[hits[0]].replace('If ((DVID == 0xFFFF))', 'If (Zero) // was: If ((DVID == 0xFFFF)), a PCI_Config read that fails on macOS'))
                done.append(label)
            else: odd.append(f'{label} ({len(hits)})')
        change('C6', 'XHCI _PSx DVID check', 'applied' if done else 'not found', 'skipped in ' + ', '.join(done) + (f'; unchanged: {odd}' if odd else ''))
    else:
        change('C6', 'XHCI _PSx DVID check', 'not found', 'PC00.XHCI not found exactly once')

    # root-level Field entries -> Names
    root_fields = [bi for bi, b in enumerate(B) if b.kind == 'Field' and b.path == '\\' and not b.in_method and not b.in_cond]
    def find_field_entry(name):
        for fb in root_fields:
            h = lines_matching(fb, rf'^\s*{name}\s*,')
            if len(h) == 1: return fb, h[0]
        return None
    def set_field_name(entry, name, value, why):
        fb, li = entry
        set_line(li, re.sub(rf'^(\s*){name}(\s*,)', r'\1\2', lines[li]) + f' // was {name}, now a Name below')
        add_after(B[fb].close, [f'    Name ({name}, {value}) // {why}'])

    # C7
    usr = 0; lad2 = lad3 = 0
    if xhci >= 0:
        usr = sum(1 for b in B if b.kind == 'Device' and b.path.startswith('\\_SB_.PC00.XHCI.') and re.search(r'\.USR\d$', b.path))
        for i in range(B[xhci].open, B[xhci].close + 1):
            m = re.search(r'If \(\((One|0x[0-9A-F]+) <= PU([23])C\)\)', doc.code[i])
            if m:
                v = 1 if m.group(1) == 'One' else int(m.group(1), 16)
                if m.group(2) == '2': lad2 = max(lad2, v)
                else: lad3 = max(lad3, v)
    pu2 = pu3 = -1; pu_src = ''
    if xhci_adr >= 0 and not a.input_dir:
        bdf = f'0000:00:{xhci_adr >> 16:02x}.{xhci_adr & 0xFFFF:x}'
        u2, u3 = usb_port_counts(bdf)
        if u2 is not None and u3 is not None:
            pu2, pu3 = u2 - usr, u3
            pu_src = f'Linux sysfs ({bdf}: {u2} USB2 ports - {usr} USR, {u3} USB3 ports)'
            say(pu_src)
    if a.pu2c >= 0: pu2, pu_src = a.pu2c, '--pu2c/--pu3c'
    if a.pu3c >= 0: pu3, pu_src = a.pu3c, '--pu2c/--pu3c'
    if pu2 < 0 or pu3 < 0:
        pu2 = 10 if pu2 < 0 else pu2; pu3 = 2 if pu3 < 0 else pu3
        pu_src = 'NOT MEASURED: ThinkBook values'
        warn('could not count the xHCI ports; used PU2C/PU3C = 10/2. Check with lsusb -t, or pass --pu2c/--pu3c')
    if lad2 and pu2 > lad2: warn(f'PU2C {pu2} > what the DSDT can create ({lad2}); using {lad2}'); pu2 = lad2
    if lad3 and pu3 > lad3: warn(f'PU3C {pu3} > what the DSDT can create ({lad3}); using {lad3}'); pu3 = lad3
    if xhci >= 0:
        locs = []
        for nm in ('PU2C', 'PU3C'):
            h = lines_matching(xhci, rf'^\s*Name \({nm}, Zero\)\s*$')
            if len(h) == 1: locs.append((nm, h[0]))
        e2, e3 = find_field_entry('PU2C'), find_field_entry('PU3C')
        if e2 and e3 and len(locs) == 2:
            set_field_name(e2, 'PU2C', hx(pu2), 'USB2 ports of PC00.XHCI.RHUB (macOS never runs the copy from PCH NVS)')
            set_field_name(e3, 'PU3C', hx(pu3), 'USB3 ports of PC00.XHCI.RHUB')
            for nm, li in locs:
                set_line(li, lines[li].replace(f'Name ({nm}, Zero)', f'Name (X{nm[1:]}, Zero) // was {nm}: XHCI now uses the root value'))
            change('C7', 'PU2C / PU3C', 'applied', f'PU2C = {pu2}, PU3C = {pu3} ({pu_src}); XHCI-local renamed XU2C/XU3C')
        else:
            change('C7', 'PU2C / PU3C', 'not found', f'root Field PU2C {bool(e2)}, PU3C {bool(e3)}; local Names {len(locs)}/2')
    facts.append(f'USB: PC00.XHCI _ADR {hx(xhci_adr, 8) if xhci_adr >= 0 else "?"}; PU2C={pu2}, PU3C={pu3} from {pu_src}; DSDT ladder {lad2}/{lad3}')

    # C8
    tp = set()
    for b in B:
        if b.kind not in ('Device', 'Scope'): continue
        m = re.search(r'\.I2C(\d)(\.|$)', b.path)
        if not m: continue
        if any('"PNP0C50"' in lines[i] for i in range(b.open, b.close + 1)): tp.add(m.group(1))
    live = set()
    if not a.input_dir:     # the firmware declares a TPD0 under every I2Cn; keep the ones Linux actually bound
        for p in glob.glob('/sys/bus/i2c/devices/i2c-*/firmware_node/path'):
            mm = re.search(r'\.I2C(\d)\.', open(p).read())
            if mm: live.add(mm.group(1))
    if a.touchpad_i2c: live = set(a.touchpad_i2c.split(','))
    if live and tp & live:
        say(f'HID-over-I2C devices declared on I2C{sorted(tp)}, present on I2C{sorted(live)}: using {sorted(tp & live)}')
        tp &= live
    if tp:
        ok, miss = [], []
        for n in sorted(tp):
            fe = find_field_entry(f'IM0{n}')
            if fe: set_field_name(fe, f'IM0{n}', 'One', f'I2C{n} in PCI mode, so its _PS0/_PS3/_DSM exist (HID-over-I2C touchpad)'); ok.append(f'IM0{n}')
            else: miss.append(f'IM0{n}')
        change('C8', 'I2C touchpad mode', 'applied' if ok else 'not found', f'{ok} = One' + (f'; no root Field for {miss}' if miss else ''))
    else:
        change('C8', 'I2C touchpad mode', 'not found', 'no PNP0C50 under an I2Cn controller')

    # C9
    os_done = ''
    for bi, b in enumerate(B):
        if b.kind != 'Method' or not b.path.endswith('._INI'): continue
        h = lines_matching(bi, r'^\s*OSYS = 0x03E8\s*$')
        if h:
            set_line(h[0], lines[h[0]].replace('OSYS = 0x03E8', 'OSYS = 0x07E5 // was 0x03E8: macOS answers no to _OSI ("Windows ...")'))
            os_done = b.path; break
    change('C9', 'OSYS default', 'applied' if os_done else 'not found', f'{os_done}: 0x03E8 -> 0x07E5' if os_done else 'no OSYS = 0x03E8 in _INI')

    # C10
    ps2 = []
    for bi, b in enumerate(B):
        if b.kind == 'Device' and b.path.endswith('.PS2K') and not b.in_method:
            sta = child_of(bi, 'Method', '_STA')
            if len(sta) == 1:
                hl = B[sta[0]].header
                set_line(hl, lines[hl].replace('Method (_STA,', 'Method (XSTA,')); ps2.append(b.path)
    change('C10', 'PS2K _STA -> XSTA', 'applied' if ps2 else 'not found',
           ', '.join(ps2) + ('' if '\\_SB_.PC00.LPCB.PS2K' in ps2 else ' -- NOT at \\_SB.PC00.LPCB.PS2K: disable SSDT-PS2VIS') if ps2 else 'disable SSDT-PS2VIS')

    # checks for this EFI's own SSDTs
    if not doc.find('Device', '\\_SB_.PC00.LPCB'): warn('\\_SB.PC00.LPCB missing: SSDT-EC / SSDT-PS2VIS will not load')
    if doc.find('Device', '\\_SB_.PC00.LPCB.EC__'): warn('\\_SB.PC00.LPCB.EC already exists: disable SSDT-EC')
    if doc.find('Device', '\\_SB_.USBX'): warn('\\_SB.USBX already exists: disable SSDT-USBX')
    if any(b.kind in ('Processor', 'Device') and re.match(r'^\\_SB_\.C0[0-2][0-9A-F]$', b.path) for b in B):
        warn('\\_SB.C000..C02F already defined: SSDT-PLUG-ALT will fail')
    if not doc.find('Device', '\\_SB_.PC00.GFX0'): warn('\\_SB.PC00.GFX0 missing: SSDT-PNLF will not load')

    # ------------------------------------------------------------------------------------------ 5. compile
    step('DSDT: compile -> ' + DSDT_OUT)
    out_lines = []
    for i in range(len(lines)):
        out_lines += before.get(i, [])
        if not dele[i]: out_lines.append(lines[i])
        out_lines += after.get(i, [])
    applied = [c[0] for c in changes if c[2] in ('applied', 'partial')]
    hdr = ['/*', f' * Patched by tools/make_acpi_tables.py {VERSION} for macOS. Changes: {", ".join(applied)}; see report.txt.', ' */']
    dsl_out = os.path.join(work, 'DSDT-patched.dsl')
    open(dsl_out, 'w', encoding='latin-1').write('\n'.join(hdr + out_lines) + '\n')
    prefix = os.path.join(work, 'DSDT-patched')
    if os.path.exists(prefix + '.aml'): os.remove(prefix + '.aml')
    code, txt = run([iasl, '-vr', '-p', prefix] + (['-f'] if a.force else []) + [dsl_out], cwd=work)
    open(os.path.join(work, 'iasl-compile.log'), 'w').write(txt)
    m = re.search(r'Compilation (complete|successful|failed)\.\s+(\d+) Errors?, (\d+) Warnings?', txt)
    errs, warns_ = (int(m.group(2)), int(m.group(3))) if m else (-1, -1)
    say(f'iasl: {errs} errors, {warns_} warnings (work/iasl-compile.log)')
    for l in [l for l in txt.splitlines() if re.match(r'^Error\s+\d+', l)][:8]: say('  ' + l)
    facts.append(f'iasl compile: {errs} errors, {warns_} warnings')
    if not os.path.exists(prefix + '.aml') or (errs != 0 and not a.force):
        fail('the patched DSDT did not compile cleanly (see work/iasl-compile.log)')
    new_dsdt = open(prefix + '.aml', 'rb').read()
    if not table_ok(new_dsdt, 'DSDT'): fail('compiled DSDT has a bad header or checksum')
    open(os.path.join(out, DSDT_OUT), 'wb').write(new_dsdt)
    say(describe(new_dsdt))

    # read back
    rt = os.path.join(work, 'roundtrip'); os.makedirs(rt, exist_ok=True)
    shutil.copyfile(os.path.join(out, DSDT_OUT), os.path.join(rt, 'DSDT.aml'))
    if os.path.exists(os.path.join(rt, 'DSDT.dsl')): os.remove(os.path.join(rt, 'DSDT.dsl'))
    run([iasl, '-d', 'DSDT.aml'], cwd=rt)
    if os.path.exists(os.path.join(rt, 'DSDT.dsl')):
        t = open(os.path.join(rt, 'DSDT.dsl'), encoding='latin-1').read()
        rb = (f'PCHS guards left {len(re.findall(r"If [(][(]PCHS != 0x04[)][)]", t))} | If (One) {t.count("If (One)")} '
              f'(C2 added {len(fwd)}) | _DEP {t.count("Name (_DEP,")} | XU2C/XU3C {len(re.findall(r"Name [(]XU[23]C", t))} | '
              f'XSTA {t.count("Method (XSTA")}')
        say('read back: ' + rb); facts.append('Read back: ' + rb)

    # ------------------------------------------------------------------------------------------ 6. EFI
    if a.efi:
        step('EFI: ' + a.efi)
        cfgp = next((p for p in (os.path.join(a.efi, 'OC', 'config.plist'), os.path.join(a.efi, 'EFI', 'OC', 'config.plist')) if os.path.exists(p)), None)
        if not cfgp: fail('no OC/config.plist under ' + a.efi)
        cfg = plistlib.load(open(cfgp, 'rb'))
        n_add = n_del = 0
        for e in cfg['ACPI']['Add']:
            if e.get('Path') in (DSDT_OUT, APIC_OUT): e['Enabled'] = True; n_add += 1
        for e in cfg['ACPI']['Delete']:
            if e.get('TableSignature') == b'APIC':
                e.update(OemTableId=apic[16:24], TableLength=len(apic), All=False, Enabled=True,
                         Comment=f'Replace the native MADT (OEM Table ID "{apic[16:24].decode(errors="replace")}", {len(apic)} bytes), set by make_acpi_tables.py')
                n_del += 1
        if n_add != 2 or n_del != 1: fail(f'config.plist: expected ACPI/Add {DSDT_OUT} + {APIC_OUT} and one ACPI/Delete APIC; found {n_add} / {n_del}. Nothing changed.')
        bak = os.path.join(out, 'efi-backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
        os.makedirs(bak)
        shutil.copyfile(cfgp, os.path.join(bak, 'config.plist'))
        acpi_dir = os.path.join(os.path.dirname(cfgp), 'ACPI')
        for f in (DSDT_OUT, APIC_OUT):
            dst = os.path.join(acpi_dir, f)
            if os.path.exists(dst): shutil.copyfile(dst, os.path.join(bak, f))
            shutil.copyfile(os.path.join(out, f), dst)
        plistlib.dump(cfg, open(cfgp, 'wb'))
        say(f'copied {DSDT_OUT} and {APIC_OUT} to {acpi_dir}; ACPI/Add enabled; ACPI/Delete APIC = "{apic[16:24].decode(errors="replace")}", {len(apic)} bytes')
        say('previous config.plist saved in ' + bak)

    # ------------------------------------------------------------------------------------------ 7. report
    rep = [f'make_acpi_tables {VERSION} report, {datetime.datetime.now():%Y-%m-%d %H:%M}', '(no serials or table contents)', '']
    rep += facts + [''] + [f'{c[0]:<4} {c[1]}: {c[2]} - {c[3]}' for c in changes]
    rep += [''] + ['WARNING: ' + w for w in warnings]
    open(os.path.join(out, 'report.txt'), 'w').write('\n'.join(rep) + '\n')
    step('done')
    say(f'{out}/{DSDT_OUT}, {out}/{APIC_OUT}, report.txt')
    say('out/dump and out/work hold firmware code: keep them to yourself')
    if warnings: say(f'{len(warnings)} warning(s), see report.txt')


if __name__ == '__main__':
    main()
