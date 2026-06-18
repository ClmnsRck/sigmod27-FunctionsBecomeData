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

#include "threadpool.h"

#include "utils/ruleutils.h"

/* TIMING: helper */
static inline uint64
elapsed_us(instr_time start, instr_time end)
{
    INSTR_TIME_SUBTRACT(end, start);
    return (uint64) INSTR_TIME_GET_MICROSEC(end);
}

static TupleDesc apply_mt_agg_record_type(List *args)
{
    LambdaExpr *lambda = (LambdaExpr *)list_nth(args, 0);
    TupleDesc outDesc;
    outDesc = CreateTemplateTupleDesc(/*inDescData->natts +*/ 1);

    // for (int i = 0; i < inDescData->natts; i++)
    // {
    //     TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescData, (AttrNumber)(i + 1));
    // }

    TupleDescInitEntry(outDesc,
                        /*(AttrNumber)(inDescData->natts + 1)*/1,
                        "result",
                        (lambda->rettype),
                        lambda->rettypmod,
                        0);

    return outDesc;
}

PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1_RECTYPE(apply_mt_agg, apply_mt_agg_record_type);

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
        //printf("\n\n------------------\nx:%f, y:%f, z:%f, result:%f\n------------------\n", DatumGetFloat8(row_in[0]), DatumGetFloat8(row_in[1]), DatumGetFloat8(row_in[2]), DatumGetFloat8(result));
    }
}
/* -------------------------------------------------------------------- */

