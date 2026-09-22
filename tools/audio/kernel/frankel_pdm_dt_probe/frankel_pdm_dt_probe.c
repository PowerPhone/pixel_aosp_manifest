// SPDX-License-Identifier: GPL-2.0-only
/*
 * Read-only Device Tree inventory probe for Frankel audio resources.
 *
 * This module deliberately does not map, read, reserve, or write MMIO and
 * does not request interrupts, clocks, DMA channels, or platform devices.
 */

#include <linux/init.h>
#include <linux/ioport.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>

#define PROBE_MAX_REG_RANGES 8

static bool include_audio;
module_param(include_audio, bool, 0444);
MODULE_PARM_DESC(include_audio,
		 "also report nodes whose name or compatible contains 'audio'");

static unsigned int max_nodes = 64;
module_param(max_nodes, uint, 0444);
MODULE_PARM_DESC(max_nodes, "maximum matching nodes to print (default 64)");

static char ascii_lower(char value)
{
	if (value >= 'A' && value <= 'Z')
		return value + ('a' - 'A');
	return value;
}

static bool span_contains(const char *text, size_t text_len, const char *word)
{
	size_t word_len = 0;
	size_t offset;
	size_t index;

	while (word[word_len])
		word_len++;
	if (!word_len || text_len < word_len)
		return false;

	for (offset = 0; offset <= text_len - word_len; offset++) {
		for (index = 0; index < word_len; index++)
			if (ascii_lower(text[offset + index]) != word[index])
				break;
		if (index == word_len)
			return true;
	}
	return false;
}

static bool span_is_interesting(const char *text, size_t text_len)
{
	return span_contains(text, text_len, "pdm") ||
	       span_contains(text, text_len, "dmic") ||
	       span_contains(text, text_len, "aoc") ||
	       (include_audio && span_contains(text, text_len, "audio"));
}

static size_t bounded_string_length(const char *text, size_t available)
{
	size_t length = 0;

	while (length < available && text[length])
		length++;
	return length;
}

static bool compatible_is_interesting(const struct device_node *node)
{
	const char *compatible;
	const char *cursor;
	const char *end;
	int length;

	compatible = of_get_property(node, "compatible", &length);
	if (!compatible || length <= 0)
		return false;

	cursor = compatible;
	end = compatible + length;
	while (cursor < end) {
		size_t available = end - cursor;
		size_t item_len = bounded_string_length(cursor, available);

		if (span_is_interesting(cursor, item_len))
			return true;
		if (item_len == available)
			break;
		cursor += item_len + 1;
	}
	return false;
}

static bool node_is_interesting(const struct device_node *node)
{
	const char *name = node->full_name;
	size_t length = 0;

	if (name) {
		while (name[length])
			length++;
		if (span_is_interesting(name, length))
			return true;
	}
	return compatible_is_interesting(node);
}

static void report_compatible(const struct device_node *node)
{
	const char *compatible;
	const char *cursor;
	const char *end;
	int length;
	unsigned int index = 0;

	compatible = of_get_property(node, "compatible", &length);
	if (!compatible || length <= 0)
		return;

	cursor = compatible;
	end = compatible + length;
	while (cursor < end) {
		size_t available = end - cursor;
		size_t item_len = bounded_string_length(cursor, available);

		if (item_len)
			pr_info("%s:   compatible[%u]=%.*s\n", KBUILD_MODNAME,
				index, (int)item_len, cursor);
		if (item_len == available)
			break;
		cursor += item_len + 1;
		index++;
	}
}

static void report_register_ranges(struct device_node *node)
{
	unsigned int index;

	for (index = 0; index < PROBE_MAX_REG_RANGES; index++) {
		struct resource resource;

		if (of_address_to_resource(node, index, &resource))
			break;
		pr_info("%s:   reg[%u]=%pr\n", KBUILD_MODNAME, index,
			&resource);
	}
}

static int __init frankel_pdm_dt_probe_init(void)
{
	struct device_node *node = NULL;
	unsigned int matches = 0;
	unsigned int reported = 0;

	pr_info("%s: read-only DT inventory start (include_audio=%u max_nodes=%u)\n",
		KBUILD_MODNAME, include_audio, max_nodes);

	/* of_find_all_nodes() drops the reference to its previous argument. */
	while ((node = of_find_all_nodes(node))) {
		if (!node_is_interesting(node))
			continue;
		matches++;
		if (reported >= max_nodes)
			continue;

		pr_info("%s: node=%pOF available=%u\n", KBUILD_MODNAME, node,
			of_device_is_available(node));
		report_compatible(node);
		report_register_ranges(node);
		reported++;
	}

	pr_info("%s: complete: matches=%u reported=%u; no MMIO was mapped or read\n",
		KBUILD_MODNAME, matches, reported);
	return 0;
}

static void __exit frankel_pdm_dt_probe_exit(void)
{
	pr_info("%s: unloaded\n", KBUILD_MODNAME);
}

module_init(frankel_pdm_dt_probe_init);
module_exit(frankel_pdm_dt_probe_exit);

MODULE_AUTHOR("CSR460 Android audio research");
MODULE_DESCRIPTION("Read-only Frankel PDM/DMIC/AoC Device Tree inventory");
MODULE_LICENSE("GPL");
