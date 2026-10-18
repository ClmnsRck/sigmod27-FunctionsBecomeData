/*
 * apply_mt_pw / apply_mt_agg_pw - apply_mt (and its average) on postgres parallel
 * workers instead of pthreads. Same arguments, same results.
 *
 * Every worker is a full backend, so it is not limited to the L3 fast path like
 * apply_mt's threads. Argument 5 picks the level:
 *   0 CHECKED     row tuple + ExprState->evalfunc: L1 with jit=off, L2 with jit=on
 *   1 FAST        L3, JIT'd Datum(**) off the flat buffer
 *   2 FAST_TUPLE  row tuple like mode 0, evaluated like mode 1
 *
 * The leader injects, const-folds and serializes the lambdas into DSM, launches
 * the workers and only then copies the data in, so the copy overlaps with their
 * first compile. JIT code is per process, so jobs are (lambda, row range) pairs
 * and rows are split only when there are fewer lambdas than workers. Workers
 * write finished output tuples (apply_mt_pw) or one partial sum per job
 * (apply_mt_agg_pw). Data and results live in shared memory, so all columns and
 * the return type must be pass-by-value (float8).
 */
#include "postgres.h"
#include "funcapi.h"
#include "jit/jit.h"
#include "optimizer/optimizer.h"
#include "executor/executor.h"
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
#include "common/config_info.h"
#include <math.h>
#include "miscadmin.h"
#include "utils/array.h"
#include "utils/lambda.h"

/* Parallel infrastructure */
#include "access/parallel.h"
#include "access/xact.h"        /* Enter/ExitParallelMode */
#include "storage/condition_variable.h"
#include "storage/dsm.h"
#include "storage/shm_toc.h"
#include "port/atomics.h"
#include "utils/wait_event.h"

#include <dlfcn.h>

#define APPLY_PW_CHECKED     0
#define APPLY_PW_FAST        1
#define APPLY_PW_FAST_TUPLE  2

/* --------------------------- DSM TOC keys ------------------------------- */
#define APPLY_PW_KEY_HEADER     UINT64CONST(0)
#define APPLY_PW_KEY_DATA       UINT64CONST(1)
#define APPLY_PW_KEY_RESULT     UINT64CONST(2)
#define APPLY_PW_KEY_JOBS       UINT64CONST(3)
#define APPLY_PW_KEY_LAMBDAS    UINT64CONST(4)
#define APPLY_PW_KEY_COLINFO    UINT64CONST(5)
#define APPLY_PW_KEY_PARTIAL    UINT64CONST(6)
#define APPLY_PW_NKEYS          7

typedef Datum (*LambdaFunc)(Datum **);

/* ------------- Worker Funcs and data for parallel workers --------------- */

/* The job list lives in DSM, workers claim jobs with one atomic counter */
typedef struct WorkItem
{
    uint64_t id_lambda;             //index of the lambda this job evaluates
    uint64_t start, end;            //beginning row and end row of chunk
} WorkItem;

typedef struct ApplyPwHeader
{
    int     mode;                   //APPLY_PW_CHECKED / _FAST / _FAST_TUPLE
    bool    agg;                    //accumulate per job instead of writing N x M
    int     num_cols;               //number of cols per row in data
    int     num_tuples;             //number of data tuples
    int     num_lambdas;            //number of lambda tuples
    int     num_jobs;               //length of the job array
    int     jit_flags;              //leader's es_jit_flags, a fresh EState has none
    pg_atomic_uint32 next_job;      //job queue head, claimed with fetch-add
    pg_atomic_uint32 data_ready;    //set to 1 once the leader has filled the data region
    ConditionVariable data_cv;      //broadcast together with data_ready
    dsm_handle tup_handle;          //flat results: segment of their own, see the leader
    Size    tup_len;                //MAXALIGN'd length of a result tuple, 0 = plain Datums
    char    tup_head[MAXALIGN(SizeofMinimalTupleHeader)];  //every result tuple starts with it
} ApplyPwHeader;

/* Per-column type info, so a worker can rebuild the input TupleDesc */
typedef struct ColInfo
{
    Oid     typid;
    int32   typmod;
} ColInfo;

