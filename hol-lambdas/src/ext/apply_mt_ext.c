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

static TupleDesc apply_mt_record_type(List *args)
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
PG_FUNCTION_INFO_V1_RECTYPE(apply_mt, apply_mt_record_type);

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
Datum apply_mt_internal(PG_FUNCTION_ARGS)
{
    MemoryContext oldcontext;
    MemoryContext per_query_ctx;
    TupleDesc outDesc = NULL;
    Tuplestorestate *tssData, *tssLambdas;
    int rowSize, nthreads, queue_capacity;
    //timer = lt_start();

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

    rowSize = inDescData->natts + 1;
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
        for (int i = 0; i < inDescData->natts; i++)
        {
            TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescData, (AttrNumber)(i + 1));
        }

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

    //timer = lt_tick(timer, "Preparations done");
    int lambda_ctr = 0;

    bool onetime = false;

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
        tmp_lambda = lambda_injector(lambda, input_tuples);
        tmp_lambda->expr = (Expr *) eval_const_expressions(NULL, (Node *) tmp_lambda->expr);

        if(onetime)
        {
            elog_node((Node *) tmp_lambda->expr);
            printf("%s", deparse_expression((Node *) tmp_lambda, NULL, false, false));
            onetime = false;
        }

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
    int num_cols_result = 1 + num_cols_data;
    bool *resultNulls = (bool *) palloc0(num_cols_result * sizeof(bool)); //always false/0, due to arithmetic operations
    Datum *results = (Datum *) palloc0(num_cols_result * sizeof(Datum)); 

    for(int i = 0; i < num_tuples_result; i++)
    {
        memcpy(results, mem_chunk_data + (i % num_tuples_data) * num_cols_data, sizeof(Datum) * num_cols_data);
        results[num_cols_data] = *(mem_chunk_result + i);

        tuplestore_putvalues(tsOut, 
                             outDesc, 
                             results, 
                             resultNulls);
    }

    //prepare result
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult = tsOut;
    rsinfo->setDesc = outDesc;
    pfree(mem_chunk_data);
    pfree(mem_chunk_result);

    MemoryContextSwitchTo(oldcontext);
    llvm_close_tmp_context(rsinfo->econtext->ecxt_estate);
    //lt_total(timer, "");

    return (Datum)0;
}

/*
 * apply_mt - injects a singular lambda expression, read from a table, into another, and calculates the result
 * 
 * This function makes multiple assumptions.
 * First: The data is in the first provided sublink, the lambda functions in the second.
 * Second: The lambda function is "alone" and inside the first column of the second Sublink
 * Third: the "used" lambda is always referred to as "X.f(...)" (especially the f part)
 * 
 * Fast variant, because injected/applied lambda is not returned
 */
Datum apply_mt(PG_FUNCTION_ARGS)
{
    return apply_mt_internal(fcinfo);
}