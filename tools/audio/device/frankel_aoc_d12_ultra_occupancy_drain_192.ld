/* SPDX-License-Identifier: Apache-2.0 */
SECTIONS {
  .occupancy_drain 0x403f0c44 : { *(.occupancy_drain) }
  .no_sync_half    0x403e87d0 : { *(.no_sync_half) }
  .period          0x403e87e4 : { *(.period) }
  .period_hook     0x403e867e : { *(.period_hook) }
}