/*
 * All serialized lambda bodies in one region. Memory layout right behind the
 * struct:
 *   uint32  offsets[num_lambdas]   - byte offsets from blob[] start
 *   uint8   blob[total_blob_size]  - concatenated raw varlena bytes
 */
typedef struct LambdaPack
{
    int     num_lambdas;
    uint32  total_blob_size;
} LambdaPack;

static inline uint32 *lambda_pack_offsets(LambdaPack *pack)
{
    return (uint32 *)(pack + 1);
}

static inline uint8 *lambda_pack_blob(LambdaPack *pack)
{
    return (uint8 *)(lambda_pack_offsets(pack) + pack->num_lambdas);
}

PGDLLEXPORT void apply_mt_pw_worker_main(dsm_segment *seg, shm_toc *toc);

/* Worker entry point: claims (lambda, row range) jobs until none are left */
void apply_mt_pw_worker_main(dsm_segment *seg, shm_toc *toc)
{
    ApplyPwHeader *hdr      = shm_toc_lookup(toc, APPLY_PW_KEY_HEADER,  false);
    Datum         *in_data  = shm_toc_lookup(toc, APPLY_PW_KEY_DATA,    false);
    WorkItem      *jobs     = shm_toc_lookup(toc, APPLY_PW_KEY_JOBS,    false);
    LambdaPack    *pack     = shm_toc_lookup(toc, APPLY_PW_KEY_LAMBDAS, false);
    ColInfo       *col_info = shm_toc_lookup(toc, APPLY_PW_KEY_COLINFO, false);

    const int mode = hdr->mode;
    const bool agg = hdr->agg;
    const int cols = hdr->num_cols;
    const uint64_t rows = hdr->num_tuples;

    //only one of the two output regions exists
    Datum  *out     = agg ? NULL : shm_toc_lookup(toc, APPLY_PW_KEY_RESULT,  true);
    double *partial = agg ? shm_toc_lookup(toc, APPLY_PW_KEY_PARTIAL, true) : NULL;
    dsm_segment *tup_seg = hdr->tup_len ? dsm_attach(hdr->tup_handle) : NULL;
    char   *tups    = tup_seg ? dsm_segment_address(tup_seg) : NULL;

    MemoryContext oldcontext, per_tuple_ctx;
    TupleDesc inDescData = NULL;
    bool *in_nulls = NULL;
    LambdaFunc (*prepare_simple_expression)(ExprState *state) = NULL;
    char jit_path[MAXPGPATH];

    //a full backend, so unlike apply_mt's threads it has its own EState
    EState *estate = CreateExecutorState();
    PlanState *pstate = (PlanState *) palloc0(sizeof(PlanState));

    /*
     * llvm_prepare_simple_expression lives in llvmjit.so, which is not loaded yet
     * when a worker loads this library, so resolve it by hand.
     */
    snprintf(jit_path, MAXPGPATH, "%s/%s%s", pkglib_path, jit_provider, DLSUFFIX);
    if(pg_file_exists(jit_path))
        prepare_simple_expression = load_external_function(jit_path, "llvm_prepare_simple_expression", true, NULL);

    //a fresh EState has no jit flags, take the leader's (as execParallel.c does)
    estate->es_jit_flags = hdr->jit_flags;
    pstate->state = estate;
    oldcontext = MemoryContextSwitchTo(estate->es_query_cxt);
    per_tuple_ctx = GetPerTupleMemoryContext(estate);

    //the checked and fast+tuple paths build a row tuple per row
    if(mode != APPLY_PW_FAST)
    {
        inDescData = CreateTemplateTupleDesc(cols);
        for(int i = 0; i < cols; i++)
            TupleDescInitEntry(inDescData, (AttrNumber)(i + 1), "col",
                               col_info[i].typid, col_info[i].typmod, 0);
        //rows of it travel as composite Datums
        BlessTupleDesc(inDescData);
        //the leader rejects NULLs, so one shared all-false array is enough
        in_nulls = (bool *) palloc0(cols * sizeof(bool));
    }

    //compiled/prepared bodies of every lambda this worker has already touched
    LambdaExpr **lambdas = (LambdaExpr **) palloc0(hdr->num_lambdas * sizeof(LambdaExpr *));
    LambdaFunc  *funcs   = (LambdaFunc *)  palloc0(hdr->num_lambdas * sizeof(LambdaFunc));
    bool have_data = false;

    for(;;)
    {
        uint32 job_id = pg_atomic_fetch_add_u32(&hdr->next_job, 1);
        WorkItem *job;
        LambdaExpr *tmp_lambda;
        LambdaFunc compiled_func;

        if(job_id >= (uint32) hdr->num_jobs)
            break;

        CHECK_FOR_INTERRUPTS();

        job = &jobs[job_id];
        tmp_lambda = lambdas[job->id_lambda];

        /*
         * First job on this lambda: deserialize and compile it. parentPlan is not
         * serialized, but init and compile need an EState, hence the minimal pstate.
         */
        if(tmp_lambda == NULL)
        {
            //copy out of DSM first, deserialization reads it as private memory
            SerializedLambda *ser_shm = (SerializedLambda *)(lambda_pack_blob(pack) + lambda_pack_offsets(pack)[job->id_lambda]);
            SerializedLambda *ser = (SerializedLambda *) palloc(VARSIZE(ser_shm));

            memcpy(ser, ser_shm, VARSIZE(ser_shm));
            tmp_lambda = lambda_deserialize(ser);
            tmp_lambda->parentPlan = (Node *) pstate;

            ExecInitLambdaExpr((Node *)tmp_lambda, mode != APPLY_PW_CHECKED, false);
            if(mode != APPLY_PW_CHECKED)
            {
                if(prepare_simple_expression == NULL)
                    ereport(ERROR,
                            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                             errmsg("apply_mt_pw: no JIT provider, so the fast path is not available"),
                             errhint("Use mode 0, or build with LLVM support.")));

                funcs[job->id_lambda] = prepare_simple_expression(castNode(ExprState, tmp_lambda->exprstate));
            }

            pfree(ser);
            lambdas[job->id_lambda] = tmp_lambda;
        }

        compiled_func = funcs[job->id_lambda];

        //before the first row, wait until the leader has filled the data region
        if(!have_data)
        {
            if(pg_atomic_read_membarrier_u32(&hdr->data_ready) == 0)
            {
                ConditionVariablePrepareToSleep(&hdr->data_cv);
                while(pg_atomic_read_membarrier_u32(&hdr->data_ready) == 0)
                    ConditionVariableSleep(&hdr->data_cv, PG_WAIT_EXTENSION);
                ConditionVariableCancelSleep();
            }
            have_data = true;
        }

        double sum = 0.0;

        for(uint64_t i = job->start; i < job->end && i < rows; i++)
        {
            const Datum *row_in  = in_data + (size_t)i * cols;
            Datum result;

            if(mode == APPLY_PW_FAST)
            {
                //Eval lambda
                result = compiled_func((Datum **) &row_in);
            }
            else
            {
                bool isnull;
                HeapTuple rowTup;

                MemoryContextSwitchTo(per_tuple_ctx);
                MemoryContextReset(per_tuple_ctx);

                rowTup = heap_form_tuple(inDescData, (Datum *) row_in, in_nulls);

                if(mode == APPLY_PW_CHECKED)
                {
                    PG_LAMBDA_SETARG(tmp_lambda, 0, HeapTupleHeaderGetDatum(rowTup->t_data));
                    result = PG_LAMBDA_EVAL(tmp_lambda, 0, &isnull);
                }
                else
                {
                    /* tuple built only to price it; evaluate off the flat row */
                    result = compiled_func((Datum **) &row_in);
                }

                MemoryContextSwitchTo(estate->es_query_cxt);
            }

            //agg writes one sum per job, see below
            if(agg)
                sum += DatumGetFloat8(result);
            else if(tups)
            {
                //the finished tuple, so the leader has nothing left to copy
                char *tup = tups + (job->id_lambda * rows + i) * hdr->tup_len;

                memcpy(tup, hdr->tup_head, sizeof(hdr->tup_head));
                memcpy(tup + sizeof(hdr->tup_head), row_in, cols * sizeof(Datum));
                ((Datum *) (tup + sizeof(hdr->tup_head)))[cols] = result;
            }
            else
                out[job->id_lambda * rows + i] = result;
        }

        //one writer per job, so the array needs no synchronisation
        if(agg)
            partial[job_id] = sum;
    }

    MemoryContextSwitchTo(oldcontext);
    if(tup_seg)
        dsm_detach(tup_seg);

    //also releases the JIT context with every compiled body
    FreeExecutorState(estate);
}
/* -------------------------------------------------------------------- */

