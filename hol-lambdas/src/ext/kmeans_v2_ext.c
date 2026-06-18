/*
 * kmeans_v2_ext.c
 *
 * K-Means clustering UDF, structured after apply_mt_ext.c:
 *   - Uses lambda_injector + llvm_prepare_simple_expression (not llvm_prepare_lambda_tablefunc)
 *   - Uses TTSOpsMinimalTuple for tuplestore reads
 *   - Flat Datum[] arrays for points and centroids (cache-friendly)
 *   - Raw pthreads for the iterative assignment loop
 *   - N-dimensional: centroid averaging generalises to any number of float8 columns
 *
 * SQL signature:
 *   kmeans_v2(points    lambdatable,   -- arg 0: data points
 *             centroids lambdatable,   -- arg 1: initial centroids
 *             dist      "lambda",      -- arg 2: distance fn
 *             nthreads  int,           -- arg 3
 *             maxit     int)           -- arg 4: max iterations (e.g. 100)
 *   RETURNS SETOF RECORD
 *
 * Lambda convention (mirrors apply_mt):
 *   group 0 = p (data points)   -- remains variable across evaluations
 *   group 1 = c (centroid)      -- injected per centroid, baked in as constants
 *
 * Example:
 *   SELECT * FROM kmeans_v2(
 *     (SELECT x, y FROM points),
 *     (SELECT x, y FROM centroids),
 *     lambda(p:[px:float8, py:float8], c:[cx:float8, cy:float8])
 *       ((p.px - c.cx)^2 + (p.py - c.cy)^2),
 *     16, 100);
 *
 * Output columns: all point columns + cluster (int4)
 */

#include "postgres.h"
#include "funcapi.h"
#include "jit/llvmjit.h"
#include "optimizer/optimizer.h"
#include "executor/spi.h"
#include "executor/execExpr.h"
#include "stdint.h"
#include "utils/builtins.h"
#include "parser/parser.h"
#include "nodes/nodes.h"
#include "catalog/pg_type.h"
#include "access/htup_details.h"
#include "nodes/print.h"
#include "portability/instr_time.h"
#include "utils/lsyscache.h"
#include "utils/hsearch.h"
#include "common/config_info.h"
#include <math.h>
#include <float.h>
#include <pthread.h>
#include "miscadmin.h"
#include "utils/array.h"
#include "utils/lambda.h"

/* compiled distance function type: matches llvm_prepare_simple_expression return */
typedef Datum (*dist_fn_t)(Datum **);

/* -----------------------------------------------------------------------
 * Record-type descriptor
 * ----------------------------------------------------------------------- */

static TupleDesc
kmeans_v2_record_type(List *args)
{
    /* dist_lambda is argument 2; group 0 of its argTypesTupDesc = point schema */
    LambdaExpr *lambda   = (LambdaExpr *) list_nth(args, 3);
    TupleDesc   nodeDesc = (TupleDesc) list_nth(lambda->argTypesTupDesc, 0);
    TupleDesc   outDesc  = CreateTemplateTupleDesc(nodeDesc->natts + 1);

    for (int i = 0; i < nodeDesc->natts; i++)
        TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), nodeDesc, (AttrNumber)(i + 1));

    TupleDescInitEntry(outDesc, (AttrNumber)(nodeDesc->natts + 1),
                       "cluster", INT4OID, -1, 0);
    return outDesc;
}

PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1_RECTYPE(kmeans_v2, kmeans_v2_record_type);

/* -----------------------------------------------------------------------
 * Per-thread work item
 * ----------------------------------------------------------------------- */

typedef struct KMeansV2WorkItem
{
    uint64_t    start;          /* first point index (inclusive) */
    uint64_t    end;            /* last  point index (exclusive) */
    uint64_t    num_points;
    int         natts_point;    /* number of float8 columns per point */

    Datum      *points;         /* flat array: [p0_col0, p0_col1, ..., p1_col0, ...] */

    int         num_centroids;
    int        *assignments;    /* shared output [num_points]; non-overlapping ranges */

    float8     *coordsAgg;      /* per-thread accumulator: [ci * natts_point + d] */
    int        *assignCount;    /* per-thread: [ci] */
    bool        changesMade;    /* per-thread convergence flag */

    dist_fn_t  *dist_funcs;     /* compiled distance fn per centroid [num_centroids] */
} KMeansV2WorkItem;

/* -----------------------------------------------------------------------
 * Worker thread: assignment step + per-thread accumulation
 * ----------------------------------------------------------------------- */

static void *
kmeans_v2_worker(void *arg)
{
    KMeansV2WorkItem *a  = (KMeansV2WorkItem *) arg;
    const int         np = a->natts_point;
    const int         nc = a->num_centroids;

    for (uint64_t pi = a->start; pi < a->end && pi < a->num_points; pi++)
    {
        Datum  *p       = a->points + (size_t) pi * np;
        int     best_ci = 0;
        float8  best_d  = DBL_MAX;
        bool    first   = true;

        for (int ci = 0; ci < nc; ci++)
        {
            float8 d = DatumGetFloat8(a->dist_funcs[ci](&p));
            if (first || (!isnan(d) && d < best_d))
            {
                best_d  = d;
                best_ci = ci;
                first   = false;
            }
        }

        if (a->assignments[pi] != best_ci)
        {
            a->assignments[pi] = best_ci;
            a->changesMade     = true;
        }

        /* accumulate for centroid update */
        for (int d = 0; d < np; d++)
            a->coordsAgg[best_ci * np + d] += DatumGetFloat8(p[d]);
        a->assignCount[best_ci]++;
    }

    return NULL;
}

