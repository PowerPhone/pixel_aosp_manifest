/* SPDX-License-Identifier: GPL-2.0 */
#ifndef POWERPHONE_FRANKEL_FW_COMPAT_H
#define POWERPHONE_FRANKEL_FW_COMPAT_H

#include <linux/firmware.h>
#include <linux/firmware/cirrus/cs_dsp.h>

/* Exported by Frankel's stock fw_cs_dsp.ko but no longer public in ACK. */
int cs_dsp_load_coeff(struct cs_dsp *dsp, const struct firmware *firmware,
		      const char *file);

#endif