/* reset callback of the per-query memory: the tuplestore is done with the tuples */
static void apply_mt_pw_detach(void *arg)
{
    dsm_detach((dsm_segment *) arg);
}

/* Output row: the data columns plus "result", or "result" alone for agg */
static TupleDesc apply_mt_pw_out_desc(LambdaExpr *lambda, bool agg)
{
    TupleDesc inDescData = (TupleDesc)list_nth(lambda->argTypesTupDesc, 0);
    int num_data_cols = agg ? 0 : inDescData->natts;
    TupleDesc outDesc = CreateTemplateTupleDesc(num_data_cols + 1);

    for (int i = 0; i < num_data_cols; i++)
        TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescData, (AttrNumber)(i + 1));

    TupleDescInitEntry(outDesc,
                       (AttrNumber)(num_data_cols + 1),
                       "result",
                       lambda->rettype,
                       lambda->rettypmod,
                       0);

    return outDesc;
}

static TupleDesc apply_mt_pw_record_type(List *args)
{
    return apply_mt_pw_out_desc((LambdaExpr *)linitial(args), false);
}

static TupleDesc apply_mt_agg_pw_record_type(List *args)
{
    return apply_mt_pw_out_desc((LambdaExpr *)linitial(args), true);
}

PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1_RECTYPE(apply_mt_pw, apply_mt_pw_record_type);
PG_FUNCTION_INFO_V1_RECTYPE(apply_mt_agg_pw, apply_mt_agg_pw_record_type);