/* -----------------------------------------------------------------------
 * Main UDF entry point
 * ----------------------------------------------------------------------- */

Datum
kmeans_v2(PG_FUNCTION_ARGS)
{
    MemoryContext       oldcontext, per_query_ctx;
    TupleDesc           outDesc = NULL;
    Tuplestorestate    *tssPoints, *tssCentroids, *tsOut;
    LambdaExpr         *dist_lambda;
    TupleDesc           nodeDesc, centroidDesc;
    int                 nthreads, maxit;
    EState             *estate;

    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

    if (unlikely(rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo)))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (unlikely(!(rsinfo->allowedModes & SFRM_Materialize)))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not allowed in this context")));

    rsinfo->returnMode = SFRM_Materialize;

    dist_lambda = PG_GETARG_LAMBDA(3);
    nthreads    = PG_GETARG_INT32(4);
    maxit       = PG_GETARG_INT32(5);

    /* group 0 = points (variable), group 1 = centroids (injected per iter), group 3 = distance functions */
    nodeDesc     = (TupleDesc) list_nth(dist_lambda->argTypesTupDesc, 0);
    centroidDesc = (TupleDesc) list_nth(dist_lambda->argTypesTupDesc, 1);

    const int natts_point    = nodeDesc->natts;
    const int natts_centroid = centroidDesc->natts;

    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext    = MemoryContextSwitchTo(per_query_ctx);
    estate        = rsinfo->econtext->ecxt_estate;

    tssPoints    = ((TypedTuplestore *) PG_GETARG_POINTER(0))->tuplestorestate;
    tssCentroids = ((TypedTuplestore *) PG_GETARG_POINTER(1))->tuplestorestate;

    const int num_points    = (int) tuplestore_tuple_count(tssPoints);
    const int num_centroids = (int) tuplestore_tuple_count(tssCentroids);

    if (nthreads > num_points && num_points > 0)
        nthreads = num_points;
    if (nthreads < 1)
        nthreads = 1;

    /* ----------------------------------------------------------------
     * Read points into flat Datum array (mirrors apply_mt_ext.c)
     * ---------------------------------------------------------------- */
    Datum *points = (Datum *) palloc((size_t) num_points * natts_point * sizeof(Datum));
    {
        const TupleTableSlotOps *ops  = &TTSOpsMinimalTuple;
        TupleTableSlot          *slot = MakeTupleTableSlot(nodeDesc, ops);
        int idx = 0;

        while (tuplestore_gettupleslot(tssPoints, true, false, slot))
        {
            slot_getallattrs(slot);
            memcpy(points + (size_t) idx * natts_point,
                   slot->tts_values,
                   natts_point * sizeof(Datum));
            idx++;
        }
    }

    /* ----------------------------------------------------------------
     * Read initial centroids into flat Datum array
     * ---------------------------------------------------------------- */
    Datum *centroids = (Datum *) palloc((size_t) num_centroids * natts_centroid * sizeof(Datum));
    {
        const TupleTableSlotOps *ops  = &TTSOpsMinimalTuple;
        TupleTableSlot          *slot = MakeTupleTableSlot(centroidDesc, ops);
        int idx = 0;

        while (tuplestore_gettupleslot(tssCentroids, true, false, slot))
        {
            slot_getallattrs(slot);
            memcpy(centroids + (size_t) idx * natts_centroid,
                   slot->tts_values,
                   natts_centroid * sizeof(Datum));
            idx++;
        }
    }

    /* ----------------------------------------------------------------
     * Initialise assignments to -1 so the first iteration always runs
     * ---------------------------------------------------------------- */
    int *assignments = (int *) palloc((size_t) num_points * sizeof(int));
    memset(assignments, -1, (size_t) num_points * sizeof(int));

    /* ----------------------------------------------------------------
     * Allocate per-thread structures
     * ---------------------------------------------------------------- */
    KMeansV2WorkItem *thread_args =
        (KMeansV2WorkItem *) palloc0((size_t) nthreads * sizeof(KMeansV2WorkItem));
    pthread_t *workers =
        (pthread_t *) palloc((size_t) nthreads * sizeof(pthread_t));
    dist_fn_t *compiled_funcs =
        (dist_fn_t *) palloc((size_t) num_centroids * sizeof(dist_fn_t));

    for (int t = 0; t < nthreads; t++)
    {
        thread_args[t].num_points    = (uint64_t) num_points;
        thread_args[t].natts_point   = natts_point;
        thread_args[t].points        = points;
        thread_args[t].num_centroids = num_centroids;
        thread_args[t].assignments   = assignments;
        thread_args[t].coordsAgg     = (float8 *) palloc(
            (size_t) num_centroids * natts_point * sizeof(float8));
        thread_args[t].assignCount   = (int *) palloc(
            (size_t) num_centroids * sizeof(int));
        thread_args[t].dist_funcs    = compiled_funcs; /* shared read-only after compile */
        thread_args[t].start = (uint64_t) num_points * (uint64_t) t / (uint64_t) nthreads;
        thread_args[t].end   = (uint64_t) num_points * (uint64_t)(t + 1) / (uint64_t) nthreads;
    }

    /* ----------------------------------------------------------------
     * Output descriptor
     * ---------------------------------------------------------------- */
    outDesc = CreateTemplateTupleDesc(natts_point + 1);
    for (int i = 0; i < natts_point; i++)
        TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), nodeDesc, (AttrNumber)(i + 1));
    TupleDescInitEntry(outDesc, (AttrNumber)(natts_point + 1),
                       "cluster", INT4OID, -1, 0);

    tsOut = tuplestore_begin_heap(false, false, work_mem);

    /* ==================================================================
     * K-Means main loop
     * ================================================================== */
    bool changed = true;

    for (int iter = 0; iter < maxit && changed; iter++)
    {
        /*
         * Compile one specialised distance function per centroid.
         * Mirrors the apply_mt lambda-table loop: inject centroid values
         * (group 1) → reduce to a FOL over points (group 0) → JIT-compile.
         * Centroid coordinates become LLVM constants, enabling full
         * constant-folding and arithmetic optimisation in the generated code.
         */
        for (int ci = 0; ci < num_centroids; ci++)
        {
            Datum inner_tuples[2];
            inner_tuples[0] = Int8GetDatum(0);   /* group 0 (points) stays variable */
            inner_tuples[1] = PointerGetDatum(   /* inject centroid coords as group 1 */
                centroids + (size_t) ci * natts_centroid);

            LambdaExpr *pt_dist = lambda_injector(dist_lambda, inner_tuples);
            pt_dist->expr = (Expr *) eval_const_expressions(NULL, (Node *) pt_dist->expr);

            llvm_enter_tmp_context(estate);
            ExecInitLambdaExpr((Node *) pt_dist, true, false);
            compiled_funcs[ci] =
                llvm_prepare_simple_expression(castNode(ExprState, pt_dist->exprstate));
            llvm_leave_tmp_context(estate);
        }

        /* Reset per-thread buffers */
        for (int t = 0; t < nthreads; t++)
        {
            memset(thread_args[t].coordsAgg,   0,
                   (size_t) num_centroids * natts_point * sizeof(float8));
            memset(thread_args[t].assignCount, 0,
                   (size_t) num_centroids * sizeof(int));
            thread_args[t].changesMade = false;
        }

        /* Launch worker threads */
        for (int t = 0; t < nthreads; t++)
            pthread_create(&workers[t], NULL, kmeans_v2_worker, &thread_args[t]);

        /* Wait for all workers to finish */
        for (int t = 0; t < nthreads; t++)
            pthread_join(workers[t], NULL);

        /* Check convergence */
        changed = false;
        for (int t = 0; t < nthreads; t++)
            changed |= thread_args[t].changesMade;

        /*
         * Update centroid positions (N-dimensional):
         * merge per-thread accumulators and compute new mean coordinates.
         * Assumes the first natts_point columns of each centroid row are
         * the coordinates (same schema as the point table).
         */
        for (int ci = 0; ci < num_centroids; ci++)
        {
            int    total_count                = 0;
            float8 total_sum[natts_point]; /* VLA: fine for practical dimensionalities */
            memset(total_sum, 0, (size_t) natts_point * sizeof(float8));

            for (int t = 0; t < nthreads; t++)
            {
                total_count += thread_args[t].assignCount[ci];
                for (int d = 0; d < natts_point; d++)
                    total_sum[d] += thread_args[t].coordsAgg[ci * natts_point + d];
            }

            if (total_count > 0)
            {
                for (int d = 0; d < natts_point; d++)
                    centroids[ci * natts_centroid + d] =
                        Float8GetDatum(total_sum[d] / (float8) total_count);
            }
        }
    }

    llvm_close_tmp_context(estate);

    /* ----------------------------------------------------------------
     * Write output: point columns + assigned cluster id
     * ---------------------------------------------------------------- */
    {
        bool  resultNulls[natts_point + 1];
        Datum resultVals [natts_point + 1];
        memset(resultNulls, 0, sizeof(resultNulls));

        for (int pi = 0; pi < num_points; pi++)
        {
            memcpy(resultVals,
                   points + (size_t) pi * natts_point,
                   (size_t) natts_point * sizeof(Datum));
            resultVals[natts_point] = Int32GetDatum(assignments[pi]);
            tuplestore_putvalues(tsOut, outDesc, resultVals, resultNulls);
        }
    }

    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult  = tsOut;
    rsinfo->setDesc    = outDesc;

    MemoryContextSwitchTo(oldcontext);
    return (Datum) 0;
}
