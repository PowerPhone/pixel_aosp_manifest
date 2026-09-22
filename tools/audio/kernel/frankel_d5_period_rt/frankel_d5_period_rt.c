// SPDX-License-Identifier: GPL-2.0-only
/* Sleep-safe, dedicated real-time period delivery for Frankel PCM0,D5.
 *
 * The companion ELF patch redirects only the queue_work_on relocation in
 * aoc_pcm_irq_process, and the util module's flush/destroy imports. The
 * original IRQ routine still obtains actual AoC counters, updates the real
 * position and enforces RUNNING/cancel checks. No synthetic clock or XRUN
 * recovery is implemented here.
 *
 * Frankel PCMs are nonatomic: snd_pcm_period_elapsed takes a mutex. Calling
 * it in the mailbox hard IRQ is invalid. The original ordered WQ_HIGHPRI
 * shares a CFS pool with GPU work; measured pending delays exceeded the
 * complete 20 ms playback ring. This module preallocates a dedicated FIFO
 * kthread and dispatches the original period callback in sleepable context.
 */
#include <linux/atomic.h>
#include <linux/errno.h>
#include <linux/err.h>
#include <linux/init.h>
#include <linux/kthread.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>
#include <uapi/linux/sched/types.h>

/* Exact reviewed aoc_alsa_dev_util module layout, not a generic ABI. */
#define FRANKEL_PERIOD_WORK_OFFSET 0x1b0
#define FRANKEL_PCM_INDEX_OFFSET 0xf0
#define FRANKEL_CANCEL_OFFSET 0x100
#define FRANKEL_PERIOD_WQ_OFFSET 0x198

static int priority = 95;
module_param(priority, int, 0444);
MODULE_PARM_DESC(priority, "Dedicated D5 period thread FIFO priority (1..99)");

static struct kthread_worker *period_worker;
static struct kthread_work period_work;
static DEFINE_RAW_SPINLOCK(binding_lock);
static DEFINE_MUTEX(teardown_lock);
static struct work_struct *bound_work;
static struct workqueue_struct *bound_wq;
static bool closing;
static u64 queued_at_ns;
static atomic64_t queued_count = ATOMIC64_INIT(0);
static atomic64_t executed_count = ATOMIC64_INIT(0);
static atomic64_t busy_count = ATOMIC64_INIT(0);
static atomic64_t binding_count = ATOMIC64_INIT(0);
static atomic64_t maximum_queue_ns = ATOMIC64_INIT(0);
static atomic64_t maximum_callback_ns = ATOMIC64_INIT(0);

static int counter_get(char *buffer, const struct kernel_param *parameter)
{
	return scnprintf(buffer, PAGE_SIZE, "%lld\n",
			 (long long)atomic64_read(parameter->arg));
}

static const struct kernel_param_ops counter_ops = { .get = counter_get };
module_param_cb(queued, &counter_ops, &queued_count, 0444);
module_param_cb(executed, &counter_ops, &executed_count, 0444);
module_param_cb(busy, &counter_ops, &busy_count, 0444);
module_param_cb(bindings, &counter_ops, &binding_count, 0444);
module_param_cb(max_queue_ns, &counter_ops, &maximum_queue_ns, 0444);
module_param_cb(max_callback_ns, &counter_ops, &maximum_callback_ns, 0444);

static void update_maximum(atomic64_t *counter, u64 value)
{
	s64 previous = atomic64_read(counter);

	while (value > previous) {
		s64 observed = atomic64_cmpxchg(counter, previous, value);

		if (observed == previous)
			break;
		previous = observed;
	}
}

static void deliver_period(struct kthread_work *unused)
{
	struct work_struct *original;
	unsigned long flags;
	u64 begin = ktime_get_ns();
	u64 queued;

	(void)unused;
	raw_spin_lock_irqsave(&binding_lock, flags);
	original = bound_work;
	queued = queued_at_ns;
	raw_spin_unlock_irqrestore(&binding_lock, flags);
	if (WARN_ON_ONCE(!original || !original->func))
		return;
	if (queued && begin >= queued)
		update_maximum(&maximum_queue_ns, begin - queued);

	/* Preserve original work argument and work_func_t/KCFI prototype. */
	original->func(original);
	atomic64_inc(&executed_count);
	update_maximum(&maximum_callback_ns, ktime_get_ns() - begin);
}

/* The ELF patch routes only aoc_pcm_irq_process's period-work call here.
 * kthread_queue_work returns true on a new enqueue and false when pending,
 * including a single follow-up enqueue while the callback executes. This
 * matches the original queue_work_on contract used by the IRQ's busy path.
 */
