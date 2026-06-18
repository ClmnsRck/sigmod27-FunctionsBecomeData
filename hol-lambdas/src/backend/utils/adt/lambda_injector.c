/*-------------------------------------------------------------------------
 *
 * lambda_injector.c
 *	  Misc user-visible lambda helpers, ast-injector, etc.
 *    Assume all Lambda functions in query execution to be in serialized
 *    form, except for those directly passed to a UDF as an argument.
 *    Lambda functions in scalar form have their own execution path
 *    because differences in structure warant enough changes.
 *
 * Copyright (c) 2003-2024, PostgreSQL Global Development Group
 *                    2025, XXXX XXXX
 *
 * IDENTIFICATION
 *	  src/backend/utils/adt/lambda.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "fmgr.h"

#include <ctype.h>
#include <float.h>
#include <math.h>
#include <limits.h>

#include "catalog/pg_type.h"
#include "common/int.h"
#include "common/shortest_dec.h"
#include "libpq/pqformat.h"
#include "utils/array.h"
#include "utils/float.h"
#include "miscadmin.h"
#include "utils/memutils.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/regproc.h"
#include "catalog/namespace.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/primnodes.h"
#include "nodes/plannodes.h"
#include "nodes/nodeFuncs.h"
#include "nodes/makefuncs.h"
#include "nodes/bitmapset.h"
#include "nodes/pg_list.h"
#include "parser/parse_expr.h"
#include "parser/parser.h"
#include "parser/parse_func.h"
#include "executor/executor.h"
#include "executor/execExpr.h"
#include "utils/lambda.h"

static int find_arg_from_rowAlias_colId(LambdaExpr *lambda, int rowIdx, int colIdx);
static Node * mother_mutator_callback(Node *node, void *context);
static Node * adjust_input_nodes_walker_callback(Node *node, void *context);
static Node * scalar_inject_walk(Node *node, void *context);
static Node * inject_scalar_child_from_row_context(LambdaExpr *child,
												   List *callArgs, List *motherArgs);

static int depth_counter = 0;

/* ------------------------------------------------------------------------- */
/* Lambda Executor injector structs                                          */
/* ------------------------------------------------------------------------- */

//Holds information necessary for the mutation of the OG-Mother-Lambda(Lambda of Highest-Order)
typedef struct LambdaInjectionContext
{
    LambdaExpr      *mother_lambda;
    List            *args; //List of List of Node*
} LambdaInjectionContext;

typedef struct LambdaAdjustWalkerContext
{
	LambdaExpr *current_lambda;
	List 			*args;
} LambdaAdjustWalkerContext;

/* ------------------------------------------------------------------------- */
/* Lambda Executor injector helpers                                          */
/* ------------------------------------------------------------------------- */

static int
find_arg_from_rowAlias_colId(LambdaExpr *lambda, int rowIdx, int colIdx)
{
	ListCell *lc_outer_types;
	int idx1 = 0, tmp_res = 0;
	foreach(lc_outer_types, lambda->argtypes)
	{
		if(rowIdx == idx1) //we have found the correct row
		{
			if(unlikely(colIdx >= list_length((List *) lfirst(lc_outer_types)) || colIdx < 0))
				elog(ERROR, "%sattempting to access column out of range: %d in injection!", FUNCNAME_DBG, colIdx);
			return tmp_res + colIdx;
		} else {
			tmp_res += list_length((List *) lfirst(lc_outer_types));
		}
		idx1++;
	}
	elog(ERROR, "%sattempting to access row out of range: %d in injection!", FUNCNAME_DBG, rowIdx);
	return -1;
}

/*
 * Walks a lambdaExpr-body and adjusts all LFAs to fit the current context and injects PE+FS combos.
 * (Current context most likely is the the top most lambda, where PE+FS combos dont match the args, etc)
 * 
 * ParamExtern+FieldSelect combos are a copy of the correct arg of the old LFA node, because they might have had
 * another expression tree as input. LFA inputs however can always only be LFA nodes, so we can just
 * change the param_id and fieldSelect_id fields in the node and return the node as if unchanged.
 */
