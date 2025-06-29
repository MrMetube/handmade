// Translated from C to Odin. The original C code can be found at
// https://github.com/ulfjack/ryu and carries the following license:
//
// Copyright 2018 Ulf Adams
//
// The contents of this file may be used under the terms of the Apache License,
// Version 2.0.
//
//    (Found at the end of this file or copy at http://www.apache.org/licenses/LICENSE-2.0)
//
// Alternatively, the contents of this file may be used under the terms of
// the Boost Software License, Version 1.0.
//
//    (Found at the end of this file or copy at https://www.boost.org/LICENSE_1_0.txt)
//
// Unless required by applicable law or agreed to in writing, this software
// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.

//  @note(viktor): The major modifications are:
// - the removal of the RYU_32_BIT_PLATFORM define and any of the 32-bit specific code
// - the removal of the HAS_UINT128 define
// - the removal of the HAS_64_BIT_INTRINSICS
// - the removal of the ryu_generic code
// - the removal of the RYU_DEBUG define and any debug prints
package game

@(common="file")

import "base:intrinsics"

RYU_FLOAT_FULL_TABLE :: #config(RYU_FLOAT_FULL_TABLE, false)
RYU_OPTIMIZE_SIZE    :: #config(RYU_OPTIMIZE_SIZE,    false)

////////////////////////////////////////////////
// f2s_intrinsics.h

when RYU_FLOAT_FULL_TABLE {
    FLOAT_POW5_INV_BITCOUNT :: 59
    FLOAT_POW5_BITCOUNT :: 61
} else {
    FLOAT_POW5_INV_BITCOUNT :: (DOUBLE_POW5_INV_BITCOUNT - 64)
    FLOAT_POW5_BITCOUNT :: (DOUBLE_POW5_BITCOUNT - 64)
}

pow5factor_32 :: proc (value: u32) -> u32 {
    value := value
    count: u32 = 0;
    for {
        assert(value != 0);
        q: u32 = value / 5;
        r: u32 = value % 5;
        if (r != 0) {
            break;
        }
        value = q;
        count += 1;
    }
    return count;
}

// Returns true if value is divisible by 5^p.
multipleOfPowerOf5_32 :: proc (value: u32, p: u32) -> bool {
    return pow5factor_32(value) >= p;
}

// Returns true if value is divisible by 2^p.
multipleOfPowerOf2_32 :: proc (value: u32, p: u32) -> bool {
    // __builtin_ctz doesn't appear to be faster here.
    return (value & ((1 << p) - 1)) == 0;
}

// It seems to be slightly faster to avoid u128 here, although the
// generated code for u128 looks slightly nicer.
mulShift32 :: proc (m: u32, factor: u64, shift: i32) -> u32 {
    assert(shift > 32);
    
    // The casts here help MSVC to avoid calls to the __allmul library
    // function.
    factorLo: u32 = cast(u32)(factor);
    factorHi: u32 = cast(u32)(factor >> 32);
    bits0: u64 = cast(u64)m * cast(u64) factorLo;
    bits1: u64 = cast(u64)m * cast(u64) factorHi;
    
    sum: u64 = (bits0 >> 32) + bits1;
    shiftedSum: u64 = sum >> cast(u32)(shift - 32);
    assert(shiftedSum <= cast(u64) max(u32));
    return cast(u32) shiftedSum;
}

mulPow5InvDivPow2 :: proc (m: u32, q: u32, j: i32) -> u32 {
    when (RYU_FLOAT_FULL_TABLE) {
        return mulShift32(m, FLOAT_POW5_INV_SPLIT[q], j);
    } else when (RYU_OPTIMIZE_SIZE) {
        // The inverse multipliers are defined as [2^x / 5^y] + 1; the upper 64 bits from the f64 lookup
        // table are the correct bits for [2^x / 5^y], so we have to add 1 here. Note that we rely on the
        // fact that the added 1 that's already stored in the table never overflows into the upper 64 bits.
        pow5: [2]u64 = ---;
        double_computeInvPow5(q, pow5);
        return mulShift32(m, pow5[1] + 1, j);
    } else {
        return mulShift32(m, DOUBLE_POW5_INV_SPLIT[q][1] + 1, j);
    }
}

mulPow5divPow2 :: proc (m: u32, i: u32, j: i32) -> u32 {
    when (RYU_FLOAT_FULL_TABLE) {
        return mulShift32(m, FLOAT_POW5_SPLIT[i], j);
    } else when (RYU_OPTIMIZE_SIZE) {
        pow5: [2]u64 = ---;
        double_computePow5(i, pow5);
        return mulShift32(m, pow5[1], j);
    } else {
        return mulShift32(m, DOUBLE_POW5_SPLIT[i][1], j);
    }
}

////////////////////////////////////////////////
// common.h

// Returns the number of decimal digits in v, which must not contain more than 9 digits.
decimalLength9 :: proc (v: u32) -> u32 {
    // Function precondition: v is not a 10-digit number.
    // (f2s: 9 digits are sufficient for round-tripping.)
    // (d2fixed: We print 9-digit blocks.)
    assert(v < 1000000000);
    if (v >= 100000000) { return 9; }
    if (v >= 10000000) { return 8; }
    if (v >= 1000000) { return 7; }
    if (v >= 100000) { return 6; }
    if (v >= 10000) { return 5; }
    if (v >= 1000) { return 4; }
    if (v >= 100) { return 3; }
    if (v >= 10) { return 2; }
    return 1;
}

// Returns e == 0 ? 1 : [log_2(5^e)]; requires 0 <= e <= 3528.
log2pow5 :: proc (e: i32) -> i32 {
    // This approximation works up to the point that the multiplication overflows at e = 3529.
    // If the multiplication were done in 64 bits, it would fail at 5^4004 which is just greater
    // than 2^9297.
    assert(e >= 0);
    assert(e <= 3528);
    return cast(i32) (((cast(u32) e) * 1217359) >> 19);
}

// Returns e == 0 ? 1 : ceil(log_2(5^e)); requires 0 <= e <= 3528.
pow5bits :: proc (e: i32) -> i32 {
    // This approximation works up to the point that the multiplication overflows at e = 3529.
    // If the multiplication were done in 64 bits, it would fail at 5^4004 which is just greater
    // than 2^9297.
    assert(e >= 0);
    assert(e <= 3528);
    return cast(i32) ((((cast(u32) e) * 1217359) >> 19) + 1);
}

// Returns e == 0 ? 1 : ceil(log_2(5^e)); requires 0 <= e <= 3528.
ceil_log2pow5 :: proc (e: i32) -> i32 {
    return log2pow5(e) + 1;
}

// Returns floor(log_10(2^e)); requires 0 <= e <= 1650.
log10Pow2 :: proc (e: i32) -> u32 {
    // The first value this approximation fails for is 2^1651 which is just greater than 10^297.
    assert(e >= 0);
    assert(e <= 1650);
    return ((cast(u32) e) * 78913) >> 18;
}

// Returns floor(log_10(5^e)); requires 0 <= e <= 2620.
log10Pow5 :: proc (e: i32) -> u32 {
    // The first value this approximation fails for is 5^2621 which is just greater than 10^1832.
    assert(e >= 0);
    assert(e <= 2620);
    return ((cast(u32) e) * 732923) >> 20;
}

copy_special_str :: proc (result: []u8, sign: bool, exponent: bool, mantissa: bool) -> int {
    if (mantissa) {
        copy(result, "NaN");
        return 3;
    }
    if (sign) {
        result[0] = '-';
    }
    if (exponent) {
        copy(result[(sign ? 1 : 0) :], "Infinity");
        return (sign ? 1 : 0) + 8;
    }
    copy(result[(sign ? 1 : 0) :], "0E0");
    return (sign ? 1 : 0) + 3;
}

float_to_bits :: proc (f: f32) -> u32 {
    bits: u32 = transmute(u32) f
    return bits;
}

double_to_bits :: proc (d: f64) -> u64 {
    bits: u64 = transmute(u64) d
    return bits;
}


////////////////////////////////////////////////
// d2s_intrinsics.h

umul128 :: proc (a: u64, b: u64, productHi: ^u64) -> u64 {
    a := cast(u128) a
    b := cast(u128) b
    
    c := a * b
    productHi ^= cast(u64) (c >> 64)
    return cast(u64) c
    // return _umul128(a, b, productHi);
}

