/* Three-instruction capture-rate selector for the live Cubs module.
 * At entry w2=requested Hz, w8=96000; all earlier rates retain their paths.
 * If not 192000, the stock 8/16/default48 sequence remains authoritative.
 * No device access and no change to playback encoding.
 */
.text
.org 0xd784
    cmp w2, w8, lsl #1
    mov w8, #7
    b.eq capture_store
.org 0xd7cc
capture_store:
