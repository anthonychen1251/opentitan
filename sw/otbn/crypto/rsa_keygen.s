/* Copyright lowRISC contributors (OpenTitan project). */
/* Licensed under the Apache License, Version 2.0, see LICENSE for details. */
/* SPDX-License-Identifier: Apache-2.0 */

/* Public interface. */
.globl rsa_keygen
.globl rsa_key_from_cofactor

/* Exposed for testing purposes only. */
.globl relprime_f4
.globl check_p
.globl check_q
.globl modinv_f4
.globl relprime_small_primes

/**
 * Generate a random RSA key pair.
 *
 * The public key is the pair (n, e), where n is the modulus and e is the
 * public exponent. and the private key is the pair (n, d), where n is the same
 * modulus as in the public key and d is the private exponent.
 *
 * For the official specification, see FIPS 186-5 section A.1.3. For the
 * purposes of this implementation, the RSA public exponent e is always 65537
 * (aka the Fermat number "F4", 2^16 + 1).
 *
 * This implementation supports only RSA-2048, RSA-3072, and RSA-4096. Do not
 * use with other RSA sizes; in particular, using this implementation for
 * RSA-1024 would require more primality test rounds.
 *
 * This implementation also takes some inspiration from BoringSSL's RSA key
 * generation:
 * https://boringssl.googlesource.com/boringssl/+/dcabfe2d8940529a69e007660fa7bf6c15954ecc/crypto/fipsmodule/rsa/rsa_impl.c#1162
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x30: plen, number of 256-bit limbs for p and q
 * @param[in]  w31: all-zero
 * @param[out] dmem[rsa_n..rsa_n+(plen*2*32)] RSA public key modulus (n)
 * @param[out] dmem[rsa_d..rsa_d+(plen*2*32)] RSA private exponent (d)
 *
 * clobbered registers: x2 to x26, x31,
 *                      w2, w3, w4..w[4+(plen-1)], w20 to w30
 * clobbered flag groups: FG0, FG1
 */
rsa_keygen:
  /* Compute (<# of limbs> - 1), a helpful constant for later computations.
       x31 <= x30 - 1 */
  addi     x2, x0, 1
  sub      x31, x30, x2

  /* Initialize wide-register pointers.
       x20 <= 20
       x21 <= 21 */
  li       x20, 20
  li       x21, 21

  /* Generate the first prime, p.
       dmem[rsa_p..rsa_p+(plen*32)] <= p */
  jal      x1, generate_p
  /* Generate the second prime, q.
       dmem[rsa_q..rsa_q+(plen*32)] <= q */
  jal      x1, generate_q

  /* Multiply p and q to get the public modulus n.
       dmem[rsa_n..rsa_n+(plen*2*32)] <= p * q */
  la       x10, rsa_p
  la       x11, rsa_q
  la       x12, rsa_n
  jal      x1, bignum_mul

  /* Derive the private exponent d from p and q.
       x2 <= zero if d is OK, otherwise nonzero */
  jal      x1, derive_d

  /* Check that d is large enough (tail-call). If d is not large enough,
     then `check_d` will restart the key-generation process. */
  jal      x0, check_d

/**
 * Derive the private RSA exponent d.
 *
 * Returns d = (65537^-1) mod LCM(p-1, q-1).
 *
 * This function overwrites p and q, and requires that they are continuous in
 * memory. Specifically, it expects to be able to use 512 bytes of space
 * following the label `rsa_pq`.
 *
 * Important: This routine uses `rsa_cofactor` as a second 512-byte work buffer
 * and clobbers the contents.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in] dmem[rsa_p..rsa_p+(plen*32)]: first prime p
 * @param[in] dmem[rsa_q..rsa_q+(plen*32)]: second prime q
 * @param[in]  x20: 20, constant
 * @param[in]  x21: 21, constant
 * @param[in]  x30: plen, number of 256-bit limbs for p and q
 * @param[in]  w31: all-zero
 * @param[out] dmem[rsa_d..rsa_d+(plen*2*32)]: result, private exponent d
 *
 * clobbered registers: x2 to x8, x10 to x15, x20 to x26, x31, w20 to w28
 * clobbered flag groups: FG0, FG1
 */
derive_d:
  /* Load pointers to p, q, and the result buffer. */
  la       x10, rsa_p
  la       x11, rsa_q

  /* Subtract 1 from p in-place (no carry from lowest limb since p is odd).
       dmem[rsa_p..rsa_p+(plen*32)] <= p - 1 */
  bn.lid   x20, 0(x10)
  bn.subi  w20, w20, 1
  bn.sid   x20, 0(x10)

  /* Subtract 1 from q in-place (no carry from lowest limb since p is odd).
       dmem[rsa_q..rsa_q+(plen*32)] <= q - 1 */
  bn.lid   x20, 0(x11)
  bn.subi  w20, w20, 1
  bn.sid   x20, 0(x11)

  /* Compute the LCM of (p-1) and (q-1) and store in the scratchpad.
       dmem[tmp_scratchpad] <= LCM(p-1,q-1) */
  la       x12, tmp_scratchpad
  jal      x1, lcm

  /* Update the number of limbs for modinv.
       x30 <= plen*2 */
  add      x30, x30, x30

  /* Compute d = (65537^-1) mod LCM(p-1,q-1). The modular inverse
     routine requires two working buffers, which we construct from
     `rsa_cofactor` and the required-contiguous `rsa_p` and `rsa_q` buffers.
       dmem[rsa_d..rsa_d+(plen*2*32)] <= (65537^-1) mod dmem[x12..x12+(n*2*32)] */
  la       x12, tmp_scratchpad
  la       x13, rsa_d
  la       x14, rsa_cofactor
  la       x15, rsa_pq
  jal      x1, modinv_f4

  /* Reset the limb count.
       x30 <= (plen*2) >> 1 = n */
  srli     x30, x30, 1
  ret

/**
 * Check the private RSA exponent d.
 *
 * Calls `rsa_keygen` if d is too small, otherwise returns. Designed to be
 * tail-called by `rsa_keygen`.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x20: 20, constant
 * @param[in]  x30: plen, number of 256-bit limbs for p and q
 * @param[in]  w31: all-zero
 * @param[out] dmem[rsa_d..rsa_d+(plen*2*32)]: result, private exponent d
 *
 * clobbered registers: x2, x3, w20, w23
 * clobbered flag groups: FG0, FG1
 */
check_d:
  /* Get a pointer to the second half of d.
       x3 <= rsa_d + plen*32 */
  slli     x2, x30, 5
  la       x3, rsa_d
  add      x3, x3, x2

  /* Check that d > 2^(plen*256), i.e. that the highest plen limbs are nonzero. We
     need to retry if it's too small (see FIPS 186-5 section A.1.1), although
     in practice this is unlikely. We do this by ORing the plen highest limbs.
       FG0.Z <= (d >> (plen*256)) == 0 */
  bn.mov   w23, w31
  loop     x30, 2
    /* w20 <= d[n+i] */
    bn.lid  x20, 0(x3++)
    /* w23 <= w23 | w20 */
    bn.or   w23, w23, w20

  /* Get the FG0.Z flag into a register.
       x2 <= CSRs[FG0] & 8 = FG0.Z << 3 */
  csrrs    x2, FG0, x0
  andi     x2, x2, 8

  /* If x2 != 0, then d is too small and we need to restart key generation from
     scratch. */
  bne      x2, x0, rsa_keygen

  ret

/**
 * Construct an RSA key pair from a modulus and cofactor.
 *
 * This routine does not check the validity of the RSA key pair; it does not
 * ensure that the factors are prime or check any other properties, simply
 * divides the modulus by the cofactor and derives the private exponent. The
 * only public exponent supported is e=65537.
 *
 * This routine will recompute the public modulus n after deriving the factors;
 * the caller may want to check that the value matches. If the modulus is not
 * in fact divisible by the cofactor, or the cofactor is much too small, it
 * will not match.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x30: plen, number of 256-bit limbs for p and q
 * @param[in]  w31: all-zero
 * @param[in] dmem[rsa_n..rsa_n+(plen*2*32)] RSA public key modulus (n)
 * @param[in] dmem[rsa_cofactor..rsa_cofactor+(plen*32)] Cofactor (p or q)
 * @param[out] dmem[rsa_n..rsa_n+(plen*2*32)] Recomputed public key modulus (n)
 * @param[out] dmem[rsa_d..rsa_d+(plen*2*32)] RSA private exponent (d)
 *
 * clobbered registers: x2 to x8, x10 to x15, x20 to x26, x31, w3, w20 to w28
 * clobbered flag groups: FG0, FG1
 */