// Returns the lower 64 bits of (hi*2^64 + lo) >> dist, with 0 < dist < 64.
shiftright128 :: proc (lo: u64, hi: u64, dist: u32) -> u64 {
    // For the __shiftright128 intrinsic, the shift value is always
    // modulo 64.
    // In the current implementation of the f64-precision version
    // of Ryu, the shift value is always < 64. (In the case
    // RYU_OPTIMIZE_SIZE == 0, the shift value is in the range [49, 58].
    // Otherwise in the range [2, 59].)
    // However, this function is now also called by s2d, which requires supporting
    // the larger shift range (TODO: what is the actual range?).
    // Check this here in case a future change requires larger shift
    // values. In this case this function needs to be adjusted.
    assert(dist < 64);
    // return __shiftright128(lo, hi, cast(u8) dist);
    val := cast(u128) lo | ((cast(u128) hi) << 64)
    return cast(u64) (val >> dist)
}

div5 :: proc (x: u64) -> u64 {
    return x / 5;
}

div10 :: proc (x: u64) -> u64 {
    return x / 10;
}

div100 :: proc (x: u64) -> u64 {
    return x / 100;
}

div1e8 :: proc (x: u64) -> u64 {
    return x / 100000000;
}

div1e9 :: proc (x: u64) -> u64 {
    return x / 1000000000;
}

mod1e9 :: proc (x: u64) -> u32 {
    return cast(u32) (x - 1000000000 * div1e9(x));
}

pow5Factor :: proc (value: u64) -> u32 {
    value := value
    
    m_inv_5: u64 = 14757395258967641293; // 5 * m_inv_5 = 1 (mod 2^64)
    n_div_5: u64 = 3689348814741910323;  // #{ n | n = 0 (mod 2^64) } = 2^64 / 5
    count: u32 = 0;
    for {
        assert(value != 0);
        value *= m_inv_5;
        if (value > n_div_5) do break;
        count += 1;
    }
    return count;
}

// Returns true if value is divisible by 5^p.
multipleOfPowerOf5 :: proc (value: u64, p: u32) -> bool {
    // I tried a case distinction on p, but there was no performance difference.
    return pow5Factor(value) >= p;
}

// Returns true if value is divisible by 2^p.
multipleOfPowerOf2 :: proc (value: u64, p: u32) -> bool {
    assert(value != 0);
    assert(p < 64);
    // __builtin_ctzll doesn't appear to be faster here.
    return (value & ((1 << p) - 1)) == 0;
}

// We need a 64x128-bit multiplication and a subsequent 128-bit shift.
// Multiplication:
//   The 64-bit factor is variable and passed in, the 128-bit factor comes
//   from a lookup table. We know that the 64-bit factor only has 55
//   significant bits (i.e., the 9 topmost bits are zeros). The 128-bit
//   factor only has 124 significant bits (i.e., the 4 topmost bits are
//   zeros).
// Shift:
//   In principle, the multiplication result requires 55 + 124 = 179 bits to
//   represent. However, we then shift this value to the right by j, which is
//   at least j >= 115, so the result is guaranteed to fit into 179 - 115 = 64
//   bits. This means that we only need the topmost 64 significant bits of
//   the 64x128-bit multiplication.
//
// There are several ways to do this:
// 1. Best case: the compiler exposes a 128-bit type.
//    We perform two 64x64-bit multiplications, add the higher 64 bits of the
//    lower result to the higher result, and shift by j - 64 bits.
//
//    We explicitly cast from 64-bit to 128-bit, so the compiler can tell
//    that these are only 64-bit inputs, and can map these to the best
//    possible sequence of assembly instructions.
//    x64 machines happen to have matching assembly instructions for
//    64x64-bit multiplications and 128-bit shifts.
//
// 2. Second best case: the compiler exposes intrinsics for the x64 assembly
//    instructions mentioned in 1.
//
// 3. We only have 64x64 bit instructions that return the lower 64 bits of
//    the result, i.e., we have to use plain C.
//    Our inputs are less than the full width, so we have three options:
//    a. Ignore this fact and just implement the intrinsics manually.
//    b. Split both into 31-bit pieces, which guarantees no internal overflow,
//       but requires extra work upfront (unless we change the lookup table).
//    c. Split only the first factor into 31-bit pieces, which also guarantees
//       no internal overflow, but requires extra work since the intermediate
//       results are not perfectly aligned.

// Best case: use 128-bit type.
mulShift64 :: proc (m: u64, mul: [^]u64, j: i32) -> u64 {
    b0: u128 = (cast(u128) m) * cast(u128) mul[0];
    b2: u128 = (cast(u128) m) * cast(u128) mul[1];
    return (u64) (((b0 >> 64) + b2) >> cast(u32) (j - 64));
}

mulShiftAll64 :: proc (m: u64, mul: ^u64, j: i32, vp: ^u64, vm: ^u64, mmShift: u32) -> u64 {
    //  m <<= 2;
    //  u128 b0 = ((u128) m) * mul[0]; // 0
    //  u128 b2 = ((u128) m) * mul[1]; // 64
    //
    //  u128 hi = (b0 >> 64) + b2;
    //  u128 lo = b0 & 0xffffffffffffffffull;
    //  u128 factor = (((u128) mul[1]) << 64) + mul[0];
    //  u128 vpLo = lo + (factor << 1);
    //  *vp = (u64) ((hi + (vpLo >> 64)) >> (j - 64));
    //  u128 vmLo = lo - (factor << mmShift);
    //  *vm = (u64) ((hi + (vmLo >> 64) - (((u128) 1ull) << 64)) >> (j - 64));
    //  return (u64) (hi >> (j - 64));
    vp ^= mulShift64(4 * m + 2, mul, j);
    vm ^= mulShift64(4 * m - 1 - cast(u64) mmShift, mul, j);
    return mulShift64(4 * m, mul, j);
}

////////////////////////////////////////////////
// d2s.c

DOUBLE_MANTISSA_BITS :: 52
DOUBLE_EXPONENT_BITS :: 11
DOUBLE_BIAS :: 1023

decimalLength17 :: proc (v: u64) -> i32 {
    // This is slightly faster than a loop.
    // The average output length is 16.38 digits, so we check high-to-low.
    // Function precondition: v is not an 18, 19, or 20-digit number.
    // (17 digits are sufficient for round-tripping.)
    assert(v < 100000000000000000);
    if (v >= 10000000000000000) { return 17; }
    if (v >= 1000000000000000) { return 16; }
    if (v >= 100000000000000) { return 15; }
    if (v >= 10000000000000) { return 14; }
    if (v >= 1000000000000) { return 13; }
    if (v >= 100000000000) { return 12; }
    if (v >= 10000000000) { return 11; }
    if (v >= 1000000000) { return 10; }
    if (v >= 100000000) { return 9; }
    if (v >= 10000000) { return 8; }
    if (v >= 1000000) { return 7; }
    if (v >= 100000) { return 6; }
    if (v >= 10000) { return 5; }
    if (v >= 1000) { return 4; }
    if (v >= 100) { return 3; }
    if (v >= 10) { return 2; }
    return 1;
}

// A floating decimal representing m * 10^e.
floating_decimal_64 :: struct {
    mantissa: u64,
    // Decimal exponent's range is -324 to 308
    // inclusive, and can fit in a short if needed.
    exponent: i32,
};