static Node *
adjust_input_nodes_walker_callback(Node *node, void *context)
{
	LambdaAdjustWalkerContext *ctx = (LambdaAdjustWalkerContext *) context;

	if(node == NULL || context == NULL)
		return NULL;

	if(IsA(node, LambdaFuncAliasExpr))
	{
		// If a LFA was found, change the necessary fileds, and then give it the correct args
		// (from the args, that the inner/old LFA had)
		LambdaFuncAliasExpr *cur = (LambdaFuncAliasExpr *) node;
		LambdaFuncAliasExpr *correct_lfa = NULL;

		int idx_of_correct_lfa = find_arg_from_rowAlias_colId(ctx->current_lambda, 
								cur->param_id - 1, 
								cur->fieldSelect_id - 1);

		correct_lfa = copyObject((LambdaFuncAliasExpr *) list_nth(ctx->args, idx_of_correct_lfa));
		correct_lfa->args = cur->args;
		return expression_tree_mutator((Node *) correct_lfa, adjust_input_nodes_walker_callback, context);
	} else if(IsA(node, FieldSelect))
	{
		// If a PE+FS combo was found, simply copy the actual args it refers to, and stop recursing into them
		FieldSelect *cur_fs = (FieldSelect *) node;
		Param * cur_param = (Param *) cur_fs->arg;
		Node *correct_arg = 
			(Node *) list_nth(ctx->args, find_arg_from_rowAlias_colId(ctx->current_lambda, cur_param->paramid - 1, (int)cur_fs->fieldnum - 1));
		if(unlikely(IsA(correct_arg, LambdaFuncAliasExpr)))
			elog(ERROR, "Lambda tried to access passed lambda-arg as fieldSelect input!");
		return copyObject(correct_arg);
	} 

	return expression_tree_mutator(node, adjust_input_nodes_walker_callback, context);
}

/*
 * Walks mother lambdas, until a FuncCall(LambdaFuncAlias) is found,
 * here, the function "builds" the injected lambda, if necessary, and injects it, and its args
 * correspondingly
 */
static Node * 
mother_mutator_callback(Node *node, void *context)
{
	LambdaInjectionContext *ctx = (LambdaInjectionContext *) context;

    if (node == NULL || context == NULL)
		return NULL;

	if (IsA(node, LambdaFuncAliasExpr))
	{
		LambdaFuncAliasExpr *lfa = (LambdaFuncAliasExpr *) node;
		List *tuple;
		LambdaExpr *targetLambda;
		LambdaAdjustWalkerContext *inner_ctx;
		LambdaExpr *injectedCopy;

		if (unlikely(lfa->param_id <= 0 || lfa->param_id > list_length(ctx->args)))
			elog(ERROR, "%sLFA param_id %d out of bounds", FUNCNAME_DBG, lfa->param_id);

		tuple = (List *) list_nth(ctx->args, lfa->param_id - 1);

		if (unlikely(lfa->fieldSelect_id <= 0 || lfa->fieldSelect_id > list_length(tuple)))
			elog(ERROR, "%sLFA fieldSelect_id %d out of bounds", FUNCNAME_DBG, lfa->fieldSelect_id);

		targetLambda = (LambdaExpr *) list_nth(tuple, lfa->fieldSelect_id - 1);

		if (unlikely(!targetLambda || !IsA(targetLambda, LambdaExpr)))
		{
			elog(ERROR, "%sNo valid lambda found for LFA %s",
					 FUNCNAME_DBG, NameListToString(lfa->name));
			return node;
		}

		/*
		 * A column-stored child (LAMBDA_SCALAR_CONTEXT) has no argtypes row
		 * structure, so the row-context walker can't address it - inline it
		 * with the scalar machinery instead.
		 */
		if (targetLambda->lambdakind == LAMBDA_SCALAR_CONTEXT)
			return inject_scalar_child_from_row_context(targetLambda,
														lfa->args, ctx->args);

		inner_ctx = palloc0(sizeof(LambdaAdjustWalkerContext));
		/* Injected copy, recurse into its body twice */
		injectedCopy = copyObject(targetLambda);
		inner_ctx->current_lambda = injectedCopy;
		inner_ctx->args = lfa->args;

		/* first to do a simple adjustment of the input-accesses */
		injectedCopy->expr = (Expr *) expression_tree_mutator((Node *) injectedCopy->expr, adjust_input_nodes_walker_callback, inner_ctx);
		/* then, simply keep walking to find other LFAs */
		injectedCopy->expr = (Expr *) expression_tree_mutator((Node *) injectedCopy->expr, mother_mutator_callback, ctx);

		/* Replace the LFA node with the body of the injected lambda */
		return (Node *) injectedCopy->expr;
	}

	return expression_tree_mutator(node, mother_mutator_callback, context);
}