static
Datum apply_mt_agg_internal(PG_FUNCTION_ARGS)
{
    MemoryContext oldcontext;
    MemoryContext per_query_ctx;
    TupleDesc outDesc = NULL;
    Tuplestorestate *tssData, *tssLambdas;
    int rowSize, nthreads, queue_capacity, body_size;

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

    INSTR_TIME_SET_CURRENT(t_total0);
    /* ---------------------------------------- */

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

    rowSize = 1;
    nthreads = PG_GETARG_INT32(3);
    queue_capacity = PG_GETARG_INT32(4);
    body_size = PG_GETARG_INT32(5);

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

    { // register each tuple-descriptor field with the corresponding field name
        // for (int i = 0; i < inDescData->natts; i++)
        // {
        //     TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescData, (AttrNumber)(i + 1));
        // }

        TupleDescInitEntry(outDesc, 
                           (AttrNumber)(rowSize), 
                           "result",
                           lambda->rettype, 
                           lambda->rettypmod, 
                           0);
    }


    /* ------------------- Allocating mem for tupStore copy ------------------- */
    instr_time t_mat0, t_mat1;
    INSTR_TIME_SET_CURRENT(t_mat0);
    Size mem_chunk_data_size;
    int num_tuples_data = tuplestore_tuple_count(tssData);
    int num_cols_data = inDescData->natts; // DANGEROUS, assumes only floats in col

    mem_chunk_data_size = num_cols_data * num_tuples_data * sizeof(Datum);
    Datum *mem_chunk_data = (Datum *) palloc(mem_chunk_data_size);
    /* ------------------------------------------------------------------------ */

    //more overhead than necessary
    if(nthreads > num_tuples_data && num_tuples_data > 0)
        nthreads = num_tuples_data;
    
    /* ------------------- Copying values into temp.-memory ------------------- */
    int idx_tup = 0;
    while(tuplestore_gettupleslot(tssData, true, false, slotData))
    {
        slot_getallattrs(slotData);
        Datum *val_ptr_data = slotData->tts_values;

        //DANGEROUS -> assumes that architecture represents 0.0 float8's as all zero bits
        memcpy(mem_chunk_data + (idx_tup * num_cols_data), val_ptr_data, num_cols_data * sizeof(Datum));
        idx_tup++;
    }
    INSTR_TIME_SET_CURRENT(t_mat1);
    materialize_input_us = elapsed_us(t_mat0, t_mat1);
    /* ------------------------------------------------------------------------ */
    /* --------------------- Allocating mem for result------------------------- */
    Size mem_chunk_result_size;
    int num_tuples_lambda = tuplestore_tuple_count(tssLambdas);
    int num_tuples_result = num_tuples_data * num_tuples_lambda;

    mem_chunk_result_size = num_tuples_result * sizeof(Datum);
    Datum *mem_chunk_result = (Datum *) palloc0(mem_chunk_result_size);
    /* ------------------------------------------------------------------------ */
    /* --------------------------- Threadpool --------------------------------- */
    TP_Pool *threadpool;
    threadpool = tp_create(nthreads, queue_capacity, eval_lambda);
    /* ------------------------------------------------------------------------ */
    INSTR_TIME_SET_CURRENT(t_eval0);

    //timer = lt_tick(timer, "Preparations done");
    int lambda_ctr = 0;


    while(tuplestore_gettupleslot(tssLambdas, true, false, slotLambdas))
    {
        //timer = lt_tick(timer, "Starting with Lambda %d", lambda_ctr);
        //int data_ctr = 0;
        LambdaExpr *tmp_lambda;
        Datum (*compiled_func)(Datum **);
        Datum input_tuples[2] = {Int8GetDatum(0), Int8GetDatum(0)};

        Datum *val_ptr_lambdas;

        slot_getallattrs(slotLambdas);
        val_ptr_lambdas = slotLambdas->tts_values;

        /* NORMALLY BAD, BUT APPLY ASSUMES ALL LAMBDAS IN SECOND SUBLINK */
        input_tuples[1] = PointerGetDatum(val_ptr_lambdas);

        instr_time t_inj0, t_inj1;
        INSTR_TIME_SET_CURRENT(t_inj0);

        tmp_lambda = lambda_injector(lambda, input_tuples);
        tmp_lambda->expr = (Expr *) eval_const_expressions(NULL, (Node *) tmp_lambda->expr);

        INSTR_TIME_SET_CURRENT(t_inj1);
        inject_us += elapsed_us(t_inj0, t_inj1);

        //Preparation for execution
        llvm_enter_tmp_context(rsinfo->econtext->ecxt_estate);
        ExecInitLambdaExpr((Node *)tmp_lambda, true, false);
        compiled_func = llvm_prepare_simple_expression(castNode(ExprState, tmp_lambda->exprstate));
        llvm_leave_tmp_context(rsinfo->econtext->ecxt_estate);

        for(int i = 0; i < nthreads; i++)
        {
            //Create Job-Ticket for Queue
            WorkItem cur_job = {
                .id_lambda = lambda_ctr,
                .in_data = mem_chunk_data,
                .start = (uint64_t) num_tuples_data * (uint64_t) i / (uint64_t) nthreads,
                .end = (uint64_t) num_tuples_data * (uint64_t) (i + 1) / (uint64_t) nthreads,
                .num_cols = num_cols_data,
                .num_tuples = num_tuples_data,
                .out = mem_chunk_result,
                .eval_func = compiled_func
            };

            tp_submit(threadpool, &cur_job, sizeof(cur_job));
        }

        lambda_ctr++;
    }
    //wait for workers to finish
    tp_finish_and_destroy(threadpool);

    INSTR_TIME_SET_CURRENT(t_eval1);
    eval_us = elapsed_us(t_eval0, t_eval1);

    //create/fill result tuplestore
    bool resultNulls = false; //always false/0, due to arithmetic operations
    Datum result;
    double_t cummulative_sum = 0.0;
    double_t cummulative_sum_inner = 0.0;

    INSTR_TIME_SET_CURRENT(t_out0);

    for(int i = 0; i < num_tuples_result; i++)
    {
        cummulative_sum_inner += DatumGetFloat8(*(mem_chunk_result + i));
    }

    cummulative_sum = cummulative_sum_inner / num_tuples_result;

    result = Float8GetDatum(cummulative_sum);

    tuplestore_putvalues(tsOut, 
                        outDesc, 
                        &result, 
                        &resultNulls);

    INSTR_TIME_SET_CURRENT(t_out1);
    rematerialize_output_us = elapsed_us(t_out0, t_out1);

    //prepare result
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult = tsOut;
    rsinfo->setDesc = outDesc;
    pfree(mem_chunk_data);
    pfree(mem_chunk_result);

    MemoryContextSwitchTo(oldcontext);
    llvm_close_tmp_context(rsinfo->econtext->ecxt_estate);
    //lt_total(timer, "");
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
         "apply_mt_agg\n"
         " body_repeat=%d\n"
         " nthreads=%d\n queuecap=%d\n"
         " num_tuples_data=%d\n num_cols_data=%d\n"
         " num_tuples_lambdas=%d\n"
         " num_tuples_cross_join=%d\n"
         " num_tuples_result=1\n"
         " prep=%lu us\n"
         " materialize_input=%lu us\n"
         " inject=%lu us\n"
         " eval=%lu us\n"
         " rematerialize_output=%lu us\n"
         " total=%lu us\n"
         "TIMING_RESULTS_MARKER",
         body_size, nthreads, queue_capacity,
         num_tuples_data, num_cols_data,
         num_tuples_lambda,
         num_tuples_result,
         (unsigned long) prep_us,
         (unsigned long) materialize_input_us,
         (unsigned long) inject_us,
         (unsigned long) eval_us,
         (unsigned long) rematerialize_output_us,
         (unsigned long) total_us);

    return (Datum)0;
}

