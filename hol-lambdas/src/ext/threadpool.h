#pragma once

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TP_Pool TP_Pool;

/*
 * Worker function called by pool threads.
 * Argument points to a private copy of the submitted job bytes.
 * The pointer is only valid for the duration of the call.
 */
typedef void (*tp_worker_func)(void *job);

/*
 * Create a threadpool.
 * - nthreads <= 0         => treated as 1
 * - queue_capacity <= 0   => unbounded queue (never blocks on full)
 * - queue_capacity > 0    => bounded queue (blocks submitter when full)
 *
 * NOTE: The pool uses malloc/free, not palloc/pfree.
 */
TP_Pool *tp_create(int nthreads, int queue_capacity, tp_worker_func fn);

/*
 * Submit a job to the pool.
 * The pool makes an internal copy of the job bytes (size = job_size).
 *
 * Returns false only if the pool is shutting down (or on OOM it ERRORs).
 */
bool tp_submit(TP_Pool *p, const void *job, size_t job_size);

/*
 * Shut down, join all worker threads, and free all resources.
 * Safe to call multiple times only if caller guards against double-free.
 */
void tp_finish_and_destroy(TP_Pool *p);

#ifdef __cplusplus
}
#endif