d2d :: proc (ieeeMantissa: u64, ieeeExponent: i32) -> floating_decimal_64 {
    e2: i32 = ---;
    m2: u64 = ---;
    if (ieeeExponent == 0) {
        // We subtract 2 so that the bounds computation has 2 additional bits.
        e2 = 1 - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS - 2;
        m2 = ieeeMantissa;
    } else {
        e2 = ieeeExponent - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS - 2;
        m2 = (1 << DOUBLE_MANTISSA_BITS) | ieeeMantissa;
    }
    even: bool = (m2 & 1) == 0;
    acceptBounds: bool = even;
    
    // Step 2: Determine the interval of valid decimal representations.
    mv: u64 = 4 * m2;
    // Implicit bool -> int conversion. True is 1, false is 0.
    mmShift: i32 = cast(i32) (ieeeMantissa != 0 || ieeeExponent <= 1);
    // We would compute mp and mm like this:
    // u64 mp = 4 * m2 + 2;
    // u64 mm = mv - 1 - mmShift;
    
    // Step 3: Convert to a decimal power base using 128-bit arithmetic.
    vr, vp, vm: u64 = ---, ---, ---;
    e10: i32 = ---;
    vmIsTrailingZeros: bool = false;
    vrIsTrailingZeros: bool = false;
    if (e2 >= 0) {
        // I tried special-casing q == 0, but there was no effect on performance.
        // This expression is slightly faster than max(0, log10Pow2(e2) - 1).
        q: i32 = cast(i32) log10Pow2(e2) - cast(i32) (e2 > 3);
        e10 = q;
        k: i32 = DOUBLE_POW5_INV_BITCOUNT + pow5bits(q) - 1;
        i: i32 = -e2 + q + k;
        when (RYU_OPTIMIZE_SIZE) {
            pow5: [2]u64 = ---;
            double_computeInvPow5(q, pow5);
            vr = mulShiftAll64(m2, pow5, i, &vp, &vm, mmShift);
        } else {
            vr = mulShiftAll64(m2, cast([^]u64) &DOUBLE_POW5_INV_SPLIT[q], i, &vp, &vm, cast(u32) mmShift);
        }
        if (q <= 21) {
            // This should use q <= 22, but I think 21 is also safe. Smaller values
            // may still be safe, but it's more difficult to reason about them.
            // Only one of mp, mv, and mm can be a multiple of 5, if any.
            mvMod5: i32 = (cast(i32) mv) - 5 * (cast(i32) div5(mv));
            if (mvMod5 == 0) {
                vrIsTrailingZeros = multipleOfPowerOf5(mv, cast(u32) q);
            } else if (acceptBounds) {
                // Same as min(e2 + (~mm & 1), pow5Factor(mm)) >= q
                // <=> e2 + (~mm & 1) >= q && pow5Factor(mm) >= q
                // <=> true && pow5Factor(mm) >= q, since e2 >= q.
                vmIsTrailingZeros = multipleOfPowerOf5(mv - 1 - cast(u64) mmShift, cast(u32) q);
            } else {
                // Same as min(e2 + 1, pow5Factor(mp)) >= q.
                vp -= cast(u64) multipleOfPowerOf5(mv + 2, cast(u32) q);
            }
        }
    } else {
        // This expression is slightly faster than max(0, log10Pow5(-e2) - 1).
        q: i32 = cast(i32) log10Pow5(-e2) - cast(i32) (-e2 > 1);
        e10 = q + e2;
        i: i32 = -e2 - q;
        k: i32 = pow5bits(i) - DOUBLE_POW5_BITCOUNT;
        j: i32 = q - k;
        when (RYU_OPTIMIZE_SIZE) {
            pow5: [2]u64 = ---;
            double_computePow5(i, pow5);
            vr = mulShiftAll64(m2, pow5, j, &vp, &vm, mmShift);
        } else {
            vr = mulShiftAll64(m2, cast([^]u64) &DOUBLE_POW5_SPLIT[i], j, &vp, &vm, cast(u32) mmShift);
        }
        if (q <= 1) {
            // {vr,vp,vm} is trailing zeros if {mv,mp,mm} has at least q trailing 0 bits.
            // mv = 4 * m2, so it always has at least two trailing 0 bits.
            vrIsTrailingZeros = true;
            if (acceptBounds) {
                // mm = mv - 1 - mmShift, so it has 1 trailing 0 bit iff mmShift == 1.
                vmIsTrailingZeros = mmShift == 1;
            } else {
                // mp = mv + 2, so it always has at least one trailing 0 bit.
                vp -= 1;
            }
        } else if (q < 63) { // TODO(ulfjack): Use a tighter bound here.
            // We want to know if the full product has at least q trailing zeros.
            // We need to compute min(p2(mv), p5(mv) - e2) >= q
            // <=> p2(mv) >= q && p5(mv) - e2 >= q
            // <=> p2(mv) >= q (because -e2 >= q)
            vrIsTrailingZeros = multipleOfPowerOf2(mv, cast(u32) q);
        }
    }
    
    // Step 4: Find the shortest decimal representation in the interval of valid representations.
    removed: i32 = 0;
    lastRemovedDigit: u8 = 0;
    output: u64 = ---;
    // On average, we remove ~2 digits.
    if (vmIsTrailingZeros || vrIsTrailingZeros) {
        // General case, which happens rarely (~0.7%).
        for {
            vpDiv10: u64 = div10(vp);
            vmDiv10: u64 = div10(vm);
            if (vpDiv10 <= vmDiv10) {
                break;
            }
            vmMod10: i32 = (cast(i32) vm) - 10 * (cast(i32) vmDiv10);
            vrDiv10: u64 = div10(vr);
            vrMod10: i32 = (cast(i32) vr) - 10 * (cast(i32) vrDiv10);
            vmIsTrailingZeros &= vmMod10 == 0;
            vrIsTrailingZeros &= lastRemovedDigit == 0;
            lastRemovedDigit = cast(u8) vrMod10;
            vr = vrDiv10;
            vp = vpDiv10;
            vm = vmDiv10;
            removed += 1;
        }
        if (vmIsTrailingZeros) {
            for {
                vmDiv10: u64 = div10(vm);
                vmMod10: i32 = (cast(i32) vm) - 10 * (cast(i32) vmDiv10);
                if (vmMod10 != 0) {
                    break;
                }
                vpDiv10: u64 = div10(vp);
                vrDiv10: u64 = div10(vr);
                vrMod10: i32 = (cast(i32) vr) - 10 * (cast(i32) vrDiv10);
                vrIsTrailingZeros &= lastRemovedDigit == 0;
                lastRemovedDigit = cast(u8) vrMod10;
                vr = vrDiv10;
                vp = vpDiv10;
                vm = vmDiv10;
                removed += 1;
            }
        }
        if (vrIsTrailingZeros && lastRemovedDigit == 5 && vr % 2 == 0) {
            // Round even if the exact number is .....50..0.
            lastRemovedDigit = 4;
        }
        // We need to take vr + 1 if vr is outside bounds or we need to round up.
        output = vr + cast(u64) ((vr == vm && (!acceptBounds || !vmIsTrailingZeros)) || lastRemovedDigit >= 5);
    } else {
        // Specialized for the common case (~99.3%). Percentages below are relative to this.
        roundUp: bool = false;
        vpDiv100: u64 = div100(vp);
        vmDiv100: u64 = div100(vm);
        if (vpDiv100 > vmDiv100) { // Optimization: remove two digits at a time (~86.2%).
            vrDiv100: u64 = div100(vr);
            vrMod100: i32 = (cast(i32) vr) - 100 * (cast(i32) vrDiv100);
            roundUp = vrMod100 >= 50;
            vr = vrDiv100;
            vp = vpDiv100;
            vm = vmDiv100;
            removed += 2;
        }
        // Loop iterations below (approximately), without optimization above:
        // 0: 0.03%, 1: 13.8%, 2: 70.6%, 3: 14.0%, 4: 1.40%, 5: 0.14%, 6+: 0.02%
        // Loop iterations below (approximately), with optimization above:
        // 0: 70.6%, 1: 27.8%, 2: 1.40%, 3: 0.14%, 4+: 0.02%
        for {
            vpDiv10: u64 = div10(vp);
            vmDiv10: u64 = div10(vm);
            if (vpDiv10 <= vmDiv10) {
                break;
            }
            vrDiv10: u64 = div10(vr);
            vrMod10: i32 = (cast(i32) vr) - 10 * (cast(i32) vrDiv10);
            roundUp = vrMod10 >= 5;
            vr = vrDiv10;
            vp = vpDiv10;
            vm = vmDiv10;
            removed += 1;
        }
        // We need to take vr + 1 if vr is outside bounds or we need to round up.
        output = vr + cast(u64) (vr == vm || roundUp);
    }
    exp: i32 = e10 + removed;
    
    fd: floating_decimal_64 = ---;
    fd.exponent = exp;
    fd.mantissa = output;
    return fd;
}