rsa_key_from_cofactor:
  /* Initialize wide-register pointers.
       x20 <= 20
       x21 <= 21 */
  li       x20, 20
  li       x21, 21

  /* Get a pointer to the end of the cofactor.
       x2 <= rsa_cofactor + plen*32 */
  slli     x2, x30, 5
  la       x3, rsa_cofactor
  add      x2, x2, x3

  /* Set the second half of the cofactor buffer to zero, so the cofactor is the
     same size as the modulus for division.
      dmem[rsa_cofactor+plen*32..rsa_cofactor+plen*2*32] <= 0 */
  li       x3, 31
  loop     x30, 1
    bn.sid   x3, 0(x2++)

  /* Update the number of limbs for division.
       x30 <= plen*2 */
  add     x30, x30, x30

  /* Compute (n / cofactor) and store the result in `rsa_pq`. The quotient will
     only occupy the first half (`rsa_p`) if the input is valid.
       dmem[rsa_n..rsa_n+plen*2*32] <= n % cofactor
       dmem[rsa_pq..rsa_pq+plen*2*32] <= n / cofactor */
  la       x10, rsa_n
  la       x11, rsa_cofactor
  la       x12, rsa_pq
  jal      x1, div

  /* Reset the limb count.
       x30 <= (plen*2) >> 1 = n */
  srli     x30, x30, 1

  /* Copy the original cofactor into `rsa_q` and compute
     the private exponent.
      dmem[rsa_q..rsa_q+plen*32] <= dmem[rsa_cofactor..rsa_cofactor+plen*32] */
  la       x11, rsa_cofactor
  la       x2, rsa_q
  li       x3, 3
  loop     x30, 2
    bn.lid   x3, 0(x11++)
    bn.sid   x3, 0(x2++)

  /* Multiply p and q to get the public modulus n.
       dmem[rsa_n..rsa_n+(plen*2*32)] <= p * q */
  la       x10, rsa_p
  la       x11, rsa_q
  la       x12, rsa_n
  jal      x1, bignum_mul

  /* Derive the private exponent d from p and q (tail-call). */
  jal      x0, derive_d

/**
 * Compute the inverse of 65537 modulo a given number.
 *
 * Returns d such that (d*65537) = 1 mod m and 0 <= d < m.
 *
 * Requires that m is nonzero, and that GCD(m, 65537) = 1.
 *
 * This is a specialized version of binary extended GCD, as described in HAC
 * Algorithm 14.61 and implemented in constant time in BoringSSL here:
 *   https://boringssl.googlesource.com/boringssl/+/dcabfe2d8940529a69e007660fa7bf6c15954ecc/crypto/fipsmodule/bn/gcd_extra.c#170
 *
 * BoringSSL's version includes a few improvements beyond being constant-time,
 * such as avoiding signed integers. This modified algorithm has also been
 * proven mathematically correct in Coq, see:
 *   https://github.com/mit-plv/fiat-crypto/pull/333
 *
 * In pseudocode,the BoringSSL algorithm is:
 *   A, B, C, D = 1, 0, 0, 1
 *   u = x
 *   v = y
 *   // Loop invariants:
 *   //   A*x - B*y = u
 *   //   D*y - C*x = v
 *   //   gcd(u, v) = gcd(x, y)
 *   //   bitlen(u) + bitlen(v) <= i
 *   //   0 < u <= x
 *   //   0 <= v <= y
 *   //   0 <= A, C < y
 *   //   0 <= B, D <= x
 *   for i=bitlen(x) + bitlen(y)..1:
 *     if u and v both odd:
 *       if v < u:
 *         u = u - v
 *         A = (A + C) mod y
 *         B = (B + D) mod x
 *       else:
 *         v = v - u
 *         C = (A + C) mod y
 *         D = (B + D) mod x
 *     // At this point, the invariant holds and >= 1 of u and v is even
 *     if u is even:
 *       u >>= 1
 *       if (A[0] | B[0]):
 *         A = (A + y) / 2
 *         B = (B + x) / 2
 *       else:
 *         A >>= 1
 *         B >>= 1
 *     if v is even:
 *       v >>= 1
 *       if (C[0] | D[0]):
 *         C = (C + x) / 2
 *         D = (D + y) / 2
 *       else:
 *         C >>= 1
 *         D >>= 1
 *    // End of loop. Guarantees the invariant plus u = gcd(x,y).
 *
 * As described in HAC note 14.64, this algorithm computes a modular inverse
 * when gcd(x,y) = 1. Specifically, at termination, A = x^-1 mod y because:
 *   (A*x) mod y = (A*x - B*y) mod y = u mod y = 1
 *
 * Of course, all the if statements are implemented with constant-time selects.
 *
 * The fully specialized and constant-time version of the pseudocode is:
 *   A, C = 1, 0
 *   u = 65537
 *   v = m
 *   // Loop invariants:
 *   //   A*x - B*y = u
 *   //   D*y - C*x = v
 *   //   gcd(u, v) = gcd(x, y)
 *   //   bitlen(u) + bitlen(v) <= i
 *   //   gcd(u, v) = 1
 *   //   bitlen(u) + bitlen(v) <= i
 *   //   0 < u <= 65537
 *   //   0 <= v <= m
 *   //   0 <= A, C < m
 *   //   0 <= B,D < 65537
 *   for i=(bitlen(m) + bitlen(65537))..1:
 *     both_odd = u[0] & v[0]
 *     v_lt_u = v < u
 *     u = u - ((both_odd && v_lt_u) ? v : 0)
 *     v = v - ((both_odd && !v_lt_u) ? u : 0)
 *     ac = (A + C) mod m
 *     A = (both_odd && v_lt_u) ? ac : A
 *     C = (both_odd && !v_lt_u) ? ac : C
 *     bd = (B + D) mod 65537
 *     B = (both_odd && v_lt_u) ? bd : B
 *     D = (both_odd && !v_lt_u) ? bd : D
 *     u_even = !u[0]
 *     a_or_b_odd = A[0] | B[0]
 *     u = u_even ? u >> 1 : u
 *     A = (u_even && a_or_b_odd) ? (A + m) : A
 *     A = u_even ? (A >> 1) : A
 *     B = (u_even && a_or_b_odd) ? (B + 65537) : B
 *     B = u_even ? (B >> 1) : B
 *     v_even = !v[0]
 *     c_or_d_odd = C[0] | D[0]
 *     v = v_even ? v >> 1 : v
 *     C = (v_even && c_or_d_odd) ? (C + m) : C
 *     C = v_even ? (C >> 1) : C
 *     D = (u_even && c_or_d_odd) ? (D + 65537) : D
 *     D = u_even ? (D >> 1) : D
 *   if u != 1:
 *     FAIL("Not invertible")
 *   return A
 *
 * This routine runs in constant time.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x12: dptr_m, pointer to modulus m in DMEM (n limbs)
 * @param[in]  x13: dptr_A, pointer to result buffer in DMEM (n limbs)
 * @param[in]  x14: dptr_C, pointer to a temporary buffer in DMEM (n limbs)
 * @param[in]  x15: dptr_v, pointer to a temporary buffer in DMEM (n limbs)
 * @param[in]  x20: 20, constant
 * @param[in]  x21: 21, constant
 * @param[in]  x30: nlen, number of 256-bit limbs for modulus m and result d
 * @param[in]  w31: all-zero
 * @param[out] dmem[dptr_A..dptr_A+(plen*32)]: result, modular inverse d
 *
 * clobbered registers: MOD, x2 to x4, x31, w20 to w28
 * clobbered flag groups: FG0, FG1
 */