/* ------------------------------------------------------------------------- */
/* Lambda Executor injector                                                  */
/* ------------------------------------------------------------------------- */

/*
 * Inject a List of LambdaExprs into the current lambda: parameter "lambda"
 *
 * This function serves as the entry point for UDF's/table functions to inject
 * their inputs into a lambda function. The actual recursive injector is in a impl-
 * function, because passing generic Datum* is the correct way UDFs 
 * should pass their data and lambdas in.
 * 
 * @param lambda - The lambda, into which all lambdas found in innerLambdas are injected
 * @param innerLambdas - all data, that the UDF has access to during injection
 * 
 * Important note: All injected lambdas need to be present during injection pass, otherwise
 * an error will cause the query to halt and abort.
 */
LambdaExpr *lambda_injector(LambdaExpr *lambda, Datum *innerLambdas)
{
	MemoryContext old_context, tmp_context;
	LambdaInjectionContext *context;
	LambdaExpr *result, *tmp_lambda;
	List *args = NIL;
	ListCell *lc, *lc_inner;
	int tupleIdx = 0, colIdx = 0;

	depth_counter = 0;

	if (unlikely(!lambda || !IsA(lambda, LambdaExpr)))
		elog(ERROR, "%sexpected a LambdaExpr in injector", FUNCNAME_DBG);

	/* Set up temporary memory context for one-time injection */
	tmp_context = AllocSetContextCreate(CurrentMemoryContext,
									"LambdaInjectionTempContext",
									ALLOCSET_SMALL_SIZES);
	old_context = MemoryContextSwitchTo(tmp_context);

	tmp_lambda = copyObject(lambda);
	
	foreach(lc, lambda->argtypes)
	{
		List *inner_list = lfirst(lc);
		List *inner_result = NIL;
		if(unlikely(!IsA(inner_list, List)))
			elog(ERROR, "%sNon-List node found in lambdaExpr argtypes during injection", FUNCNAME_DBG);
		
		colIdx = 0;
		foreach(lc_inner, inner_list)
		{
			LambdaInputParam *input = lfirst_node(LambdaInputParam, lc_inner);
			if(input->isAtomic)
			{
				inner_result = lappend(inner_result, NULL);
			} else {
				Datum inner_datum = innerLambdas[tupleIdx];
				Datum *data_array = (Datum *) DatumGetPointer(inner_datum);
				LambdaExpr *inner_lambda = lambda_deserialize((SerializedLambda *) PG_DETOAST_DATUM(data_array[colIdx]));

				if(inner_lambda->lambdakind != LAMBDA_SCALAR_CONTEXT)
					elog(ERROR, "%sNon-column-stored Lambda function passed to injector!", FUNCNAME_DBG);
				
				inner_result = lappend(inner_result, 
					copyObject(inner_lambda));
			}
			colIdx++;
		}
		args = lappend(args, inner_result);
		tupleIdx++;
	}

	context = palloc0(sizeof(LambdaInjectionContext));
	context->mother_lambda = tmp_lambda;
	context->args = args;
	tmp_lambda = (LambdaExpr *) expression_tree_mutator((Node *) tmp_lambda, mother_mutator_callback, context);

	/* Switch back and copy result to caller's context */
	MemoryContextSwitchTo(old_context);
	result = copyObject(tmp_lambda);
	result->argTypesTupDesc = lambda->argTypesTupDesc;

	MemoryContextDelete(tmp_context);

	return result;
}

/* ------------------------------------------------------------------------- */
/* Scalar-context lambda injector                                            */
/* ------------------------------------------------------------------------- */

/*
 * Column-stored(LAMBDA_SCALAR_CONTEXT) lambdas work differently from the UDF/row
 * context that lambda_injector() above serves:
 *   - their argtypes list is empty (grammar leaves it NIL),
 *   - inputs are bare PARAM_EXEC Params (not Param+FieldSelect), paramid == the
 *     flat input index, and
 *   - LFA call sites carry fieldSelect_id == input index of the called function(0-based).
 * So the helpers below do their own addressing and never touch the row-context
 * functions above, the UDF path stays the same. Function-input positions come
 * straight from the LFA nodes in each body, no signature/argtypes reconstruction.
 */

