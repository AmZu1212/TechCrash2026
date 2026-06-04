"""Verify write_adder3.py logic against test vectors before compiling."""
import os

def load_hex(path):
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('//') and not line.startswith('@'):
                for tok in line.split():
                    vals.append(int(tok, 16))
    return vals

base = r'c:\Users\Administrator\Desktop\Hackathon 2026\Our Fork\TechCrash2026\challenge_submissions\fp8_adder\fpga\mem'
mem_a   = load_hex(os.path.join(base,'mem_a.hex'))
mem_b   = load_hex(os.path.join(base,'mem_b.hex'))
mem_exp = load_hex(os.path.join(base,'mem_expected.hex'))

def fast_log2(v):
    v = v & 0x3FFFF
    if v == 0:
        return 0
    return v.bit_length() - 1

def fp8_to_mag(fp):
    fp = fp & 0xFF
    exp_f = (fp >> 3) & 0xF
    man_f = fp & 0x7
    if exp_f == 0:
        mag = man_f
    else:
        mag = (8 + man_f) << (exp_f - 1)
    sign = (fp >> 7) & 1
    return (sign, mag)  # sign, unsigned magnitude

def signed_sum(a_neg, a_mag, b_neg, b_mag):
    if a_neg == b_neg:
        return a_neg, a_mag + b_mag
    else:
        if a_mag >= b_mag:
            return a_neg, a_mag - b_mag
        else:
            return b_neg, b_mag - a_mag

def fp8_encode(neg, mag):
    if mag == 0:
        return 0x00
    if mag > 229376:
        return (0x80 if neg else 0x00) | 0x7E
    if mag < 8:
        return (0x80 if neg else 0x00) | (mag & 0xFF)
    eb = fast_log2(mag & 0x3FFFF) - 2
    sh = eb - 1
    ba = mag >> sh
    if sh > 0:
        rm = mag - (ba << sh)
        hf = 1 << (sh - 1)
        if rm > hf:
            ba += 1
        elif rm == hf and (ba & 1):
            ba += 1
    if ba >= 16:
        ba = 8
        eb += 1
    if eb > 15:
        return (0x80 if neg else 0x00) | 0x7E
    if eb == 15 and (ba & 0xF) == 15:
        return (0x80 if neg else 0x00) | 0x7E
    # ba in [8,15], ba[2:0] = mantissa
    return (0x80 if neg else 0x00) | ((eb & 0xF) << 3) | (ba & 0x7)

def our_adder(a, b):
    a_nan = (a & 0x7F) == 0x7F
    b_nan = (b & 0x7F) == 0x7F
    if a_nan or b_nan:
        return 0x7F
    if (a & 0x7F) == 0 and (b & 0x7F) == 0:
        if (a & 0x80) and (b & 0x80):
            return 0x80
        return 0x00
    a_neg, a_mag = fp8_to_mag(a)
    b_neg, b_mag = fp8_to_mag(b)
    neg, mag = signed_sum(a_neg, a_mag, b_neg, b_mag)
    return fp8_encode(neg, mag)

fails = 0
for i in range(len(mem_a)):
    got = our_adder(mem_a[i], mem_b[i])
    exp = mem_exp[i]
    nan_match = ((got & 0x7F) == 0x7F) and ((exp & 0x7F) == 0x7F)
    if got != exp and not nan_match:
        fails += 1
        if fails <= 5:
            print(f'[{i:4d}] a=0x{mem_a[i]:02X} b=0x{mem_b[i]:02X} exp=0x{exp:02X} got=0x{got:02X}')

print(f'Failures: {fails} / {len(mem_a)}')
