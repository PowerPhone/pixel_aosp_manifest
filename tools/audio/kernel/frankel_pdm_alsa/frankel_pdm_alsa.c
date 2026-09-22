// SPDX-License-Identifier: GPL-2.0-only
/*
 * Guarded Frankel raw-PDM FIFO to ALSA capture prototype.
 *
 * This research module never writes MMIO.  It registers three independent
 * mono S32_LE/192 kHz capture PCMs for PDM controllers 0, 2, and 3.  Mapping
 * and access are separate, explicit opt-ins.  status_probe performs only one
 * synchronous +0x10 read per selected controller.  Destructive FIFO pops do
 * not begin until that proof is consumed by a polling_enabled 0 -> 1 change.
 */

#include <linux/atomic.h>
#include <linux/device.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/kthread.h>
#include <linux/limits.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/sched.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/suspend.h>
#include <linux/wait.h>

#include <sound/core.h>
#include <sound/pcm.h>

#define FRANKEL_MODEL "FRANKEL MP based on LGA"
#define FRANKEL_COMPAT_PRIMARY "google,lga-frankel"
#define FRANKEL_COMPAT_FAMILY "google,lga"

#define FRANKEL_BLK_AOC_START ((resource_size_t)0x09000000)
#define FRANKEL_BLK_AOC_SIZE ((resource_size_t)0x02000000)
#define FRANKEL_PDM_LOCAL_BASE ((resource_size_t)0x01c0a000)
#define FRANKEL_PDM_STRIDE ((resource_size_t)0x00001000)
#define FRANKEL_PDM_WINDOW_SIZE ((resource_size_t)0x00001000)
#define FRANKEL_PDM0_AP_PHYS ((unsigned long)0x0ac0a000)

#define PDM_FIFO_DATA_OFFSET 0x0c
#define PDM_FIFO_STATUS_OFFSET 0x10
#define PDM_FIFO_STATUS_EMPTY BIT(0)

#define PDM_INPUT_RATE 4800000U
#define PDM_DECIMATION 25U
#define PCM_OUTPUT_RATE (PDM_INPUT_RATE / PDM_DECIMATION)
#define PDM_CONTROLLERS 3
#define PDM_ALLOWED_MASK (BIT(0) | BIT(2) | BIT(3))
#define PCM_SAMPLE_BYTES 4U
#define PCM_BUFFER_BYTES_MAX (PCM_OUTPUT_RATE * PCM_SAMPLE_BYTES)
#define PCM_PERIOD_BYTES_MIN (64U * PCM_SAMPLE_BYTES)
#define PCM_PERIOD_BYTES_MAX (19200U * PCM_SAMPLE_BYTES)

struct frankel_pdm_stats {
	atomic64_t status_polls;
	atomic64_t status_probe_reads;
	atomic64_t empty_polls;
	atomic64_t fifo_words;
	atomic64_t pdm_bits;
	atomic64_t decimated_frames;
	atomic64_t delivered_frames;
	atomic64_t discarded_frames;
	atomic64_t period_events;
	atomic64_t overruns;
	atomic64_t decimator_clips;
};

struct frankel_pdm_controller {
	unsigned int pdm_id;
	const char *pcm_name;
	resource_size_t physical;
	void __iomem *base;

	unsigned int decimator_phase;
	s64 integrator[3];
	s64 comb_delay[3];
	u32 last_status;

	spinlock_t pcm_lock;
	struct snd_pcm_substream *substream;
	bool running;
	bool xrun_reported;
	snd_pcm_uframes_t hw_position;
	snd_pcm_uframes_t period_position;
	atomic_t callbacks_in_flight;
	wait_queue_head_t callback_wait;

	struct frankel_pdm_stats stats;
};

static struct frankel_pdm_controller controllers[PDM_CONTROLLERS] = {
	{ .pdm_id = 0, .pcm_name = "Frankel raw PDM0" },
	{ .pdm_id = 2, .pcm_name = "Frankel raw PDM2" },
	{ .pdm_id = 3, .pcm_name = "Frankel raw PDM3" },
};

static const struct snd_pcm_hardware frankel_pdm_pcm_hardware = {
	.info = SNDRV_PCM_INFO_MMAP |
		SNDRV_PCM_INFO_MMAP_VALID |
		SNDRV_PCM_INFO_INTERLEAVED |
		SNDRV_PCM_INFO_BLOCK_TRANSFER |
		SNDRV_PCM_INFO_PAUSE,
	.formats = SNDRV_PCM_FMTBIT_S32_LE,
	.rates = SNDRV_PCM_RATE_192000,
	.rate_min = PCM_OUTPUT_RATE,
	.rate_max = PCM_OUTPUT_RATE,
	.channels_min = 1,
	.channels_max = 1,
	.buffer_bytes_max = PCM_BUFFER_BYTES_MAX,
	.period_bytes_min = PCM_PERIOD_BYTES_MIN,
	.period_bytes_max = PCM_PERIOD_BYTES_MAX,
	.periods_min = 2,
	.periods_max = 1024,
	.fifo_size = 0,
};