/*
 * One pass over a scalar body. Per input position records:
 *   isFunc[i] -- input i is function-valued: referenced as a LAMBDAOID Param or
 *                called via an LFA. No fixpoint needed - a threaded-only function
 *                input still shows up as a bare Param, so one pass catches it.
 *   proto[i]  -- a representative Param node for input i, for type info when
 *                building Const/residual Params (may be NULL if the caller doesnt
 *                need it; stays NULL for inputs that only appear as a call site).
 * Embedded LambdaExpr values are opaque(their bodies live in another input index
 * space), so we never descend into them.
 */
typedef struct ScalarPrescan
{
	bool   *isFunc;
	Param **proto;
	int		nargs;
} ScalarPrescan;

static bool
scalar_prescan_walker(Node *node, void *context)
{
	ScalarPrescan *s = (ScalarPrescan *) context;

	if (node == NULL)
		return false;

	if (IsA(node, LambdaExpr))
		return false;			/* opaque value, separate index space */

	if (IsA(node, Param))
	{
		Param	   *p = (Param *) node;

		if (p->paramkind == PARAM_EXEC && p->lambda &&
			p->paramid >= 0 && p->paramid < s->nargs)
		{
			if (p->paramtype == LAMBDAOID)
				s->isFunc[p->paramid] = true;
			if (s->proto && s->proto[p->paramid] == NULL)
				s->proto[p->paramid] = p;
		}
		return false;
	}

	if (IsA(node, LambdaFuncAliasExpr))
	{
		int			k = ((LambdaFuncAliasExpr *) node)->fieldSelect_id;	/* 0-based */

		if (k >= 0 && k < s->nargs)
			s->isFunc[k] = true;
		/* recurse into the call's args below */
	}

	return expression_tree_walker(node, scalar_prescan_walker, context);
}

static void
scalar_prescan(LambdaExpr *mother, bool *isFunc, Param **proto, int nargs)
{
	ScalarPrescan s;

	s.isFunc = isFunc;
	s.proto = proto;
	s.nargs = nargs;

	if (mother != NULL && mother->expr != NULL && nargs > 0)
		scalar_prescan_walker((Node *) mother->expr, &s);
}

/* stop on first LFA, for lambda_body_has_lfa() */
static bool
has_lfa_walker(Node *node, void *context)
{
	if (node == NULL)
		return false;
	if (IsA(node, LambdaFuncAliasExpr))
	{
		*((bool *) context) = true;
		return true;			/* short-circuit the walk */
	}
	return expression_tree_walker(node, has_lfa_walker, context);
}

bool
lambda_body_has_lfa(LambdaExpr *lambda)
{
	bool		found = false;

	if (lambda == NULL || lambda->expr == NULL)
		return false;

	has_lfa_walker((Node *) lambda->expr, &found);
	return found;
}

int
lambda_scalar_func_inputs(LambdaExpr *mother, Datum *argvalues, bool *argnulls,
						  int nargs, int *out)
{
	bool	   *isFunc;
	int			n = 0;

	if (mother == NULL || mother->expr == NULL || nargs <= 0)
		return 0;

	isFunc = palloc0(sizeof(bool) * nargs);
	scalar_prescan(mother, isFunc, NULL, nargs);

	for (int i = 0; i < nargs; i++)
		if (isFunc[i])
			out[n++] = i;

	return n;
}

/*
 * Per-scope binding for the scalar inliner. binding[m] is what input m resolves
 * to in the current lambda scope:
 *   Const (or any scalar expr) -- atomic input bound to a value.
 *   LambdaExpr                 -- function input bound to a lambda value: a bare
 *                                 reference embeds it, a call inlines its body.
 *   Param (PARAM_EXEC)         -- an OPEN input that survives into the output(a
 *                                 mother atomic left for per-row binding, or a
 *                                 held residual slot). A bare reference becomes
 *                                 that Param, a call keeps the LFA and retargets
 *                                 it to the Param's paramid.
 *   NULL                       -- leave a bare reference untouched (identity).
 *
 * slotnames[paramid] = the residual slot's LFA name; a retargeted call takes it so
 * it stops deparsing under an inlined child's old name. NULL outside partial apply.
 */
typedef struct ScalarBind
{
	Node  **binding;
	int		nargs;
	List  **slotnames;
	int		nslots;
} ScalarBind;

/*
 * Inline scalar lambda calls. An LFA whose callee input is bound to a lambda
 * value gets replaced by that lambda's body, with the call's args resolved in the
 * current scope and bound as the callee's inputs. Embedded LambdaExpr values are
 * opaque, pass through untouched.
 */