modinv_f4:
  /* Zero the intermediate buffers.
       dmem[dptr_A..dptr_A+(nlen*32)] <= 0
       dmem[dptr_C..dptr_C+(nlen*32)] <= 0 */
  li       x2, 31
  addi     x3, x13, 0
  addi     x4, x14, 0
  loop     x30, 2
    bn.sid   x2, 0(x3++)
    bn.sid   x2, 0(x4++)

  /* Set the lowest limb of A to 1.
       dmem[dptr_A] <= 1 */
  bn.addi  w20, w31, 1
  bn.sid   x20, 0(x13)

  /* Initialize B to 0.
       w27 <= 0 */
  bn.mov   w27, w31

  /* Initialize D to 1.
       w28 <= 1 */
  bn.addi  w28, w31, 1

  /* Copy the modulus to the buffer for v.
       dmem[dptr_v..dptr_v+(nlen*32)] <= m */
  addi     x3, x12, 0
  addi     x4, x15, 0
  loop     x30, 2
    bn.lid   x20, 0(x3++)
    bn.sid   x20, 0(x4++)

  /* Initialize u = F4.
       w22 <= (1 << 16) + 1 = 65537 */
  bn.addi  w23, w31, 1
  bn.add   w22, w23, w23 << 16

  /* MOD <= 65537 */
  bn.wsrw  MOD, w22

  /* Calculate number of loop iterations = bitlen(m) + bitlen(65537).
       x31 <= (x30 << 8) + 17 = 256*n + 17 */
  slli     x31, x30, 8
  addi     x31, x31, 17

  /* Main loop. */
  loop     x31, 120
    /* Load the least significant limb of v.
         w20 <= dmem[dptr_v] = v[255:0] */
    bn.lid   x20, 0(x15)

    /* Construct a flag that is 1 if both u and v are odd.
         FG1.L <= (w22 & w20)[0] = u[0] && v[0] */
    bn.and   w20, w22, w20, FG1

    /* Compare u and v.
         FG0.C <= v < u */
    bn.mov   w23, w22
    addi     x2, x15, 0
    loop     x30, 3
      /* w20 <= v[i] */
      bn.lid   x20, 0(x2++)
      /* FG0.C <= v[i] <? w23 + FG0.C */
      bn.cmpb  w20, w23
      /* Higher limbs of u are all zero; set w23 = 0 for next round. */
      bn.mov   w23, w31

    /* Capture FG0.C in a mask.
         w23 <= FG0.C ? 2^256 - 1 : 0 */
    bn.subb  w23, w31, w31

    /* Select a mask that is all 1s if we should subtract v from u.
         w24 <= FG1.L ? w23 : w31 = (u[0] && v[0] && v < u) ? 2^256 - 1 : 0 */
    bn.sel   w24, w23, w31, FG1.L

    /* Select a mask that is all 1s if we should subtract u from v.
         w25 <= FG1.L ? !w23 : w31 = (u[0] && v[0] && u <= v) ? 2^256 - 1 : 0 */
    bn.not   w23, w23
    bn.sel   w25, w23, w31, FG1.L

    /* Conditionally subtract v from u. If we do this subtraction, we know that
       v < u <= 65537, so we can use only one limb of v.
         w22 <= w22 - (dmem[dptr_v] & w24) */
    bn.lid   x20, 0(x15)
    bn.and   w20, w20, w24
    bn.sub   w22, w22, w20

    /* Conditionally subtract u from v.
         dmem[dptr_v..dptr_v+(nlen*32)] <= v - (u & w25) */
    bn.and   w23, w22, w25
    addi     x2, x15, 0
    loop     x30, 4
      /* w20 <= v[i] */
      bn.lid   x20, 0(x2)
      /* w20, FG0.C <= v[i] - w23 - FG0.C */
      bn.subb  w20, w20, w23
      /* v[i] <= w20 */
      bn.sid   x20, 0(x2++)
      /* Higher limbs of u are all zero; set w23 = 0 for next round. */
      bn.mov   w23, w31

    /* Calculate what we should add to B; D if we updated u in the previous
       steps (w24 == 2^256=1), otherwise 0.
         w20 <= (D & w24) */
    bn.and   w20, w28, w24

    /* Calculate what we should add to D; B if we updated v in the previous
       steps (w25 == 2^256=1), otherwise 0.
         w21 <= (B & w25) */
    bn.and   w21, w27, w25

    /* Update B.
         w27 <= (B + (D & w24)) mod 65537 */
    bn.addm  w27, w27, w20

    /* Update D.
         w27 <= (D + (B & w25)) mod 65537 */
    bn.addm  w28, w28, w21

    /* Clear flags for both groups. */
    bn.sub   w31, w31, w31, FG0
    bn.sub   w31, w31, w31, FG1

    /* Compare (A + C) to m.
         FG1.C <= A + C < m */
    addi     x2, x12, 0
    addi     x3, x13, 0
    addi     x4, x14, 0
    loop     x30, 5
      /* w20 <= A[i] */
      bn.lid   x20, 0(x3++)
      /* w21 <= C[i] */
      bn.lid   x21, 0(x4++)
      /* w23, FG0.C <= A[i] + C[i] + FG0.C */
      bn.addc  w23, w20, w21
      /* w20 <= m[i] */
      bn.lid   x20, 0(x2++)
      /* FG1.C <= w23 <? m[i] + FG1.C */
      bn.cmpb  w23, w20, FG1

    /* Capture FG1.C as a mask that is all 1s if we should subtract the modulus.
         w26 <= FG1.C ? 0 : 2^256 - 1 */
    bn.subb  w26, w31, w31, FG1
    bn.not   w26, w26

    /* Clear flags for both groups. */
    bn.sub   w31, w31, w31, FG0
    bn.sub   w31, w31, w31, FG1

    /* Update A if we updated u in the previous steps (w24 == 2^256-1). We
       additionally subtract the modulus if *both* w24,w26 == 2^256-1.
         dmem[dptr_A..dptr_A+(nlen*32)] <= (w24 == 2^256-1) ? (A + C) mod m : A */
    addi     x2, x12, 0
    addi     x3, x13, 0
    addi     x4, x14, 0
    loop     x30, 9
      /* w20 <= A[i] */
      bn.lid   x20, 0(x3)
      /* w21 <= C[i] */
      bn.lid   x21, 0(x4++)
      /* w21 <= C[i] & w24 */
      bn.and   w21, w21, w24
      /* w20, FG0.C <= w20 + w21 + FG0.C */
      bn.addc  w20, w20, w21
      /* w21 <= m[i] */
      bn.lid   x21, 0(x2++)
      /* w21 <= m[i] & w24 */
      bn.and   w21, w21, w24
      /* w21 <= m[i] & w24 & w26 */
      bn.and   w21, w21, w26
      /* w20, FG1.C <= w20 - w21 - FG1.C  */
      bn.subb  w20, w20, w21, FG1
      /* A[i] <= w20 */
      bn.sid   x20, 0(x3++)

    /* Update C if we updated v in the previous steps (w25 == 2^256-1). We
       additionally subtract the modulus if *both* w25,w26 == 2^256-1.
         dmem[dptr_C..dptr_C+(nlen*32)] <= (w25 == 2^256-1) ? (A + C) mod m : C */
    addi     x2, x12, 0
    addi     x3, x13, 0
    addi     x4, x14, 0
    loop     x30, 9
      /* w20 <= C[i] */
      bn.lid   x20, 0(x4)
      /* w21 <= A[i] */
      bn.lid   x21, 0(x3++)
      /* w21 <= A[i] & w25 */
      bn.and   w21, w21, w25
      /* w20, FG0.C <= w20 + w21 + FG0.C */
      bn.addc  w20, w20, w21
      /* w21 <= m[i] */
      bn.lid   x21, 0(x2++)
      /* w21 <= m[i] & w25 */
      bn.and   w21, w21, w25
      /* w21 <= m[i] & w25 & w26 */
      bn.and   w21, w21, w26
      /* w20, FG1.C <= w20 - w21 - FG1.C  */
      bn.subb  w20, w20, w21, FG1
      /* C[i] <= w20 */
      bn.sid   x20, 0(x4++)

    /* Get a flag that is set if u is odd.
         FG1.L <= u[0] */
    bn.or    w22, w22, w31, FG1

    /* Update u if it is even.
         w22 <= FG1.L ? w22 : w22 >> 1 */
    bn.rshi  w23, w31, w22 >> 1
    bn.sel   w22, w22, w23, FG1.L

    /* Create an all-ones mask.
         w23 <= 2^256 - 1 */
    bn.not   w23, w31

    /* Get a flag that is set if A or B is odd.
         FG0.L <= A[0] | B[0] */
    bn.lid   x20, 0(x13)
    bn.or    w20, w20, w27

    /* Select a mask for adding moduli to A and B (should do this if u is even
       and at least one of A and B is odd).
         w23 <= (!FG1.L && FG0.L) ? 2^256 - 1 : 0 */
    bn.sel   w23, w31, w23, FG1.L
    bn.sel   w23, w23, w31, FG0.L

    /* Conditionally add to B.
         w27 <= B + (65537 & w23) */
    bn.wsrr  w24, MOD
    bn.and   w24, w24, w23
    bn.add   w27, w27, w24

    /* Shift B if u is even.
         w27 <= FG1.L ? B : B >> 1 */
    bn.rshi  w24, w31, w27 >> 1
    bn.sel   w27, w27, w24, FG1.L

    /* Clear flags for group 0. */
    bn.sub   w31, w31, w31

    /* Conditionally add m to A.
         dmem[dptr_A..dptr_A+(nlen*32)] <= (!u[0] && (A[0] | B[0])) ? A + m : A */
    addi     x2, x12, 0
    addi     x3, x13, 0
    loop     x30, 5
      /* w20 <= A[i] */
      bn.lid   x20, 0(x3)
      /* w21 <= m[i] */
      bn.lid   x21, 0(x2++)
      /* w21 <= m[i] & w23 */
      bn.and   w21, w21, w23
      /* w20, FG0.C <= A[i] + (m[i] & w23) + FG0.C */
      bn.addc  w20, w20, w21
      /* A[i] <= w20 */
      bn.sid   x20, 0(x3++)

    /* Capture the final carry bit in a register to use as the MSB for the
       shift. */
    bn.addc  w23, w31, w31

    /* Shift A to the right 1 if FG1.L is unset.
         dmem[dptr_A..dptr_A+(nlen*32)] <= FG1.L ? A : A >> 1 */
    addi     x3, x13, 0
    jal      x1, bignum_rshift1_if_not_fg1L

    /* Get a flag that is set if v is odd.
         FG1.L <= v[0] */
    bn.lid   x20, 0(x15)
    bn.or    w20, w20, w31, FG1

    /* Shift v to the right 1 if FG1.L is unset.
         dmem[dptr_v..dptr_v+(nlen*32)] <= FG1.L ? v : v >> 1 */
    addi     x3, x15, 0
    bn.mov   w23, w31
    jal      x1, bignum_rshift1_if_not_fg1L

    /* Create an all-ones mask.
         w23 <= 2^256 - 1 */
    bn.not   w23, w31

    /* Get a flag that is set if C or D is odd.
         FG0.L <= C[0] | D[0] */
    bn.lid   x20, 0(x14)
    bn.or    w20, w20, w28

    /* Select a mask for adding moduli to C and D (should do this if v is even
       and at least one of C and D is odd).
         w23 <= (!FG1.L && FG0.L) ? 2^256 - 1 : 0 */
    bn.sel   w23, w31, w23, FG1.L
    bn.sel   w23, w23, w31, FG0.L

    /* Conditionally add to D.
         w28 <= D + (65537 & w23) */
    bn.wsrr  w24, MOD
    bn.and   w24, w24, w23
    bn.add   w28, w28, w24

    /* Shift D if u is even.
         w28 <= FG1.L ? D : D >> 1 */
    bn.rshi  w24, w31, w28 >> 1
    bn.sel   w28, w28, w24, FG1.L

    /* Clear flags for group 0. */
    bn.sub   w31, w31, w31

    /* Conditionally add m to C.
         dmem[dptr_C..dptr_C+(nlen*32)] <= (!v[0] && (C[0] | D[0])) ? C + m : C */
    addi     x2, x12, 0
    addi     x3, x14, 0
    loop     x30, 5
      /* w20 <= C[i] */
      bn.lid   x20, 0(x3)
      /* w21 <= m[i] */
      bn.lid   x21, 0(x2++)
      /* w21 <= m[i] & w23 */
      bn.and   w21, w21, w23
      /* w20, FG0.C <= C[i] + (m[i] & w23) + FG0.C */
      bn.addc  w20, w20, w21
      /* A[i] <= w20 */
      bn.sid   x20, 0(x3++)

    /* Capture the final carry bit in a register to use as the MSB for the
       shift. */
    bn.addc  w23, w31, w31

    /* Shift C to the right 1 if FG1.L is unset.
         dmem[dptr_C..dptr_C+(nlen*32)] <= FG1.L ? C : C >> 1 */
    addi     x3, x14, 0
    jal      x1, bignum_rshift1_if_not_fg1L

    /* End of loop; no-op so we don't end on a jump. */
    nop

  /* FG0.Z <= u == 1 */
  bn.addi    w23, w31, 1
  bn.cmp     w22, w23

  /* Get the FG0.Z flag into a register.
       x2 <= CSRs[FG0] & 8 = FG0.Z << 3 */
  csrrs    x2, FG0, x0
  andi     x2, x2, 8

  /* If the flag is unset (x2 == 0) then u != 1; in this case GCD(65537, m) !=
     1 and the modular inverse cannot be computed. This should never happen
     under normal operation, so panic and abort the program immediately. */
  bne      x2, x0, _modinv_f4_u_ok
  unimp

