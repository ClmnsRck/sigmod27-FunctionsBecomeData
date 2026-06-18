/*-------------------------------------------------------------------------
 *
 * llvmjit_types.c
 *	  List of types needed by JIT emitting code.
 *
 * JIT emitting code often needs to access struct elements, create functions
 * with the correct signature etc. To allow synchronizing these types with a
 * low chance of definitions getting out of sync, this file lists types and
 * functions that directly need to be accessed from LLVM.
 *
 * When LLVM is first used in a backend, a bitcode version of this file will
 * be loaded. The needed types and signatures will be stored into Struct*,
 * Type*, Func* variables.
 *
 * NB: This file will not be linked into the server, it's just converted to
 * bitcode.
 *
 *
 * Copyright (c) 2016-2024, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/backend/jit/llvm/llvmjit_types.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/htup.h"
#include "access/htup_details.h"
#include "access/tupdesc.h"
#include "catalog/pg_attribute.h"
#include "executor/execExpr.h"
#include "executor/nodeAgg.h"
#include "executor/tuptable.h"
#include "fmgr.h"
#include "nodes/execnodes.h"
#include "nodes/memnodes.h"
#include "utils/expandeddatum.h"
#include "utils/palloc.h"
#include "utils/array.h"
#include "math.h"

/*
 * List of types needed for JITing. These have to be non-static, otherwise
 * clang/LLVM will omit them.  As this file will never be linked into
 * anything, that's harmless.
 */
PGFunction	TypePGFunction;
size_t		TypeSizeT;
Datum 		TypeDatum;
bool		TypeStorageBool;

ExecEvalSubroutine TypeExecEvalSubroutine;
ExecEvalBoolSubroutine TypeExecEvalBoolSubroutine;

NullableDatum StructNullableDatum;
AggState	StructAggState;
AggStatePerGroupData StructAggStatePerGroupData;
AggStatePerTransData StructAggStatePerTransData;
ArrayType StructArrayType;
ExprContext StructExprContext;
ExprEvalStep StructExprEvalStep;
ExprState	StructExprState;
FunctionCallInfoBaseData StructFunctionCallInfoData;
HeapTupleData StructHeapTupleData;
HeapTupleHeaderData StructHeapTupleHeaderData;
MemoryContextData StructMemoryContextData;
TupleTableSlot StructTupleTableSlot;
HeapTupleTableSlot StructHeapTupleTableSlot;
MinimalTupleTableSlot StructMinimalTupleTableSlot;
TupleDescData StructTupleDescData;
PlanState	StructPlanState;
MinimalTupleData StructMinimalTupleData;


/*
 * To determine which attributes functions need to have (depends e.g. on
 * compiler version and settings) to be compatible for inlining, we simply
 * copy the attributes of this function.
 */
extern Datum AttributeTemplate(PG_FUNCTION_ARGS);
Datum
AttributeTemplate(PG_FUNCTION_ARGS)
{
	AssertVariableIsOfType(&AttributeTemplate, PGFunction);

	PG_RETURN_NULL();
}

/*
 * And some more "templates" to give us examples of function types
 * corresponding to function pointer types.
 */

extern void ExecEvalSubroutineTemplate(ExprState *state,
									   struct ExprEvalStep *op,
									   ExprContext *econtext);
void
ExecEvalSubroutineTemplate(ExprState *state,
						   struct ExprEvalStep *op,
						   ExprContext *econtext)
{
	AssertVariableIsOfType(&ExecEvalSubroutineTemplate,
						   ExecEvalSubroutine);
}

extern bool ExecEvalBoolSubroutineTemplate(ExprState *state,
										   struct ExprEvalStep *op,
										   ExprContext *econtext);
bool
ExecEvalBoolSubroutineTemplate(ExprState *state,
							   struct ExprEvalStep *op,
							   ExprContext *econtext)
{
	AssertVariableIsOfType(&ExecEvalBoolSubroutineTemplate,
						   ExecEvalBoolSubroutine);

	return false;
}

/*
 * Clang represents stdbool.h style booleans that are returned by functions
 * differently (as i1) than stored ones (as i8). Therefore we do not just need
 * TypeBool (above), but also a way to determine the width of a returned
 * integer. This allows us to keep compatible with non-stdbool using
 * architectures.
 */