static Node *
scalar_inject_walk(Node *node, void *context)
{
	ScalarBind *ctx = (ScalarBind *) context;

	if (node == NULL)
		return NULL;

	if (IsA(node, LambdaExpr))
		return node;			/* opaque lambda value */

	if (IsA(node, Param))
	{
		Param	   *p = (Param *) node;

		if (p->paramkind == PARAM_EXEC && p->lambda &&
			p->paramid >= 0 && p->paramid < ctx->nargs &&
			ctx->binding[p->paramid] != NULL)
			return (Node *) copyObject(ctx->binding[p->paramid]);

		return node;
	}

	if (IsA(node, LambdaFuncAliasExpr))
	{
		LambdaFuncAliasExpr *lfa = (LambdaFuncAliasExpr *) node;
		int			k = lfa->fieldSelect_id;	/* 0-based input index */
		Node	   *b;

		if (k < 0 || k >= ctx->nargs)
			elog(ERROR, "%sscalar injector: function input %d out of range",
				 FUNCNAME_DBG, k);

		b = ctx->binding[k];

		if (b != NULL && IsA(b, LambdaExpr))
		{
			/* callee is a concrete lambda: inline its body */
			LambdaExpr *child = (LambdaExpr *) b;
			int			child_nargs = list_length(child->argnames);
			Node	  **child_binding;
			ScalarBind	child_ctx;
			ListCell   *lc;
			int			m;

			if (list_length(lfa->args) != child_nargs)
				elog(ERROR, "%sscalar injector: call to input %d passes %d args, expected %d",
					 FUNCNAME_DBG, k, list_length(lfa->args), child_nargs);

			child_binding = palloc0(sizeof(Node *) * (child_nargs > 0 ? child_nargs : 1));

			m = 0;
			foreach(lc, lfa->args)
				child_binding[m++] =
					scalar_inject_walk((Node *) copyObject(lfirst(lc)), ctx);

			child_ctx.binding = child_binding;
			child_ctx.nargs = child_nargs;
			child_ctx.slotnames = ctx->slotnames;	/* slots are global to the residual */
			child_ctx.nslots = ctx->nslots;

			return scalar_inject_walk((Node *) copyObject(child->expr), &child_ctx);
		}

		if (b != NULL && IsA(b, Param))
		{
			/* callee is an open/held input: keep the call, retarget + rewrite args */
			LambdaFuncAliasExpr *nlfa = copyObject(lfa);
			ListCell   *lc;
			List	   *newargs = NIL;

			nlfa->fieldSelect_id = ((Param *) b)->paramid;
			/* take the residual slot's name so we don't keep a stale child name */
			if (ctx->slotnames != NULL &&
				nlfa->fieldSelect_id >= 0 && nlfa->fieldSelect_id < ctx->nslots &&
				ctx->slotnames[nlfa->fieldSelect_id] != NULL)
				nlfa->name = copyObject(ctx->slotnames[nlfa->fieldSelect_id]);
			foreach(lc, lfa->args)
				newargs = lappend(newargs,
								  scalar_inject_walk((Node *) copyObject(lfirst(lc)), ctx));
			nlfa->args = newargs;
			return (Node *) nlfa;
		}

		elog(ERROR, "%sscalar injector: input %d is not a function", FUNCNAME_DBG, k);
	}

	return expression_tree_mutator(node, scalar_inject_walk, context);
}

/*
 * Inline a column-stored (scalar) child called from a row-context mother, e.g.
 * b.g(a.x, a.y, a.z, b.f) where g is a stored higher-order lambda. Each call
 * arg is resolved in the mother's context and bound as the child's flat input:
 * a function value (argless LambdaFuncAliasExpr) -> the concrete lambda the
 * mother deserialized for it; anything else (a.col, Const, ...) -> bound as-is.
 * motherArgs is the row injector's args (List of List, per row/per column).
 */
