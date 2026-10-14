/* Paired RAW-type2 MCPS control: leave the immutable cost table alone.
 * Both enabledelta and disabledelta must agree to avoid a leaked vote.
 * These are windowless midfunction hooks; no additional stack locals.
 */
.begin no-transform
.section .raw_mcps_enable_hook,"ax"
    j cubs_raw_mcps_enable
    nop.n
.section .raw_mcps_disable_hook,"ax"
    j cubs_raw_mcps_disable
    nop.n
.section .raw_mcps_enable_cave,"ax"
.global cubs_raw_mcps_enable
cubs_raw_mcps_enable:
    l32i.n a15,a15,0
    bnei a4,2,.Lenable_continue
    movi a15,112
.Lenable_continue:
    j 0x40279a27
.section .raw_mcps_disable_cave,"ax"
.global cubs_raw_mcps_disable
cubs_raw_mcps_disable:
    bnei a4,2,.Ldisable_stock
    movi a4,112
    j .Ldisable_negate
.Ldisable_stock:
    l32i.n a4,a15,0
.Ldisable_negate:
    neg a15,a4
    j 0x40279a27
.end no-transform