/*
 * apply_mt_agg_internal_notiming - identical computation to apply_mt_agg_internal,
 * but with all timing instrumentation and the TIMING_RESULTS_MARKER elog removed.
 * Pure compute path: same threadpool setup, work distribution and eval as apply_mt,
 * aggregating the N x M results into a single flat average.
 */
static
Datum apply_mt_agg_internal_notiming(PG_FUNCTION_ARGS)
{
    MemoryContext oldcontext;
    MemoryContext per_query_ctx;
    TupleDesc outDesc = NULL;
    Tuplestorestate *tssData, *tssLambdas;
    int rowSize, nthreads, queue_capacity;

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

    rowSize = 1;
    nthreads = PG_GETARG_INT32(3);
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

    { // register each tuple-descriptor field with the corresponding field name
        TupleDescInitEntry(outDesc,
                           (AttrNumber)(rowSize),
                           "result",
                           lambda->rettype,
                           lambda->rettypmod,
                           0);
    }


    /* ------------------- Allocating mem for tupStore copy ------------------- */
    Size mem_chunk_data_size;
    int num_tuples_data = tuplestore_tuple_count(tssData);
    int num_cols_data = inDescData->natts; // DANGEROUS, assumes only floats in col

    mem_chunk_data_size = num_cols_data * num_tuples_data * sizeof(Datum);
    Datum *mem_chunk_data = (Datum *) palloc(mem_chunk_data_size);
    /* ------------------------------------------------------------------------ */

    //more overhead than necessary
    if(nthreads > num_tuples_data && num_tuples_data > 0)
        nthreads = num_tuples_data;

    /* ------------------- Copying values into temp.-memory ------------------- */
    int idx_tup = 0;
    while(tuplestore_gettupleslot(tssData, true, false, slotData))
    {
        slot_getallattrs(slotData);
        Datum *val_ptr_data = slotData->tts_values;

        //DANGEROUS -> assumes that architecture represents 0.0 float8's as all zero bits
        memcpy(mem_chunk_data + (idx_tup * num_cols_data), val_ptr_data, num_cols_data * sizeof(Datum));
        idx_tup++;
    }
    /* ------------------------------------------------------------------------ */
    /* --------------------- Allocating mem for result------------------------- */
    Size mem_chunk_result_size;
    int num_tuples_lambda = tuplestore_tuple_count(tssLambdas);
    int num_tuples_result = num_tuples_data * num_tuples_lambda;

    mem_chunk_result_size = num_tuples_result * sizeof(Datum);
    Datum *mem_chunk_result = (Datum *) palloc0(mem_chunk_result_size);
    /* ------------------------------------------------------------------------ */
    /* --------------------------- Threadpool --------------------------------- */
    TP_Pool *threadpool;
    threadpool = tp_create(nthreads, queue_capacity, eval_lambda);
    /* ------------------------------------------------------------------------ */

    int lambda_ctr = 0;

    while(tuplestore_gettupleslot(tssLambdas, true, false, slotLambdas))
    {
        LambdaExpr *tmp_lambda;
        Datum (*compiled_func)(Datum **);
        Datum input_tuples[2] = {Int8GetDatum(0), Int8GetDatum(0)};

        Datum *val_ptr_lambdas;

        slot_getallattrs(slotLambdas);
        val_ptr_lambdas = slotLambdas->tts_values;

        /* NORMALLY BAD, BUT APPLY ASSUMES ALL LAMBDAS IN SECOND SUBLINK */
        input_tuples[1] = PointerGetDatum(val_ptr_lambdas);

        tmp_lambda = lambda_injector(lambda, input_tuples);
        tmp_lambda->expr = (Expr *) eval_const_expressions(NULL, (Node *) tmp_lambda->expr);

        //Preparation for execution
        llvm_enter_tmp_context(rsinfo->econtext->ecxt_estate);
        ExecInitLambdaExpr((Node *)tmp_lambda, true, false);
        compiled_func = llvm_prepare_simple_expression(castNode(ExprState, tmp_lambda->exprstate));
        llvm_leave_tmp_context(rsinfo->econtext->ecxt_estate);

        for(int i = 0; i < nthreads; i++)
        {
            //Create Job-Ticket for Queue
            WorkItem cur_job = {
                .id_lambda = lambda_ctr,
                .in_data = mem_chunk_data,
                .start = (uint64_t) num_tuples_data * (uint64_t) i / (uint64_t) nthreads,
                .end = (uint64_t) num_tuples_data * (uint64_t) (i + 1) / (uint64_t) nthreads,
                .num_cols = num_cols_data,
                .num_tuples = num_tuples_data,
                .out = mem_chunk_result,
                .eval_func = compiled_func
            };

            tp_submit(threadpool, &cur_job, sizeof(cur_job));
        }

        lambda_ctr++;
    }
    //wait for workers to finish
    tp_finish_and_destroy(threadpool);

    //create/fill result tuplestore
    bool resultNulls = false; //always false/0, due to arithmetic operations
    Datum result;
    double_t cummulative_sum = 0.0;
    double_t cummulative_sum_inner = 0.0;

    for(int i = 0; i < num_tuples_result; i++)
    {
        cummulative_sum_inner += DatumGetFloat8(*(mem_chunk_result + i));
    }

    cummulative_sum = cummulative_sum_inner / num_tuples_result;

    result = Float8GetDatum(cummulative_sum);

    tuplestore_putvalues(tsOut,
                        outDesc,
                        &result,
                        &resultNulls);

    //prepare result
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult = tsOut;
    rsinfo->setDesc = outDesc;
    pfree(mem_chunk_data);
    pfree(mem_chunk_result);

    MemoryContextSwitchTo(oldcontext);
    llvm_close_tmp_context(rsinfo->econtext->ecxt_estate);

    return (Datum)0;
}

/*
 * apply_mt_agg - timing helper, that aggregates result into average, instead of return N x M cross-joined rows
 */
Datum apply_mt_agg(PG_FUNCTION_ARGS)
{
    return apply_mt_agg_internal_notiming(fcinfo);
}