#!/usr/bin/env python3
"""Make apply_mt_pw_ptime_ext.c: hol-lambdas/src/ext/apply_mt_pw_ext.c plus phase stamps.

    python3 make_ptime.py <apply_mt_pw_ext.c> <apply_mt_pw_ptime_ext.c>

Same code path as the installed operator; only adds CLOCK_MONOTONIC stamps, renames
the exported symbols (so it can never be confused with the installed .so) and installs
ExecutorStart/End hooks that measure the executor's read-out of the result after the
UDF has returned. One NOTICE per query, emitted from ExecutorEnd, between two
TIMING_RESULTS_MARKER lines. Fails loudly if an anchor in the operator's source moved.
run_ptime.py calls this itself.
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()


def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"patch anchor found {n}x (want {count}):\n{old}")
    s = s.replace(old, new)


# ---- symbols ------------------------------------------------------------------
rep("apply_mt_pw_worker_main", "apply_mt_pw_ptime_worker_main", 4)
rep("PG_FUNCTION_INFO_V1_RECTYPE(apply_mt_pw, apply_mt_pw_record_type);",
    "PG_FUNCTION_INFO_V1_RECTYPE(apply_mt_pw_ptime, apply_mt_pw_record_type);")
rep("PG_FUNCTION_INFO_V1_RECTYPE(apply_mt_agg_pw, apply_mt_agg_pw_record_type);",
    "PG_FUNCTION_INFO_V1_RECTYPE(apply_mt_agg_pw_ptime, apply_mt_agg_pw_record_type);")
rep("Datum apply_mt_pw(PG_FUNCTION_ARGS)", "Datum apply_mt_pw_ptime(PG_FUNCTION_ARGS)")
rep("Datum apply_mt_agg_pw(PG_FUNCTION_ARGS)", "Datum apply_mt_agg_pw_ptime(PG_FUNCTION_ARGS)")

# ---- timing infrastructure ----------------------------------------------------
rep("#include <dlfcn.h>\n", r'''#include <dlfcn.h>
#include <time.h>

/* ---------------------------- PTIME: stamps ----------------------------- */
static inline int64 ptime_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64) ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

typedef struct PtimeWorker
{
    int64 t_start, t_end;           //entry / exit of the worker function
    int64 compile_us;               //deserialize + init + JIT of every lambda it touched
    int64 wait_us;                  //blocked on data_ready
    int64 eval_us;                  //row loops, incl. writing the result tuples
    int   njobs, nlambdas;
} PtimeWorker;

#define PTIME_MAXW 64
static struct
{
    bool  pending;
    bool  agg;
    int   nworkers_req, nworkers, ndata, nlambdas, njobs;
    int64 t_es;                     //ExecutorStart entry
    int64 t_udf0, t_udf1;           //UDF entry / return
    int64 inject_us, serialize_us, mat_us, wait_us, out_us, launch_us, destroy_us;
    int64 t_launch;
    PtimeWorker w[PTIME_MAXW];
} ptime;

static ExecutorStart_hook_type ptime_prev_start = NULL;
static ExecutorEnd_hook_type ptime_prev_end = NULL;

static void ptime_executor_start(QueryDesc *qd, int eflags)
{
    ptime.t_es = ptime_now();
    if (ptime_prev_start)
        ptime_prev_start(qd, eflags);
    else
        standard_ExecutorStart(qd, eflags);
}

static void ptime_executor_end(QueryDesc *qd)
{
    int64 t_ee0 = ptime_now(), t_ee1;

    if (ptime_prev_end)
        ptime_prev_end(qd);
    else
        standard_ExecutorEnd(qd);
    t_ee1 = ptime_now();

    if (ptime.pending)
    {
        int64 total = ptime.t_udf1 - ptime.t_udf0;
        int64 prep = total - ptime.inject_us - ptime.mat_us - ptime.wait_us - ptime.out_us;
        int64 wmax_compile = 0, wmax_eval = 0, wmax_wait = 0, wmax_alive = 0, wmax_start = 0;
        double wsum_compile = 0, wsum_eval = 0, wsum_wait = 0;
        int n = Min(ptime.nworkers, PTIME_MAXW), nseen = 0;

        ptime.pending = false;
        for (int i = 0; i < n; i++)
        {
            PtimeWorker *w = &ptime.w[i];
            if (w->t_start == 0)
                continue;
            nseen++;
            wmax_compile = Max(wmax_compile, w->compile_us);
            wmax_eval = Max(wmax_eval, w->eval_us);
            wmax_wait = Max(wmax_wait, w->wait_us);
            wmax_alive = Max(wmax_alive, w->t_end - w->t_start);
            wmax_start = Max(wmax_start, w->t_start - ptime.t_launch);
            wsum_compile += w->compile_us;
            wsum_eval += w->eval_us;
            wsum_wait += w->wait_us;
        }
        ereport(NOTICE,
                (errmsg_internal("TIMING_RESULTS_MARKER\n"
                    "%s\n"
                    " nworkers_req=%d\n nworkers=%d\n workers_seen=%d\n"
                    " num_tuples_data=%d\n num_tuples_lambdas=%d\n num_jobs=%d\n"
                    " prep=" INT64_FORMAT " us\n"
                    " materialize_input=" INT64_FORMAT " us\n"
                    " inject=" INT64_FORMAT " us\n"
                    " eval=" INT64_FORMAT " us\n"
                    " rematerialize_output=" INT64_FORMAT " us\n"
                    " total=" INT64_FORMAT " us\n"
                    " readout=" INT64_FORMAT " us\n"
                    " executor_end=" INT64_FORMAT " us\n"
                    " pre_udf=" INT64_FORMAT " us\n"
                    " serialize=" INT64_FORMAT " us\n"
                    " launch=" INT64_FORMAT " us\n"
                    " destroy=" INT64_FORMAT " us\n"
                    " w_start_max=" INT64_FORMAT " us\n"
                    " w_alive_max=" INT64_FORMAT " us\n"
                    " w_compile_max=" INT64_FORMAT " us\n"
                    " w_compile_mean=%.1f us\n"
                    " w_eval_max=" INT64_FORMAT " us\n"
                    " w_eval_mean=%.1f us\n"
                    " w_wait_max=" INT64_FORMAT " us\n"
                    " w_wait_mean=%.1f us\n"
                    "TIMING_RESULTS_MARKER",
                    ptime.agg ? "apply_mt_agg_pw_ptime" : "apply_mt_pw_ptime",
                    ptime.nworkers_req, ptime.nworkers, nseen,
                    ptime.ndata, ptime.nlambdas, ptime.njobs,
                    prep, ptime.mat_us, ptime.inject_us, ptime.wait_us, ptime.out_us, total,
                    t_ee0 - ptime.t_udf1, t_ee1 - t_ee0, ptime.t_udf0 - ptime.t_es,
                    ptime.serialize_us, ptime.launch_us, ptime.destroy_us,
                    wmax_start, wmax_alive,
                    wmax_compile, nseen ? wsum_compile / nseen : 0.0,
                    wmax_eval, nseen ? wsum_eval / nseen : 0.0,
                    wmax_wait, nseen ? wsum_wait / nseen : 0.0)));
    }
}

void _PG_init(void)
{
    ptime_prev_start = ExecutorStart_hook;
    ExecutorStart_hook = ptime_executor_start;
    ptime_prev_end = ExecutorEnd_hook;
    ExecutorEnd_hook = ptime_executor_end;
}
/* ------------------------------------------------------------------------ */
''')

rep("#define APPLY_PW_NKEYS          7", "#define APPLY_PW_KEY_PTIME      UINT64CONST(7)\n#define APPLY_PW_NKEYS          8")

# ---- worker -------------------------------------------------------------------
rep("""    ColInfo       *col_info = shm_toc_lookup(toc, APPLY_PW_KEY_COLINFO, false);
""", """    ColInfo       *col_info = shm_toc_lookup(toc, APPLY_PW_KEY_COLINFO, false);
    PtimeWorker   *pt_all   = shm_toc_lookup(toc, APPLY_PW_KEY_PTIME,   false);
    PtimeWorker    pt       = {0};

    pt.t_start = ptime_now();
""")
rep("""        if(tmp_lambda == NULL)
        {
            //copy out of DSM first""", """        if(tmp_lambda == NULL)
        {
            int64 pt_c0 = ptime_now();
            //copy out of DSM first""")
rep("""            pfree(ser);
            lambdas[job->id_lambda] = tmp_lambda;
        }
""", """            pfree(ser);
            lambdas[job->id_lambda] = tmp_lambda;
            pt.compile_us += ptime_now() - pt_c0;
            pt.nlambdas++;
        }
        pt.njobs++;
""")
rep("""        if(!have_data)
        {
            if(""", """        if(!have_data)
        {
            int64 pt_w0 = ptime_now();
            if(""")
rep("""            have_data = true;
        }

        double sum = 0.0;
""", """            have_data = true;
            pt.wait_us += ptime_now() - pt_w0;
        }

        double sum = 0.0;
        int64 pt_e0 = ptime_now();
""")
rep("""        //one writer per job, so the array needs no synchronisation
        if(agg)
            partial[job_id] = sum;
    }
""", """        //one writer per job, so the array needs no synchronisation
        if(agg)
            partial[job_id] = sum;
        pt.eval_us += ptime_now() - pt_e0;
    }
""")
rep("""    FreeExecutorState(estate);
}""", """    FreeExecutorState(estate);

    pt.t_end = ptime_now();
    if(ParallelWorkerNumber >= 0 && ParallelWorkerNumber < PTIME_MAXW)
        pt_all[ParallelWorkerNumber] = pt;
}""")

# ---- leader -------------------------------------------------------------------
rep("""    int nworkers, mode;

    ReturnSetInfo *rsinfo""", """    int nworkers, mode;
    int64 pt_udf0 = ptime_now(), pt_t;

    memset(&ptime, 0, offsetof(typeof(ptime), w));
    memset(ptime.w, 0, sizeof(ptime.w));
    ptime.t_es = 0;

    ReturnSetInfo *rsinfo""")
# t_es is written by the hook before the UDF runs; keep it across the reset above
rep("""    memset(&ptime, 0, offsetof(typeof(ptime), w));
    memset(ptime.w, 0, sizeof(ptime.w));
    ptime.t_es = 0;
""", """    {
        int64 keep_es = ptime.t_es;
        memset(&ptime, 0, sizeof(ptime));
        ptime.t_es = keep_es;
    }
""")
rep("""        input_tuples[1] = PointerGetDatum(slotLambdas->tts_values);
        tmp_lambda = lambda_injector(lambda, input_tuples);
        tmp_lambda->expr = (Expr *) eval_const_expressions(NULL, (Node *) tmp_lambda->expr);

        serialized[lambda_ctr] = lambdaExprToSerialLambda(tmp_lambda);
""", """        input_tuples[1] = PointerGetDatum(slotLambdas->tts_values);
        pt_t = ptime_now();
        tmp_lambda = lambda_injector(lambda, input_tuples);
        tmp_lambda->expr = (Expr *) eval_const_expressions(NULL, (Node *) tmp_lambda->expr);
        ptime.inject_us += ptime_now() - pt_t;

        pt_t = ptime_now();
        serialized[lambda_ctr] = lambdaExprToSerialLambda(tmp_lambda);
        ptime.serialize_us += ptime_now() - pt_t;
""")
rep("""        shm_toc_estimate_keys(&pcxt->estimator, APPLY_PW_NKEYS);
""", """        shm_toc_estimate_chunk(&pcxt->estimator, PTIME_MAXW * sizeof(PtimeWorker));
        shm_toc_estimate_keys(&pcxt->estimator, APPLY_PW_NKEYS);
""")
rep("""        shm_toc_insert(pcxt->toc, APPLY_PW_KEY_COLINFO, shm_cols);

        LaunchParallelWorkers(pcxt);
""", """        shm_toc_insert(pcxt->toc, APPLY_PW_KEY_COLINFO, shm_cols);

        PtimeWorker *shm_ptime = shm_toc_allocate(pcxt->toc, PTIME_MAXW * sizeof(PtimeWorker));
        memset(shm_ptime, 0, PTIME_MAXW * sizeof(PtimeWorker));
        shm_toc_insert(pcxt->toc, APPLY_PW_KEY_PTIME, shm_ptime);

        ptime.t_launch = ptime_now();
        LaunchParallelWorkers(pcxt);
        ptime.launch_us = ptime_now() - ptime.t_launch;
        ptime.nworkers = pcxt->nworkers_launched;
""")
rep("""        int idx_tup = 0;
        while(tuplestore_gettupleslot(tssData, true, false, slotData))""", """        int64 pt_m0 = ptime_now();
        int idx_tup = 0;
        while(tuplestore_gettupleslot(tssData, true, false, slotData))""")
rep("""        ConditionVariableBroadcast(&hdr->data_cv);
        /* -------------------------------------------------------------------- */

        //wait for workers to finish, this also re-throws their errors
        WaitForParallelWorkersToFinish(pcxt);
    }
""", """        ConditionVariableBroadcast(&hdr->data_cv);
        ptime.mat_us = ptime_now() - pt_m0;
        /* -------------------------------------------------------------------- */

        //wait for workers to finish, this also re-throws their errors
        pt_t = ptime_now();
        WaitForParallelWorkersToFinish(pcxt);
        ptime.wait_us = ptime_now() - pt_t;
        memcpy(ptime.w, shm_ptime, PTIME_MAXW * sizeof(PtimeWorker));
    }

    int64 pt_o0 = ptime_now();
""")
rep("""    if(pcxt != NULL)
    {
        DestroyParallelContext(pcxt);
        ExitParallelMode();
    }
""", """    ptime.out_us = ptime_now() - pt_o0;

    pt_t = ptime_now();
    if(pcxt != NULL)
    {
        DestroyParallelContext(pcxt);
        ExitParallelMode();
    }
    ptime.destroy_us = ptime_now() - pt_t;
""")
rep("""    //no llvm_close_tmp_context here, the leader never compiled anything

    return (Datum)0;""", """    //no llvm_close_tmp_context here, the leader never compiled anything

    ptime.agg = agg;
    ptime.nworkers_req = PG_GETARG_INT32(3);
    ptime.ndata = num_tuples_data;
    ptime.nlambdas = num_tuples_lambda;
    ptime.njobs = num_jobs;
    ptime.t_udf0 = pt_udf0;
    ptime.t_udf1 = ptime_now();
    ptime.pending = true;

    return (Datum)0;""")

open(dst, "w").write(s)
print("ok", dst)