static
Datum apply_mt_pw_internal(FunctionCallInfo fcinfo, bool agg)
{
    MemoryContext oldcontext;
    TupleDesc outDesc;
    Tuplestorestate *tssData, *tssLambdas;
    int nworkers, mode;

    ReturnSetInfo *rsinfo = (ReturnSetInfo *)fcinfo->resultinfo;

    if (unlikely(rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo)))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (unlikely(!(rsinfo->allowedModes & SFRM_Materialize)))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not "
                        "allowed in this context")));

    rsinfo->returnMode = SFRM_Materialize;

    LambdaExpr *lambda = PG_GETARG_LAMBDA(0);
    TupleDesc inDescData = (TupleDesc)list_nth(lambda->argTypesTupDesc, 0);
    TupleDesc inDescLambdas = (TupleDesc)list_nth(lambda->argTypesTupDesc, 1);

    nworkers = PG_GETARG_INT32(3);
    mode = PG_GETARG_INT32(4);

    if (mode != APPLY_PW_CHECKED && mode != APPLY_PW_FAST && mode != APPLY_PW_FAST_TUPLE)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("apply_mt_pw: mode must be 0 (checked), 1 (fast) or 2 (fast+tuple), got %d", mode)));

    //L3 has no interpreter fallback, without jit a worker would call a body that was never compiled
    if (mode != APPLY_PW_CHECKED && !jit_enabled)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("apply_mt_pw: mode %d needs the fast-path JIT, but jit is off", mode),
                 errhint("Set jit = on, or use mode 0.")));

    //data and results are shared as plain Datums, so no pass-by-reference types
    for (int i = 0; i < inDescData->natts; i++)
    {
        Form_pg_attribute att = TupleDescAttr(inDescData, i);

        if (!att->attbyval)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("apply_mt_pw: data column \"%s\" is pass-by-reference",
                            NameStr(att->attname)),
                     errdetail("Parallel workers read the data out of shared memory, "
                               "so every column has to be pass-by-value (float8).")));
    }

    if (!get_typbyval(lambda->rettype))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("apply_mt_pw: lambda returns a pass-by-reference type"),
                 errdetail("Results are written into shared memory, "
                           "so the return type has to be pass-by-value (float8).")));

    oldcontext = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);

    tssData = ((TypedTuplestore *) PG_GETARG_POINTER(1))->tuplestorestate;
    TupleTableSlot *slotData = MakeTupleTableSlot(inDescData, &TTSOpsMinimalTuple);

    tssLambdas = ((TypedTuplestore *) PG_GETARG_POINTER(2))->tuplestorestate;
    TupleTableSlot *slotLambdas = MakeTupleTableSlot(inDescLambdas, &TTSOpsMinimalTuple);

    Tuplestorestate *tsOut = tuplestore_begin_heap(false, false, work_mem);

    outDesc = apply_mt_pw_out_desc(lambda, agg);

    /* ---------------------- Sizing the tupStore copy ----------------------- */
    //the copy into DSM happens after the launch, sized here
    int num_tuples_data = tuplestore_tuple_count(tssData);
    int num_cols_data = inDescData->natts; //one Datum per column, all pass-by-value (checked above)
    Size mem_chunk_data_size = (Size) num_cols_data * num_tuples_data * sizeof(Datum);
    Datum *mem_chunk_data = NULL;
    /* ------------------------------------------------------------------------ */
    /* --------------------- Sizing the result buffer ------------------------- */
    //all columns 8-byte by value: workers write finished tuples, read in place
    bool result_flat = !agg;
    MinimalTuple tupOut = NULL;

    for(int i = 0; result_flat && i < outDesc->natts; i++)
    {
        Form_pg_attribute att = TupleDescAttr(outDesc, i);

        if(!att->attbyval || att->attlen != sizeof(Datum) || att->attalign != TYPALIGN_DOUBLE)
            result_flat = false;
    }
    if(result_flat)
        tupOut = heap_form_minimal_tuple(outDesc, (Datum *) palloc0(outDesc->natts * sizeof(Datum)),
                                         (bool *) palloc0(outDesc->natts * sizeof(bool)));

    //N x M may exceed INT_MAX for agg
    int num_tuples_lambda = tuplestore_tuple_count(tssLambdas);
    int64 num_tuples_result = (int64) num_tuples_data * num_tuples_lambda;
    Size mem_chunk_result_size = Max(sizeof(Datum), (Size) (result_flat ? 0 : num_tuples_result) * sizeof(Datum));
    /* ------------------------------------------------------------------------ */
    /* ---------------------- Serializing the lambda bodies ------------------- */
    //injection and const folding as in apply_mt, only the compilation moves
    SerializedLambda **serialized = (SerializedLambda **)
        palloc(Max(1, num_tuples_lambda) * sizeof(SerializedLambda *));
    Size total_blob_size = 0;
    int lambda_ctr = 0;

    while(tuplestore_gettupleslot(tssLambdas, true, false, slotLambdas))
    {
        LambdaExpr *tmp_lambda;
        Datum input_tuples[2] = {Int8GetDatum(0), Int8GetDatum(0)};

        CHECK_FOR_INTERRUPTS();

        slot_getallattrs(slotLambdas);

        /* NORMALLY BAD, BUT APPLY ASSUMES ALL LAMBDAS IN SECOND SUBLINK */
        input_tuples[1] = PointerGetDatum(slotLambdas->tts_values);
        tmp_lambda = lambda_injector(lambda, input_tuples);
        tmp_lambda->expr = (Expr *) eval_const_expressions(NULL, (Node *) tmp_lambda->expr);

        serialized[lambda_ctr] = lambdaExprToSerialLambda(tmp_lambda);
        total_blob_size += VARSIZE(serialized[lambda_ctr]);
        lambda_ctr++;
    }

    Size pack_size = sizeof(LambdaPack) + (Size) num_tuples_lambda * sizeof(uint32) + total_blob_size;
    /* ------------------------------------------------------------------------ */
    /* --------------------------- Building the jobs -------------------------- */
    /*
     * One job is one lambda over one row range. Rows are split only on the
     * checked path and only with fewer lambdas than workers: each extra lambda a
     * worker sees costs another compile, which the fast path rarely earns back.
     */
    int chunks_per_lambda = 1;

    if(nworkers < 1)
        nworkers = 1;

    if(mode == APPLY_PW_CHECKED && num_tuples_lambda > 0 && num_tuples_lambda < nworkers)
        chunks_per_lambda = (nworkers + num_tuples_lambda - 1) / num_tuples_lambda;
    if(chunks_per_lambda > num_tuples_data)
        chunks_per_lambda = num_tuples_data;
    if(chunks_per_lambda < 1)
        chunks_per_lambda = 1;

    int num_jobs = num_tuples_lambda * chunks_per_lambda;

    //never launch more workers than there are jobs
    if(nworkers > num_jobs && num_jobs > 0)
        nworkers = num_jobs;

    Size jobs_size = Max(sizeof(WorkItem), (Size) num_jobs * sizeof(WorkItem));
    WorkItem *jobs = (WorkItem *) palloc(jobs_size);

    //agg: one accumulator per job instead of one Datum per result
    Size partial_size = Max(sizeof(double), (Size) num_jobs * sizeof(double));

    for(int l = 0; l < num_tuples_lambda; l++)
    {
        for(int c = 0; c < chunks_per_lambda; c++)
        {
            WorkItem cur_job = {
                .id_lambda = l,
                .start = (uint64_t) num_tuples_data * (uint64_t) c / (uint64_t) chunks_per_lambda,
                .end = (uint64_t) num_tuples_data * (uint64_t) (c + 1) / (uint64_t) chunks_per_lambda
            };

            jobs[l * chunks_per_lambda + c] = cur_job;
        }
    }
    /* ------------------------------------------------------------------------ */
    /* --------------------- Per-column type info for workers ----------------- */
    Size col_info_size = Max(sizeof(ColInfo), (Size) num_cols_data * sizeof(ColInfo));
    ColInfo *col_info = (ColInfo *) palloc(col_info_size);

    for(int i = 0; i < num_cols_data; i++)
    {
        Form_pg_attribute att = TupleDescAttr(inDescData, i);

        col_info[i].typid = att->atttypid;
        col_info[i].typmod = att->atttypmod;
    }
    /* ------------------------------------------------------------------------ */
    /* --------------------------- Parallel workers --------------------------- */
    Datum *mem_chunk_result = NULL;
    double *partial_sums = NULL;
    ParallelContext *pcxt = NULL;
    dsm_segment *tup_seg = NULL;

    //no data or no lambdas: no segment
    if(num_jobs > 0 && num_tuples_result > 0)
    {
        //workers look up the entry point by library path
        Dl_info dli;

        if (dladdr((void *) apply_mt_pw_worker_main, &dli) == 0 || dli.dli_fname == NULL)
            ereport(ERROR,
                    (errmsg("apply_mt_pw: could not resolve the path of this shared library")));

        EnterParallelMode();

        pcxt = CreateParallelContext(pstrdup(dli.dli_fname), "apply_mt_pw_worker_main", nworkers);

        //all estimates have to be in before the segment is created
        shm_toc_estimate_chunk(&pcxt->estimator, sizeof(ApplyPwHeader));
        shm_toc_estimate_chunk(&pcxt->estimator, mem_chunk_data_size);
        shm_toc_estimate_chunk(&pcxt->estimator, agg ? partial_size : mem_chunk_result_size);
        shm_toc_estimate_chunk(&pcxt->estimator, jobs_size);
        shm_toc_estimate_chunk(&pcxt->estimator, pack_size);
        shm_toc_estimate_chunk(&pcxt->estimator, col_info_size);
        shm_toc_estimate_keys(&pcxt->estimator, APPLY_PW_NKEYS);

        //creates the segment and serializes GUCs(jit!), snapshot and xact state
        InitializeParallelDSM(pcxt);

        ApplyPwHeader *hdr = shm_toc_allocate(pcxt->toc, sizeof(ApplyPwHeader));
        hdr->mode = mode;
        hdr->agg = agg;
        hdr->num_cols = num_cols_data;
        hdr->num_tuples = num_tuples_data;
        hdr->num_lambdas = num_tuples_lambda;
        hdr->num_jobs = num_jobs;
        pg_atomic_init_u32(&hdr->data_ready, 0);
        ConditionVariableInit(&hdr->data_cv);
        hdr->jit_flags = rsinfo->econtext->ecxt_estate ?
                         rsinfo->econtext->ecxt_estate->es_jit_flags : PGJIT_NONE;
        pg_atomic_init_u32(&hdr->next_job, 0);
        hdr->tup_len = 0;
        if(result_flat)
        {
            //own segment, the tuplestore reads it until the end of the query
            MemoryContextCallback *cb = palloc(sizeof(MemoryContextCallback));

            Assert(tupOut->t_hoff - MINIMAL_TUPLE_OFFSET == sizeof(hdr->tup_head));
            hdr->tup_len = MAXALIGN(tupOut->t_len);
            memcpy(hdr->tup_head, tupOut, sizeof(hdr->tup_head));
            tup_seg = dsm_create((Size) num_tuples_result * hdr->tup_len, 0);
            dsm_pin_mapping(tup_seg);
            cb->func = apply_mt_pw_detach;
            cb->arg = tup_seg;
            MemoryContextRegisterResetCallback(rsinfo->econtext->ecxt_per_query_memory, cb);
            hdr->tup_handle = dsm_segment_handle(tup_seg);
        }
        shm_toc_insert(pcxt->toc, APPLY_PW_KEY_HEADER, hdr);

        //only reserved here, filled after LaunchParallelWorkers
        mem_chunk_data = shm_toc_allocate(pcxt->toc, mem_chunk_data_size);
        shm_toc_insert(pcxt->toc, APPLY_PW_KEY_DATA, mem_chunk_data);

        //only the region this variant writes
        if(agg)
        {
            //every job writes its own slot, zeroing is only a safety net
            partial_sums = shm_toc_allocate(pcxt->toc, partial_size);
            memset(partial_sums, 0, partial_size);
            shm_toc_insert(pcxt->toc, APPLY_PW_KEY_PARTIAL, partial_sums);
        }
        else
        {
            mem_chunk_result = shm_toc_allocate(pcxt->toc, mem_chunk_result_size);
            shm_toc_insert(pcxt->toc, APPLY_PW_KEY_RESULT, mem_chunk_result);
        }

        WorkItem *shm_jobs = shm_toc_allocate(pcxt->toc, jobs_size);
        memcpy(shm_jobs, jobs, jobs_size);
        shm_toc_insert(pcxt->toc, APPLY_PW_KEY_JOBS, shm_jobs);

        LambdaPack *shm_pack = shm_toc_allocate(pcxt->toc, pack_size);
        shm_pack->num_lambdas = num_tuples_lambda;
        shm_pack->total_blob_size = (uint32) total_blob_size;
        {
            uint32 *offsets = lambda_pack_offsets(shm_pack);
            uint8 *blob = lambda_pack_blob(shm_pack);
            uint32 cur_off = 0;

            for(int l = 0; l < num_tuples_lambda; l++)
            {
                uint32 sz = (uint32) VARSIZE(serialized[l]);

                offsets[l] = cur_off;
                memcpy(blob + cur_off, serialized[l], sz);
                cur_off += sz;
            }
        }
        shm_toc_insert(pcxt->toc, APPLY_PW_KEY_LAMBDAS, shm_pack);

        ColInfo *shm_cols = shm_toc_allocate(pcxt->toc, col_info_size);
        memcpy(shm_cols, col_info, col_info_size);
        shm_toc_insert(pcxt->toc, APPLY_PW_KEY_COLINFO, shm_cols);

        LaunchParallelWorkers(pcxt);

        if(pcxt->nworkers_launched == 0)
        {
            DestroyParallelContext(pcxt);
            ExitParallelMode();
            ereport(ERROR,
                    (errcode(ERRCODE_INSUFFICIENT_RESOURCES),
                     errmsg("apply_mt_pw: no parallel worker could be launched"),
                     errhint("Raise max_parallel_workers and max_worker_processes.")));
        }
        if(pcxt->nworkers_launched < nworkers)
            ereport(WARNING,
                    (errmsg("apply_mt_pw: %d of %d parallel workers launched",
                            pcxt->nworkers_launched, nworkers),
                     errhint("Raise max_parallel_workers and max_worker_processes.")));

        /* --------------- Copying values from tupStore into DSM -------------- */
        //runs while the workers compile; an error here terminates them
        int idx_tup = 0;
        while(tuplestore_gettupleslot(tssData, true, false, slotData))
        {
            slot_getallattrs(slotData);

            //only the values cross into DSM, so a NULL would silently become garbage
            for(int c = 0; c < num_cols_data; c++)
                if(slotData->tts_isnull[c])
                    ereport(ERROR,
                            (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                             errmsg("apply_mt_pw: data column \"%s\" contains a NULL",
                                    NameStr(TupleDescAttr(inDescData, c)->attname))));

            memcpy(mem_chunk_data + (size_t) idx_tup * num_cols_data, slotData->tts_values, num_cols_data * sizeof(Datum));
            idx_tup++;
        }

        //full barrier: every store above is visible before data_ready reads 1
        pg_atomic_write_membarrier_u32(&hdr->data_ready, 1);
        ConditionVariableBroadcast(&hdr->data_cv);
        /* -------------------------------------------------------------------- */

        //wait for workers to finish, this also re-throws their errors
        WaitForParallelWorkersToFinish(pcxt);
    }

    if(agg)
    {
        //summed in job order, so the result does not depend on scheduling
        bool resultNull = false; //always false/0, due to arithmetic operations
        Datum result;
        double cummulative_sum = 0.0;

        //empty input: no accumulators
        if(partial_sums != NULL)
        {
            for(int i = 0; i < num_jobs; i++)
                cummulative_sum += partial_sums[i];
        }

        //flat average over all N x M results (NaN if empty)
        cummulative_sum /= num_tuples_result;

        result = Float8GetDatum(cummulative_sum);

        tuplestore_putvalues(tsOut,
                             outDesc,
                             &result,
                             &resultNull);
    }
    else
    {
        //reads the DSM segment, so before DestroyParallelContext
        int num_cols_result = 1 + num_cols_data;
        bool *resultNulls = (bool *) palloc0(num_cols_result * sizeof(bool)); //always false/0, due to arithmetic operations
        Datum *results = (Datum *) palloc0(num_cols_result * sizeof(Datum));

        if(result_flat)
        {
            //the workers wrote the finished tuples, lambda-major
            if(tup_seg)
                tuplestore_putblock(tsOut, dsm_segment_address(tup_seg), num_tuples_result,
                                    MAXALIGN(tupOut->t_len), false);
        }
        else
        {
            //a column is not 8-byte pass-by-value, build each tuple from scratch
            for(int64 i = 0; i < num_tuples_result; i++)
            {
                memcpy(results, mem_chunk_data + (i % num_tuples_data) * num_cols_data, sizeof(Datum) * num_cols_data);
                results[num_cols_data] = mem_chunk_result[i];

                tuplestore_putvalues(tsOut,
                                     outDesc,
                                     results,
                                     resultNulls);
            }
        }
    }

    if(pcxt != NULL)
    {
        DestroyParallelContext(pcxt);
        ExitParallelMode();
    }
    /* ------------------------------------------------------------------------ */

    //prepare result
    rsinfo->setResult = tsOut;
    rsinfo->setDesc = outDesc;

    MemoryContextSwitchTo(oldcontext);
    //no llvm_close_tmp_context here, the leader never compiled anything

    return (Datum)0;
}

/*
 * apply_mt_pw - apply_mt on parallel workers, arg 5 picks the execution level
 */
Datum apply_mt_pw(PG_FUNCTION_ARGS)
{
    return apply_mt_pw_internal(fcinfo, false);
}

/*
 * apply_mt_agg_pw - the flat average over all N x M results, no N x M buffer
 */
Datum apply_mt_agg_pw(PG_FUNCTION_ARGS)
{
    return apply_mt_pw_internal(fcinfo, true);
}