static bool map_controllers;
module_param(map_controllers, bool, 0444);
MODULE_PARM_DESC(map_controllers,
		 "explicitly map guarded PDM windows; mapping alone performs no read");

static unsigned long projection_ack;
module_param(projection_ack, ulong, 0444);
MODULE_PARM_DESC(projection_ack,
		 "must equal derived PDM0 AP address 0x0ac0a000 when mapping");

static unsigned int decimator_order = 3;
module_param(decimator_order, uint, 0444);
MODULE_PARM_DESC(decimator_order,
		 "CIC order: 3 (default research path) or 1 (debug boxcar)");

static unsigned int controller_mask = BIT(0);
module_param(controller_mask, uint, 0444);
MODULE_PARM_DESC(controller_mask,
		 "immutable selected PDM IDs: bit0/bit2/bit3 only (default 0x1)");

static bool pdm_msb_first;
module_param(pdm_msb_first, bool, 0444);
MODULE_PARM_DESC(pdm_msb_first,
		 "consume each payload byte MSB-first (default false/LSB-first)");

static bool pdm_reverse_bytes;
module_param(pdm_reverse_bytes, bool, 0444);
MODULE_PARM_DESC(pdm_reverse_bytes,
		 "consume payload bytes +3,+2,+1 (default false/+1,+2,+3)");

static bool pdm_invert;
module_param(pdm_invert, bool, 0444);
MODULE_PARM_DESC(pdm_invert,
		 "invert each PDM bit before CIC processing (default false)");

static struct snd_card *pdm_card;
static struct device *pdm_device;
static struct task_struct *poll_task;
static DECLARE_WAIT_QUEUE_HEAD(polling_waitq);
static DEFINE_MUTEX(poll_control_lock);
static atomic_t polling_active = ATOMIC_INIT(0);
static bool polling_requested;
static bool status_probe_completed;
static bool module_ready;
static bool pm_guard_registered;

static int frankel_pdm_pm_notify(struct notifier_block *notifier,
				 unsigned long action, void *data)
{
	(void)notifier;
	(void)data;
	if (!map_controllers)
		return NOTIFY_OK;
	if (action != PM_SUSPEND_PREPARE &&
	    action != PM_HIBERNATION_PREPARE &&
	    action != PM_RESTORE_PREPARE)
		return NOTIFY_OK;

	pr_err("%s: refusing system sleep while guarded PDM windows are mapped\n",
	       KBUILD_MODNAME);
	return NOTIFY_BAD;
}

static struct notifier_block frankel_pdm_pm_notifier = {
	.notifier_call = frankel_pdm_pm_notify,
	.priority = INT_MAX,
};

static int stats_get(char *buffer, const struct kernel_param *parameter)
{
	int written = 0;
	unsigned int index;

	(void)parameter;
	for (index = 0; index < PDM_CONTROLLERS; index++) {
		struct frankel_pdm_controller *controller = &controllers[index];
		struct frankel_pdm_stats *stats = &controller->stats;

		written += scnprintf(buffer + written, PAGE_SIZE - written,
			"pdm%u status=%lld probe_reads=%lld empty=%lld words=%lld bits=%lld "
			"frames=%lld delivered=%lld discarded=%lld "
			"periods=%lld overruns=%lld clips=%lld "
			"last_status=0x%08x\n",
			controller->pdm_id,
			atomic64_read(&stats->status_polls),
			atomic64_read(&stats->status_probe_reads),
			atomic64_read(&stats->empty_polls),
			atomic64_read(&stats->fifo_words),
			atomic64_read(&stats->pdm_bits),
			atomic64_read(&stats->decimated_frames),
			atomic64_read(&stats->delivered_frames),
			atomic64_read(&stats->discarded_frames),
			atomic64_read(&stats->period_events),
			atomic64_read(&stats->overruns),
			atomic64_read(&stats->decimator_clips),
			READ_ONCE(controller->last_status));
	}
	return written;
}

static const struct kernel_param_ops stats_ops = {
	.get = stats_get,
};
static unsigned int stats_anchor;
module_param_cb(stats, &stats_ops, &stats_anchor, 0444);
MODULE_PARM_DESC(stats, "read-only lifetime FIFO/PCM diagnostic counters");

