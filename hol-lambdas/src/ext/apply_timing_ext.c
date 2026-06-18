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
#include <pthread.h>
#include "miscadmin.h"
#include "utils/array.h"
#include "utils/lambda.h"
#include "port/atomics.h"

#include "threadpool.h"

#include "utils/ruleutils.h"

/* TIMING: helper */
static inline uint64
elapsed_us(instr_time start, instr_time end)
{
    INSTR_TIME_SUBTRACT(end, start);
    return (uint64) INSTR_TIME_GET_MICROSEC(end);
}

static TupleDesc apply_timing_record_type(List *args)
{
    LambdaExpr *lambda = (LambdaExpr *)list_nth(args, 0);
    TupleDesc inDescData = (TupleDesc)list_nth(lambda->argTypesTupDesc, 0);
    TupleDesc outDesc;
    outDesc = CreateTemplateTupleDesc(inDescData->natts + 1);

    for (int i = 0; i < inDescData->natts; i++)
    {
        TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescData, (AttrNumber)(i + 1));
    }

    TupleDescInitEntry(outDesc,
                        (AttrNumber)(inDescData->natts + 1),
                        "result",
                        (lambda->rettype),
                        lambda->rettypmod,
                        0);

    return outDesc;
}

PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1_RECTYPE(apply_timing, apply_timing_record_type);

/* ------------- Worker Funcs and data for multithreading ---------------- */
typedef struct WorkItem
{
    uint64_t id_lambda;             //id of job
    uint64_t start, end;            //beginning row and end row of chunk
    int num_cols;                   //number of cols per row in data
    uint64_t num_tuples;            //number of data tuples
    const void *in_data;            //pointer to data mem_chunk
    void *out;                      //where to put the result
    Datum (*eval_func)(Datum **);   //L3 Jit compiled evalfunc per worker
} WorkItem;

typedef void (*worker_func)(void *job);

static void eval_lambda(void *job)
{
    const WorkItem *args = (const WorkItem *)job;
    const int cols = args->num_cols;
    const uint64_t rows = args->num_tuples;
    const Datum *data = (const Datum *) args->in_data;
    Datum *out = (Datum *) args->out;

    for(uint64_t i = args->start; i < args->end && i < rows; i++)
    {
        const Datum *row_in  = data + (size_t)i * cols;
        Datum *row_out = out + args->id_lambda * args->num_tuples + i;
        //Eval lambda
        Datum result = args->eval_func((Datum **) &row_in);
        //store result
        *row_out = result;
    }
}
/* -------------------------------------------------------------------- */