static Node *
inject_scalar_child_from_row_context(LambdaExpr *child, List *callArgs,
									 List *motherArgs)
{
	int			child_nargs = list_length(child->argnames);
	ScalarBind	ctx;
	ListCell   *lc;
	int			m = 0;

	if (list_length(callArgs) != child_nargs)
		elog(ERROR, "%sscalar child called with %d args, expected %d",
			 FUNCNAME_DBG, list_length(callArgs), child_nargs);

	ctx.binding = palloc0(sizeof(Node *) * (child_nargs > 0 ? child_nargs : 1));
	ctx.nargs = child_nargs;
	ctx.slotnames = NULL;
	ctx.nslots = 0;

	foreach(lc, callArgs)
	{
		Node *arg = (Node *) lfirst(lc);

		if (IsA(arg, LambdaFuncAliasExpr) &&
			((LambdaFuncAliasExpr *) arg)->args == NIL)
		{
			/* function value passed by name: resolve to the concrete lambda */
			LambdaFuncAliasExpr *fa = (LambdaFuncAliasExpr *) arg;
			List	   *tuple;
			Node	   *concrete;

			if (fa->param_id <= 0 || fa->param_id > list_length(motherArgs))
				elog(ERROR, "%sscalar child arg param_id %d out of bounds",
					 FUNCNAME_DBG, fa->param_id);

			tuple = (List *) list_nth(motherArgs, fa->param_id - 1);

			if (fa->fieldSelect_id <= 0 || fa->fieldSelect_id > list_length(tuple))
				elog(ERROR, "%sscalar child arg fieldSelect_id %d out of bounds",
					 FUNCNAME_DBG, fa->fieldSelect_id);

			concrete = (Node *) list_nth(tuple, fa->fieldSelect_id - 1);
			ctx.binding[m++] = concrete ? (Node *) copyObject(concrete) : NULL;
		}
		else
		{
			ctx.binding[m++] = (Node *) copyObject(arg);
		}
	}

	return scalar_inject_walk((Node *) copyObject(child->expr), &ctx);
}

LambdaExpr *
lambda_injector_scalar(LambdaExpr *mother, Datum *argvalues, bool *argnulls, int nargs)
{
	MemoryContext old_context, tmp_context;
	ScalarBind	ctx;
	LambdaExpr *result;
	bool	   *isFunc;
	int			i;

	if (unlikely(!mother || !IsA(mother, LambdaExpr)))
		elog(ERROR, "%sexpected a LambdaExpr in scalar injector", FUNCNAME_DBG);

	tmp_context = AllocSetContextCreate(CurrentMemoryContext,
										"LambdaScalarInjectionTempContext",
										ALLOCSET_SMALL_SIZES);
	old_context = MemoryContextSwitchTo(tmp_context);

	/*
	 * Bind every function input to its supplied lambda value, leave atomic inputs
	 * unbound(NULL) so they survive as per-row PARAM_EXEC params.
	 */
	isFunc = palloc0(sizeof(bool) * (nargs > 0 ? nargs : 1));
	scalar_prescan(mother, isFunc, NULL, nargs);

	ctx.binding = palloc0(sizeof(Node *) * (nargs > 0 ? nargs : 1));
	ctx.nargs = nargs;
	ctx.slotnames = NULL;		/* no residual: nothing gets retargeted */
	ctx.nslots = 0;

	for (i = 0; i < nargs; i++)
	{
		if (!isFunc[i])
			continue;			/* atomic: NULL binding -> stays a runtime param */
		if (argnulls[i])
			elog(ERROR, "%sscalar injector: function input %d is NULL", FUNCNAME_DBG, i);
		ctx.binding[i] = (Node *) copyObject(lambda_deserialize(
				(SerializedLambda *) PG_DETOAST_DATUM(argvalues[i])));
	}

	result = copyObject(mother);
	result->expr = (Expr *) scalar_inject_walk((Node *) copyObject(mother->expr), &ctx);

	/* hand the flattened lambda back to the caller's context */
	MemoryContextSwitchTo(old_context);
	result = copyObject(result);
	result->argTypesTupDesc = mother->argTypesTupDesc;

	MemoryContextDelete(tmp_context);

	return result;
}

/* ------------------------------------------------------------------------- */
/* Partial application (the "_" hole path)                                   */
/* ------------------------------------------------------------------------- */

/*
 * Partially apply a scalar mother lambda. Held positions(heldargs) stay open and
 * get renumbered to a dense 0..k-1 residual space, filled positions are baked
 * into a copy of the body:
 *   filled atomic input   -> Const carrying the supplied value
 *   filled function input -> its deserialized LambdaExpr (inlined where called,
 *                            embedded as opaque value where merely threaded)
 *   held input            -> a Param/LFA reference retargeted to its residual
 *                            slot, so a later full application binds it like any
 *                            other supplied arg.
 * vals/nulls are full-length(mother-position indexed), held slots are ignored.
 * The rewriting itself is the shared scalar inliner, here we only build its
 * per-input binding.
 */