static void reset_decimators(void)
{
	unsigned int index;

	for (index = 0; index < PDM_CONTROLLERS; index++) {
		unsigned int stage;

		controllers[index].decimator_phase = 0;
		for (stage = 0; stage < 3; stage++) {
			controllers[index].integrator[stage] = 0;
			controllers[index].comb_delay[stage] = 0;
		}
	}
}

/* Caller holds poll_control_lock, excluding every new 0 -> 1 transition. */
static void force_polling_off_locked(void)
{
	WRITE_ONCE(polling_requested, false);
	wake_up_all(&polling_waitq);
	/*
	 * A release store of zero is published only after the worker's last
	 * MMIO read, FIFO delivery, and period callback.  The acquire load makes
	 * their completion visible before this synchronous stop returns.
	 */
	wait_event(polling_waitq,
		   atomic_read_acquire(&polling_active) == 0);
}

/*
 * Perform one synchronous, status-only AP permission probe over the selected
 * controllers.  This path cannot call the FIFO-pop helper, cannot wake the
 * polling worker, and is serialized against every polling transition.  A
 * successful write of one creates a single-use token: the next 0 -> 1 polling
 * transition consumes it before waking the worker.
 */
static int status_probe_set(const char *value,
			    const struct kernel_param *parameter)
{
	bool requested;
	unsigned int index;
	int error;

	(void)parameter;
	error = kstrtobool(value, &requested);
	if (error)
		return error;

	mutex_lock(&poll_control_lock);
	if (!requested) {
		if (READ_ONCE(polling_requested) ||
		    atomic_read_acquire(&polling_active) != 0) {
			error = -EBUSY;
			goto out;
		}
		WRITE_ONCE(status_probe_completed, false);
		goto out;
	}

	if (!READ_ONCE(module_ready)) {
		error = -EPERM;
		goto out;
	}
	if (!map_controllers) {
		error = -ENODEV;
		goto out;
	}
	if (READ_ONCE(polling_requested) ||
	    atomic_read_acquire(&polling_active) != 0) {
		error = -EBUSY;
		goto out;
	}
	if (READ_ONCE(status_probe_completed)) {
		error = -EALREADY;
		goto out;
	}

	for (index = 0; index < PDM_CONTROLLERS; index++) {
		struct frankel_pdm_controller *controller = &controllers[index];
		struct frankel_pdm_stats *stats = &controller->stats;
		u32 status;

		if (!(controller_mask & BIT(controller->pdm_id)))
			continue;
		if (!controller->base) {
			error = -ENODEV;
			goto out;
		}

		/* The sole hardware access is non-destructive FIFO status +0x10. */
		status = readl(controller->base + PDM_FIFO_STATUS_OFFSET);
		WRITE_ONCE(controller->last_status, status);
		atomic64_inc(&stats->status_polls);
		atomic64_inc(&stats->status_probe_reads);
		if (status & PDM_FIFO_STATUS_EMPTY)
			atomic64_inc(&stats->empty_polls);
	}
	WRITE_ONCE(status_probe_completed, true);

out:
	mutex_unlock(&poll_control_lock);
	return error;
}

static int status_probe_get(char *buffer,
			    const struct kernel_param *parameter)
{
	(void)parameter;
	return scnprintf(buffer, PAGE_SIZE, "%u\n",
			 READ_ONCE(status_probe_completed) ? 1 : 0);
}

static const struct kernel_param_ops status_probe_ops = {
	.set = status_probe_set,
	.get = status_probe_get,
};
module_param_cb(status_probe, &status_probe_ops, &status_probe_completed, 0600);
MODULE_PARM_DESC(status_probe,
		 "write 1 for one synchronous status-only AP read per selected controller; next polling start consumes proof");

static int polling_set(const char *value, const struct kernel_param *parameter)
{
	bool requested;
	int error;

	(void)parameter;
	error = kstrtobool(value, &requested);
	if (error)
		return error;

	mutex_lock(&poll_control_lock);
	if (requested) {
		if (!READ_ONCE(module_ready)) {
			error = -EPERM;
			goto out;
		}
		if (!map_controllers || !poll_task) {
			error = -ENODEV;
			goto out;
		}
		if (!READ_ONCE(polling_requested)) {
			if (!READ_ONCE(status_probe_completed)) {
				error = -EPERM;
				goto out;
			}
			reset_decimators();
			/* Consume the status-only proof before any worker can run. */
			WRITE_ONCE(status_probe_completed, false);
			WRITE_ONCE(polling_requested, true);
			wake_up_all(&polling_waitq);
		}
	} else {
		force_polling_off_locked();
	}
out:
	mutex_unlock(&poll_control_lock);
	return error;
}