to_chars_64 :: proc (v: floating_decimal_64, sign: bool, result: []u8) -> int {
    // Step 5: Print the decimal representation.
    index: int = 0;
    if (sign) {
        result[index] = '-';
        index += 1
    }
    
    output: u64 = v.mantissa;
    olength: i32 = decimalLength17(output);
    
    // Print the decimal digits.
    // The following code is equivalent to:
    // for (i32 i = 0; i < olength - 1; ++i) {
    //   i32 c = output % 10; output /= 10;
    //   result[index + olength - i] = (u8) ('0' + c);
    // }
    // result[index] = '0' + output % 10;
    
    i: i32 = 0;
    // We prefer 32-bit operations, even on 64-bit platforms.
    // We have at most 17 digits, and i32 can store 9 digits.
    // If output doesn't fit into i32, we cut off 8 digits,
    // so the rest will fit into i32.
    if ((output >> 32) != 0) {
        // Expensive 64-bit division.
        q: u64 = div1e8(output);
        output2: i32 = (cast(i32) output) - 100000000 * (cast(i32) q);
        output = q;
        
        c: i32 = output2 % 10000;
        output2 /= 10000;
        d: i32 = output2 % 10000;
        c0: i32 = (c % 100) << 1;
        c1: i32 = (c / 100) << 1;
        d0: i32 = (d % 100) << 1;
        d1: i32 = (d / 100) << 1;
        result[cast(i32) index + olength - i - 1 + 0] = DIGIT_TABLE[c0 +0];
        result[cast(i32) index + olength - i - 1 + 1] = DIGIT_TABLE[c0 +1];
        
        result[cast(i32) index + olength - i - 3 + 0] = DIGIT_TABLE[c1 +0];
        result[cast(i32) index + olength - i - 3 + 1] = DIGIT_TABLE[c1 +1];
        
        result[cast(i32) index + olength - i - 5 + 0] = DIGIT_TABLE[d0 +0];
        result[cast(i32) index + olength - i - 5 + 1] = DIGIT_TABLE[d0 +1];
        
        result[cast(i32) index + olength - i - 7 + 0] = DIGIT_TABLE[d1 +0];
        result[cast(i32) index + olength - i - 7 + 1] = DIGIT_TABLE[d1 +1];
        i += 8;
    }
    output2: i32 = cast(i32) output;
    for (output2 >= 10000) {
        c: i32 = output2 % 10000;
        output2 /= 10000;
        c0: i32 = (c % 100) << 1;
        c1: i32 = (c / 100) << 1;
        result[cast(i32) index + olength - i - 1 + 0] = DIGIT_TABLE[c0 +0];
        result[cast(i32) index + olength - i - 1 + 1] = DIGIT_TABLE[c0 +1];
        
        result[cast(i32) index + olength - i - 3 + 0] = DIGIT_TABLE[c1 +0];
        result[cast(i32) index + olength - i - 3 + 1] = DIGIT_TABLE[c1 +1];
        i += 4;
    }
    if (output2 >= 100) {
        c: i32 = (output2 % 100) << 1;
        output2 /= 100;
        result[cast(i32) index + olength - i - 1 + 0] = DIGIT_TABLE[c +0];
        result[cast(i32) index + olength - i - 1 + 1] = DIGIT_TABLE[c +1];
        i += 2;
    }
    if (output2 >= 10) {
        c: i32 = output2 << 1;
        // We can't use memcpy here: the decimal dot goes between these two digits.
        result[index + cast(int) olength - cast(int) i] = DIGIT_TABLE[c + 1];
        result[index] = DIGIT_TABLE[c];
    } else {
        result[index] = (u8) ('0' + output2);
    }
    
    // Print decimal point if needed.
    if (olength > 1) {
        result[index + 1] = '.';
        index += cast(int) olength + 1;
    } else {
        index += 1;
    }
    
    // Print the exponent.
    result[index] = 'E';
    index += 1
    exp: i32 = v.exponent + olength - 1;
    if (exp < 0) {
        result[index] = '-';
        index += 1
        exp = -exp;
    }
    
    if (exp >= 100) {
        c: i32 = exp % 10;
        result[cast(i32) index + 0] = DIGIT_TABLE[2 * (exp / 10) +0];
        result[cast(i32) index + 1] = DIGIT_TABLE[2 * (exp / 10) +1];
        result[index + 2] = (u8) ('0' + c);
        index += 3;
    } else if (exp >= 10) {
        result[cast(i32) index + 0] = DIGIT_TABLE[2 * exp +0];
        result[cast(i32) index + 1] = DIGIT_TABLE[2 * exp +1];
        index += 2;
    } else {
        result[index] = (u8) ('0' + exp);
        index += 1
    }
    
    return index;
}

d2d_small_int :: proc (ieeeMantissa: u64, ieeeExponent: i32, v: ^floating_decimal_64) -> bool  {
    m2: u64 = (1 << DOUBLE_MANTISSA_BITS) | ieeeMantissa;
    e2: i32 = ieeeExponent - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS;
    
    if (e2 > 0) {
        // f = m2 * 2^e2 >= 2^53 is an integer.
        // Ignore this case for now.
        return false;
    }
    
    if (e2 < -52) {
        // f < 1.
        return false;
    }
    
    // Since 2^52 <= m2 < 2^53 and 0 <= -e2 <= 52: 1 <= f = m2 / 2^-e2 < 2^53.
    // Test if the lower -e2 bits of the significand are 0, i.e. whether the fraction is 0.
    mask: u64 = (1 << cast(u64)(-e2)) - 1;
    fraction: u64 = m2 & mask;
    if (fraction != 0) {
        return false;
    }
    
    // f is an integer in the range [1, 2^53).
    // Note: mantissa might contain trailing (decimal) 0's.
    // Note: since 2^53 < 10^16, there is no need to adjust decimalLength17().
    v.mantissa = m2 >> cast(u64)(-e2);
    v.exponent = 0;
    return true;
}

d2s :: proc(f: f64, allocator := context.allocator) -> (result: string) {
    buffer := make([]u8, 25, allocator)
    result = d2s_buffered(f, buffer); 
    return result;
}

d2s_buffered :: proc (f: f64, buffer: []u8) -> (result: string) {
    // Step 1: Decode the floating-point number, and unify normalized and subnormal cases.
    bits: u64 = double_to_bits(f);
    
    // Decode bits into sign, mantissa, and exponent.
    ieeeSign: bool = ((bits >> (DOUBLE_MANTISSA_BITS + DOUBLE_EXPONENT_BITS)) & 1) != 0;
    ieeeMantissa: u64 = bits & ((1 << DOUBLE_MANTISSA_BITS) - 1);
    ieeeExponent: i32 = cast(i32) ((bits >> DOUBLE_MANTISSA_BITS) & ((1 << DOUBLE_EXPONENT_BITS) - 1));
    // Case distinction; exit early for the easy cases.
    if (ieeeExponent == ((1 << DOUBLE_EXPONENT_BITS) - 1) || (ieeeExponent == 0 && ieeeMantissa == 0)) {
        n := copy_special_str(buffer, ieeeSign, cast(bool) ieeeExponent, cast(bool) ieeeMantissa);
        return transmute(string) buffer[:n]
    }
    
    v: floating_decimal_64 = ---;
    isSmallInt: bool = d2d_small_int(ieeeMantissa, ieeeExponent, &v);
    if (isSmallInt) {
        // For small integers in the range [1, 2^53), v.mantissa might contain trailing (decimal) zeros.
        // For scientific notation we need to move these zeros into the exponent.
        // (This is not needed for fixed-point notation, so it might be beneficial to trim
        // trailing zeros in to_chars only if needed - once fixed-point notation output is implemented.)
        for {
            q: u64 = div10(v.mantissa);
            r: i32 = (cast(i32) v.mantissa) - 10 * (cast(i32) q);
            if (r != 0) {
                break;
            }
            v.mantissa = q;
            v.exponent += 1;
        }
    } else {
        v = d2d(ieeeMantissa, ieeeExponent);
    }
    
    n := to_chars(v, ieeeSign, buffer);
    return transmute(string) buffer[:n]
}


////////////////////////////////////////////////
// f2s.c

FLOAT_MANTISSA_BITS :: 23
FLOAT_EXPONENT_BITS :: 8
FLOAT_BIAS :: 127

// A floating decimal representing m * 10^e.
floating_decimal_32 :: struct {
    mantissa: u32,
    // Decimal exponent's range is -45 to 38
    // inclusive, and can fit in a short if needed.
    exponent: i32,
}

