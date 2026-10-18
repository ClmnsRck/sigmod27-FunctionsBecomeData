#include "postgres.h"
#include "funcapi.h"
#include "jit/llvmjit.h"
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

static TupleDesc apply_record_type(List *args)
{
    LambdaExpr *lambda = (LambdaExpr *)list_nth(args, 0);
    TupleDesc inDescData = (TupleDesc)list_nth(lambda->argTypesTupDesc, 0);
    TupleDesc inDescLambdas = (TupleDesc)list_nth(lambda->argTypesTupDesc, 1);
    Form_pg_attribute lambda_attr = TupleDescAttr(inDescLambdas, 0); //DANGEROUS, implies the first column in lambdas table is a lambda-func
    TupleDesc outDesc;
    outDesc = CreateTemplateTupleDesc(inDescData->natts + inDescLambdas->natts + 1 + 1);

    for (int i = 0; i < inDescData->natts; i++)
    {
        TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescData, (AttrNumber)(i + 1));
    }

    for (int i = inDescData->natts; i < inDescLambdas->natts + inDescData->natts; i++)
    {
        TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescLambdas, (AttrNumber)(i + 1 - inDescData->natts));
    }

    TupleDescInitEntry(outDesc,
                        (AttrNumber)(inDescData->natts + inDescLambdas->natts + 1),
                        "applied_lambda",
                        lambda_attr->atttypid,
                        lambda_attr->atttypmod,
                        lambda_attr->attndims);

    TupleDescInitEntry(outDesc,
                        (AttrNumber)(inDescData->natts + inDescLambdas->natts + 1 + 1),
                        "result",
                        (lambda->rettype),
                        lambda->rettypmod,
                        0);

    return outDesc;
}

static TupleDesc apply_fast_record_type(List *args)
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
PG_FUNCTION_INFO_V1_RECTYPE(apply_l1_2, apply_record_type);
PG_FUNCTION_INFO_V1_RECTYPE(apply_fast, apply_fast_record_type);