static int polling_get(char *buffer, const struct kernel_param *parameter)
{
	(void)parameter;
	return scnprintf(buffer, PAGE_SIZE, "%u\n",
			 READ_ONCE(polling_requested) ? 1 : 0);
}

static const struct kernel_param_ops polling_ops = {
	.set = polling_set,
	.get = polling_get,
};
module_param_cb(polling_enabled, &polling_ops, &polling_requested, 0600);
MODULE_PARM_DESC(polling_enabled,
		 "start/stop destructive FIFO polling after consuming status_probe proof");

static bool exact_root_compatible(const struct device_node *node)
{
	const char *property;
	const char *second;
	size_t first_length = sizeof(FRANKEL_COMPAT_PRIMARY);
	size_t second_length = sizeof(FRANKEL_COMPAT_FAMILY);
	int property_length;

	property = of_get_property(node, "compatible", &property_length);
	if (!property || property_length != first_length + second_length)
		return false;
	second = property + first_length;
	return !memcmp(property, FRANKEL_COMPAT_PRIMARY, first_length) &&
	       !memcmp(second, FRANKEL_COMPAT_FAMILY, second_length);
}

static bool exact_aoc_compatible(const struct device_node *node)
{
	static const char expected[] = "google,aoc";
	const char *property;
	int property_length;

	property = of_get_property(node, "compatible", &property_length);
	return property && property_length == sizeof(expected) &&
	       !memcmp(property, expected, sizeof(expected));
}

static int discover_frankel_blk_aoc(struct resource *blk_aoc)
{
	struct device_node *node = NULL;
	bool root_seen = false;
	bool root_valid = false;
	unsigned int aoc_nodes = 0;
	int resource_error = -ENODEV;

	/* of_find_all_nodes() releases the reference to its previous argument. */
	while ((node = of_find_all_nodes(node))) {
		if (!node->parent) {
			const char *model;

			root_seen = true;
			root_valid = !of_property_read_string(node, "model", &model) &&
				     !strcmp(model, FRANKEL_MODEL) &&
				     exact_root_compatible(node);
		}

		if (!exact_aoc_compatible(node))
			continue;

		aoc_nodes++;
		if (aoc_nodes > 1)
			continue;
		if (of_property_match_string(node, "reg-names", "blk_aoc") != 0) {
			resource_error = -EINVAL;
			continue;
		}
		resource_error = of_address_to_resource(node, 0, blk_aoc);
	}

	if (!root_seen || !root_valid) {
		pr_err("%s: exact Frankel root model/compatible guard failed\n",
		       KBUILD_MODNAME);
		return -ENODEV;
	}
	if (aoc_nodes != 1 || resource_error) {
		pr_err("%s: expected exactly one google,aoc node with reg-names[0]=blk_aoc\n",
		       KBUILD_MODNAME);
		return resource_error ? resource_error : -ENODEV;
	}
	if (resource_type(blk_aoc) != IORESOURCE_MEM ||
	    blk_aoc->start != FRANKEL_BLK_AOC_START ||
	    resource_size(blk_aoc) != FRANKEL_BLK_AOC_SIZE) {
		pr_err("%s: blk_aoc guard mismatch: %pr\n",
		       KBUILD_MODNAME, blk_aoc);
		return -ERANGE;
	}
	return 0;
}

static void initialize_controller(struct frankel_pdm_controller *controller)
{
	struct frankel_pdm_stats *stats = &controller->stats;

	spin_lock_init(&controller->pcm_lock);
	init_waitqueue_head(&controller->callback_wait);
	atomic_set(&controller->callbacks_in_flight, 0);
	atomic64_set(&stats->status_polls, 0);
	atomic64_set(&stats->status_probe_reads, 0);
	atomic64_set(&stats->empty_polls, 0);
	atomic64_set(&stats->fifo_words, 0);
	atomic64_set(&stats->pdm_bits, 0);
	atomic64_set(&stats->decimated_frames, 0);
	atomic64_set(&stats->delivered_frames, 0);
	atomic64_set(&stats->discarded_frames, 0);
	atomic64_set(&stats->period_events, 0);
	atomic64_set(&stats->overruns, 0);
	atomic64_set(&stats->decimator_clips, 0);
}

