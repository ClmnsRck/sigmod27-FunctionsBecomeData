/*-------------------------------------------------------------------------
 *
 * lambda.h
 *     Declarations for lambda data type support.
 *
 * Copyright (c) 1996-2024, PostgreSQL Global Development Group
 * Copyright (c) 2021-2025, XXXX XXXX
 *
 * src/include/utils/lambda.h
 *-------------------------------------------------------------------------*/
#ifndef __LAMBDA_H__
#define __LAMBDA_H__

#include "postgres.h"
#include "lib/stringinfo.h"
#include "utils/array.h"
#include "utils/numeric.h"
#include "access/htup_details.h"
#include "utils/varlena.h"
#include "nodes/nodes.h"
#include "nodes/primnodes.h"
#include "nodes/execnodes.h"
#include "portability/instr_time.h"
#include "catalog/pg_lambdasig.h"
#include "utils/fmgroids.h"

/* Debug macros for QoL */
#define FUNCNAME_DBG \
	(custom_lambda_debugging_enabled() ? psprintf("%s:%d:%s:", __FILE__, __LINE__, __func__) : "")

#define DEBUGMSG(msg, ...) \
	do { \
		if (custom_lambda_debugging_enabled()) \
			elog(DEBUG1, "[%s:%d:%s]: " msg, __FILE__, __LINE__, __func__, ##__VA_ARGS__); \
	} while (0)

/* Ensure Alignement safety */
#define SERIAL_LAMBDA_MAGIC 0x1a1a1a1a

/* First gets used if matching lambda function was found in func arguments */
#define LAMBDA_PASS_TO_FUNC_DETAIL "lambda-prefix-string-check"
/* gets used, if matching lambda column was found in namespace, but wasnt in lambda call(outside UDF) */
#define LAMBDA_PASS_TO_FUNC_DETAIL_ON_MATCH "lambda-prefix-string-on-matching-table-name"

/* Align length to 4-byte boundary */
#define ALIGN_TO_4(len) (((len) + 3) & ~3)

/*-------------------------------------------------------------------------
 * The L3 instruction whitelist ("the L3 mask")
 *
 * L3 is the subset of ops with a fast, "unsafe" execution path: the hand-written
 * instruction switch in the lambda JIT(llvm_compile_expr's lambda path in
 * llvmjit_expr.c, the switch over fcinfo->flinfo->fn_oid, mirrored by the
 * derivative switch). A lambda body is L3-safe iff EVERY node is one of:
 *   - a Const,
 *   - a PARAM_EXEC Param (lambda arg / input binding),
 *   - an op/func call whose function is in the list below,
 *   - a nested lambda call(LFA, or a CallLambdaExpr on a column-stored lambda)
 *     whose ARG EXPRESSIONS are all L3-safe. The callee body is a runtime value
 *     (function input / Var of type lambda), not reachable here - "callee is also
 *     L3-safe" is enforced at injection time, where every lambda in a flattened
 *     combo must have l3_safe == true before the fast path is taken.
 * Anything else(unknown tag, PARAM_EXTERN, non-listed function, ...) makes the
 * body NOT L3-safe. Fails safe: unknown == unsafe. See lambda_expr_is_l3_safe().
 *
 * Every function here MUST have a matching hand-written L3 impl(a case in that
 * switch). This list is the single human-readable registry of "what has an L3
 * impl" and must line up with the switch EXACTLY. Kept in sync BY HAND, on
 * purpose no automation cross-checks the two:
 *   - add an L3 case in the switch -> add its fmgr OID here,
 *   - remove/break one -> remove it here,
 *   - on every change, eyeball BOTH sides.
 * Entries use the F_* fmgr-OID macros from utils/fmgroids.h. Where the switch
 * takes several OIDs for the same op(numeric variant, pow/power aliases) every
 * one is listed so the mask matches case-for-case. Columns: X(oid macro, comment).
 *-------------------------------------------------------------------------*/
#define LAMBDA_L3_FUNC_LIST(X) \
	/* --- arithmetic (numeric-typed OIDs are compiled as float8 too) --- */ \
	X(F_FLOAT8MUL,             "float8 * float8") \
	X(F_NUMERIC_MUL,           "numeric *  (compiled as float8 *)") \
	X(F_FLOAT8DIV,             "float8 / float8") \
	X(F_NUMERIC_DIV,           "numeric /  (compiled as float8 /)") \
	X(F_FLOAT8PL,              "float8 + float8") \
	X(F_NUMERIC_ADD,           "numeric +  (compiled as float8 +)") \
	X(F_FLOAT8MI,              "float8 - float8") \
	X(F_NUMERIC_SUB,           "numeric -  (compiled as float8 -)") \
	X(F_FLOAT8UM,              "- float8 (unary minus)") \
	X(F_FLOAT8ABS,             "@ float8 (absolute value)") \
	X(F_ABS_FLOAT8,            "abs(float8)") \
	/* --- powers / roots / exp / log --- */ \
	X(F_DPOW,                  "pow(float8, float8)") \
	X(F_POW_FLOAT8_FLOAT8,     "pow(float8, float8)  (alias)") \
	X(F_POWER_FLOAT8_FLOAT8,   "power(float8, float8)  (alias)") \
	X(F_DSQRT,                 "sqrt(float8)") \
	X(F_SQRT_FLOAT8,           "sqrt(float8)  (alias)") \
	X(F_EXP_FLOAT8,            "exp(float8)") \
	X(F_LN_FLOAT8,             "ln(float8) (natural log)") \
	X(F_DLOG10,                "log(float8) (base 10)") \
	/* --- trig --- */ \
	X(F_SIN,                   "sin(float8)") \
	X(F_COS,                   "cos(float8)") \
	X(F_TAN,                   "tan(float8)") \
	X(F_COT,                   "cot(float8)") \
	X(F_ASIN,                  "asin(float8)") \
	X(F_ACOS,                  "acos(float8)") \
	X(F_ATAN,                  "atan(float8)") \
	X(F_ATAN2,                 "atan2(float8, float8)") \
	/* --- scalar neural-net activations / loss (custom builtins) --- */ \
	X(F_SOFTMAX_CCE,           "softmax_cce(float8[], float8[])") \
	X(F_SILU,                  "silu(float8)") \
	X(F_SIGMOID,               "sigmoid(float8)") \
	X(F_TANH,                  "tanh(float8)") \
	X(F_RELU,                  "relu(float8)") \
	/* --- matrix operations (custom builtins, OIDs 9000+) --- */ \
	X(F_MAT_MUL,               "matrix multiply") \
	X(F_SILU_M,                "matrix silu") \
	X(F_SIGMOID_M,             "matrix sigmoid") \
	X(F_TANH_M,                "matrix tanh") \
	X(F_RELU_M,                "matrix relu") \
	X(F_MAT_ADD,               "matrix add")
	/* When extending: add the line above and provide the matching JIT case. */

/* True iff funcid is in the L3 whitelist (LAMBDA_L3_FUNC_LIST). */
extern bool lambda_op_has_l3_impl(Oid funcid);

/*
 * True iff the body only uses L3-whitelisted ops over L3-safe leaves. Fails safe
 * (false) for NULL/empty bodies and unknown nodes. Computed once at parse
 * analysis, cached in LambdaExpr.l3_safe.
 */
extern bool lambda_expr_is_l3_safe(LambdaExpr *lambda);

/*
 * Size of the per-call PARAM_EXEC array installed while evaluating a lambda body
 * (see ExecEvalCallLambdaExpr). Generous so nested/higher-order paramid refs stay
 * in bounds, also caps how many of the query's own PARAM_EXEC slots we preserve
 * across a lambda call.
 */
#define LAMBDA_PARAM_EXEC_SLOTS 512

/* Total size of SerializedLambda including varlena header */
#define SerializedLambdaSize(sl) VARSIZE(sl)
/* Pointer to end of SerializedLambda buffer */
#define SerializedLambdaEnd(sl) ((char *)(sl) + SerializedLambdaSize(sl))
/* Cast a Datum to SerializedLambda pointer, detoasting if necessary */
#define SerializedLambdaFromDatum(d) ((SerializedLambda *) PG_DETOAST_DATUM(d))
/* Get the nth argument as a SerializedLambda pointer */
#define PG_GETARG_SERIALIZEDLAMBDA_P(n) SerializedLambdaFromDatum(PG_GETARG_DATUM(n))

/*
 * Root object of any Serialized lambda expression. Holds varlena header and 
 * metadata, followed by TLV-encoded SerializedLambdaOpHeader stream.
 *
 * The field vl_len_ is a required PostgreSQL convention for TOASTable (varlena) 
 * types. It stores the total length of the palloc'd object. VARSIZE() and 
 * SET_VARSIZE() macros operate on this field.
 */
typedef struct SerializedLambda
{
    int32 vl_len_;   /* varlena header: total length of the struct */
    int32 nargs;     /* number of ParamExterns */
    uint32 magic;    /* for alignment portability */
    char  data[FLEXIBLE_ARRAY_MEMBER];  /* TLV-encoded ops */
} SerializedLambda;

/*
 * ExprState of a Called lambda function. Holds everything needed to execute a
 * lambda loaded dynamically during the executor run.
 */
typedef struct CallLambdaExprState
{
	CallLambdaExpr *expr;

	Datum		lambda_value;
	bool		lambda_isnull;

	Datum	   *argvalues;
	bool	   *argnulls;
	int			nargs;

	bool		cached_lambda_valid;
	Datum		cached_lambda_image;
	ExprState  *cached_body_state;
	MemoryContext cached_lambda_cxt;

	/*
	 * Per-combination cache key for the hoisting/injection path.
	 *
	 * cached_lambda_arg_idx = flat indices of the lambda-valued(non-atomic) args.
	 * These positions are constant per call site, since the parser type-checks every
	 * mother lambda in the column against one signature. cached_lambda_arg_image =
	 * their datum images at the time cached_body_state(the flattened, injected
	 * first-order body) was built. We only re-inject when the mother lambda OR one of
	 * these lambda args changes -> once per lambda combination, not per row. Atomic
	 * args never trigger re-injection.
	 */
	bool		hoisted;			/* cached_body_state came from lambda_injector */
	int		   *cached_lambda_arg_idx;
	Datum	   *cached_lambda_arg_image;
	int			n_cached_lambda_args;

	/* argument binding for lambda body PARAM_EXEC nodes */
	ParamExecData *lambda_params;
	int			nlambda_params;
} CallLambdaExprState;

//I/O, helper and walker functions to de-/serialize lambdas
extern SerializedLambda *lambdaExprToSerialLambda(LambdaExpr *expr);
extern LambdaExpr *lambda_deserialize(SerializedLambda *sl);

extern Datum lambda_in(PG_FUNCTION_ARGS);
extern Datum lambda_out(PG_FUNCTION_ARGS);

extern char *lambdaDecorateTargetName(Node *expr, char *colname);
extern char *lambdaUndecorateName(Node *expr, const char *colname);
extern void printLambdaInputsWithType(LambdaExpr *expr, StringInfo buf);

extern void elog_tupDesc(TupleDesc tupdesc, const char *label);
extern void elog_node(Node *node);
extern void elog_expr_steps(ExprState *state);
extern LambdaInputParam *get_input_param_from_index(LambdaExpr *lambda, int rowIndex, int colIndex);
extern LambdaInputParam *get_input_param_from_name(LambdaExpr *lambda, List *name);

extern LambdaExpr *lambda_injector(LambdaExpr *motherLambda, Datum *innerLambdas);

/*
 * Scalar-context(column-stored, plain-SQL) injector.
 *
 * Unlike lambda_injector(the UDF/row-context apply() path, driven by
 * mother->argtypes + Param/FieldSelect access), scalar lambdas have empty
 * argtypes and reference inputs as bare PARAM_EXEC nodes. This flattens a
 * higher-order mother into a first-order body by inlining the lambda values in
 * argvalues at the mother's function-input positions. argvalues/argnulls are the
 * flat call args(length nargs), function-input positions come from the LFA nodes
 * in the bodies, so no signature needed.
 */
extern LambdaExpr *lambda_injector_scalar(LambdaExpr *mother, Datum *argvalues,
										  bool *argnulls, int nargs);

/* True if a (scalar) lambda body calls any of its function-valued inputs. */
extern bool lambda_body_has_lfa(LambdaExpr *lambda);

/*
 * Partial-application builder. Given a (scalar-context) mother lambda and the set
 * of held arg positions, produce the residual lambda: supplied args are baked
 * into a copy of the body(atomic inputs -> Consts, filled function inputs are
 * inlined) and held inputs get reindexed to a dense 0..k-1 range, so the result
 * is a first-class lambda over just the held positions. vals/nulls are full-length
 * (mother-position indexed), held slots ignored. nargs == mother arity.
 */
extern LambdaExpr *lambda_partial_apply(LambdaExpr *mother, Bitmapset *heldargs,
										Datum *vals, bool *nulls, int nargs);

/*
 * Fill out[](caller-provided, size >= nargs) with the 0-based indices of the
 * mother's function-valued inputs. Catches both inputs called directly and inputs
 * only threaded into other function inputs. Returns the count.
 */
extern int lambda_scalar_func_inputs(LambdaExpr *mother, Datum *argvalues,
									 bool *argnulls, int nargs, int *out);

//Internal, lambda-specific debugging var, setable from SQL
extern bool custom_lambda_debugging_var;
extern void _InitLambdaGUCs(void);
extern bool custom_lambda_debugging_enabled(void);

//Enables hoisting + injection-based execution of higher-order lambda calls
extern bool custom_lambda_hoisting_var;
extern bool custom_lambda_hoisting_enabled(void);

/*-------------------Timer--------------------*/
/*
 * Timing helper, with QoL helper functions
 */
typedef struct Lambda_Timer {
	instr_time start;
	instr_time last;
} Lambda_Timer;

/* starts the timer */
static inline Lambda_Timer lt_start(void) 
{
	Lambda_Timer t;
	INSTR_TIME_SET_CURRENT(t.start);
	INSTR_TIME_SET_CURRENT(t.last);
	return t;
}

/* internal: format a message into a fixed buffer */
static inline const char *lt_vformat(char *buf, size_t bufsz, const char *fmt, va_list ap) pg_attribute_printf(3, 0);
static inline const char *lt_vformat(char *buf, size_t bufsz, const char *fmt, va_list ap)
{
    if (!fmt || !*fmt) { buf[0] = '\0'; return buf; }
    vsnprintf(buf, bufsz, fmt, ap);   /* truncation is fine for debug timing */
    buf[bufsz - 1] = '\0';
    return buf;
}

/* prints "TIMER: <msg> +X.XXX ms (total Y.YYY ms)" and advances last */
static inline Lambda_Timer lt_tick(Lambda_Timer t, const char *fmt, ...) pg_attribute_printf(2, 3);
static inline Lambda_Timer lt_tick(Lambda_Timer t, const char *fmt, ...)
{
    instr_time now, dlast, dtotal;
    char msg[512];
    va_list ap;
    INSTR_TIME_SET_CURRENT(now);

    dlast  = now;  INSTR_TIME_SUBTRACT(dlast,  t.last);
    dtotal = now;  INSTR_TIME_SUBTRACT(dtotal, t.start);

    va_start(ap, fmt);
    lt_vformat(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    elog(INFO, "TIMER: %s  +%.3f ms (total %.3f ms)",
         msg,
         INSTR_TIME_GET_MILLISEC(dlast),
         INSTR_TIME_GET_MILLISEC(dtotal));

    t.last = now;
    return t;
}

/* prints final time, from start until now in ms */
static inline Lambda_Timer lt_total(Lambda_Timer t, const char *fmt, ...) pg_attribute_printf(2, 3);
static inline Lambda_Timer lt_total(Lambda_Timer t, const char *fmt, ...)
{
    instr_time dtotal;
    char msg[512];
    va_list ap;

    INSTR_TIME_SET_CURRENT(dtotal);
	INSTR_TIME_SUBTRACT(dtotal, t.start);

    va_start(ap, fmt);
    lt_vformat(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    elog(INFO, "FINAL-TIME: %s -> total %.3f ms",
         msg,
         INSTR_TIME_GET_MILLISEC(dtotal));

    return t;
}

#endif /* __LAMBDA_H__ */