static
Datum apply_l1_2_internal(PG_FUNCTION_ARGS)
{
    MemoryContext oldcontext;
    MemoryContext per_query_ctx, per_tuple_ctx;
    TupleDesc outDesc = NULL;
    Tuplestorestate *tssData, *tssLambdas;
    Datum *replVal;
    bool *replIsNull;
    bool baseline;
    int rowSize;
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
    Form_pg_attribute lambda_attr = TupleDescAttr(inDescLambdas, 0); //See not in "apply_record_type()"

    rowSize = inDescData->natts + inDescLambdas->natts + 1 + 1;

    baseline = PG_GETARG_BOOL(3);

    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    per_tuple_ctx = rsinfo->econtext->ecxt_per_tuple_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);

    tssData = ((TypedTuplestore *) PG_GETARG_POINTER(1))->tuplestorestate;
    const TupleTableSlotOps *slotOpsData = &TTSOpsMinimalTuple;
    TupleTableSlot *slotData = MakeTupleTableSlot(inDescData, slotOpsData);

    tssLambdas = ((TypedTuplestore *) PG_GETARG_POINTER(2))->tuplestorestate;
    const TupleTableSlotOps *slotOpsLambdas = &TTSOpsMinimalTuple;
    TupleTableSlot *slotLambdas = MakeTupleTableSlot(inDescLambdas, slotOpsLambdas);

    Tuplestorestate *tsOut = tuplestore_begin_heap(true, false, work_mem);


    outDesc = CreateTemplateTupleDesc(rowSize);

    { // register each tuple-descriptor field with the corresponding field name
        for (int i = 0; i < inDescData->natts; i++)
        {
            TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescData, (AttrNumber)(i + 1));
        }

        for (int i = inDescData->natts; i < inDescLambdas->natts + inDescData->natts; i++)
        {
            TupleDescCopyEntry(outDesc, (AttrNumber)(i + 1), inDescLambdas, (AttrNumber)(i + 1 - inDescData->natts));
        }

        TupleDescInitEntry(outDesc, 
                            (AttrNumber)(rowSize - 1), 
                            "applied_lambda",
                            lambda_attr->atttypid,
                            lambda_attr->atttypmod,
                            lambda_attr->attndims);

        TupleDescInitEntry(outDesc, 
                           (AttrNumber)(rowSize), 
                           "result",
                           lambda->rettype, 
                           lambda->rettypmod, 
                           0);
    }

    replIsNull = (bool *)palloc((rowSize) * sizeof(bool));
    replVal = (Datum *)palloc((rowSize) * sizeof(Datum));

    //timer = lt_tick(timer, "Preparations done");
    //int lambda_ctr = 1;

    //for (slotLambdas = ExecProcNode(planStateLambdas); !TupIsNull(slotLambdas); slotLambdas = ExecProcNode(planStateLambdas))
    while(tuplestore_gettupleslot(tssLambdas, true, false, slotLambdas))
    {
        CHECK_FOR_INTERRUPTS();
        MemoryContext per_lambda_ctx = AllocSetContextCreate(
            per_query_ctx, "per lambda context", ALLOCSET_DEFAULT_SIZES
        );
        MemoryContextSwitchTo(per_lambda_ctx);
        //timer = lt_tick(timer, "Starting with Lambda %d", lambda_ctr);
        //int data_ctr = 0;
        LambdaExpr *tmp_lambda;
        Datum serializedLambda;
        Datum input_tuples[2] = {Int8GetDatum(0), Int8GetDatum(0)};

        Datum *val_ptr_lambdas;
        bool *null_ptr_lambdas;

        slot_getallattrs(slotLambdas);
        val_ptr_lambdas = slotLambdas->tts_values;
        null_ptr_lambdas = slotLambdas->tts_isnull;

        if(baseline)
        {
            //for benchmark ok, apply assumes first col of lambdas table to be a lambda, but dangerous otherwise
            tmp_lambda = copyObject(lambda_deserialize((SerializedLambda *) PG_DETOAST_DATUM(val_ptr_lambdas[0])));
            tmp_lambda->argTypesTupDesc = lambda->argTypesTupDesc;
            tmp_lambda->parentPlan = lambda->parentPlan;
        } else {
            /* NORMALLY BAD, BUT APPLY ASSUMES ALL LAMBDAS IN SECOND SUBLINK */
            input_tuples[1] = PointerGetDatum(val_ptr_lambdas);
            tmp_lambda = lambda_injector(lambda, input_tuples);
        }

        //Preparation for execution
        llvm_enter_tmp_context(rsinfo->econtext->ecxt_estate);
        ExecInitLambdaExpr((Node *)tmp_lambda, false, false);
        llvm_leave_tmp_context(rsinfo->econtext->ecxt_estate);
        MemoryContextSwitchTo(per_query_ctx);

        if(baseline)
        {
            ExprState * state = (ExprState *) tmp_lambda->exprstate;
            //very bad, but for benchmark baseline, manually set all fieldselect tupleDescs to data-tupleDesc
            for(int i = 0; i < state->steps_len; i++)
            {
                ExprEvalStep *step = &state->steps[i];
                if(ExecEvalStepOp(state, step) != EEOP_FIELDSELECT)
                    continue;
                step->d.fieldselect.rowcache.cacheptr = inDescData;
                step->d.fieldselect.lambda = true;
            }
        }

        //prepare a already serilized version of the lambda for output
        serializedLambda = PointerGetDatum(lambdaExprToSerialLambda(tmp_lambda));

        //timer = lt_tick(timer, "Lambda %d injected", lambda_ctr);

        while(tuplestore_gettupleslot(tssData, true, false, slotData))
        {
            CHECK_FOR_INTERRUPTS();

            MemoryContextSwitchTo(per_tuple_ctx);
            MemoryContextReset(per_tuple_ctx);
            //data_ctr++;
            bool isnull;
            Datum *val_ptr_data;
            bool *null_ptr_data;

            slot_getallattrs(slotData);
            val_ptr_data = slotData->tts_values;
            null_ptr_data = slotData->tts_isnull;

            HeapTuple newTup = heap_form_tuple(inDescData, val_ptr_data, null_ptr_data);
            PG_LAMBDA_SETARG(tmp_lambda, 0, HeapTupleHeaderGetDatum(newTup->t_data));
            Datum result = PG_LAMBDA_EVAL(tmp_lambda, 0, &isnull);

            heap_freetuple(newTup);
            ExecClearTuple(slotData);

            MemoryContextSwitchTo(per_query_ctx);

            for (int i = 0; i < inDescData->natts; i++) 
            {
                replVal[i] = val_ptr_data[i];
                replIsNull[i] = null_ptr_data[i];
            }

            for (int i = inDescData->natts; i < rowSize-2; i++)
            {
                replVal[i] = val_ptr_lambdas[i - inDescData->natts];
                replIsNull[i] = null_ptr_lambdas[i - inDescData->natts];
            }

            //applied lambda
            replVal[rowSize - 2] = serializedLambda;
            replIsNull[rowSize - 2] = false;

            //actual numerical result
            replVal[rowSize - 1] = result;
            replIsNull[rowSize - 1] = false;

            tuplestore_putvalues(tsOut, outDesc, replVal, replIsNull);
        }
        tuplestore_rescan(tssData);

        MemoryContextSwitchTo(per_query_ctx);
        MemoryContextDelete(per_lambda_ctx);
        //timer = lt_tick(timer, "Lambda %d with %d tuples", lambda_ctr, data_ctr);
        //lambda_ctr++;
    }

    rsinfo->setResult = tsOut;
    rsinfo->setDesc = outDesc;

    MemoryContextSwitchTo(oldcontext);
    llvm_close_tmp_context(rsinfo->econtext->ecxt_estate);
    //lt_total(timer, "");

    return (Datum)0;
}