static int map_pdm_controllers(const struct resource *blk_aoc)
{
	resource_size_t resource_bytes = resource_size(blk_aoc);
	unsigned int index;
	int error = -ERANGE;

	if (!map_controllers)
		return 0;
	if (projection_ack != FRANKEL_PDM0_AP_PHYS) {
		pr_err("%s: mapping requires projection_ack=0x%lx\n",
		       KBUILD_MODNAME, FRANKEL_PDM0_AP_PHYS);
		return -EPERM;
	}

	for (index = 0; index < PDM_CONTROLLERS; index++) {
		struct frankel_pdm_controller *controller = &controllers[index];
		resource_size_t offset = FRANKEL_PDM_LOCAL_BASE +
			controller->pdm_id * FRANKEL_PDM_STRIDE;

		if (!(controller_mask & BIT(controller->pdm_id)))
			continue;
		if (offset + FRANKEL_PDM_WINDOW_SIZE > resource_bytes)
			goto error_unmap;
		controller->physical = blk_aoc->start + offset;
		controller->base = ioremap(controller->physical,
					  FRANKEL_PDM_WINDOW_SIZE);
		if (!controller->base) {
			error = -ENOMEM;
			goto error_unmap;
		}
	}
	return 0;

	error_unmap:
	while (index > 0) {
		index--;
		if (controllers[index].base) {
			iounmap(controllers[index].base);
			controllers[index].base = NULL;
		}
	}
	return error;
}

static void unmap_pdm_controllers(void)
{
	unsigned int index;

	for (index = 0; index < PDM_CONTROLLERS; index++) {
		if (!controllers[index].base)
			continue;
		iounmap(controllers[index].base);
		controllers[index].base = NULL;
	}
}

static void complete_period_callback(struct frankel_pdm_controller *controller)
{
	if (atomic_dec_and_test(&controller->callbacks_in_flight))
		wake_up_all(&controller->callback_wait);
}

static void deliver_pcm_frame(struct frankel_pdm_controller *controller,
			      s32 sample)
{
	struct snd_pcm_substream *substream = NULL;
	struct snd_pcm_runtime *runtime;
	unsigned long flags;
	unsigned long stream_flags;
	bool notify = false;
	bool xrun;

	atomic64_inc(&controller->stats.decimated_frames);
	spin_lock_irqsave(&controller->pcm_lock, flags);
	substream = controller->substream;
	if (!controller->running || !substream || !substream->runtime ||
	    !substream->runtime->dma_area || !substream->runtime->buffer_size ||
	    !substream->runtime->period_size) {
		atomic64_inc(&controller->stats.discarded_frames);
		spin_unlock_irqrestore(&controller->pcm_lock, flags);
		return;
	}

	runtime = substream->runtime;
	((s32 *)runtime->dma_area)[controller->hw_position] = sample;
	controller->hw_position++;
	if (controller->hw_position >= runtime->buffer_size)
		controller->hw_position = 0;
	controller->period_position++;
	atomic64_inc(&controller->stats.delivered_frames);

	if (controller->period_position >= runtime->period_size) {
		controller->period_position %= runtime->period_size;
		atomic_inc(&controller->callbacks_in_flight);
		notify = true;
		atomic64_inc(&controller->stats.period_events);
	}
	spin_unlock_irqrestore(&controller->pcm_lock, flags);

	if (!notify)
		return;

	snd_pcm_period_elapsed(substream);
	snd_pcm_stream_lock_irqsave(substream, stream_flags);
	xrun = substream->runtime &&
		substream->runtime->state == SNDRV_PCM_STATE_XRUN;
	snd_pcm_stream_unlock_irqrestore(substream, stream_flags);

	spin_lock_irqsave(&controller->pcm_lock, flags);
	if (controller->substream == substream && xrun &&
	    !controller->xrun_reported) {
		controller->xrun_reported = true;
		controller->running = false;
		atomic64_inc(&controller->stats.overruns);
	}
	spin_unlock_irqrestore(&controller->pcm_lock, flags);
	complete_period_callback(controller);
}

/* CIC arithmetic is explicitly modulo 2^64, as required by CIC integrators. */
static s64 cic_wrap_add(s64 left, s64 right)
{
	return (s64)((u64)left + (u64)right);
}

static s64 cic_wrap_sub(s64 left, s64 right)
{
	return (s64)((u64)left - (u64)right);
}

static void consume_pdm_bit(struct frankel_pdm_controller *controller,
			    unsigned int bit)
{
	s64 value = bit ? 1 : -1;
	s64 gain;
	s64 sample_value;
	unsigned int stage;

	for (stage = 0; stage < decimator_order; stage++) {
		controller->integrator[stage] =
			cic_wrap_add(controller->integrator[stage], value);
		value = controller->integrator[stage];
	}

	controller->decimator_phase++;
	if (controller->decimator_phase != PDM_DECIMATION)
		return;
	controller->decimator_phase = 0;

	for (stage = 0; stage < decimator_order; stage++) {
		s64 delayed = controller->comb_delay[stage];

		controller->comb_delay[stage] = value;
		value = cic_wrap_sub(value, delayed);
	}

	/* A +/-1 PDM stream has normalized DC gain R^N. */
	gain = decimator_order == 3 ? 15625 : 25;
	if (value > gain) {
		value = gain;
		atomic64_inc(&controller->stats.decimator_clips);
	} else if (value < -gain) {
		value = -gain;
		atomic64_inc(&controller->stats.decimator_clips);
	}
	sample_value = (value * S32_MAX) / gain;
	deliver_pcm_frame(controller, (s32)sample_value);
}