bool pp_d5_qwork(int cpu, struct workqueue_struct *wq, struct work_struct *work)
{
	u8 *stream = (u8 *)work - FRANKEL_PERIOD_WORK_OFFSET;
	unsigned long flags;
	bool queued;

	if (READ_ONCE(*(u32 *)(stream + FRANKEL_PCM_INDEX_OFFSET)) != 5)
		return queue_work_on(cpu, wq, work);
	if (READ_ONCE(*(int *)(stream + FRANKEL_CANCEL_OFFSET)) > 0)
		return false;
	if (WARN_ON_ONCE(READ_ONCE(*(struct workqueue_struct **)
				  (stream + FRANKEL_PERIOD_WQ_OFFSET)) != wq))
		return false;

	raw_spin_lock_irqsave(&binding_lock, flags);
	if (!bound_work) {
		bound_work = work;
		bound_wq = wq;
		closing = false;
		atomic64_inc(&binding_count);
	}
	if (unlikely(closing || bound_work != work || bound_wq != wq)) {
		raw_spin_unlock_irqrestore(&binding_lock, flags);
		pr_err_ratelimited("frankel_d5_period_rt: conflicting/closing D5 binding\n");
		return false;
	}
	queued = kthread_queue_work(period_worker, &period_work);
	if (queued) {
		queued_at_ns = ktime_get_ns();
		atomic64_inc(&queued_count);
	} else {
		atomic64_inc(&busy_count);
	}
	raw_spin_unlock_irqrestore(&binding_lock, flags);
	return queued;
}
EXPORT_SYMBOL_GPL(pp_d5_qwork);

/* The stock close/reset flow first disables its ISR/cancel path and then
 * flushes and destroys this exact WQ. Extend those same barriers to the RT
 * dispatch before the original stream container may be freed. No reference
 * to that container is retained after destroy returns.
 */
void pp_d5_flush(struct workqueue_struct *wq)
{
	unsigned long flags;
	bool selected;

	mutex_lock(&teardown_lock);
	raw_spin_lock_irqsave(&binding_lock, flags);
	selected = bound_wq == wq;
	raw_spin_unlock_irqrestore(&binding_lock, flags);
	if (selected)
		kthread_flush_work(&period_work);
	__flush_workqueue(wq);
	mutex_unlock(&teardown_lock);
}
EXPORT_SYMBOL_GPL(pp_d5_flush);

void pp_d5_destroy(struct workqueue_struct *wq)
{
	unsigned long flags;
	bool selected;

	mutex_lock(&teardown_lock);
	raw_spin_lock_irqsave(&binding_lock, flags);
	selected = bound_wq == wq;
	if (selected)
		closing = true;
	raw_spin_unlock_irqrestore(&binding_lock, flags);
	if (selected) {
		kthread_flush_work(&period_work);
		raw_spin_lock_irqsave(&binding_lock, flags);
		bound_work = NULL;
		bound_wq = NULL;
		queued_at_ns = 0;
		closing = false;
		raw_spin_unlock_irqrestore(&binding_lock, flags);
	}
	destroy_workqueue(wq);
	mutex_unlock(&teardown_lock);
}
EXPORT_SYMBOL_GPL(pp_d5_destroy);

static int __init frankel_d5_period_rt_init(void)
{
	struct sched_param parameter = { .sched_priority = priority };
	int status;

	if (priority < 1 || priority > 99)
		return -EINVAL;
	kthread_init_work(&period_work, deliver_period);
	period_worker = kthread_create_worker(0, "pp_d5_period");
	if (IS_ERR(period_worker))
		return PTR_ERR(period_worker);
	status = sched_setscheduler_nocheck(period_worker->task, SCHED_FIFO, &parameter);
	if (status) {
		kthread_destroy_worker(period_worker);
		return status;
	}
	pr_info("frankel_d5_period_rt: ready, dedicated FIFO/%d period delivery\n", priority);
	return 0;
}

static void __exit frankel_d5_period_rt_exit(void)
{
	/* Import dependency keeps us loaded until the patched util is unloaded. */
	WARN_ON(bound_work != NULL);
	kthread_destroy_worker(period_worker);
}

module_init(frankel_d5_period_rt_init);
module_exit(frankel_d5_period_rt_exit);
MODULE_DESCRIPTION("Frankel D5 sleep-safe dedicated RT ALSA period worker");
MODULE_AUTHOR("PowerPhone research build");
MODULE_LICENSE("GPL");