f2d :: proc (ieeeMantissa: u32, ieeeExponent: u32) -> floating_decimal_32 {
    e2: i32 = ---;
    m2: u32 = ---;
    if (ieeeExponent == 0) {
        // We subtract 2 so that the bounds computation has 2 additional bits.
        e2 = 1 - FLOAT_BIAS - FLOAT_MANTISSA_BITS - 2;
        m2 = ieeeMantissa;
    } else {
        e2 = cast(i32) ieeeExponent - FLOAT_BIAS - FLOAT_MANTISSA_BITS - 2;
        m2 = (1 << FLOAT_MANTISSA_BITS) | ieeeMantissa;
    }
    even := (m2 & 1) == 0;
    acceptBounds := even;
    
    // Step 2: Determine the interval of valid decimal representations.
    mv: u32 = 4 * m2;
    mp: u32 = 4 * m2 + 2;
    // Implicit bool -> int conversion. True is 1, false is 0.
    mmShift: u32 = cast(u32) (ieeeMantissa != 0 || ieeeExponent <= 1);
    mm: u32 = 4 * m2 - 1 - mmShift;
    
    // Step 3: Convert to a decimal power base using 64-bit arithmetic.
    vr, vp, vm: u32 = ---, ---, ---;
    e10: i32 = ---;
    vmIsTrailingZeros := false;
    vrIsTrailingZeros := false;
    lastRemovedDigit: u8 = 0;
    if (e2 >= 0) {
        q: u32 = log10Pow2(e2);
        e10 = cast(i32) q;
        k: i32 = FLOAT_POW5_INV_BITCOUNT + pow5bits(cast(i32) q) - 1;
        i: i32 = -e2 + cast(i32) q + k;
        vr = mulPow5InvDivPow2(mv, q, i);
        vp = mulPow5InvDivPow2(mp, q, i);
        vm = mulPow5InvDivPow2(mm, q, i);
        if (q != 0 && (vp - 1) / 10 <= vm / 10) {
            // We need to know one removed digit even if we are not going to loop below. We could use
            // q = X - 1 above, except that would require 33 bits for the result, and we've found that
            // 32-bit arithmetic is faster even on 64-bit machines.
            l: i32 = FLOAT_POW5_INV_BITCOUNT + pow5bits(cast(i32) (q - 1)) - 1;
            lastRemovedDigit = cast(u8) (mulPow5InvDivPow2(mv, q - 1, -e2 + cast(i32) q - 1 + l) % 10);
        }
        if (q <= 9) {
            // The largest power of 5 that fits in 24 bits is 5^10, but q <= 9 seems to be safe as well.
            // Only one of mp, mv, and mm can be a multiple of 5, if any.
            if (mv % 5 == 0) {
                vrIsTrailingZeros = multipleOfPowerOf5_32(mv, q);
            } else if (acceptBounds) {
                vmIsTrailingZeros = multipleOfPowerOf5_32(mm, q);
            } else {
                vp -= cast(u32) multipleOfPowerOf5_32(mp, q);
            }
        }
    } else {
        q: u32 = log10Pow5(-e2);
        e10 = cast(i32) q + e2;
        i: i32 = -e2 - cast(i32) q;
        k: i32 = pow5bits(i) - FLOAT_POW5_BITCOUNT;
        j: i32 = cast(i32) q - k;
        vr = mulPow5divPow2(mv, cast(u32) i, j);
        vp = mulPow5divPow2(mp, cast(u32) i, j);
        vm = mulPow5divPow2(mm, cast(u32) i, j);
        if (q != 0 && (vp - 1) / 10 <= vm / 10) {
            j = cast(i32) q - 1 - (pow5bits(i + 1) - FLOAT_POW5_BITCOUNT);
            lastRemovedDigit = (u8) (mulPow5divPow2(mv, (u32) (i + 1), j) % 10);
        }
        if (q <= 1) {
            // {vr,vp,vm} is trailing zeros if {mv,mp,mm} has at least q trailing 0 bits.
            // mv = 4 * m2, so it always has at least two trailing 0 bits.
            vrIsTrailingZeros = true;
            if (acceptBounds) {
                // mm = mv - 1 - mmShift, so it has 1 trailing 0 bit iff mmShift == 1.
                vmIsTrailingZeros = mmShift == 1;
            } else {
                // mp = mv + 2, so it always has at least one trailing 0 bit.
                vp -= 1;
            }
        } else if (q < 31) { // TODO(ulfjack): Use a tighter bound here.
            vrIsTrailingZeros = multipleOfPowerOf2_32(mv, q - 1);
        }
    }
    
    // Step 4: Find the shortest decimal representation in the interval of valid representations.
    removed: i32 = 0;
    output: u32 = ---;
    if (vmIsTrailingZeros || vrIsTrailingZeros) {
        // General case, which happens rarely (~4.0%).
        for (vp / 10 > vm / 10) {
            vmIsTrailingZeros &= vm % 10 == 0;
            vrIsTrailingZeros &= lastRemovedDigit == 0;
            lastRemovedDigit = (u8) (vr % 10);
            vr /= 10;
            vp /= 10;
            vm /= 10;
            removed += 1;
        }
        if (vmIsTrailingZeros) {
            for (vm % 10 == 0) {
                vrIsTrailingZeros &= lastRemovedDigit == 0;
                lastRemovedDigit = (u8) (vr % 10);
                vr /= 10;
                vp /= 10;
                vm /= 10;
                removed += 1;
            }
        }
        if (vrIsTrailingZeros && lastRemovedDigit == 5 && vr % 2 == 0) {
            // Round even if the exact number is .....50..0.
            lastRemovedDigit = 4;
        }
        // We need to take vr + 1 if vr is outside bounds or we need to round up.
        output = vr + cast(u32) ((vr == vm && (!acceptBounds || !vmIsTrailingZeros)) || lastRemovedDigit >= 5);
    } else {
        // Specialized for the common case (~96.0%). Percentages below are relative to this.
        // Loop iterations below (approximately):
        // 0: 13.6%, 1: 70.7%, 2: 14.1%, 3: 1.39%, 4: 0.14%, 5+: 0.01%
        for (vp / 10 > vm / 10) {
            lastRemovedDigit = (u8) (vr % 10);
            vr /= 10;
            vp /= 10;
            vm /= 10;
            removed += 1;
        }
        // We need to take vr + 1 if vr is outside bounds or we need to round up.
        output = vr + cast(u32) (vr == vm || lastRemovedDigit >= 5);
    }
    exp: i32 = e10 + removed;
    
    fd: floating_decimal_32 = ---;
    fd.exponent = exp;
    fd.mantissa = output;
    return fd;
}

to_chars :: proc { to_chars_32, to_chars_64 }
to_chars_32 :: proc (v: floating_decimal_32, sign: bool, result: []u8) -> int {
    // Step 5: Print the decimal representation.
    index: int = 0;
    if (sign) {
        result[index] = '-';
        index += 1
    }
    
    output: u32 = v.mantissa;
    olength: u32 = decimalLength9(output);
    
    // Print the decimal digits.
    // The following code is equivalent to:
    // for (u32 i = 0; i < olength - 1; ++i) {
    //   u32 c = output % 10; output /= 10;
    //   result[index + olength - i] = (u8) ('0' + c);
    // }
    // result[index] = '0' + output % 10;
    i: u32 = 0;
    for output >= 10000 {
        c: u32 = output % 10000;
        output /= 10000;
        c0: u32 = (c % 100) << 1;
        c1: u32 = (c / 100) << 1;
        result[cast(u32) index + olength - i - 1 + 0] = DIGIT_TABLE[c0 +0];
        result[cast(u32) index + olength - i - 1 + 1] = DIGIT_TABLE[c0 +1];
        
        result[cast(u32) index + olength - i - 3 + 0] = DIGIT_TABLE[c1 +0];
        result[cast(u32) index + olength - i - 3 + 1] = DIGIT_TABLE[c1 +1];
        i += 4;
    }
    if (output >= 100) {
        c: u32 = (output % 100) << 1;
        output /= 100;
        result[cast(u32) index + olength - i - 1 + 0] = DIGIT_TABLE[c +0];
        result[cast(u32) index + olength - i - 1 + 1] = DIGIT_TABLE[c +1];
        i += 2;
    }
    if (output >= 10) {
        c: u32 = output << 1;
        // We can't use memcpy here: the decimal dot goes between these two digits.
        result[cast(u32) index + olength - i] = DIGIT_TABLE[c + 1];
        result[index] = DIGIT_TABLE[c];
    } else {
        result[index] = cast(u8) ('0' + output);
    }
    
    // Print decimal point if needed.
    if (olength > 1) {
        result[index + 1] = '.';
        index += cast(int) olength + 1;
    } else {
        index += 1;
    }
    
    // Print the exponent.
    result[index] = 'E';
    index += 1
    exp: i32 = v.exponent + cast(i32) olength - 1;
    if (exp < 0) {
        result[index] = '-';
        index += 1
        exp = -exp;
    }
    
    if (exp >= 10) {
        result[index+0] = DIGIT_TABLE[2 * exp +0];
        result[index+1] = DIGIT_TABLE[2 * exp +1];
        index += 2;
    } else {
        result[index] = cast(u8) ('0' + exp);
        index += 1
    }
    
    return index;
}

f2s :: proc (f: f32, allocator := context.allocator) -> string {
    buffer := make([]u8, 16, allocator)
    result := f2s_buffered(f, buffer); 
    return result;
}