static void consume_fifo_word(struct frankel_pdm_controller *controller,
			      u32 word)
{
	unsigned int sequence_index;

	/* bits[7:0] are not sample payload; bytes +1, +2, +3 carry 24 bits. */
	for (sequence_index = 0; sequence_index < 3; sequence_index++) {
		unsigned int byte_index = pdm_reverse_bytes ?
			3 - sequence_index : 1 + sequence_index;
		u8 payload = (word >> (byte_index * 8)) & 0xff;
		unsigned int bit_index;

		for (bit_index = 0; bit_index < 8; bit_index++) {
			unsigned int source_bit = pdm_msb_first ?
				7 - bit_index : bit_index;
			unsigned int bit = (payload >> source_bit) & 1;

			consume_pdm_bit(controller, bit ^ pdm_invert);
		}
	}
	atomic64_add(24, &controller->stats.pdm_bits);
}

static bool poll_one_controller(struct frankel_pdm_controller *controller)
{
	u32 status;
	u32 word;

	/* These are the only two MMIO reads in the module. */
	status = readl(controller->base + PDM_FIFO_STATUS_OFFSET);
	WRITE_ONCE(controller->last_status, status);
	atomic64_inc(&controller->stats.status_polls);
	if (status & PDM_FIFO_STATUS_EMPTY) {
		atomic64_inc(&controller->stats.empty_polls);
		return false;
	}

	if (!READ_ONCE(polling_requested))
		return false;
	word = readl(controller->base + PDM_FIFO_DATA_OFFSET);
	atomic64_inc(&controller->stats.fifo_words);
	consume_fifo_word(controller, word);
	return true;
}

static int frankel_pdm_poll_thread(void *unused)
{
	unsigned int iterations = 0;

	(void)unused;
	while (!kthread_should_stop()) {
		wait_event_interruptible(polling_waitq,
			kthread_should_stop() || READ_ONCE(polling_requested));
		if (kthread_should_stop())
			break;

		/*
		 * Serialize activation against force_polling_off_locked().  If the
		 * stop side gets the mutex first, this worker observes false and can
		 * never publish active=1 after the stop has returned.  If this side
		 * gets it first, the stop side must observe active=1 and wait for the
		 * release-store of zero below.
		 */
		mutex_lock(&poll_control_lock);
		if (kthread_should_stop() || !READ_ONCE(polling_requested)) {
			mutex_unlock(&poll_control_lock);
			continue;
		}
		atomic_set_release(&polling_active, 1);
		mutex_unlock(&poll_control_lock);
		wake_up_all(&polling_waitq);
		while (!kthread_should_stop() &&
		       READ_ONCE(polling_requested)) {
			bool popped = false;
			unsigned int index;

			for (index = 0; index < PDM_CONTROLLERS; index++) {
				if (!READ_ONCE(polling_requested))
					break;
				if (!(controller_mask &
				      BIT(controllers[index].pdm_id)))
					continue;
				popped |= poll_one_controller(&controllers[index]);
			}
			if ((++iterations & 0xff) == 0)
				cond_resched();
			else if (!popped)
				cpu_relax();
		}
		atomic_set_release(&polling_active, 0);
		wake_up_all(&polling_waitq);
	}

	atomic_set_release(&polling_active, 0);
	wake_up_all(&polling_waitq);
	return 0;
}

static int frankel_pcm_open(struct snd_pcm_substream *substream)
{
	struct frankel_pdm_controller *controller =
		snd_pcm_substream_chip(substream);
	struct snd_pcm_runtime *runtime = substream->runtime;
	unsigned long flags;
	int error;

	if (!(controller_mask & BIT(controller->pdm_id)))
		return -ENODEV;
	runtime->hw = frankel_pdm_pcm_hardware;
	runtime->private_data = controller;
	error = snd_pcm_hw_constraint_integer(runtime,
					      SNDRV_PCM_HW_PARAM_PERIODS);
	if (error)
		return error;

	spin_lock_irqsave(&controller->pcm_lock, flags);
	controller->substream = substream;
	controller->running = false;
	controller->xrun_reported = false;
	spin_unlock_irqrestore(&controller->pcm_lock, flags);
	return 0;
}

