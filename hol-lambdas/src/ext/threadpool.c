#include "postgres.h"
#include "miscadmin.h"
#include "utils/memutils.h"
#include "threadpool.h"
#include <pthread.h>
#include <string.h>

/* -------------------- Unbounded queue (linked list) -------------------- */

typedef struct TP_QNode
{
    struct TP_QNode *next;
    size_t len;
    char   data[FLEXIBLE_ARRAY_MEMBER]; /* job bytes follow */
} TP_QNode;

typedef struct TP_Queue
{
    TP_QNode *head;
    TP_QNode *tail;
    size_t    count;

    pthread_mutex_t mu;
    pthread_cond_t  not_empty;
    bool shutdown;
} TP_Queue;

struct TP_Pool
{
    pthread_t *threads;
    size_t nthreads;
    TP_Queue q;
    tp_worker_func fn;
};

/* allocate a node containing a copy of [job, job+len) in ONE palloc */
static inline TP_QNode *
qnode_create_copy(const void *job, size_t len)
{
    TP_QNode *n;

    if (len == 0 || job == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("threadpool job must be non-empty")));

    n = (TP_QNode *) palloc(offsetof(TP_QNode, data) + len);
    n->next = NULL;
    n->len = len;
    memcpy(n->data, job, len);
    return n;
}

static void
q_init(TP_Queue *q)
{
    q->head = q->tail = NULL;
    q->count = 0;
    q->shutdown = false;

    pthread_mutex_init(&q->mu, NULL);
    pthread_cond_init(&q->not_empty, NULL);
}

static void
q_destroy(TP_Queue *q)
{
    pthread_mutex_destroy(&q->mu);
    pthread_cond_destroy(&q->not_empty);
    /* nodes are palloc'd and freed by MemoryContext deletion */
}

static void
q_enqueue(TP_Queue *q, TP_QNode *n)
{
    pthread_mutex_lock(&q->mu);

    if (q->shutdown)
    {
        pthread_mutex_unlock(&q->mu);
        return;
    }

    if (q->tail)
        q->tail->next = n;
    else
        q->head = n;

    q->tail = n;
    q->count++;

    pthread_cond_signal(&q->not_empty);
    pthread_mutex_unlock(&q->mu);
}

/* dequeue; returns false iff shutting down and empty */
static bool
q_dequeue(TP_Queue *q, TP_QNode **out)
{
    pthread_mutex_lock(&q->mu);

    while (q->head == NULL && !q->shutdown)
        pthread_cond_wait(&q->not_empty, &q->mu);

    if (q->head == NULL && q->shutdown)
    {
        pthread_mutex_unlock(&q->mu);
        return false;
    }

    TP_QNode *n = q->head;
    q->head = n->next;
    if (q->head == NULL)
        q->tail = NULL;

    q->count--;

    pthread_mutex_unlock(&q->mu);

    *out = n;
    return true;
}

static void *
tp_worker_main(void *arg)
{
    TP_Pool *p = (TP_Pool *) arg;
    TP_QNode *n = NULL;

    while (q_dequeue(&p->q, &n))
    {
        /* job bytes live in node->data */
        p->fn((void *) n->data);

        /*
         * DO NOT free n here:
         * - It's palloc'd (Postgres memory context)
         * - pfree/palloc aren't thread-safe
         * Memory is reclaimed when the owning context is deleted.
         */
        n = NULL;
    }

    return NULL;
}

/* -------------------- Public API (same as your header) -------------------- */

TP_Pool *
tp_create(int nthreads, int queue_capacity, tp_worker_func fn)
{
    (void) queue_capacity; /* always unbounded */

    if (nthreads <= 0)
        nthreads = 1;

    if (fn == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("threadpool worker function must not be NULL")));

    TP_Pool *p = (TP_Pool *) palloc0(sizeof(TP_Pool));
    p->nthreads = (size_t) nthreads;
    p->fn = fn;

    p->threads = (pthread_t *) palloc(sizeof(pthread_t) * p->nthreads);

    q_init(&p->q);

    for (size_t i = 0; i < p->nthreads; i++)
    {
        int rc = pthread_create(&p->threads[i], NULL, tp_worker_main, p);
        if (rc != 0)
        {
            /* ask all workers to exit */
            pthread_mutex_lock(&p->q.mu);
            p->q.shutdown = true;
            pthread_cond_broadcast(&p->q.not_empty);
            pthread_mutex_unlock(&p->q.mu);

            for (size_t j = 0; j < i; j++)
                pthread_join(p->threads[j], NULL);

            q_destroy(&p->q);

            ereport(ERROR,
                    (errcode(ERRCODE_SYSTEM_ERROR),
                     errmsg("pthread_create failed (rc=%d)", rc)));
        }
    }

    return p;
}

bool
tp_submit(TP_Pool *p, const void *job, size_t job_size)
{
    if (p == NULL)
        return false;

    /* fast reject if shutting down */
    pthread_mutex_lock(&p->q.mu);
    bool shutting_down = p->q.shutdown;
    pthread_mutex_unlock(&p->q.mu);
    if (shutting_down)
        return false;

    TP_QNode *n = qnode_create_copy(job, job_size);
    q_enqueue(&p->q, n);
    return true;
}

void
tp_finish_and_destroy(TP_Pool *p)
{
    if (!p)
        return;

    /* tell workers to stop once queue drains */
    pthread_mutex_lock(&p->q.mu);
    p->q.shutdown = true;
    pthread_cond_broadcast(&p->q.not_empty);
    pthread_mutex_unlock(&p->q.mu);

    for (size_t i = 0; i < p->nthreads; i++)
        pthread_join(p->threads[i], NULL);

    q_destroy(&p->q);

    /*
     * DO NOT pfree(p) / pfree(p->threads):
     * caller should delete the MemoryContext that owns these allocations
     * after threads have joined.
     */
}