f2s_buffered :: proc (f: f32,  buffer: []u8) -> (result: string) {
    // Step 1: Decode the floating-point number, and unify normalized and subnormal cases.
    bits: u32 = float_to_bits(f);
    
    // Decode bits into sign, mantissa, and exponent.
    ieeeSign: bool = ((bits >> (FLOAT_MANTISSA_BITS + FLOAT_EXPONENT_BITS)) & 1) != 0;
    ieeeMantissa: u32 = bits & ((1 << FLOAT_MANTISSA_BITS) - 1);
    ieeeExponent: u32 = (bits >> FLOAT_MANTISSA_BITS) & ((1 << FLOAT_EXPONENT_BITS) - 1);
    
    // Case distinction; exit early for the easy cases.
    if (ieeeExponent == ((1 << FLOAT_EXPONENT_BITS) - 1) || (ieeeExponent == 0 && ieeeMantissa == 0)) {
        n := copy_special_str(buffer, ieeeSign, cast(bool) ieeeExponent, cast(bool) ieeeMantissa);
        return transmute(string) buffer[:n]
    }
    
    v: floating_decimal_32 = f2d(ieeeMantissa, ieeeExponent);
    
    n: = to_chars(v, ieeeSign, buffer);
    return transmute(string) buffer[:n]
}

////////////////////////////////////////////////
// d2fixed.c

POW10_ADDITIONAL_BITS :: 120

umul256 :: proc (a: u128, bHi: u64, bLo: u64, productHi: ^u128) -> u128 {
    aLo: u64 = cast(u64)a;
    aHi: u64 = cast(u64)(a >> 64);
    
    b00: u128 = cast(u128)aLo * cast(u128) bLo;
    b01: u128 = cast(u128)aLo * cast(u128) bHi;
    b10: u128 = cast(u128)aHi * cast(u128) bLo;
    b11: u128 = cast(u128)aHi * cast(u128) bHi;
    
    b00Lo: u64 = cast(u64)b00;
    b00Hi: u64 = cast(u64)(b00 >> 64);
    
    mid1: u128 = b10 + cast(u128) b00Hi;
    mid1Lo: u64 = cast(u64)(mid1);
    mid1Hi: u64 = cast(u64)(mid1 >> 64);
    
    mid2: u128 = b01 + cast(u128) mid1Lo;
    mid2Lo: u64 = cast(u64)(mid2);
    mid2Hi: u64 = cast(u64)(mid2 >> 64);
    
    pHi: u128 = b11 + cast(u128) mid1Hi + cast(u128) mid2Hi;
    pLo: u128 = (cast(u128)mid2Lo << 64) | cast(u128) b00Lo;
    
    productHi ^= pHi;
    return pLo;
}

// Returns the high 128 bits of the 256-bit product of a and b.
umul256_hi :: proc (a: u128, bHi: u64, bLo: u64) -> u128 {
    // Reuse the umul256 implementation.
    // Optimizers will likely eliminate the instructions used to compute the
    // low part of the product.
    hi: u128 = ---;
    umul256(a, bHi, bLo, &hi);
    return hi;
}

// Unfortunately, gcc/clang do not automatically turn a 128-bit integer division
// into a multiplication, so we have to do it manually.
uint128_mod1e9 :: proc (v: u128) -> u32 {
    // After multiplying, we're going to shift right by 29, then truncate to u32.
    // This means that we need only 29 + 32 = 61 bits, so we can truncate to u64 before shifting.
    multiplied: u64 = cast(u64) umul256_hi(v, 0x89705F4136B4A597, 0x31680A88F8953031);
    
    // For u32 truncation, see the mod1e9() comment in d2s_intrinsics.h.
    shifted: u32 = cast(u32) (multiplied >> 29);
    
    return (cast(u32) v) - 1000000000 * shifted;
}

// Best case: use 128-bit type.
mulShift_mod1e9 :: proc (m: u64, mul: [^]u64, j: i32) -> u32 {
    b0: u128 = (cast(u128) m) * cast(u128) mul[0]; // 0
    b1: u128 = (cast(u128) m) * cast(u128) mul[1]; // 64
    b2: u128 = (cast(u128) m) * cast(u128) mul[2]; // 128
    assert(j >= 128);
    assert(j <= 180);
    // j: [128, 256)
    mid: u128 = b1 + cast(u128) cast(u64) (b0 >> 64); // 64
    s1: u128 = b2 + cast(u128) cast(u64) (mid >> 64); // 128
    return uint128_mod1e9(s1 >> cast(u32) (j - 128));
}

// Convert `digits` to a sequence of decimal digits. Append the digits to the result.
// The caller has to guarantee that:
//   10^(olength-1) <= digits < 10^olength
// e.g., by passing `olength` as `decimalLength9(digits)`.
append_n_digits :: proc (olength: u32, digits: u32, result: []u8) {
    digits := digits
    i: u32 = 0;
    for digits >= 10000 {
        c: u32 = digits % 10000;
        digits /= 10000;
        c0: u32 = (c % 100) << 1;
        c1: u32 = (c / 100) << 1;
        result[olength - i - 2 +0] = DIGIT_TABLE[c0+0]
        result[olength - i - 2 +1] = DIGIT_TABLE[c0+1]
        
        result[olength - i - 4 +0] = DIGIT_TABLE[c1+0]
        result[olength - i - 4 +1] = DIGIT_TABLE[c1+1]
        i += 4;
    }
    if (digits >= 100) {
        c: u32 = (digits % 100) << 1;
        digits /= 100;
        result[olength - i - 2 +0] = DIGIT_TABLE[c+0]
        result[olength - i - 2 +1] = DIGIT_TABLE[c+1]
        i += 2;
    }
    if (digits >= 10) {
        c: u32 = digits << 1;
        result[olength - i - 2 +0] = DIGIT_TABLE[c+0]
        result[olength - i - 2 +1] = DIGIT_TABLE[c+1]
    } else {
        result[0] = cast(u8) ('0' + digits);
    }
}

// Convert `digits` to a sequence of decimal digits. Print the first digit, followed by a decimal
// dot '.' followed by the remaining digits. The caller has to guarantee that:
//   10^(olength-1) <= digits < 10^olength
// e.g., by passing `olength` as `decimalLength9(digits)`.
append_d_digits :: proc (olength: u32, digits: u32, result: []u8) {
    digits:= digits
    
    i: u32 = 0;
    for digits >= 10000 {
        c: u32 = digits % 10000;
        digits /= 10000;
        c0: u32 = (c % 100) << 1;
        c1: u32 = (c / 100) << 1;
        result[olength + 1 - i - 2 +0] = DIGIT_TABLE[c0+0]
        result[olength + 1 - i - 2 +1] = DIGIT_TABLE[c0+1]
        
        result[olength + 1 - i - 4 +0] = DIGIT_TABLE[c1+0]
        result[olength + 1 - i - 4 +1] = DIGIT_TABLE[c1+1]
        i += 4;
    }
    if (digits >= 100) {
        c: u32 = (digits % 100) << 1;
        digits /= 100;
        result[olength + 1 - i - 2 +0] = DIGIT_TABLE[c+0]
        result[olength + 1 - i - 2 +1] = DIGIT_TABLE[c+1]
        i += 2;
    }
    if (digits >= 10) {
        c: u32 = digits << 1;
        result[2] = DIGIT_TABLE[c + 1];
        result[1] = '.';
        result[0] = DIGIT_TABLE[c];
    } else {
        result[1] = '.';
        result[0] = cast(u8) ('0' + digits);
    }
}

// Convert `digits` to decimal and write the last `count` decimal digits to result.
// If `digits` contains additional digits, then those are silently ignored.
append_c_digits :: proc (count: u32, digits: u32, result: []u8) {
    // Copy pairs of digits from DIGIT_TABLE.
    digits := digits
    i: u32 = 0;
    for ; i < count - 1; i += 2 {
        c: u32 = (digits % 100) << 1;
        digits /= 100;
        result[count - i - 2 +0] = DIGIT_TABLE[c+0]
        result[count - i - 2 +1] = DIGIT_TABLE[c+1]
    }
    // Generate the last digit if count is odd.
    if (i < count) {
        c: u8 = (u8) ('0' + (digits % 10));
        result[count - i - 1] = c;
    }
}

// Convert `digits` to decimal and write the last 9 decimal digits to result.
// If `digits` contains additional digits, then those are silently ignored.
append_nine_digits :: proc (digits: u32, result: []u8) {
    if (digits == 0) {
        for index in 0..<9 do result[index] = '0'
        return;
    }
    
    digits := digits
    for i: u32 = 0; i < 5; i += 4 {
        c: u32 = digits % 10000;
        digits /= 10000;
        c0: u32 = (c % 100) << 1;
        c1: u32 = (c / 100) << 1;
        
        result[7 - i +0] = DIGIT_TABLE[c0+0]
        result[7 - i +1] = DIGIT_TABLE[c0+1]
        
        result[5 - i +0] = DIGIT_TABLE[c1+0]
        result[5 - i +1] = DIGIT_TABLE[c1+1]
    }
    result[0] = cast(u8) ('0' + digits);
}