static int frankel_pcm_close(struct snd_pcm_substream *substream)
{
	struct frankel_pdm_controller *controller =
		snd_pcm_substream_chip(substream);
	unsigned long flags;

	spin_lock_irqsave(&controller->pcm_lock, flags);
	controller->running = false;
	controller->substream = NULL;
	spin_unlock_irqrestore(&controller->pcm_lock, flags);
	wait_event(controller->callback_wait,
		   atomic_read_acquire(&controller->callbacks_in_flight) == 0);
	return 0;
}

static int frankel_pcm_prepare(struct snd_pcm_substream *substream)
{
	struct frankel_pdm_controller *controller =
		snd_pcm_substream_chip(substream);
	unsigned long flags;

	spin_lock_irqsave(&controller->pcm_lock, flags);
	controller->hw_position = 0;
	controller->period_position = 0;
	controller->running = false;
	controller->xrun_reported = false;
	spin_unlock_irqrestore(&controller->pcm_lock, flags);
	return 0;
}

static int frankel_pcm_trigger(struct snd_pcm_substream *substream, int command)
{
	struct frankel_pdm_controller *controller =
		snd_pcm_substream_chip(substream);
	unsigned long flags;
	int error = 0;

	spin_lock_irqsave(&controller->pcm_lock, flags);
	switch (command) {
	case SNDRV_PCM_TRIGGER_START:
		controller->hw_position = 0;
		controller->period_position = 0;
		controller->xrun_reported = false;
		controller->running = true;
		break;
	case SNDRV_PCM_TRIGGER_PAUSE_RELEASE:
		controller->running = true;
		break;
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
	case SNDRV_PCM_TRIGGER_PAUSE_PUSH:
		controller->running = false;
		break;
	default:
		error = -EINVAL;
		break;
	}
	spin_unlock_irqrestore(&controller->pcm_lock, flags);
	return error;
}

static int frankel_pcm_sync_stop(struct snd_pcm_substream *substream)
{
	struct frankel_pdm_controller *controller =
		snd_pcm_substream_chip(substream);

	wait_event(controller->callback_wait,
		   atomic_read_acquire(&controller->callbacks_in_flight) == 0);
	return 0;
}

static snd_pcm_uframes_t frankel_pcm_pointer(
		struct snd_pcm_substream *substream)
{
	struct frankel_pdm_controller *controller =
		snd_pcm_substream_chip(substream);

	return READ_ONCE(controller->hw_position);
}

static const struct snd_pcm_ops frankel_pcm_ops = {
	.open = frankel_pcm_open,
	.close = frankel_pcm_close,
	.ioctl = snd_pcm_lib_ioctl,
	.prepare = frankel_pcm_prepare,
	.trigger = frankel_pcm_trigger,
	.sync_stop = frankel_pcm_sync_stop,
	.pointer = frankel_pcm_pointer,
};

static int create_capture_pcms(struct snd_card *card)
{
	unsigned int index;

	for (index = 0; index < PDM_CONTROLLERS; index++) {
		struct frankel_pdm_controller *controller = &controllers[index];
		struct snd_pcm *pcm;
		int error;

		error = snd_pcm_new(card, controller->pcm_name,
				    controller->pdm_id, 0, 1, &pcm);
		if (error)
			return error;
		pcm->private_data = controller;
		pcm->info_flags = 0;
		strscpy(pcm->name, controller->pcm_name, sizeof(pcm->name));
		snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_CAPTURE, &frankel_pcm_ops);
		error = snd_pcm_set_managed_buffer_all(pcm,
				SNDRV_DMA_TYPE_VMALLOC, NULL,
				16 * 1024, PCM_BUFFER_BYTES_MAX);
		if (error)
			return error;
	}
	return 0;
}

static void report_stats(void)
{
	unsigned int index;

	for (index = 0; index < PDM_CONTROLLERS; index++) {
		struct frankel_pdm_controller *controller = &controllers[index];
		struct frankel_pdm_stats *stats = &controller->stats;

		pr_info("%s: pdm%u polls=%lld probe_reads=%lld empty=%lld words=%lld frames=%lld delivered=%lld discarded=%lld overruns=%lld clips=%lld\n",
			KBUILD_MODNAME, controller->pdm_id,
			atomic64_read(&stats->status_polls),
			atomic64_read(&stats->status_probe_reads),
			atomic64_read(&stats->empty_polls),
			atomic64_read(&stats->fifo_words),
			atomic64_read(&stats->decimated_frames),
			atomic64_read(&stats->delivered_frames),
			atomic64_read(&stats->discarded_frames),
			atomic64_read(&stats->overruns),
			atomic64_read(&stats->decimator_clips));
	}
}