LambdaExpr *
lambda_partial_apply(LambdaExpr *mother, Bitmapset *heldargs,
					 Datum *vals, bool *nulls, int nargs)
{
	MemoryContext old_context, tmp_context;
	ScalarBind	ctx;
	LambdaExpr *result;
	bool	   *isFunc;
	Param	  **proto;
	int		   *newidx;
	List	   *new_argnames = NIL;
	int			hidx;
	int			p;

	if (mother == NULL || mother->expr == NULL)
		elog(ERROR, "%spartial apply: empty mother lambda", FUNCNAME_DBG);

	tmp_context = AllocSetContextCreate(CurrentMemoryContext,
										"LambdaPartialApplyTempContext",
										ALLOCSET_SMALL_SIZES);
	old_context = MemoryContextSwitchTo(tmp_context);

	isFunc = palloc0(sizeof(bool) * (nargs > 0 ? nargs : 1));
	proto = palloc0(sizeof(Param *) * (nargs > 0 ? nargs : 1));
	scalar_prescan(mother, isFunc, proto, nargs);

	newidx = palloc0(sizeof(int) * (nargs > 0 ? nargs : 1));
	ctx.binding = palloc0(sizeof(Node *) * (nargs > 0 ? nargs : 1));
	ctx.nargs = nargs;
	ctx.slotnames = palloc0(sizeof(List *) * (nargs > 0 ? nargs : 1));
	ctx.nslots = nargs;

	/* assign dense residual indices to held positions, in mother order */
	hidx = 0;
	for (p = 0; p < nargs; p++)
		if (bms_is_member(p, heldargs))
			newidx[p] = hidx++;

	for (p = 0; p < nargs; p++)
	{
		if (bms_is_member(p, heldargs))
		{
			/* held: a reference retargeted to the dense residual slot */
			Param	   *rp;

			if (proto[p] != NULL)
				rp = copyObject(proto[p]);
			else
			{
				/* a function input that is only ever called: synthesize a ref */
				rp = makeNode(Param);
				rp->paramkind = PARAM_EXEC;
				rp->lambda = true;
				rp->paramtype = LAMBDAOID;
				rp->paramtypmod = -1;
				rp->paramcollid = InvalidOid;
			}
			rp->paramid = newidx[p];
			ctx.binding[p] = (Node *) rp;

			new_argnames = lappend(new_argnames,
								   copyObject(list_nth(mother->argnames, p)));
			/* slot's LFA name, so retargeted calls deparse under the held name */
			ctx.slotnames[newidx[p]] =
				list_make1(copyObject(list_nth(mother->argnames, p)));
		}
		else if (isFunc[p])
		{
			/* filled function input: its concrete lambda value */
			if (nulls[p])
				elog(ERROR, "%spartial apply: filled function input %d is NULL",
					 FUNCNAME_DBG, p);
			ctx.binding[p] = (Node *) copyObject(lambda_deserialize(
					(SerializedLambda *) PG_DETOAST_DATUM(vals[p])));
		}
		else if (proto[p] != NULL)
		{
			/* filled atomic input: a Const baking the supplied value */
			Param	   *pp = proto[p];
			int16		typlen;
			bool		typbyval;

			get_typlenbyval(pp->paramtype, &typlen, &typbyval);
			ctx.binding[p] = (Node *) makeConst(pp->paramtype, pp->paramtypmod,
												pp->paramcollid, (int) typlen,
												nulls[p] ? (Datum) 0 : vals[p],
												nulls[p], typbyval);
		}
		/* else: input never referenced in the body -> no binding needed */
	}

	result = makeNode(LambdaExpr);
	result->lambdakind = LAMBDA_SCALAR_CONTEXT;
	result->expr = (Expr *) scalar_inject_walk((Node *) copyObject(mother->expr), &ctx);
	result->rettype = mother->rettype;
	result->rettypmod = mother->rettypmod;
	result->lambdatypmod = -1;	/* residual signature is interned at parse time */
	result->is_strict = mother->is_strict;
	result->argnames = new_argnames;
	result->argtypes = NIL;		/* scalar lambdas carry no inline argtypes */

	/* hand the residual back to the caller's context */
	MemoryContextSwitchTo(old_context);
	result = copyObject(result);

	MemoryContextDelete(tmp_context);

	return result;
}
