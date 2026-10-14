/* Isolated Cubs 6.4-MHz receiver-edge discriminator. No RFactor or HPF change.
 * The native per-lane load at 4025d1fc feeds PdmV4 virtual+24, which changes
 * only CONTROL bit1. Do not use this file as a qualified microphone profile.
 */
.include "cubs_d10_mono192_candidate.S"
.begin no-transform
.section .native_receiver_edge_zero,"ax"
    movi a12,0
.end no-transform
