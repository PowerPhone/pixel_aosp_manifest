#!/usr/bin/env python3
"""Give Frankel PCM0/D0 bounded progress while retaining the real mailbox ISR.

The clean 192 kHz driver receives a real AoC playback notification after D0
has consumed the complete 15,360-byte ring.  Reporting that counter directly
leaves the ALSA hardware pointer at the same modulo-buffer position, so the
next full-buffer ``WRITEI_FRAMES`` times out without entering ``copy_user``.

This transform changes only the consumed-counter path for PCM device 0.  Each
mailbox invocation reports at most one period of the already-observed AoC Rx
counter: ``min(actual_rx, previous_report + period_bytes)``.  The intermediate
nonzero ALSA pointer releases one real period to the writer; consumption of
that newly supplied period causes the next mailbox notification.  No timer,
prefill, availability bypass, or synthetic counter is introduced.  Other PCM
devices and the clean module's mailbox selection remain byte-for-byte stock.

Pair this module with the global ``aoc_core`` zero-wp reset fix.
"""

from __future__ import annotations

import patch_frankel_aoc_ep1_d0_real_progress as implementation


# Reuse the audited selector/counter cave and its single call-site redirect,
# but deliberately omit every open/timer/private-data mutation from the prior
# timer-only experiment.
implementation.PATCHES = implementation.PATCHES[-3:]
implementation.PATCHED_SHA256 = (
    "fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0"
)


if __name__ == "__main__":
    raise SystemExit(implementation.main())