_modinv_f4_u_ok:
  /* Done; the modular inverse is stored in A. */

  ret

/**
 * Shifts input 1 bit to the right in-place if FG1.L is 0.
 *
 * Returns A' = if FG1.L then A else (msb || A) >> 1.
 *
 * The MSB of the final result will be the LSB of w23.
 *
 * Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]   x3: dptr_A, pointer to input A in DMEM
 * @param[in]  x20: 20, constant
 * @param[in]  x21: 21, constant
 * @param[in]  x30: alen, number of 256-bit limbs for input A
 * @param[in]   w23: value to use as the msb
 * @param[in]   w31: all-zero
 * @param[out] dmem[dptr_A..dptr_A+alen*32]: A', result
 *
 * clobbered registers: x2, x3, x4, w20, w21
 * clobbered flag groups: FG0
 */
bignum_rshift1_if_not_fg1L:
  /* Calculate number of loop iterations for bignum shifts.
       x2 <= n - 1 */
  addi     x2, x0, 1
  sub      x2, x30, x2

  /* Conditionally shift the lower limbs. */
  addi      x4, x3, 32
  loop      x2, 5
    /* w20 <= dmem[x3] = A[i] */
    bn.lid    x20, 0(x3)
    /* w21 <= dmem[x4] = A[i+1] */
    bn.lid    x21, 0(x4++)
    /* w21 <= (A >> 1)[i] */
    bn.rshi   w21, w21, w20 >> 1
    /* w20 <= FG1.L ? w20 : w21 */
    bn.sel    w20, w20, w21, FG1.L
    /* dmem[x3] <= w20 */
    bn.sid    x20, 0(x3++)

  /* Last limb is special because there's no next limb; we use the provided
     input value. */
  bn.lid    x20, 0(x3)
  bn.rshi   w21, w23, w20 >> 1
  bn.sel    w21, w20, w21, FG1.L
  bn.sid    x21, 0(x3)

  ret

/**
 * Generate a random prime for `p` according to FIPS 186-5.
 *
 * Repeatedly generates random numbers until one is within bounds and passes
 * the primality check, as per FIPS 186-5 section A.1.3. If the checks fail
 * 5*nlen times, where `nlen` is the bit-length of the RSA public key
 * (nlen=2048 for RSA-2048), then this routine causes an `ILLEGAL_INSN`
 * software error, since the probability of this happening by chance is very
 * low.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x20: 20, constant
 * @param[in]  x21: 21, constant
 * @param[in]  x30: plen, number of 256-bit limbs in the candidate prime
 * @param[in]  x31: n-1, constant
 * @param[in]  w31: all-zero
 * @param[out] dmem[rsa_p..rsa_p+(plen*32)]: result, probable prime p
 *
 * clobbered registers: x2 to x13, x16 to x19, x22 to x26,
 *                      w2, w3, w4..w[4+(plen-1)], w20 to w30
 * clobbered flag groups: FG0, FG1
 */
generate_p:
  /* Compute nlen, the bit-length of the RSA modulus based on the number of
     limbs for p.
       x4 <= n << 9 = plen*256*2 = nlen */
  slli     x4, x30, 9

  /* Initialize counter for # of attempts.
       x4 <= (x4 << 2) + x4 = 5*nlen */
  slli     x5, x4, 2
  add      x4, x4, x5

_generate_p_retry:
  /* Check if the attempt counter is nonzero. Otherwise, trigger an error that
     immediately aborts the OTBN program. */
  bne      x4, x0, _generate_p_counter_nonzero
  unimp

_generate_p_counter_nonzero:

  /* Decrement attempt counter. */
  addi     x5, x0, 1
  sub      x4, x4, x5

  /* Generate a new random value for p.
       dmem[rsa_p] <= <random plen*256-bit odd value> */
  la       x16, rsa_p
  jal      x1, generate_prime_candidate

  /* Check if the random value is acceptable for p.
       w24 <= 2^256-1 if the p value is OK, otherwise 0 */
  jal      x1, check_p

  /* Compare the result of the check to the "check passed" all-1s value.
       FG0.Z <= (w24 == 2^256-1) */
  bn.not   w20, w31
  bn.cmp   w20, w24

  /* Get the FG0.Z flag into a register.
       x2 <= CSRs[FG0] & 8 = FG0.Z << 3 */
  csrrs    x2, FG0, x0
  andi     x2, x2, 8

  /* If the flag is set, then the check passed. Otherwise, retry.*/
  beq      x2, x0, _generate_p_retry

  /* If we get here, the check succeeded and p is OK. */
  ret

