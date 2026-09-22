// SPDX-License-Identifier: GPL-2.0
/*
 * Export adapter for Google's split CS35L43 core/transport DDK layout.
 *
 * Cirrus's public kernel tree links the core into each transport module, while
 * Frankel ships one core module plus small I2C and SPI modules.  Keep the
 * public source unchanged and reproduce only the exports consumed by those
 * stock transport modules.
 */

#include <linux/module.h>
#include <linux/regulator/consumer.h>
#include "wm_adsp.h"
#include "cs35l43.h"
#include <sound/cs35l43.h>

EXPORT_SYMBOL_GPL(cs35l43_pm_ops);
EXPORT_SYMBOL_GPL(cs35l43_precious_reg);
EXPORT_SYMBOL_GPL(cs35l43_probe);
EXPORT_SYMBOL_GPL(cs35l43_readable_reg);
EXPORT_SYMBOL_GPL(cs35l43_reg);
EXPORT_SYMBOL_GPL(cs35l43_remove);
EXPORT_SYMBOL_GPL(cs35l43_volatile_reg);
