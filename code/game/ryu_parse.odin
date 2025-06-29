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
package game

@(common="file")

import "base:intrinsics"
////////////////////////////////////////////////
// ryu_parse.h

Status :: enum {
    SUCCESS, 
    INPUT_TOO_SHORT,
    INPUT_TOO_LONG,
    MALFORMED_INPUT,
}

////////////////////////////////////////////////
// s2d.c

// @todo(viktor): 
when RYU_OPTIMIZE_SIZE {
    // #include "ryu/d2s_small_table.h"
} else {
    // #include "ryu/d2s_full_table.h"
}

DOUBLE_EXPONENT_BIAS :: 1023

floor_log2_u64 :: proc (value: u64) -> u32 {
    return cast(u32) (63 - intrinsics.count_leading_zeros(value));
}

// The max function is already defined on Windows.
max32 :: proc (a: i32, b: i32) -> i32 {
    return a < b ? b : a;
}

int64Bits2Double :: proc (bits: u64) -> f64 {
    f: f64 = transmute(f64) bits;
    return f;
}

s2d_n :: proc ( buffer: []u8, len: int, result: ^f64) -> Status {
    if (len == 0) {
        return .INPUT_TOO_SHORT;
    }
    m10digits: int = 0;
    e10digits: int = 0;
    dotIndex: int = len;
    eIndex: int = len;
    m10: u64 = 0;
    e10: i32 = 0;
    signedM: bool = false;
    signedE: bool = false;
    i: int = 0;
    if (buffer[i] == '-') {
        signedM = true;
        i += 1;
    }
    for ; i < len; i+=1 {
        c: u8 = buffer[i];
        if (c == '.') {
            if (dotIndex != len) {
                return .MALFORMED_INPUT;
            }
            dotIndex = i;
            continue;
        }
        if ((c < '0') || (c > '9')) {
            break;
        }
        if (m10digits >= 17) {
            return .INPUT_TOO_LONG;
        }
        m10 = 10 * m10 + cast(u64) (c - '0');
        if (m10 != 0) {
            m10digits+=1;
        }
    }
    if (i < len && ((buffer[i] == 'e') || (buffer[i] == 'E'))) {
        eIndex = i;
        i+=1;
        if (i < len && ((buffer[i] == '-') || (buffer[i] == '+'))) {
            signedE = buffer[i] == '-';
            i+=1;
        }
        for ; i < len; i+=1 {
            c: u8 = buffer[i];
            if ((c < '0') || (c > '9')) {
                return .MALFORMED_INPUT;
            }
            if (e10digits > 3) {
                // TODO: Be more lenient. Return +/-Infinity or +/-0 instead.
                return .INPUT_TOO_LONG;
            }
            e10 = 10 * e10 + cast(i32) (c - '0');
            if (e10 != 0) {
                e10digits+=1;
            }
        }
    }
    if (i < len) {
        return .MALFORMED_INPUT;
    }
    if (signedE) {
        e10 = -e10;
    }
    e10 -= cast(i32) (dotIndex < eIndex ? eIndex - dotIndex - 1 : 0);
    if (m10 == 0) {
        result ^= signedM ? -0.0 : 0.0;
        return .SUCCESS;
    }
    
    if ((cast(i32) m10digits + e10 <= -324) || (m10 == 0)) {
        // Number is less than 1e-324, which should be rounded down to 0; return +/-0.0.
        ieee: u64 = (cast(u64) signedM) << (DOUBLE_EXPONENT_BITS + DOUBLE_MANTISSA_BITS);
        result ^= int64Bits2Double(ieee);
        return .SUCCESS;
    }
    if (cast(i32) m10digits + e10 >= 310) {
        // Number is larger than 1e+309, which should be rounded to +/-Infinity.
        ieee: u64 = ((cast(u64) signedM) << (DOUBLE_EXPONENT_BITS + DOUBLE_MANTISSA_BITS)) | (0x7ff << DOUBLE_MANTISSA_BITS);
        result ^= int64Bits2Double(ieee);
        return .SUCCESS;
    }
    
    // Convert to binary f32 m2 * 2^e2, while retaining information about whether the conversion
    // was exact (trailingZeros).
    e2: i32 = ---;
    m2: u64 = ---;
    trailingZeros: bool = ---;
    if (e10 >= 0) {
        // The length of m * 10^e in bits is:
        //   log2(m10 * 10^e10) = log2(m10) + e10 log2(10) = log2(m10) + e10 + e10 * log2(5)
        //
        // We want to compute the DOUBLE_MANTISSA_BITS + 1 top-most bits (+1 for the implicit leading
        // one in IEEE format). We therefore choose a binary output exponent of
        //   log2(m10 * 10^e10) - (DOUBLE_MANTISSA_BITS + 1).
        //
        // We use floor(log2(5^e10)) so that we get at least this many bits; better to
        // have an additional bit than to not have enough bits.
        e2 = cast(i32) floor_log2(m10) + e10 + log2pow5(e10) - (DOUBLE_MANTISSA_BITS + 1);
        
        // We now compute [m10 * 10^e10 / 2^e2] = [m10 * 5^e10 / 2^(e2-e10)].
        // To that end, we use the DOUBLE_POW5_SPLIT table.
        j: int = cast(int) (e2 - e10 - ceil_log2pow5(e10) + DOUBLE_POW5_BITCOUNT);
        assert(j >= 0);
        when RYU_OPTIMIZE_SIZE {
            pow5: [2]u64 = ---;
            double_computePow5(e10, pow5);
            m2 = mulShift64(m10, pow5, j);
        } else {
            assert(e10 < DOUBLE_POW5_TABLE_SIZE);
            m2 = mulShift64(m10, cast([^]u64) &DOUBLE_POW5_SPLIT[e10], cast(i32) j);
        }
        // We also compute if the result is exact, i.e.,
        //   [m10 * 10^e10 / 2^e2] == m10 * 10^e10 / 2^e2.
        // This can only be the case if 2^e2 divides m10 * 10^e10, which in turn requires that the
        // largest power of 2 that divides m10 + e10 is greater than e2. If e2 is less than e10, then
        // the result must be exact. Otherwise we use the existing multipleOfPowerOf2 function.
        trailingZeros = e2 < e10 || (e2 - e10 < 64 && multipleOfPowerOf2(m10, cast(u32) (e2 - e10)));
    } else {
        e2 = cast(i32) floor_log2(m10) + e10 - ceil_log2pow5(-e10) - (DOUBLE_MANTISSA_BITS + 1);
        j: int = cast(int) (e2 - e10 + ceil_log2pow5(-e10) - 1 + DOUBLE_POW5_INV_BITCOUNT);
        when RYU_OPTIMIZE_SIZE {
            pow5: [2]u64;
            double_computeInvPow5(-e10, pow5);
            m2 = mulShift64(m10, pow5, j);
        } else {
            assert(-e10 < DOUBLE_POW5_INV_TABLE_SIZE);
            m2 = mulShift64(m10, cast([^]u64) &DOUBLE_POW5_INV_SPLIT[-e10], cast(i32) j);
        }
        trailingZeros = multipleOfPowerOf5(m10, cast(u32) -e10);
    }
    
    // Compute the final IEEE exponent.
    ieee_e2: u32 = max(0, cast(u32) e2 + DOUBLE_EXPONENT_BIAS + floor_log2(m2));
    
    if (ieee_e2 > 0x7fe) {
        // Final IEEE exponent is larger than the maximum representable; return +/-Infinity.
        ieee: u64 = ((cast(u64) signedM) << (DOUBLE_EXPONENT_BITS + DOUBLE_MANTISSA_BITS)) | (0x7ff << DOUBLE_MANTISSA_BITS);
        result ^= int64Bits2Double(ieee);
        return .SUCCESS;
    }
    
    // We need to figure out how much we need to shift m2. The tricky part is that we need to take
    // the final IEEE exponent into account, so we need to reverse the bias and also special-case
    // the value 0.
    shift: i32 = cast(i32) (ieee_e2 == 0 ? 1 : ieee_e2) - e2 - DOUBLE_EXPONENT_BIAS - DOUBLE_MANTISSA_BITS;
    assert(shift >= 0);
    // We need to round up if the exact value is more than 0.5 above the value we computed. That's
    // equivalent to checking if the last removed bit was 1 and either the value was not just
    // trailing zeros or the result would otherwise be odd.
    //
    // We need to update trailingZeros given that we have the exact output exponent ieee_e2 now.
    trailingZeros &= (m2 & ((1 << cast(u32) (shift - 1)) - 1)) == 0;
    lastRemovedBit: u64 = (m2 >> cast(u32) (shift - 1)) & 1;
    roundUp: bool = (lastRemovedBit != 0) && (!trailingZeros || (((m2 >> cast(u32) shift) & 1) != 0));
    
    ieee_m2: u64 = (m2 >> cast(u32) shift) + cast(u64) roundUp;
    assert(ieee_m2 <= (1 << (DOUBLE_MANTISSA_BITS + 1)));
    ieee_m2 &= (1 << DOUBLE_MANTISSA_BITS) - 1;
    if (ieee_m2 == 0 && roundUp) {
        // Due to how the IEEE represents +/-Infinity, we don't need to check for overflow here.
        ieee_e2+=1;
    }
    
    ieee: u64 = ((((cast(u64) signedM) << DOUBLE_EXPONENT_BITS) | cast(u64)ieee_e2) << DOUBLE_MANTISSA_BITS) | ieee_m2;
    result ^= int64Bits2Double(ieee);
    return .SUCCESS;
}