static
Datum apply_timing_internal(PG_FUNCTION_ARGS)
{
    MemoryContext oldcontext;
    MemoryContext per_query_ctx;
    TupleDesc outDesc = NULL;
    Tuplestorestate *tssData, *tssLambdas;
    Datum *replVal;
    bool *replIsNull;
    int rowSize, nthreads, queue_capacity;

    /* ---------------- TIMING ---------------- */
    uint64 total_us = 0;
    uint64 prep_us = 0;
    uint64 materialize_input_us = 0;
    uint64 inject_us = 0;
    uint64 eval_us = 0;
    uint64 rematerialize_output_us = 0;

    instr_time t_total0, t_total1;
    instr_time t_eval0, t_eval1;
    instr_time t_out0, t_out1;
    /* ---------------------------------------- */

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

    INSTR_TIME_SET_CURRENT(t_total0);

    LambdaExpr *lambda = PG_GETARG_LAMBDA(0);
    TupleDesc inDescData    = (TupleDesc) list_nth(lambda->argTypesTupDesc, 0);
    TupleDesc inDescLambdas = (TupleDesc) list_nth(lambda->argTypesTupDesc, 1);

    rowSize        = inDescData->natts + 1;
    nthreads       = PG_GETARG_INT32(3);
    queue_capacity = PG_GETARG_INT32(4);

    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);

    tssData = ((TypedTuplestore *) PG_GETARG_POINTER(1))->tuplestorestate;
    const TupleTableSlotOps *slotOpsData = &TTSOpsMinimalTuple;
    TupleTableSlot *slotData = MakeTupleTableSlot(inDescData, slotOpsData);

    tssLambdas = ((TypedTuplestore *) PG_GETARG_POINTER(2))->tuplestorestate;
    const TupleTableSlotOps *slotOpsLambdas = &TTSOpsMinimalTuple;
    TupleTableSlot *slotLambdas = MakeTupleTableSlot(inDescLambdas, slotOpsLambdas);

    Tuplestorestate *tsOut = tuplestore_begin_heap(false, false, work_mem);

    outDesc = CreateTemplateTupleDesc(rowSize);
    for (int i = 0; i < inDescData->natts; i++)
        TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescData, (AttrNumber)(i + 1));

    TupleDescInitEntry(outDesc,
                       (AttrNumber) rowSize,
                       "result",
                       lambda->rettype,
                       lambda->rettypmod,
                       0);

    replIsNull = (bool *) palloc((rowSize) * sizeof(bool));
    replVal    = (Datum *) palloc((rowSize) * sizeof(Datum));
    (void) replIsNull;
    (void) replVal;

    /* ------------------- MATERIALIZE INPUT (alloc+copy) ------------------- */
    instr_time t_mat0, t_mat1;
    INSTR_TIME_SET_CURRENT(t_mat0);

    int num_tuples_data = tuplestore_tuple_count(tssData);
    int num_cols_data   = inDescData->natts;

    Size mem_chunk_data_size = (Size) num_cols_data * (Size) num_tuples_data * sizeof(Datum);
    Datum *mem_chunk_data = (Datum *) palloc(mem_chunk_data_size);

    if (nthreads <= 0)
        nthreads = 1;
    if (nthreads > num_tuples_data && num_tuples_data > 0)
        nthreads = num_tuples_data;

    int idx_tup = 0;
    while (tuplestore_gettupleslot(tssData, true, false, slotData))
    {
        slot_getallattrs(slotData);
        Datum *val_ptr_data = slotData->tts_values;

        memcpy(mem_chunk_data + (idx_tup * num_cols_data),
               val_ptr_data,
               num_cols_data * sizeof(Datum));
        idx_tup++;
    }

    INSTR_TIME_SET_CURRENT(t_mat1);
    materialize_input_us = elapsed_us(t_mat0, t_mat1);
    /* ---------------------------------------------------------------------- */

    /* --------------------- RESULT BUFFER + THREADPOOL SETUP ---------------- */
    int num_tuples_lambda = tuplestore_tuple_count(tssLambdas);
    int num_tuples_result = num_tuples_data * num_tuples_lambda;

    Size mem_chunk_result_size = (Size) num_tuples_result * sizeof(Datum);
    Datum *mem_chunk_result = (Datum *) palloc0(mem_chunk_result_size);

    TP_Pool *threadpool = tp_create(nthreads, queue_capacity, eval_lambda);
    /* ---------------------------------------------------------------------- */

    /* ------------------------------ EVAL ----------------------------- */
    INSTR_TIME_SET_CURRENT(t_eval0);

    int lambda_ctr = 0;
    while (tuplestore_gettupleslot(tssLambdas, true, false, slotLambdas))
    {
        Datum input_tuples[2] = { Int8GetDatum(0), Int8GetDatum(0) };

        slot_getallattrs(slotLambdas);
        Datum *val_ptr_lambdas = slotLambdas->tts_values;

        /* NORMALLY BAD, BUT APPLY ASSUMES ALL LAMBDAS IN SECOND SUBLINK */
        input_tuples[1] = PointerGetDatum(val_ptr_lambdas);

        instr_time t_inj0, t_inj1;
        INSTR_TIME_SET_CURRENT(t_inj0);

        LambdaExpr *tmp_lambda = lambda_injector(lambda, input_tuples);
        tmp_lambda->expr = (Expr *) eval_const_expressions(NULL, (Node *) tmp_lambda->expr);

        INSTR_TIME_SET_CURRENT(t_inj1);
        inject_us += elapsed_us(t_inj0, t_inj1);

        Datum (*compiled_func)(Datum **);

        llvm_enter_tmp_context(rsinfo->econtext->ecxt_estate);
        ExecInitLambdaExpr((Node *) tmp_lambda, true, false);
        compiled_func = llvm_prepare_simple_expression(castNode(ExprState, tmp_lambda->exprstate));
        llvm_leave_tmp_context(rsinfo->econtext->ecxt_estate);

        for (int i = 0; i < nthreads; i++)
        {
            WorkItem cur_job = {
                .id_lambda  = (uint64_t) lambda_ctr,
                .start      = (uint64_t) num_tuples_data * (uint64_t) i / (uint64_t) nthreads,
                .end        = (uint64_t) num_tuples_data * (uint64_t) (i + 1) / (uint64_t) nthreads,
                .num_cols   = num_cols_data,
                .num_tuples = (uint64_t) num_tuples_data,
                .in_data    = mem_chunk_data,
                .out        = mem_chunk_result,
                .eval_func  = compiled_func
            };

            tp_submit(threadpool, &cur_job, sizeof(cur_job));
        }

        lambda_ctr++;
    }

    tp_finish_and_destroy(threadpool);

    INSTR_TIME_SET_CURRENT(t_eval1);
    eval_us = elapsed_us(t_eval0, t_eval1);
    /* ---------------------------------------------------------------------- */

    /* ----------------------- REMATERIALIZE OUTPUT -------------------------- */
    int num_cols_result = 1 + num_cols_data;
    bool  *resultNulls = (bool *)  palloc0(num_cols_result * sizeof(bool));
    Datum *results     = (Datum *) palloc0(num_cols_result * sizeof(Datum));

    INSTR_TIME_SET_CURRENT(t_out0);

    for (int i = 0; i < num_tuples_result; i++)
    {
        memcpy(results,
               mem_chunk_data + (i % num_tuples_data) * num_cols_data,
               sizeof(Datum) * num_cols_data);

        results[num_cols_data] = *(mem_chunk_result + i);

        tuplestore_putvalues(tsOut, outDesc, results, resultNulls);
    }

    INSTR_TIME_SET_CURRENT(t_out1);
    rematerialize_output_us = elapsed_us(t_out0, t_out1);
    /* ---------------------------------------------------------------------- */

    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult  = tsOut;
    rsinfo->setDesc    = outDesc;

    pfree(mem_chunk_data);
    pfree(mem_chunk_result);

    MemoryContextSwitchTo(oldcontext);
    llvm_close_tmp_context(rsinfo->econtext->ecxt_estate);

    INSTR_TIME_SET_CURRENT(t_total1);
    total_us = elapsed_us(t_total0, t_total1);

    {
        int64 residual = (int64) total_us
                       - (int64) materialize_input_us
                       - (int64) eval_us
                       - (int64) rematerialize_output_us;
        prep_us = (residual > 0) ? (uint64) residual : 0;
    }

    elog(LOG,
         "TIMING_RESULTS_MARKER\n"
         "apply_timing\n"
         " nthreads=%d\n queuecap=%d\n"
         " num_tuples_data=%d\n num_cols_data=%d\n"
         " num_tuples_lambdas=%d\n"
         " num_tuples_result=%d\n"
         " prep=%lu us\n"
         " materialize_input=%lu us\n"
         " inject=%lu us\n"
         " eval=%lu us\n"
         " rematerialize_output=%lu us\n"
         " total=%lu us\n"
         "TIMING_RESULTS_MARKER",
         nthreads, queue_capacity,
         num_tuples_data, num_cols_data,
         num_tuples_lambda,
         num_tuples_result,
         (unsigned long) prep_us,
         (unsigned long) materialize_input_us,
         (unsigned long) inject_us,
         (unsigned long) eval_us,
         (unsigned long) rematerialize_output_us,
         (unsigned long) total_us);

    return (Datum) 0;
}


Datum apply_timing(PG_FUNCTION_ARGS)
{
    return apply_timing_internal(fcinfo);
}