/**
 * Generate a random prime for `q` according to FIPS 186-5.
 *
 * Repeatedly generates random numbers until one is within bounds, far enough
 * from the previously generated `p` value, and passes the primality check, as
 * per FIPS 186-5 section A.1.3. If the checks fail 10*nlen times, where `nlen`
 * is the bit-length of the RSA public key (nlen=2048 for RSA-2048), then this
 * routine causes an `ILLEGAL_INSN` software error, since the probability of
 * this happening by chance is very low.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x20: 20, constant
 * @param[in]  x21: 21, constant
 * @param[in]  x30: plen, number of 256-bit limbs in the candidate prime
 * @param[in]  x31: n-1, constant
 * @param[in]  w31: all-zero
 * @param[out] dmem[rsa_p..rsa_p+(plen*32)]: result, probable prime p
 *
 * clobbered registers: x2 to x13, x16 to x19, x22 to x26,
 *                      w2, w3, w4..w[4+(plen-1)], w20 to w30
 * clobbered flag groups: FG0, FG1
 */
generate_q:
  /* Compute nlen, the bit-length of the RSA modulus based on the number of
     limbs for q.
       x4 <= n << 9 = plen*256*2 = nlen */
  slli     x4, x30, 9

  /* Initialize counter for # of attempts.
       x4 <= ((x4 << 2) + x4) << 1 = 10*nlen */
  slli     x5, x4, 2
  add      x4, x4, x5
  slli     x4, x4, 1

_generate_q_retry:
  /* Check if the attempt counter is nonzero. Otherwise, trigger an error that
     immediately aborts the OTBN program. */
  bne      x4, x0, _generate_q_counter_nonzero
  unimp

_generate_q_counter_nonzero:

  /* Decrement attempt counter. */
  addi     x5, x0, 1
  sub      x4, x4, x5

  /* Generate a new random value for q.
       dmem[rsa_q] <= <random plen*256-bit odd value> */
  la       x16, rsa_q
  jal      x1, generate_prime_candidate

  /* Check if the random value is acceptable for q.
       w24 <= 2^256-1 if the q value is OK, otherwise 0 */
  jal      x1, check_q

  /* Compare the result of the check to the "check passed" all-1s value.
       FG0.Z <= (w24 == 2^256-1) */
  bn.not   w20, w31
  bn.cmp   w20, w24

  /* Get the FG0.Z flag into a register.
       x2 <= CSRs[FG0] & 8 = FG0.Z << 3 */
  csrrs    x2, FG0, x0
  andi     x2, x2, 8

  /* If the flag is set, then the check passed. Otherwise, retry.*/
  beq      x2, x0, _generate_q_retry

  /* If we get here, the check succeeded and q is OK. */
  ret

/**
 * Check if the input is an acceptable value for p.
 *
 * Returns all 1s if the check passess, and 0 if it fails.
 *
 * For the candidate value p, this check passes only if:
 *   * GCD(p-1, 65537) = 1, and
 *   * p passes 5 rounds of the Miller-Rabin primality test.
 *
 * Assumes that the input is an odd number (this is a precondition for the
 * primality test) and that p >= sqrt(2)*(2^(nlen/2 - 1)), where nlen = RSA
 * public key length. Internally, `generate_prime_candidate` guarantees these
 * conditions. The caller must ensure them before using this routine to check
 * untrusted or imported keys.
 *
 * See FIPS 186-5 section A.1.3 for the official spec. See this comment in
 * BoringSSL's implementation for a detailed description of how to choose the
 * number of rounds for Miller-Rabin:
 *   https://boringssl.googlesource.com/boringssl/+/dcabfe2d8940529a69e007660fa7bf6c15954ecc/crypto/fipsmodule/bn/prime.c#208
 *
 * Since this implementation supports only RSA >= 2048, 5 rounds should always
 * be enough (and is even slightly more than needed for larger primes).
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x16: dptr_p, address of the candidate prime in DMEM
 * @param[in]  x20: 20, constant
 * @param[in]  x21: 21, constant
 * @param[in]  x30: plen, number of 256-bit limbs in the candidate prime
 * @param[in]  x31: plen-1, constant
 * @param[in]  w31: all-zero
 * @param[out] w24: result, all 1s if the check passed and 0 otherwise
 *
 * clobbered registers: x2, x3, x5 to x13, x17 to x19, x22 to x26,
 *                      w2, w3, w4..w[4+(plen-1)], w20 to w30
 * clobbered flag groups: FG0, FG1
 */
check_p:
  /* Set the output to the "check passed" value (all 1s) by default.
       w24 <= 2^256 - 1 */
  bn.not   w24, w31

  /* Check p for divisibility by small primes.
      w22 <= nonzero if p is divisible by a small prime, otherwise 0 */
  jal     x1, relprime_small_primes

  /* Check if the small primes check passed (w22 is nonzero). If the check
     failed (w22==0), select the "failure" value of 0 for the result register.
       w24 <= (w22 == 0) ? 0 : w24 */
  bn.add   w22, w22, w31
  bn.sel   w24, w31, w24, FG0.Z

  /* Get the FG0.Z flag into a register.
       x2 <= CSRs[FG0] & 8 = FG0.Z << 3 */
  csrrs    x2, FG0, x0
  andi     x2, x2, 8

  /* If the flag is set, then the check failed and we can skip the remaining
     checks. */
  bne      x2, x0, _check_prime_fail

  /* Subtract 1 from the lowest limb in-place.
       dmem[x16] <= dmem[x16] - 1 = p - 1 */
  bn.lid   x20, 0(x16)
  bn.subi  w20, w20, 1
  bn.sid   x20, 0(x16)

  /* Check if p-1 is relatively prime to e=65537.
       w22 <= nonzero if GCD(p-1, e) == 1, otherwise 0 */
  jal      x1, relprime_f4

  /* Check if the relprime(e) check passed (w22 is nonzero). If the check
     failed (w22==0), select the "failure" value of 0 for the result register.
       w24 <= (w22 == 0) ? 0 : w24 */
  bn.add   w22, w22, w31
  bn.sel   w24, w31, w24, FG0.Z

  /* Get the FG0.Z flag into a register.
       x2 <= CSRs[FG0] & 8 = FG0.Z << 3 */
  csrrs    x2, FG0, x0
  andi     x2, x2, 8

  /* If the flag is set, then the check failed and we can skip the remaining
     checks. */
  bne      x2, x0, _check_prime_fail

  /* Add 1 back to the lowest limb in-place (correcting for the subtraction
     before the last check).
       dmem[x16] <= dmem[x16] + 1 = p */
  bn.lid   x20, 0(x16)
  bn.addi  w20, w20, 1
  bn.sid   x20, 0(x16)

  /* Load Montgomery constants for p.
       dmem[mont_m0inv] <= Montgomery constant m0'
       dmem[mont_rr] <= Montgomery constant RR */
  la       x17, mont_m0inv
  la       x18, mont_rr
  jal      x1, modload

  /* Load pointers to temporary buffers for Miller-Rabin. Each buffer needs to
     be at least 256 bytes for RSA-4096; we return pointers to the beginning
     and middle of the 512-byte `tmp` buffer.
       x14 <= tmp
       x15 <= tmp + 256 */
  la       x14, tmp_scratchpad
  li       x2, 256
  add      x15, x14, x2

  /* Calculate the number of Miller-Rabin rounds. The number of rounds is
     selected based on the bit-length according to FIPS 186-5, table B.1.
     According to that table, the minimums for an error probability matching
     the overall algorithm's security level are:
         RSA-2048 (1024-bit primes, n=4): 5 rounds
         RSA-3072 (1536-bit primes, n=6): 4 rounds
         RSA-4096 (2048-bit primes, n=8): 4 rounds

      x10 <= (x30 == 4) ? 5 : 4 */
  li      x10, 4
  bne     x10, x30, _check_p_num_rounds_done
  addi    x10, x10, 1

_check_p_num_rounds_done:

  /* Finally, run the Miller-Rabin primality test.
       w21 <= 2^256-1 if p is probably prime, 0 if p is composite */
  jal      x1, miller_rabin

  /* Restore constants. */
  li       x20, 20
  li       x21, 21

  /* Note: the primality test will have clobbered the result register, but if
     we got as far as the primality test at all then the previous checks must
     have succeeded. Therefore, we can simply return the result of the
     primality test. */
  bn.mov   w24, w21
  ret

_check_prime_fail:
  /* `check_p` and `check_q` jump here if they fail; set the result to 0.
       w24 <= 0 */
  bn.sub  w24, w24, w24
  ret