static int __init frankel_pdm_alsa_init(void)
{
	struct resource blk_aoc;
	unsigned int index;
	int error;

	BUILD_BUG_ON(PCM_OUTPUT_RATE != 192000);
	if (decimator_order != 1 && decimator_order != 3) {
		pr_err("%s: decimator_order must be 1 or 3\n", KBUILD_MODNAME);
		return -EINVAL;
	}
	if (!controller_mask || (controller_mask & ~PDM_ALLOWED_MASK)) {
		pr_err("%s: controller_mask must be a nonzero subset of 0x%lx\n",
		       KBUILD_MODNAME, PDM_ALLOWED_MASK);
		return -EINVAL;
	}
	for (index = 0; index < PDM_CONTROLLERS; index++)
		initialize_controller(&controllers[index]);

	error = discover_frankel_blk_aoc(&blk_aoc);
	if (error)
		return error;

	pdm_device = root_device_register("frankel-pdm");
	if (IS_ERR(pdm_device)) {
		error = PTR_ERR(pdm_device);
		pdm_device = NULL;
		return error;
	}

	error = snd_card_new(pdm_device, 1, "FrankelPDM", THIS_MODULE, 0,
			     &pdm_card);
	if (error)
		goto error_device;
	strscpy(pdm_card->driver, "FrankelPDM", sizeof(pdm_card->driver));
	strscpy(pdm_card->shortname, "Frankel raw PDM",
		sizeof(pdm_card->shortname));
	strscpy(pdm_card->longname,
		"Guarded Frankel PDM0/PDM2/PDM3 raw capture",
		sizeof(pdm_card->longname));

	error = create_capture_pcms(pdm_card);
	if (error)
		goto error_card;
	if (map_controllers) {
		error = register_pm_notifier(&frankel_pdm_pm_notifier);
		if (error)
			goto error_card;
		pm_guard_registered = true;
	}

	error = map_pdm_controllers(&blk_aoc);
	if (error)
		goto error_pm_guard;
	if (map_controllers) {
		poll_task = kthread_run(frankel_pdm_poll_thread, NULL,
					"frankel_pdm_poll");
		if (IS_ERR(poll_task)) {
			error = PTR_ERR(poll_task);
			poll_task = NULL;
			goto error_unmap;
		}
	}
	error = snd_card_register(pdm_card);
	if (error)
		goto error_thread;

	WRITE_ONCE(module_ready, true);
	pr_info("%s: registered 3x mono S32_LE/192000 capture; CIC%u/R25 mask=0x%x mapped=%u polling=0\n",
		KBUILD_MODNAME, decimator_order, controller_mask,
		map_controllers ? 1 : 0);
	pr_info("%s: provisional PDM chronology: bytes=%s bits=%s polarity=%s\n",
		KBUILD_MODNAME, pdm_reverse_bytes ? "+3,+2,+1" : "+1,+2,+3",
		pdm_msb_first ? "MSB-first" : "LSB-first",
		pdm_invert ? "inverted" : "normal");
	pr_info("%s: no MMIO read occurs until status_probe=1; polling requires and consumes that status-only proof; no MMIO write exists\n",
		KBUILD_MODNAME);
	return 0;

	error_thread:
	if (poll_task) {
		kthread_stop(poll_task);
		poll_task = NULL;
	}
	error_unmap:
	unmap_pdm_controllers();
	error_pm_guard:
	if (pm_guard_registered) {
		unregister_pm_notifier(&frankel_pdm_pm_notifier);
		pm_guard_registered = false;
	}
	error_card:
	snd_card_free(pdm_card);
	pdm_card = NULL;
	error_device:
	root_device_unregister(pdm_device);
	pdm_device = NULL;
	return error;
}

static void __exit frankel_pdm_alsa_exit(void)
{
	WRITE_ONCE(module_ready, false);
	mutex_lock(&poll_control_lock);
	force_polling_off_locked();
	mutex_unlock(&poll_control_lock);
	if (poll_task) {
		kthread_stop(poll_task);
		poll_task = NULL;
	}
	if (pdm_card) {
		snd_card_free(pdm_card);
		pdm_card = NULL;
	}
	if (pm_guard_registered) {
		unregister_pm_notifier(&frankel_pdm_pm_notifier);
		pm_guard_registered = false;
	}
	unmap_pdm_controllers();
	if (pdm_device) {
		root_device_unregister(pdm_device);
		pdm_device = NULL;
	}
	report_stats();
	pr_info("%s: unloaded after polling stopped; no MMIO write performed\n",
		KBUILD_MODNAME);
}

module_init(frankel_pdm_alsa_init);
module_exit(frankel_pdm_alsa_exit);

MODULE_AUTHOR("CSR460 Android audio research");
MODULE_DESCRIPTION("Guarded read-only Frankel raw-PDM FIFO ALSA capture prototype");
MODULE_LICENSE("GPL");