extern bool FunctionReturningBool(void);
bool
FunctionReturningBool(void)
{
	return false;
}

/* 
 * Functions not inplemented in math.h, that lambdas are allowed to use
 */
extern Datum dcot(PG_FUNCTION_ARGS);
extern Datum softmax_cce(PG_FUNCTION_ARGS);
extern Datum silu(PG_FUNCTION_ARGS);
extern Datum sigmoid(PG_FUNCTION_ARGS);
extern Datum dtanh(PG_FUNCTION_ARGS);
extern Datum relu(PG_FUNCTION_ARGS);


/*
 * To force signatures of functions used during JITing to be present,
 * reference the functions required. This again has to be non-static, to avoid
 * being removed as unnecessary.
 */
void	   *referenced_functions[] =
{
	ExecAggInitGroup,
	ExecAggCopyTransValue,
	ExecEvalPreOrderedDistinctSingle,
	ExecEvalPreOrderedDistinctMulti,
	ExecEvalAggOrderedTransDatum,
	ExecEvalAggOrderedTransTuple,
	ExecEvalArrayCoerce,
	ExecEvalArrayExpr,
	ExecEvalConstraintCheck,
	ExecEvalConstraintNotNull,
	ExecEvalConvertRowtype,
	ExecEvalCurrentOfExpr,
	ExecEvalFieldSelect,
	ExecEvalFastFieldSelect,
	ExecEvalFieldStoreDeForm,
	ExecEvalFieldStoreForm,
	ExecEvalFuncExprFusage,
	ExecEvalFuncExprStrictFusage,
	ExecEvalGroupingFunc,
	ExecEvalMergeSupportFunc,
	ExecEvalMinMax,
	ExecEvalNextValueExpr,
	ExecEvalParamExec,
	ExecEvalParamExtern,
	ExecEvalFastParamExtern,
	ExecEvalRow,
	ExecEvalRowNotNull,
	ExecEvalRowNull,
	ExecEvalCoerceViaIOSafe,
	ExecEvalSQLValueFunction,
	ExecEvalScalarArrayOp,
	ExecEvalHashedScalarArrayOp,
	ExecEvalSubPlan,
	ExecEvalSysVar,
	ExecEvalWholeRowVar,
	ExecEvalXmlExpr,
	ExecEvalJsonConstructor,
	ExecEvalJsonIsPredicate,
	ExecEvalJsonCoercion,
	ExecEvalJsonCoercionFinish,
	ExecEvalJsonExprPath,
	MakeExpandedObjectReadOnlyInternal,
	slot_getmissingattrs,
	slot_getsomeattrs_int,
	strlen,
	varsize_any,
	ExecInterpExprStillValid,
	//Lambda function execution - general
	ExecEvalCallLambdaExpr,
	//functions implemented for lambda expressions, that can be referenced from interpreted and jit-compiled execution
	acos,
	asin,
	atan,
	atan2,
	cos,
	exp,
	fabs,
	log,
	log10,
	pow,
	sin,
	sqrt,
	tan,
	tanh,
	fmax,
	//functions not implemented by math.h itself, imported from PostgreSQL operator/function catalog, some implemented by XXXX XXXX
	dcot,
	softmax_cce,
	silu,
	sigmoid,
	dtanh,
	relu,
	//functions not implemented in math.h, but used in matrix_math, implemented by XXXX XXXX
	matrix_mul,
	matrix_mul_internal,
	mat_transpose_external,
	matrix_transpose_internal,
	matrix_add_inplace,
	matrix_add,
	matrix_add_internal,
	matrix_elem_mult_external,
	matrix_elem_mult,
	mat_sub_mm,
	mat_sub_ms,
	mat_sub_sm,
	mat_mul_sm,
	mat_apply_gradient,
	softmax,
	softmax_cce,
	softmax_cce_internal,
	softmax_cce_derive,
	silu_m,
	silu_m_internal,
	silu_m_derive,
	sigmoid_m,
	sigmoid_m_internal,
	sigmoid_m_derive,
	tanh_m,
	tanh_m_internal,
	tanh_m_derive,
	relu_m,
	relu_m_internal,
	relu_m_derive,
	initResult,
	copyArray,
	createArray,
	createSeedArray,
	createScalar,
	isScalar,
	index_max,
	matrixPrint,
	matrixSetValue,
};