/**
 * Check if the input is an acceptable value for q.
 *
 * Returns all 1s if the check passess, and 0 if it fails.
 *
 * Assumes that the input is an odd number (this is a precondition for the
 * primality test). Before using this to check untrusted or imported keys, the
 * caller must check to ensure q is odd.
 *
 * The check for q is very similar to the check for p (see `check_p`), except
 * that we also need to ensure the value is not too close to p. Specifically,
 * we need to reject the value if |p-q| < 2^(nlen/2 - 100), where `nlen` is the
 * size of the RSA public key. So, for RSA-2048, the bound is 2^(1024 - 100).
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x20: 20, constant
 * @param[in]  x21: 21, constant
 * @param[in]  x30: plen, number of 256-bit limbs in the candidate prime
 * @param[in]  x31: plen-1, constant
 * @param[in]  w31: all-zero
 * @param[in]  dmem[rsa_p..rsa_p+(plen*32)]: value for p
 * @param[in]  dmem[rsa_q..rsa_q+(plen*32)]: candidate value for q
 * @param[out] w24: result, all 1s if the check passed and 0 otherwise
 *
 * clobbered registers: x2, x3, x5 to x13, x17 to x19, x22 to x26,
 *                      w2, w3, w4..w[4+(plen-1)], w20 to w30
 * clobbered flag groups: FG0, FG1
 */
check_q:
  /* Clear flags for both groups. */
  bn.sub   w31, w31, w31, FG0
  bn.sub   w31, w31, w31, FG1

  /* Compute the last limbs of (p-q) and (q-p).
       w22 <= (p - q) mod (2^(256*n)) >> (256*(n-1))
       w23 <= (q - p) mod (2^(256*n)) >> (256*(n-1)) */
  la       x7, rsa_p
  la       x8, rsa_q
  loop     x30, 4
    /* w20 <= p[i] */
    bn.lid   x20, 0(x7++)
    /* w21 <= q[i] */
    bn.lid   x21, 0(x8++)
    /* w22, FG0.C <= p[i] - q[i] - FG0.C */
    bn.subb  w22, w20, w21, FG0
    /* w23, FG1.C <= q[i] - p[i] - FG1.C */
    bn.subb  w23, w21, w20, FG1

  /* If p < q, then FG0.C will be set. Use the flag to select the last limb
     that matches |p-q|.
       w20 <= FG0.C ? w23 : w22 = (p - q) ? (q - p)[n-1] : (p - q)[n-1] */
  bn.sel   w20, w23, w22, FG0.C

  /* Get the highest 100 bits of |p - q|.
       w20 <= w20 >> 156 = |p-q| >> (256*n - 100) */
  bn.rshi  w20, w31, w20 >> 156

  /* Check if the highest 100 bits are 0 (we will need to fail if so).
       FG0.Z <= (w20 == 0) */
  bn.addi  w20, w20, 0

  /* Get the FG0.Z flag into a register.
       x2 <= CSRs[FG0] & 8 = FG0.Z << 3 */
  csrrs    x2, FG0, x0
  andi     x2, x2, 8

  /* If the flag is set, then the check failed and we can skip the remaining
     checks. */
  bne      x2, x0, _check_prime_fail

  /* Remaining checks are the same as for p; tail call `check_p`. */
  la   x16, rsa_q
  jal  x0, check_p

/**
 * Generate a candidate prime (can be used for either p or q).
 *
 * Fixes the lowest 3 bits to 1 and the highest 2 bits to 1, so the number is
 * always equivalent to 7 mod 8 and is always >= 2^(256*n - 1) * 1.5.  This
 * implies that the prime candidate is always in range, i.e. it is greater than
 * sqrt(2) * (2^(256*n - 1)), because sqrt(2) < 1.5. All other bits are fully
 * random. This follows FIPS 186-5 section A.1.3, which allows generating prime
 * candidates with a specific value mod 8 and allows the highest 2 bits to be
 * set arbitrarily.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x16: dptr_result, address of the result buffer in DMEM
 * @param[in]  x20: 20, constant
 * @param[in]  x30: plen, number of 256-bit limbs for the result
 * @param[in]  x31: plen-1, constant
 * @param[in]  w31: all-zero
 * @param[out] dmem[x16..x16+(plen*32)]: random candidate prime
 *
 * clobbered registers: x2, x3, w20, w21
 * clobbered flag groups: FG0
 */
generate_prime_candidate:
  /* Generate random 256-bit limbs.
       dmem[x16..x16+(plen*32)] <= RND(n*32) ^ URND(n*32)  */
  addi     x2, x16, 0
  loop     x30, 4
    /* w20 <= RND() */
    bn.wsrr  w20, RND
    /* w21 <= URND() */
    bn.wsrr  w21, URND
    /* w20 <= w20 ^ w21 */
    bn.xor   w20, w20, w21
    /* dmem[x2] <= w20 */
    bn.sid   x20, 0(x2++)

  /* Fix the lowest 3 bits to 1 so the number is always 7 mod 8.
       dmem[x16] <= dmem[x16] | 7 */
  bn.lid   x20, 0(x16)
  bn.addi  w21, w31, 7
  bn.or    w20, w20, w21
  bn.sid   x20, 0(x16)

  /* Get a pointer to the last limb.
       x2 <= x16 + ((n-1) << 5) = x16 + (n-1)*32 */
  slli     x3, x31, 5
  add      x2, x16, x3

  /* Fix the highest 2 bits to 1.
       dmem[x2] <= dmem[x2] | (3 << 6) << 248 = dmem[x2] | 3 << 254 */
  bn.lid   x20, 0(x2)
  bn.addi  w21, w31, 192
  bn.or    w20, w20, w21 << 248
  bn.sid   x20, 0(x2)

  ret

/**
 * Partially reduce a value modulo m such that 2^32 mod m == 1.
 *
 * Returns r such that r mod m = x mod m and r < 2^35.
 *
 * Can be used to speed up modular reduction on certain numbers, such as 3, 5,
 * 17, and 65537.
 *
 * Because we know 2^32 mod m is 1, it follows that in general 2^(32*k) for any
 * k are all 1 modulo m. This includes 2^256, so when we receive the input as
 * a bignum in 256-bit limbs, we can simply all the limbs together to get an
 * equivalent number modulo m:
 *  x = x[0] + 2^256 * x[1] + 2^512 * x[2] + ...
 *  x \equiv x[0] + x[1] + x[2] + ... (mod F4)
 *
 * From there, we can essentially use the same trick to bisect the number into
 * 128-bit, 64-bit, and 32-bit chunks and add these together to get an
 * equivalent number modulo m. This operation is visually sort of like folding
 * the number over itself repeatedly, which is where the function gets its
 * name.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x16: dptr_x, pointer to first limb of x in dmem
 * @param[in]  x30: plen, number of 256-bit limbs for x
 * @param[in]  w24: constant, 2^256 - 1
 * @param[in]  w31: all-zero
 * @param[out] w23: r, result
 *
 * clobbered registers: x2, w22, w23
 * clobbered flag groups: FG0
 */
fold_bignum:
  /* Initialize constants for loop. */
  li      x22, 22

  /* Copy input pointer. */
  addi    x2, x16, 0

  /* Initialize sum to zero and clear FG0.C.
       w23 <= 0
       FG0.C <= 0 */
  bn.addi  w23, w31, 0

  /* Iterate through the limbs of x and add them together.

     Loop invariants for iteration i (i=0..n-1):
       x2 = dptr_x + i*32
       x22 = 22
       (w23 + FG0.C) \equiv x[0] + x[1] + ... + x[i-1] (mod m)
   */
  loop    x30, 2
    /* Load the next limb.
         w22 <= x[i] */
    bn.lid   x22, 0(x2++)

    /* Accumulate the new limb, incorporating the carry bit from the previous
       round if there was one (this works because 2^256 \equiv 1 mod m).
         w23 <= (w23 + x[i] + FG0.C) mod 2^256
         FG0.C <= (w23 + x[i] + FG0.C) / 2^256 */
    bn.addc  w23, w23, w22

  /* Isolate the lower 128 bits of the sum.
       w22 <= w23[127:0] */
  bn.and   w22, w23, w24 >> 128

  /* Add the two 128-bit halves of the sum, plus the carry from the last round
     of the sum computation. The sum is now up to 129 bits.
       w23 <= (w22 + (w23 >> 128) + FG0.C) */
  bn.addc  w23, w22, w23 >> 128

  /* Isolate the lower 64 bits of the sum.
       w22 <= w23[63:0] */
  bn.and   w22, w23, w24 >> 192

  /* Add the two halves of the sum (technically 64 and 65 bits). A carry was
     not possible in the previous addition since the value is too small. The
     value is now up to 66 bits.
       w23 <= (w22 + (w23 >> 64)) */
  bn.add   w23, w22, w23 >> 64

  /* Isolate the lower 32 bits of the sum.
       w22 <= w23[31:0] */
  bn.and   w22, w23, w24 >> 224

  /* Add the two halves of the sum (technically 32 and 34 bits). A carry was
     not possible in the previous addition since the value is too small.
       w23 <= (w22 + (w23 >> 32)) */
  bn.add   w23, w22, w23 >> 32

  ret