s2d :: proc (buffer: string) -> (f64) {
    result: f64
    status := s2d_n(transmute([]u8) buffer, len(buffer), &result);
    return result
}


////////////////////////////////////////////////
// s2f.c

FLOAT_EXPONENT_BIAS :: 127

floor_log2 :: proc { floor_log2_u32, floor_log2_u64 }
floor_log2_u32 :: proc (value: u32) -> u32 {
    return 31 - intrinsics.count_leading_zeros(value);
}

int32Bits2Float :: proc (bits: u32) -> f32 {
    f: f32 = transmute(f32) bits;
    return f;
}

s2f_n :: proc (buffer: []u8, len: int, result: ^f32) -> Status {
    if (len == 0) {
        return .INPUT_TOO_SHORT;
    }
    m10digits: int = 0;
    e10digits: int = 0;
    dotIndex: int = len;
    eIndex: int = len;
    m10: u32 = 0;
    e10: i32 = 0;
    signedM: bool = false;
    signedE: bool = false;
    i: int = 0;
    if (buffer[i] == '-') {
        signedM = true;
        i+=1;
    }
    for ;i < len; i+=1 {
        c: u8 = buffer[i];
        if (c == '.') {
            if (dotIndex != len) {
                return .MALFORMED_INPUT;
            }
            dotIndex = i;
            continue;
        }
        if ((c < '0') || (c > '9')) {
            break;
        }
        if (m10digits >= 9) {
            return .INPUT_TOO_LONG;
        }
        m10 = 10 * m10 + cast(u32) (c - '0');
        if (m10 != 0) {
            m10digits+=1;
        }
    }
    if (i < len && ((buffer[i] == 'e') || (buffer[i] == 'E'))) {
        eIndex = i;
        i+=1;
        if (i < len && ((buffer[i] == '-') || (buffer[i] == '+'))) {
            signedE = buffer[i] == '-';
            i+=1;
        }
        for ; i < len; i+=1 {
            c: u8 = buffer[i];
            if ((c < '0') || (c > '9')) {
                return .MALFORMED_INPUT;
            }
            if (e10digits > 3) {
                // TODO: Be more lenient. Return +/-Infinity or +/-0 instead.
                return .INPUT_TOO_LONG;
            }
            e10 = 10 * e10 + cast(i32) (c - '0');
            if (e10 != 0) {
                e10digits+=1;
            }
        }
    }
    if (i < len) {
        return .MALFORMED_INPUT;
    }
    if (signedE) {
        e10 = -e10;
    }
    e10 -= cast(i32) (dotIndex < eIndex ? eIndex - dotIndex - 1 : 0);
    if (m10 == 0) {
        result ^= signedM ? -0. : 0.;
        return .SUCCESS;
    }
    
    if ((cast(i32) m10digits + e10 <= -46) || (m10 == 0)) {
        // Number is less than 1e-46, which should be rounded down to 0; return +/-0.0.
        ieee: u32 = (cast(u32) signedM) << (FLOAT_EXPONENT_BITS + FLOAT_MANTISSA_BITS);
        result ^= int32Bits2Float(ieee);
        return .SUCCESS;
    }
    if (cast(i32) m10digits + e10 >= 40) {
        // Number is larger than 1e+39, which should be rounded to +/-Infinity.
        ieee: u32 = ((cast(u32) signedM) << (FLOAT_EXPONENT_BITS + FLOAT_MANTISSA_BITS)) | (0xff << FLOAT_MANTISSA_BITS);
        result ^= int32Bits2Float(ieee);
        return .SUCCESS;
    }
    
    // Convert to binary f32 m2 * 2^e2, while retaining information about whether the conversion
    // was exact (trailingZeros).
    e2: i32 = ---;
    m2: u32 = ---;
    trailingZeros: bool = ---;
    if (e10 >= 0) {
        // The length of m * 10^e in bits is:
        //   log2(m10 * 10^e10) = log2(m10) + e10 log2(10) = log2(m10) + e10 + e10 * log2(5)
        //
        // We want to compute the FLOAT_MANTISSA_BITS + 1 top-most bits (+1 for the implicit leading
        // one in IEEE format). We therefore choose a binary output exponent of
        //   log2(m10 * 10^e10) - (FLOAT_MANTISSA_BITS + 1).
        //
        // We use floor(log2(5^e10)) so that we get at least this many bits; better to
        // have an additional bit than to not have enough bits.
        e2 = cast(i32) floor_log2(m10) + e10 + log2pow5(e10) - (FLOAT_MANTISSA_BITS + 1);
        
        // We now compute [m10 * 10^e10 / 2^e2] = [m10 * 5^e10 / 2^(e2-e10)].
        // To that end, we use the FLOAT_POW5_SPLIT table.
        j: int = cast(int) (e2 - e10 - ceil_log2pow5(e10) + FLOAT_POW5_BITCOUNT);
        assert(j >= 0);
        m2 = mulPow5divPow2(m10, cast(u32) e10, cast(i32) j);
        
        // We also compute if the result is exact, i.e.,
        //   [m10 * 10^e10 / 2^e2] == m10 * 10^e10 / 2^e2.
        // This can only be the case if 2^e2 divides m10 * 10^e10, which in turn requires that the
        // largest power of 2 that divides m10 + e10 is greater than e2. If e2 is less than e10, then
        // the result must be exact. Otherwise we use the existing multipleOfPowerOf2 function.
        trailingZeros = e2 < e10 || (e2 - e10 < 32 && multipleOfPowerOf2_32(m10, cast(u32) (e2 - e10)));
    } else {
        e2 = cast(i32) floor_log2(m10) + e10 - ceil_log2pow5(-e10) - (FLOAT_MANTISSA_BITS + 1);
        
        // We now compute [m10 * 10^e10 / 2^e2] = [m10 / (5^(-e10) 2^(e2-e10))].
        j: int = cast(int) (e2 - e10 + ceil_log2pow5(-e10) - 1 + FLOAT_POW5_INV_BITCOUNT);
        m2 = mulPow5InvDivPow2(m10, cast(u32) -e10, cast(i32) j);
        
        // We also compute if the result is exact, i.e.,
        //   [m10 / (5^(-e10) 2^(e2-e10))] == m10 / (5^(-e10) 2^(e2-e10))
        //
        // If e2-e10 >= 0, we need to check whether (5^(-e10) 2^(e2-e10)) divides m10, which is the
        // case iff pow5(m10) >= -e10 AND pow2(m10) >= e2-e10.
        //
        // If e2-e10 < 0, we have actually computed [m10 * 2^(e10 e2) / 5^(-e10)] above,
        // and we need to check whether 5^(-e10) divides (m10 * 2^(e10-e2)), which is the case iff
        // pow5(m10 * 2^(e10-e2)) = pow5(m10) >= -e10.
        trailingZeros = (e2 < e10 || (e2 - e10 < 32 && multipleOfPowerOf2_32(m10, cast(u32) (e2 - e10)))) && multipleOfPowerOf5_32(m10, cast(u32) (-e10));
    }
    
    // Compute the final IEEE exponent.
    ieee_e2: u32 = max(0, cast(u32) e2 + FLOAT_EXPONENT_BIAS + floor_log2(m2));
    
    if (ieee_e2 > 0xfe) {
        // Final IEEE exponent is larger than the maximum representable; return +/-Infinity.
        ieee: u32 = ((cast(u32) signedM) << (FLOAT_EXPONENT_BITS + FLOAT_MANTISSA_BITS)) | (0xff << FLOAT_MANTISSA_BITS);
        result ^= int32Bits2Float(ieee);
        return .SUCCESS;
    }
    
    // We need to figure out how much we need to shift m2. The tricky part is that we need to take
    // the final IEEE exponent into account, so we need to reverse the bias and also special-case
    // the value 0.
    shift: i32 = cast(i32) (ieee_e2 == 0 ? 1 : ieee_e2) - e2 - FLOAT_EXPONENT_BIAS - FLOAT_MANTISSA_BITS;
    assert(shift >= 0);
    
    // We need to round up if the exact value is more than 0.5 above the value we computed. That's
    // equivalent to checking if the last removed bit was 1 and either the value was not just
    // trailing zeros or the result would otherwise be odd.
    //
    // We need to update trailingZeros given that we have the exact output exponent ieee_e2 now.
    trailingZeros &= (m2 & ((1 << cast(u32) (shift - 1)) - 1)) == 0;
    lastRemovedBit: u32 = (m2 >> cast(u32) (shift - 1)) & 1;
    roundUp: bool = (lastRemovedBit != 0) && (!trailingZeros || (((m2 >> cast(u32) shift) & 1) != 0));
    
    ieee_m2: u32 = (m2 >> cast(u32) shift) + cast(u32) roundUp;
    assert(ieee_m2 <= (1 << (FLOAT_MANTISSA_BITS + 1)));
    ieee_m2 &= (1 << FLOAT_MANTISSA_BITS) - 1;
    if (ieee_m2 == 0 && roundUp) {
        // Rounding up may overflow the mantissa.
        // In this case we move a trailing zero of the mantissa into the exponent.
        // Due to how the IEEE represents +/-Infinity, we don't need to check for overflow here.
        ieee_e2+=1;
    }
    ieee: u32 = ((((cast(u32) signedM) << FLOAT_EXPONENT_BITS) | ieee_e2) << FLOAT_MANTISSA_BITS) | ieee_m2;
    result ^= int32Bits2Float(ieee);
    return .SUCCESS;
}

s2f :: proc (buffer: []u8, result: ^f32) -> Status {
    return s2f_n(buffer, len(buffer), result);
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