static
Datum apply_fast_internal(PG_FUNCTION_ARGS)
{
    MemoryContext oldcontext;
    MemoryContext per_query_ctx, per_tuple_ctx;
    TupleDesc outDesc = NULL;
    Tuplestorestate *tssData, *tssLambdas;
    Datum *replVal;
    bool *replIsNull;
    bool baseline;
    int rowSize;
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

    baseline = PG_GETARG_BOOL(3);

    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    per_tuple_ctx = rsinfo->econtext->ecxt_per_tuple_memory;
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

    replIsNull = (bool *)palloc((rowSize) * sizeof(bool));
    replVal = (Datum *)palloc((rowSize) * sizeof(Datum));

    //timer = lt_tick(timer, "Preparations done");
    //int lambda_ctr = 1;

    //for (slotLambdas = ExecProcNode(planStateLambdas); !TupIsNull(slotLambdas); slotLambdas = ExecProcNode(planStateLambdas))
    while(tuplestore_gettupleslot(tssLambdas, true, false, slotLambdas))
    {
        CHECK_FOR_INTERRUPTS();
        MemoryContext per_lambda_ctx = AllocSetContextCreate(
            per_query_ctx, "per lambda context", ALLOCSET_DEFAULT_SIZES
        );
        MemoryContextSwitchTo(per_lambda_ctx);
        //timer = lt_tick(timer, "Starting with Lambda %d", lambda_ctr);
        //int data_ctr = 0;
        LambdaExpr *tmp_lambda;
        Datum input_tuples[2] = {Int8GetDatum(0), Int8GetDatum(0)};

        Datum *val_ptr_lambdas;

        slot_getallattrs(slotLambdas);
        val_ptr_lambdas = slotLambdas->tts_values;

        if(baseline)
        {
            //for benchmark ok, apply assumes first col of lambdas table to be a lambda, but dangerous otherwise
            tmp_lambda = copyObject(lambda_deserialize((SerializedLambda *) PG_DETOAST_DATUM(val_ptr_lambdas[0])));
            tmp_lambda->argTypesTupDesc = lambda->argTypesTupDesc;
            tmp_lambda->parentPlan = lambda->parentPlan;
        } else {
            /* NORMALLY BAD, BUT APPLY ASSUMES ALL LAMBDAS IN SECOND SUBLINK */
            input_tuples[1] = PointerGetDatum(val_ptr_lambdas);
            tmp_lambda = lambda_injector(lambda, input_tuples);
        }

        //Preparation for execution
        llvm_enter_tmp_context(rsinfo->econtext->ecxt_estate);
        ExecInitLambdaExpr((Node *)tmp_lambda, false, false);
        llvm_leave_tmp_context(rsinfo->econtext->ecxt_estate);
        MemoryContextSwitchTo(per_query_ctx);

        if(baseline)
        {
            ExprState * state = (ExprState *) tmp_lambda->exprstate;
            //very bad, but for benchmark baseline, manually set all fieldselect tupleDescs to data-tupleDesc
            for(int i = 0; i < state->steps_len; i++)
            {
                ExprEvalStep *step = &state->steps[i];
                if(ExecEvalStepOp(state, step) != EEOP_FIELDSELECT)
                    continue;
                step->d.fieldselect.rowcache.cacheptr = inDescData;
                step->d.fieldselect.lambda = true;
            }
        }

        //timer = lt_tick(timer, "Lambda %d injected", lambda_ctr);

        while(tuplestore_gettupleslot(tssData, true, false, slotData))
        {
            CHECK_FOR_INTERRUPTS();

            MemoryContextSwitchTo(per_tuple_ctx);
            MemoryContextReset(per_tuple_ctx);
            //data_ctr++;
            bool isnull;
            Datum *val_ptr_data;
            bool *null_ptr_data;

            slot_getallattrs(slotData);
            val_ptr_data = slotData->tts_values;
            null_ptr_data = slotData->tts_isnull;

            HeapTuple newTup = heap_form_tuple(inDescData, val_ptr_data, null_ptr_data);
            PG_LAMBDA_SETARG(tmp_lambda, 0, HeapTupleHeaderGetDatum(newTup->t_data));
            Datum result = PG_LAMBDA_EVAL(tmp_lambda, 0, &isnull);

            heap_freetuple(newTup);
            ExecClearTuple(slotData);

            MemoryContextSwitchTo(per_query_ctx);

            for (int i = 0; i < inDescData->natts; i++) 
            {
                replVal[i] = val_ptr_data[i];
                replIsNull[i] = null_ptr_data[i];
            }

            //actual numerical result
            replVal[rowSize - 1] = result;
            replIsNull[rowSize - 1] = false;

            tuplestore_putvalues(tsOut, outDesc, replVal, replIsNull);
        }
        tuplestore_rescan(tssData);

        MemoryContextSwitchTo(per_query_ctx);
        MemoryContextDelete(per_lambda_ctx);
        //timer = lt_tick(timer, "Lambda %d with %d tuples", lambda_ctr, data_ctr);
        //lambda_ctr++;
    }

    rsinfo->setResult = tsOut;
    rsinfo->setDesc = outDesc;

    MemoryContextSwitchTo(oldcontext);
    llvm_close_tmp_context(rsinfo->econtext->ecxt_estate);
    //lt_total(timer, "");

    return (Datum)0;
}

/*
 * apply_l1_2 - injects a singular lambda expression, read from a table, into another, and calculates the result
 * 
 * This function makes multiple assumptions.
 * First: The data is in the first provided sublink, the lambda functions in the second.
 * Second: The lambda function is "alone" and inside the first column of the second Sublink
 * Third: the "used" lambda is always referred to as "X.f(...)" (especially the f part)
 */
Datum apply_l1_2(PG_FUNCTION_ARGS)
{

    return apply_l1_2_internal(fcinfo);
}

/*
 * apply_fast - injects a singular lambda expression, read from a table, into another, and calculates the result
 * 
 * This function makes multiple assumptions.
 * First: The data is in the first provided sublink, the lambda functions in the second.
 * Second: The lambda function is "alone" and inside the first column of the second Sublink
 * Third: the "used" lambda is always referred to as "X.f(...)" (especially the f part)
 * 
 * Fast variant, because injected/applied lambda is not returned
 */
Datum apply_fast(PG_FUNCTION_ARGS)
{
    return apply_fast_internal(fcinfo);
}