/**
 * Partially reduce a value modulo m such that 2^32 mod m == 4.
 *
 * Returns r such that r mod m = x mod m and r < 2^33.
 *
 * Can be used to speed up modular reduction on certain numbers, such as 7, 11,
 * and 31.
 *
 * The logic here is very similar to `fold_bignum`, except we need to multiply
 * by a power of 4 each time we fold. The core reasoning is that, for any
 * positive k:
 *   x0 + 2^(32*k)x1 \equiv x0 + (4**k)*x1 (mod m)
 *
 * This routine assumes that the number of limbs `n` is at most 8 (i.e. enough
 * for RSA-4096); bounds analysis may not work out for larger numbers.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x16: dptr_x, pointer to first limb of x in dmem
 * @param[in]  x30: n, number of 256-bit limbs for x, 1 <= n < 8
 * @param[in]  w24: constant, 2^256 - 1
 * @param[in]  w31: all-zero
 * @param[out] w23: r, result
 *
 * clobbered registers: x2, x3, w22, w23, w25
 * clobbered flag groups: FG0
 */
fold_bignum_pow2_32_equiv_4:
  /* Initialize constants for loop. */
  li      x3, 32
  li      x22, 22

  /* Get a pointer to the end of the input.
       x2 <= dptr_x + n*32 */
  slli    x2, x30, 5
  add     x2, x2, x16

  /* Initialize the two-limb sum to zero and clear FG0.C.
       w25, w23 <= 0
       FG0.C <= 0 */
  bn.sub   w23, w23, w23
  bn.sub   w25, w25, w25

  /* Iterate through the limbs of x and add them together.

     We shift by 16 each time, since 2^256 mod m = 4**8 = 2^16. The size of the
     sum therefore increases by 17 bits on each iteration (16 from the shift
     and 1 from the addition). Since we are assuming at most 8 limbs, the
     maximum value of the final sum should fit in 256+8*17 = 375 bits.

     Loop invariants for iteration i (i=0..n-1):
       x2 = dptr_x + (n-i)*32
       x3 = 32
       x22 = 22
       (w23 + (w25 << 256)) \equiv x[i+1] + x[i+2] + ... + x[n-1] (mod m)
       (w23 + (w25 << 256)) < 2^(256+(n-1-i)*17)
   */
  loop    x30, 5
    /* Move the pointer down one limb.
         x2 <= dptr_x + (n-1-i)*32 */
    sub      x2, x2, x3

    /* Load the next limb.
         w22 <= x[n-1-i] */
    bn.lid   x22, 0(x2)

    /* Get the high part of the shifted sum.
         w25 <= ([w25,w23] << 16) >> 256 */
    bn.rshi  w25, w25, w23 >> 240

    /* Accumulate the new limb.
         [w25,w23] <= ([w25,w23] << 16 + x[i]) mod 2^256 */
    bn.add   w23, w22, w23 << 16
    bn.addc  w25, w31, w25

  /* Add the two limbs of the sum for a 257-bit result.
       w23 + (FG0.C << 256) <= w23 + (w25 << 16) */
  bn.add     w23, w23, w25 << 16

  /* Add the carry bit to the high 128 bits of the sum.
       w25 <= (w23 >> 128) + FG0.C */
  bn.addc    w25, w31, w23 >> 128

  /* Isolate the lower 128 bits of the sum.
       w22 <= w23[127:0] */
  bn.and   w22, w23, w24 >> 128

  /* Add the two halves of the sum to get a 129+8+1=138-bit value.
       w23 <= w22 + w25 << 8 */
  bn.addc  w23, w22, w25 << 8

  /* Isolate the lower 64 bits of the sum.
       w22 <= w23[63:0] */
  bn.and   w22, w23, w24 >> 192

  /* Add the two halves of the sum to get a (138-64)+4+1=79-bit value.
       w23 <= (w22 + ((w23 >> 64) << 4)) */
  bn.rshi  w23, w31, w23 >> 64
  bn.rshi  w23, w23, w31 >> 252
  bn.add   w23, w22, w23

  /* Isolate the lower 32 bits of the sum.
       w22 <= w23[31:0] */
  bn.and   w22, w23, w24 >> 224

  /* Add the two halves of the sum to get a (79-32)+2+1=50-bit value.
       w23 <= (w22 + ((w23 >> 32) << 2)) */
  bn.rshi  w23, w31, w23 >> 32
  bn.rshi  w23, w23, w31 >> 254
  bn.add   w23, w22, w23

  /* Isolate the lower 32 bits of the sum again.
       w22 <= w23[31:0] */
  bn.and   w22, w23, w24 >> 224

  /* Add the two halves of the sum to get a 33-bit value.
       w23 <= (w22 + ((w23 >> 32) << 2)) */
  bn.rshi  w23, w31, w23 >> 32
  bn.rshi  w23, w23, w31 >> 254
  bn.add   w23, w22, w23

  ret

/**
 * Check if a large number is relatively prime to 65537 (aka F4).
 *
 * Returns a nonzero value if GCD(x,65537) == 1, and 0 otherwise
 *
 * A naive implementation would simply check if GCD(x, F4) == 1, However, we
 * can simplify the check for relative primality using a few helpful facts
 * about F4 specifically:
 *   1. It is prime.
 *   2. It has the special form (2^16 + 1).
 *
 * Because F4 is prime, checking if a number x is relatively prime to F4 means
 * simply checking if x is a direct multiple of F4; if (x % F4) != 0, then x is
 * relatively prime to F4. This means that instead of computing GCD, we can use
 * basic modular arithmetic.
 *
 * Here, the special form of F4, fact (2), comes in handy. Since 2^32 mod F4 =
 * 1, we can use `fold_bignum` to bring the number down to 35 bits cheaply.
 *
 * Since 2^16 is equivalent to -1 modulo F4, we can express the resulting
 * number in base-2^16 and simplify as follows:
 *   x = x0 + 2^16 * x1 + 2^32 * x2
 *   x \equiv x0 + (-1) * x1 + (-1)^2 * x2
 *   x \equiv x0 - x1 + x2 (mod F4)
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x16: dptr_x, pointer to first limb of x in dmem
 * @param[in]  x30: n, number of 256-bit limbs for x
 * @param[in]  w31: all-zero
 * @param[out] w22: result, 0 only if x is not relatively prime to F4
 *
 * clobbered registers: x2, w22, w23
 * clobbered flag groups: FG0
 */
relprime_f4:
  /* Load F4 into the modulus register for later.
       MOD <= 2^16 + 1 */
  bn.addi  w22, w31, 1
  bn.add   w22, w22, w22 << 16
  bn.wsrw  MOD, w22

  /* Generate a 256-bit mask.
       w24 <= 2^256 - 1 */
  bn.not   w24, w31

  /* Fold the bignum to get a 35-bit number r such that r mod F4 = x mod F4.
       w23 <= r */
  jal      x1, fold_bignum

  /* Isolate the lower 16 bits of the 35-bit working sum.
       w22 <= w23[15:0] */
  bn.and   w22, w23, w24 >> 240

  /* Add the lower 16 bits of the sum to the highest 3 bits to get a 17-bit
     result.
       w22 <= w22 + (w23 >> 32) */
  bn.add   w22, w22, w23 >> 32

  /* The sum from the previous addition is at most 2^16 - 1 + 2^3 - 1 < 2 * F4,
     so a modular addition with zero is sufficient to fully reduce.
       w22 <= w22 mod F4 */
  bn.addm  w22, w22, w31

  /* Isolate the subtraction term.
       w23 <= w23[31:16] */
  bn.rshi  w23, w23, w31 >> 32
  bn.rshi  w23, w31, w23 >> 240

  /* Final subtraction modulo F4.
       w22 <= (w22 - w23) mod F4 = x mod F4 */
  bn.subm  w22, w22, w23

  ret