indexForExponent :: proc (e: u32) -> u32 {
    return (e + 15) / 16;
}

pow10BitsForIndex :: proc (idx: u32) -> u32 {
    return 16 * idx + POW10_ADDITIONAL_BITS;
}

lengthForIndex :: proc (idx: u32) -> u32 {
    // +1 for ceil, +16 for mantissa, +8 to round up when dividing by 9
    return (log10Pow2(16 * cast(i32) idx) + 1 + 16 + 8) / 9;
}

copy_special_str_printf :: proc (result: []u8, sign: bool, mantissa: u64) -> int {
    when ODIN_OS == .Windows {
        // TODO: Check that -nan is expected output on Windows.
        if (sign) {
            result[0] = '-';
        }
        if (mantissa != 0) {
            if (mantissa < (1 << (DOUBLE_MANTISSA_BITS - 1))) {
                copy(result[cast(int) sign:], "nan(snan)");
            return cast(int) sign + 9;
            }
            copy(result[cast(int) sign:], "nan");
            return cast(int) sign + 3;
        }
    } else {
        if (mantissa != 0) {
            copy(result, "nan");
            return 3;
        }
        if (sign) {
            result[0] = '-';
        }
    }
    copy(result[cast(i32) sign:], "Infinity");
    return cast(int) sign + 8;
}

d2fixed :: proc (d: f64, precision: u32, allocator:= context.allocator) -> (result: string) {
    buffer: []u8 = make([]u8, 2000, allocator);
    result = d2fixed_buffered(d, precision, buffer);
    return result
}

d2fixed_buffered :: proc (d: f64, precision: u32, buffer: []u8) -> (result: string) {
    bits: u64 = double_to_bits(d);
    
    // Decode bits into sign, mantissa, and exponent.
    ieeeSign: bool = ((bits >> (DOUBLE_MANTISSA_BITS + DOUBLE_EXPONENT_BITS)) & 1) != 0;
    ieeeMantissa: u64 = bits & ((1 << DOUBLE_MANTISSA_BITS) - 1);
    ieeeExponent: u32 = (u32) ((bits >> DOUBLE_MANTISSA_BITS) & ((1 << DOUBLE_EXPONENT_BITS) - 1));
    
    // Case distinction; exit early for the easy cases.
    if (ieeeExponent == ((1 << DOUBLE_EXPONENT_BITS) - 1)) {
        n := copy_special_str_printf(buffer, ieeeSign, ieeeMantissa);
        return transmute(string) buffer[:n];
    }
    // Zero
    if (ieeeExponent == 0 && ieeeMantissa == 0) {
        index: int = 0;
        if (ieeeSign) {
            buffer[index] = '-';
            index += 1
        }
        buffer[index] = '0';
        index += 1
        if (precision > 0) {
            buffer[index] = '.';
            index += 1
            for i in 0..<precision do buffer[cast(u32)index+i] = '0'
            index += cast(int) precision;
        }
        
        return transmute(string) buffer[:index];
    }
    
    e2: i32 = ---;
    m2: u64 = ---;
    if (ieeeExponent == 0) {
        e2 = 1 - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS;
        m2 = ieeeMantissa;
    } else {
        e2 = cast(i32) ieeeExponent - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS;
        m2 = (1 << DOUBLE_MANTISSA_BITS) | ieeeMantissa;
    }
    
    index: int = 0;
    nonzero: bool = false;
    if (ieeeSign) {
        buffer[index] = '-';
        index += 1
    }
    if (e2 >= -52) {
        idx: u32 = e2 < 0 ? 0 : indexForExponent(cast(u32) e2);
        p10bits: u32 = pow10BitsForIndex(idx);
        len: i32 = cast(i32) lengthForIndex(idx);
        for i: i32 = len - 1; i >= 0; i-=1 {
            j: u32 = p10bits - cast(u32) e2;
            // Temporary: j is usually around 128, and by shifting a bit, we push it to 128 or above, which is
            // a slightly faster code path in mulShift_mod1e9. Instead, we can just increase the multipliers.
            digits: u32 = mulShift_mod1e9(m2 << 8, cast([^]u64) &POW10_SPLIT[cast(i32) POW10_OFFSET[idx] + i], cast(i32) (j + 8));
            if (nonzero) {
                append_nine_digits(digits, buffer[index:]);
                index += 9;
            } else if (digits != 0) {
                olength: u32 = decimalLength9(digits);
                append_n_digits(olength, digits, buffer[index:]);
                index += cast(int) olength;
                nonzero = true;
            }
        }
    }
    if (!nonzero) {
        buffer[index] = '0';
        index += 1
    }
    if (precision > 0) {
        buffer[index] = '.';
        index += 1
    }
    if (e2 < 0) {
        idx: i32 = -e2 / 16;
        blocks: u32 = precision / 9 + 1;
        // 0 = don't round up; 1 = round up unconditionally; 2 = round up if odd.
        roundUp: int = 0;
        i: u32 = 0;
        if (blocks <= cast(u32) MIN_BLOCK_2[idx]) {
            i = blocks;
            for j in 0..<precision do buffer[index + cast(int) j] = '0'
            index += cast(int) precision;
        } else if (i < cast(u32) MIN_BLOCK_2[idx]) {
            i = cast(u32) MIN_BLOCK_2[idx];
            for j in 0..<9*i do buffer[index + cast(int) j] = '0'
            index += cast(int) (9 * i);
        }
        for ; i < blocks; i += 1 {
            j: i32 = ADDITIONAL_BITS_2 + (-e2 - 16 * idx);
            p: u32 = cast(u32) POW10_OFFSET_2[idx] + i - cast(u32) MIN_BLOCK_2[idx];
            if (p >= cast(u32) POW10_OFFSET_2[idx + 1]) {
                // If the remaining digits are all 0, then we might as well use memset.
                // No rounding required in this case.
                fill: u32 = precision - 9 * i;
                for ii in 0..<fill do buffer[index + cast(int) ii] = '0'
                index += cast(int) fill;
                break;
            }
            // Temporary: j is usually around 128, and by shifting a bit, we push it to 128 or above, which is
            // a slightly faster code path in mulShift_mod1e9. Instead, we can just increase the multipliers.
            digits: u32 = mulShift_mod1e9(m2 << 8, cast([^]u64) &POW10_SPLIT_2[p], j + 8);
            if (i < blocks - 1) {
                append_nine_digits(digits, buffer[index:]);
                index += 9;
            } else {
                maximum: u32 = precision - 9 * i;
                lastDigit: u32 = 0;
                for k: u32 = 0; k < 9 - maximum; k += 1 {
                    lastDigit = digits % 10;
                    digits /= 10;
                }
                if (lastDigit != 5) {
                    roundUp = cast(int) (lastDigit > 5);
                } else {
                    // Is m * 10^(additionalDigits + 1) / 2^(-e2) integer?
                    requiredTwos: i32 = -e2 - cast(i32) precision - 1;
                    trailingZeros: bool = requiredTwos <= 0 || (requiredTwos < 60 && multipleOfPowerOf2(m2, cast(u32) requiredTwos));
                    roundUp = trailingZeros ? 2 : 1;
                }
                if (maximum > 0) {
                    append_c_digits(maximum, digits, buffer[index:]);
                    index += cast(int) maximum;
                }
                break;
            }
        }
        if (roundUp != 0) {
            roundIndex: int = index;
            dotIndex: int = 0; // '.' can't be located at index 0
            for {
                roundIndex -= 1;
                c: u8 = --- ;
                condition := roundIndex == -1
                if !condition {
                    c = buffer[roundIndex]
                    condition = c == '-'
                }
                if condition {
                    buffer[roundIndex + 1] = '1';
                    if (dotIndex > 0) {
                        buffer[dotIndex] = '0';
                        buffer[dotIndex + 1] = '.';
                    }
                    buffer[index] = '0';
                    index += 1
                    break;
                }
                if (c == '.') {
                    dotIndex = roundIndex;
                    continue;
                } else if (c == '9') {
                    buffer[roundIndex] = '0';
                    roundUp = 1;
                    continue;
                } else {
                    if (roundUp == 2 && c % 2 == 0) {
                        break;
                    }
                    buffer[roundIndex] = c + 1;
                    break;
                }
            }
        }
    } else {
        for i in 0..<precision do buffer[index + cast(int) i] = '0'
        index += cast(int) precision;
    }
    
    return transmute(string) buffer[:index];
}

d2exp :: proc (d: f64, precision: u32, allocator := context.allocator) -> (result: string) {
    buffer: []u8 = make([]u8, 2000, allocator);
    result = d2exp_buffered(d, precision, buffer);
    return result;
}

