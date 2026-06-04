import os

# Load hex files
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
print('Loaded', len(mem_a), len(mem_b), len(mem_exp), 'vectors')

# Python model of our Verilog fp8_to_scaled
def fp8_to_scaled(v):
    v = v & 0xFF
    exp_field = (v >> 3) & 0xF
    man_field = v & 0x7
    if exp_field == 0:
        result = man_field
    else:
        result = (8 + man_field) << (exp_field - 1)
    if v & 0x80:
        result = -result
    return result

# Python model of our fast_log2 (highest set bit position)
def fast_log2(v):
    v = v & 0x3FFFF  # 18-bit
    if v == 0:
        return 0
    return v.bit_length() - 1

# Python model of our fp8_from_sum
def fp8_from_sum(sum_scaled):
    if sum_scaled == 0:
        return 0
    if sum_scaled < 0:
        sign_bit = 1
        abs_scaled = -sum_scaled
    else:
        sign_bit = 0
        abs_scaled = sum_scaled
    sb = 0x80 if sign_bit else 0x00
    if abs_scaled > 229376:
        return sb | 0x7E
    elif abs_scaled < 8:
        return sb | (abs_scaled & 0xFF)
    else:
        exp_biased = fast_log2(abs_scaled & 0x3FFFF) - 2
        shift = exp_biased - 1
        base = abs_scaled >> shift
        if shift > 0:
            rem  = abs_scaled - (base << shift)
            half = 1 << (shift - 1)
            if rem > half:
                base += 1
            elif rem == half and (base & 1):
                base += 1
        if base >= 16:
            base = 8
            exp_biased += 1
        if exp_biased > 15:
            return sb | 0x7E
        elif exp_biased == 15 and base == 15:
            return sb | 0x7E
        else:
            return sb | ((exp_biased & 0xF) << 3) | ((base - 8) & 7)

def our_adder(a, b):
    a_nan = (a & 0x7F) == 0x7F
    b_nan = (b & 0x7F) == 0x7F
    if a_nan or b_nan:
        return 0x7F
    if (a & 0x7F) == 0 and (b & 0x7F) == 0:
        if (a & 0x80) and (b & 0x80):
            return 0x80
        return 0x00
    s = fp8_to_scaled(a) + fp8_to_scaled(b)
    return fp8_from_sum(s)

# Count failures
fails = 0
fail_samples = []
neg_sum_fails = 0
pos_sum_fails = 0
for i in range(len(mem_a)):
    a, b = mem_a[i], mem_b[i]
    got = our_adder(a, b)
    exp = mem_exp[i]
    nan_match = ((got & 0x7F) == 0x7F) and ((exp & 0x7F) == 0x7F)
    if got != exp and not nan_match:
        fails += 1
        s = fp8_to_scaled(a) + fp8_to_scaled(b)
        if s < 0:
            neg_sum_fails += 1
        else:
            pos_sum_fails += 1
        if len(fail_samples) < 30:
            fail_samples.append((i, a, b, exp, got, s))

print('Failures:', fails, '/ 4096')
print('  neg sum fails:', neg_sum_fails)
print('  pos sum fails:', pos_sum_fails)
print()
print('First 30 failures:')
for idx,a,b,e,g,s in fail_samples:
    print(f'  [{idx:4d}] a=0x{a:02X} b=0x{b:02X} exp=0x{e:02X} got=0x{g:02X}  sum={s:8d}  a_s={fp8_to_scaled(a):8d} b_s={fp8_to_scaled(b):8d}')