/**
 * Check if a large number is divisible by a few small primes.
 *
 * Returns 0 if x is divisible by a small prime, 2^256 - 1 otherwise.
 *
 * In this implementation, we check the primes 3, 5, 7, 11, 17, and 31.
 * These primes have special properties that allow us to compute the residue
 * quickly:
 *   - p = {3,5,17} have the property that (2^8) mod p = 1
 *   - p = {7,11,31} have the property that (2^32) mod p = 4
 *
 * Testing for these primes will catch approximately:
 *   1 - ((1 - 1/3) * (1 - 1/5) * ... * (1 - 1/31))
 *   = 62.1% of composite numbers.
 *
 * Quick intuition for the estimate above: the multiplications calculate the
 * proportion of composites we will *fail* to catch. At each multiplication
 * step, we multiply the proportion of composites we still haven't caught by
 * the proportion that the next small prime will *not* catch (e.g. 4/5 of
 * numbers will not be multiples of 5).
 *
 * This routine is constant-time relative to x if x is not divisible by any
 * small primes, but exits early if it finds that x is divisible by a small
 * prime.
 *
 * Flags: Flags have no meaning beyond the scope of this subroutine.
 *
 * @param[in]  x16: dptr_x, pointer to first limb of x in dmem
 * @param[in]  x30: n, number of 256-bit limbs for x
 * @param[in]  w31: all-zero
 * @param[out] w22: result, 0 if x is divisible by a small prime
 *
 * clobbered registers: x2, w22, w23, w24, w25, w26
 * clobbered flag groups: FG0
 */
relprime_small_primes:
  /* Generate a 256-bit mask.
       w24 <= 2^256 - 1 */
  bn.not   w24, w31

  /* Fold the bignum to get a 35-bit number r such that r mod m = x mod m for
     all m such that 2^32 mod m == 1.
       w23 <= r */
  jal      x1, fold_bignum

  /* Isolate the lower 16 bits of the 35-bit working sum.
       w22 <= w23[15:0] */
  bn.and   w22, w23, w24 >> 240

  /* Add the lower 16 bits to the higher 19 bits to get a 20-bit result.
       w23 <= w22 + (w23 >> 16) */
  bn.add   w23, w22, w23 >> 16

  /* Isolate the lower 8 bits of the 20-bit working sum.
       w22 <= w23[7:0] */
  bn.and   w22, w23, w24 >> 248

  /* Add the lower 8 bits to the higher 12 bits to get a 13-bit result.
       w23 <= w22 + (w23 >> 8) */
  bn.add   w23, w22, w23 >> 8

  /* Isolate the lower 8 bits of the 13-bit working sum.
       w22 <= w23[7:0] */
  bn.and   w22, w23, w24 >> 248

  /* Add the lower 8 bits to the higher 5 bits to get a 9-bit result.
       w23 <= w22 + (w23 >> 8) */
  bn.add   w23, w22, w23 >> 8

  /* Load the bit-length for `is_zero_mod_small_prime`. */
  li       x10, 9

  /* Check the residue modulo 3.
       x2 <= if (w23 mod 3) == 0 then 8 else 0 */
  bn.addi  w26, w31, 3
  jal      x1, is_zero_mod_small_prime

  /* If x2 != 0, exit early. */
  bne      x2, x0, __relprime_small_primes_fail

  /* Check the residue modulo 5.
       x2 <= if (w23 mod 5) == 0 then 8 else 0 */
  bn.addi  w26, w31, 5
  jal      x1, is_zero_mod_small_prime

  /* If x2 != 0, exit early. */
  bne      x2, x0, __relprime_small_primes_fail

  /* Check the residue modulo 17.
       x2 <= if (w23 mod 17) == 0 then 8 else 0 */
  bn.addi  w26, w31, 17
  jal      x1, is_zero_mod_small_prime

  /* If x2 != 0, exit early. */
  bne      x2, x0, __relprime_small_primes_fail

  /* We didn't find any divisors among the primes p such that 2^8 mod p == 1;
     now let's try primes such that 2^32 mod p == 4. This includes 7, 11, and
     31. */

  /* Fold the bignum to get a 33-bit number r such that r mod m = x mod m for
     all m such that 2^32 mod m == 4.
       w23 <= r */
  jal      x1, fold_bignum_pow2_32_equiv_4

  /* Load the bit-length for `is_zero_mod_small_prime`. */
  li       x10, 33

  /* Check the residue modulo 7.
       x2 <= if (w23 mod 7) == 0 then 8 else 0 */
  bn.addi  w26, w31, 7
  jal      x1, is_zero_mod_small_prime

  /* If x2 != 0, exit early. */
  bne      x2, x0, __relprime_small_primes_fail

  /* Check the residue modulo 11.
       x2 <= if (w23 mod 5) == 0 then 8 else 0 */
  bn.addi  w26, w31, 11
  jal      x1, is_zero_mod_small_prime

  /* If x2 != 0, exit early. */
  bne      x2, x0, __relprime_small_primes_fail

  /* Check the residue modulo 31.
       x2 <= if (w23 mod 17) == 0 then 8 else 0 */
  bn.addi  w26, w31, 31
  jal      x1, is_zero_mod_small_prime

  /* If x2 != 0, exit early. */
  bne      x2, x0, __relprime_small_primes_fail

  /* No small prime divisors found; return 2^256 - 1. */
  bn.not   w22, w31
  ret

__relprime_small_primes_fail:
  /* Small prime divisor found; return 0. */
  bn.sub   w22, w22, w22
  ret

/**
 * Reduce input modulo a small number with conditional subtractions.
 *
 * Returns r = 8 if a mod m = 0, otherwise r = 0.
 *
 * Helper function for `relprime_small_primes`. This routine takes time linear
 * in the number of bits of the input, so it's slow for large numbers and
 * should only be used as a last step once the bit-bound is low.
 *
 * The sum of the bit-length of the input and the modulus should not exceed
 * 256.
 *
 * This function runs in constant time.
 *
 * @param[in]  x10: len, max. number of bits in input, 1 < len
 * @param[in]  w23: a, input, a < 2^len.
 * @param[in]  w26: m, modulus, 2 < m < 2^(256-len).
 * @param[in]  w31: all-zero
 * @param[out] x2: result, 8 if a mod m = 0 and otherwise 0
 *
 * clobbered registers: x2, w22, w25, w26
 * clobbered flag groups: FG0
 */
is_zero_mod_small_prime:
  /* Copy input. */
  bn.mov  w25, w23

  /* Initialize shifted modulus for loop.
       w26 <= m << (len - 1) */
  li       x2, 1
  sub      x2, x10, x2
  loop     x2, 1
    bn.add   w26, w26, w26

  /* Repeatedly reduce using conditional subtractions.

     Loop invariant (i=len-1 to 0):
       w26 = m << i
       w25 < 2*(m << i)
       w25 mod m = a mod m
  */
  loop     x10, 3
    /* w22 <= w25 - w26 */
    bn.sub   w22, w25, w26
    /* Select the subtraction only if it did not underflow.
         w25 <= FG0.C ? w25 : w22 */
    bn.sel   w25, w25, w22, FG0.C
    /* w26 <= w26 >> 1 */
    bn.rshi  w26, w31, w26 >> 1

  /* Check if w25 is 0.
       FG0.Z <= w25 == 0 */
  bn.cmp   w25, w31

  /* Get the FG0.Z flag into a register and return.
       x2 <= CSRs[FG0] & 8 = FG0.Z << 3 */
  csrrs    x2, FG0, x0
  andi     x2, x2, 8

  ret

.section .scratchpad

/* Extra label marking the start of p || q in memory. The `derive_d` function
   uses this to get a 512-byte working buffer, which means p and q must be
   continuous in memory. In addition, `rsa_key_from_cofactor` uses the
   larger buffer for division and depends on the order of `p` and `q`. */
.balign 32
rsa_pq:

/* Secret RSA `p` parameter (prime). Up to 2048 bits. */
.globl rsa_p
rsa_p:
.zero 256

/* Secret RSA `q` parameter (prime). Up to 2048 bits. */
.globl rsa_q
rsa_q:
.zero 256

/* Temporary working buffer (4096 bits). */
.balign 32
tmp_scratchpad:
.zero 512

.bss

/* RSA modulus n = p*q (up to 4096 bits). */
.balign 32
.globl rsa_n
rsa_n:
.zero 512

/* RSA private exponent d (up to 4096 bits). */
.balign 32
.globl rsa_d
rsa_d:
.zero 512

/* Prime cofactor for n for `rsa_key_from_cofactor`; also used as a temporary
 * work buffer. */
.balign 32
.globl rsa_cofactor
rsa_cofactor:
.zero 512

/* Montgomery constant m0' (256 bits). */
.balign 32
mont_m0inv:
.zero 32

/* Montgomery constant R^2 (up to 2048 bits). */
.balign 32
mont_rr:
.zero 256