d2exp_buffered :: proc (d: f64, precision: u32, buffer: []u8) -> string {
    precision := precision
    bits: u64 = double_to_bits(d);
    
    // Decode bits into sign, mantissa, and exponent.
    ieeeSign: bool = ((bits >> (DOUBLE_MANTISSA_BITS + DOUBLE_EXPONENT_BITS)) & 1) != 0;
    ieeeMantissa: u64 = bits & ((1 << DOUBLE_MANTISSA_BITS) - 1);
    ieeeExponent: u32 = cast(u32) ((bits >> DOUBLE_MANTISSA_BITS) & ((1 << DOUBLE_EXPONENT_BITS) - 1));
    
    // Case distinction; exit early for the easy cases.
    if (ieeeExponent == ((1 << DOUBLE_EXPONENT_BITS) - 1)) {
        index := copy_special_str_printf(buffer, ieeeSign, ieeeMantissa);
        return transmute(string) buffer[:index];
    }
    if (ieeeExponent == 0 && ieeeMantissa == 0) {
        index: int = 0;
        if (ieeeSign) {
            buffer[index] = '-';
            index += 1
        }
        buffer[index] = '0';
        index += 1
        if (precision > 0) {
            buffer[index] = '.';
            index += 1
            for i in 0..<precision do buffer[index + cast(int) i] = '0'
            index += cast(int) precision;
        }
        copy(buffer[index:], "e+00");
        index += 4;
        return transmute(string) buffer[:index];
    }
    
    e2: i32 = ---;
    m2: u64 = ---;
    if (ieeeExponent == 0) {
        e2 = 1 - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS;
        m2 = ieeeMantissa;
    } else {
        e2 = cast(i32) ieeeExponent - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS;
        m2 = (1 << DOUBLE_MANTISSA_BITS) | ieeeMantissa;
    }
    
    printDecimalPoint: bool = precision > 0;
    precision += 1;
    index: int = 0;
    if (ieeeSign) {
        buffer[index] = '-';
        index += 1
    }
    digits: u32 = 0;
    printedDigits: u32 = 0;
    availableDigits: u32 = 0;
    exp: i32 = 0;
    if (e2 >= -52) {
        idx: u32 = e2 < 0 ? 0 : indexForExponent(cast(u32) e2);
        p10bits: u32 = pow10BitsForIndex(idx);
        len: i32 = cast(i32) lengthForIndex(idx);
        for i: i32 = len - 1; i >= 0; i-= 1 {
            j: u32 = p10bits - cast(u32) e2;
            // Temporary: j is usually around 128, and by shifting a bit, we push it to 128 or above, which is
            // a slightly faster code path in mulShift_mod1e9. Instead, we can just increase the multipliers.
            digits = mulShift_mod1e9(m2 << 8, cast([^]u64) &POW10_SPLIT[cast(i32) POW10_OFFSET[idx] + i], cast(i32) (j + 8));
            if (printedDigits != 0) {
                if (printedDigits + 9 > precision) {
                    availableDigits = 9;
                    break;
                }
                append_nine_digits(digits, buffer[index:]);
                index += 9;
                printedDigits += 9;
            } else if (digits != 0) {
                availableDigits = decimalLength9(digits);
                exp = i * 9 + cast(i32) availableDigits - 1;
                if (availableDigits > precision) {
                    break;
                }
                if (printDecimalPoint) {
                    append_d_digits(availableDigits, digits, buffer[index:]);
                    index += cast(int) availableDigits + 1; // +1 for decimal point
                } else {
                    buffer[index] = cast(u8) ('0' + digits);
                    index += 1
                }
                printedDigits = availableDigits;
                availableDigits = 0;
            }
        }
    }
    
    if (e2 < 0 && availableDigits == 0) {
        idx: i32 = -e2 / 16;
        for i: i32 = cast(i32) MIN_BLOCK_2[idx]; i < 200; i += 1 {
            j: i32 = ADDITIONAL_BITS_2 + (-e2 - 16 * idx);
            p: u32 = cast(u32) POW10_OFFSET_2[idx] + cast(u32) i - cast(u32) MIN_BLOCK_2[idx];
            // Temporary: j is usually around 128, and by shifting a bit, we push it to 128 or above, which is
            // a slightly faster code path in mulShift_mod1e9. Instead, we can just increase the multipliers.
            digits = (p >= cast(u32) POW10_OFFSET_2[idx + 1]) ? 0 : mulShift_mod1e9(m2 << 8, cast([^]u64) &POW10_SPLIT_2[p], j + 8);
            if (printedDigits != 0) {
                if (printedDigits + 9 > precision) {
                    availableDigits = 9;
                    break;
                }
                append_nine_digits(digits, buffer[index:]);
                index += 9;
                printedDigits += 9;
            } else if (digits != 0) {
                availableDigits = decimalLength9(digits);
                exp = -(i + 1) * 9 + cast(i32) availableDigits - 1;
                if (availableDigits > precision) {
                    break;
                }
                if (printDecimalPoint) {
                    append_d_digits(availableDigits, digits, buffer[index:]);
                    index += cast(int) availableDigits + 1; // +1 for decimal point
                } else {
                    buffer[index] = cast(u8) ('0' + digits);
                    index += 1
                }
                printedDigits = availableDigits;
                availableDigits = 0;
            }
        }
    }
    
    maximum: u32 = precision - printedDigits;
    if (availableDigits == 0) {
        digits = 0;
    }
    lastDigit: u32 = 0;
    if (availableDigits > maximum) {
        for k: u32 = 0; k < availableDigits - maximum; k += 1 {
            lastDigit = digits % 10;
            digits /= 10;
        }
    }
    // 0 = don't round up; 1 = round up unconditionally; 2 = round up if odd.
    roundUp: int = 0;
    if (lastDigit != 5) {
        roundUp = cast(int) (lastDigit > 5);
    } else {
        // Is m * 2^e2 * 10^(precision + 1 - exp) integer?
        // precision was already increased by 1, so we don't need to write + 1 here.
        rexp: i32 = cast(i32) precision - exp;
        requiredTwos: i32 = -e2 - rexp;
        trailingZeros: bool = requiredTwos <= 0 || (requiredTwos < 60 && multipleOfPowerOf2(m2, cast(u32) requiredTwos));
        if (rexp < 0) {
            requiredFives: i32 = -rexp;
            trailingZeros = trailingZeros && multipleOfPowerOf5(m2, cast(u32) requiredFives);
        }
        roundUp = trailingZeros ? 2 : 1;
    }
    if (printedDigits != 0) {
        if (digits == 0) {
            for i in 0..<maximum do buffer[index + cast(int) i] = '0'
        } else {
            append_c_digits(maximum, digits, buffer[index:]);
        }
        index += cast(int) maximum;
    } else {
        if (printDecimalPoint) {
            append_d_digits(maximum, digits, buffer[index:]);
            index += cast(int) maximum + 1; // +1 for decimal point
        } else {
            buffer[index] = cast(u8) ('0' + digits);
            index += 1
        }
    }
    if (roundUp != 0) {
        roundIndex: int = index;
        for {
            roundIndex -= 1;
            c: u8 = ---;
            condition := roundIndex == -1
            if !condition {
                c = buffer[roundIndex]
                condition = c == '-'
            }
            if condition {
                buffer[roundIndex + 1] = '1';
                exp += 1;
                break;
            }
            if (c == '.') {
                continue;
            } else if (c == '9') {
                buffer[roundIndex] = '0';
                roundUp = 1;
                continue;
            } else {
                if (roundUp == 2 && c % 2 == 0) {
                    break;
                }
                buffer[roundIndex] = c + 1;
                break;
            }
        }
    }
    buffer[index] = 'e';
    index += 1
    if (exp < 0) {
        buffer[index] = '-';
        index += 1
        exp = -exp;
    } else {
        buffer[index] = '+';
        index += 1
    }
    
    if (exp >= 100) {
        c: i32 = exp % 10;
        buffer[index + 0] = DIGIT_TABLE[2 * (exp / 10) + 0]
        buffer[index + 1] = DIGIT_TABLE[2 * (exp / 10) + 1]
        buffer[index + 2] = cast(u8) ('0' + c);
        index += 3;
    } else {
        buffer[index + 0] = DIGIT_TABLE[2 * exp + 0]
        buffer[index + 1] = DIGIT_TABLE[2 * exp + 1]
        index += 2;
    }
    
    return transmute(string) buffer[:index];
}

////////////////////////////////////////////////
// Licenses

/* 

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

*/

/* 

Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.

*/