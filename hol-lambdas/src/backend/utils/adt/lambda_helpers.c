/*-------------------------------------------------------------------------
 *
 * lambda.c
 *	  Misc user-visible lambda support, I/O support, etc.
 *    Assume all Lambda functions in query execution to be in serialized
 *    form, except for those directly passed to a UDF as an argument.
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
#include "utils/ruleutils.h"
#include "catalog/namespace.h"
#include "nodes/parsenodes.h"
#include "nodes/primnodes.h"
#include "nodes/plannodes.h"
#include "nodes/nodeFuncs.h"
#include "parser/parse_expr.h"
#include "parser/parser.h"
#include "parser/parse_type.h"
#include "executor/executor.h"
#include "executor/execExpr.h"
#include "utils/lambda.h"
#include "access/htup_details.h"
#include "catalog/pg_attribute.h"

/* ------------------------------------------------------------------------- */
/* L3 safety analysis                                                        */
/* ------------------------------------------------------------------------- */

/*
 * True if funcid is in LAMBDA_L3_FUNC_LIST(see utils/lambda.h), i.e. we
 * hand-wrote an L3 impl for it. List and impls are kept in sync by hand.
 */
bool
lambda_op_has_l3_impl(Oid funcid)
{
	switch (funcid)
	{
#define L3_CASE(oid, name) case oid:
		LAMBDA_L3_FUNC_LIST(L3_CASE)
#undef L3_CASE
			return true;
		default:
			return false;
	}
}

/*
 * expression_tree_walker callback. Returns true (aborts the walk) as soon as it
 * hits a node thats NOT L3-safe. L3-safe means: a Const, a PARAM_EXEC Param, an
 * op/func call into a whitelisted func with L3-safe args, or a nested lambda call
 * (LFA/CallLambda) with L3-safe arg expressions. For nested calls we dont look at
 * the callee body on purpose - its a runtime value(function-valued input, or a
 * column-stored lambda behind a Var), so we only know its safety once its bound.
 * The "callee is also L3-safe" part is AND-ed in at injection time, where every
 * lambda in a flattened combo must have l3_safe == true. Anything else (incl. tags
 * we dont handle yet) counts as unsafe -> fail safe.
 */
static bool
lambda_l3_unsafe_walker(Node *node, void *context)
{
	if (node == NULL)
		return false;

	switch (nodeTag(node))
	{
		case T_Const:
			/* literal, no children */
			return false;

		case T_Param:
			/*
			 * only executor params(lambda args / input bindings) are L3-safe.
			 * PARAM_EXTERN / PARAM_SUBLINK reach outside the body -> not L3.
			 */
			if (((Param *) node)->paramkind == PARAM_EXEC)
				return false;
			return true;

		case T_FuncExpr:
			if (!lambda_op_has_l3_impl(((FuncExpr *) node)->funcid))
				return true;	/* no L3 impl -> abort */
			break;				/* else recurse into args */

		case T_OpExpr:
		case T_DistinctExpr:	/* shares the OpExpr layout */
		case T_NullIfExpr:		/* shares the OpExpr layout */
			if (!lambda_op_has_l3_impl(((OpExpr *) node)->opfuncid))
				return true;
			break;

		case T_LambdaFuncAliasExpr:
			/*
			 * call to a function-valued lambda input. callee body is a runtime
			 * binding, not reachable here, so we only check the call args(callee
			 * l3_safe is AND-ed in at injection time). Walk the args directly.
			 */
			return expression_tree_walker(
				(Node *) ((LambdaFuncAliasExpr *) node)->args,
				lambda_l3_unsafe_walker, context);

		case T_CallLambdaExpr:
			/*
			 * direct call of a column-stored lambda. lambda_expr is a Var of type
			 * lambda(target only known at runtime), so same as LFA: dont descend
			 * into it(the generic walker would hit the Var and fail safe). Only
			 * the call args, callee l3_safe is enforced at injection time.
			 */
			return expression_tree_walker(
				(Node *) ((CallLambdaExpr *) node)->args,
				lambda_l3_unsafe_walker, context);

		default:
			/* unhandled tag -> fail safe */
			return true;
	}

	return expression_tree_walker(node, lambda_l3_unsafe_walker, context);
}

/*
 * Entry point: true iff the whole lambda body is L3-safe. Run once during parse
 * analysis, result is cached in LambdaExpr.l3_safe.
 */
bool
lambda_expr_is_l3_safe(LambdaExpr *lambda)
{
	if (lambda == NULL || lambda->expr == NULL)
		return false;

	/* walker returns true the moment it sees a non-L3 node */
	return !lambda_l3_unsafe_walker((Node *) lambda->expr, NULL);
}


/* ------------------------------------------------------------------------- */
/* Misc Internal Helpers                                                     */
/* ------------------------------------------------------------------------- */

/*
 * Debug printer for TupleDesc's
 */
void
elog_tupDesc(TupleDesc tupdesc, const char *label)
{
    char *rowtypename;

    if (!tupdesc)
    {
        elog(INFO, "TupleDesc%s: (null)",
             (label && *label) ? psprintf(" [%s]", label) : "");
        return;
    }

    rowtypename = format_type_with_typemod(tupdesc->tdtypeid, tupdesc->tdtypmod);
    elog(INFO, "TupleDesc%s: natts=%d, rowtype=%u (%s)",
         (label && *label) ? psprintf(" [%s]", label) : "",
         tupdesc->natts, tupdesc->tdtypeid,
         rowtypename ? rowtypename : "?");
    if (rowtypename) pfree(rowtypename);

    for (int i = 0; i < tupdesc->natts; i++)
    {
        Form_pg_attribute a = TupleDescAttr(tupdesc, i);
        char *typname = format_type_with_typemod(a->atttypid, a->atttypmod);

        elog(INFO, "  %2d | %s%s :: %s | notnull=%s | def=%s | id=%c | gen=%c",
             i + 1,
             NameStr(a->attname),
             a->attisdropped ? " [DROPPED]" : "",
             typname ? typname : "?",
             a->attnotnull ? "true" : "false",
             a->atthasdef ? "true" : "false",
             a->attidentity ? a->attidentity : '-',     /* 'a','d' or '-' */
             a->attgenerated ? a->attgenerated : '-');  /* 's','v' or '-' */

        if (typname) pfree(typname);
    }
}


/*
 * Debug printer for any node tree(pre- and post-transform)
 */
void elog_node(Node *node)
{
	char *tmp;
	StringInfoData intermediateRes;
	int currIndent = -1;
	int strLen = -1;

    if (node == NULL) {
		elog(INFO, "Node: NULL");
		return;
	}
	if(IsA(node, LambdaExpr))
		elog(INFO, "Deparsed Lambda: %s", deparse_expression(node, NIL, false, false));

	tmp = nodeToString(node);
	strLen = strlen(tmp);
	initStringInfo(&intermediateRes);

	for(int i = 0; i < strLen; i++)
	{
		bool newline = false;
		switch (tmp[i])
		{
		case '{':
			currIndent++;
			appendStringInfoChar(&intermediateRes, '\n');
			newline = true;
			break;
		
		case ':':
			appendStringInfoChar(&intermediateRes, '\n');
			newline = true;
			break;
		
		case '}':
			currIndent--;
			appendStringInfoChar(&intermediateRes, '\n');
			newline = true;
			break;
		
		default:
			break;
		}

		for(int j = 0; j < currIndent && newline; j++) {
			appendStringInfoChar(&intermediateRes, '\t');
		}

		appendStringInfoChar(&intermediateRes, tmp[i]);
	}

	elog(INFO, "Node:\n%s\n", intermediateRes.data);
	pfree(intermediateRes.data);
}

/* 
 * Debug printer for the small subset of operations, that might be in Lambda-Functions
 * Prints a list of ExprEvalSteps, if initialized in the passed ExprState
 */
void
elog_expr_steps(ExprState *state)
{
	int i;

	if (state == NULL)
	{
		elog(INFO, "ExprState: NULL");
		return;
	}

	elog(INFO, "ExprState: steps_len = %d", state->steps_len);

	for (i = 0; i < state->steps_len; i++)
	{
		ExprEvalStep *step = &state->steps[i];

		switch (ExecEvalStepOp(state, step))
		{
			case EEOP_DONE:
				elog(INFO, "[%d] DONE", i);
				break;

			case EEOP_INNER_FETCHSOME:
				elog(INFO, "[%d] INNER_FETCHSOME: last_var=%d fixed=%s",
					 i,
					 step->d.fetch.last_var,
					 step->d.fetch.fixed ? "yes" : "no");
				break;

			case EEOP_OUTER_FETCHSOME:
				elog(INFO, "[%d] OUTER_FETCHSOME: last_var=%d fixed=%s",
					 i,
					 step->d.fetch.last_var,
					 step->d.fetch.fixed ? "yes" : "no");
				break;

			case EEOP_SCAN_FETCHSOME:
				elog(INFO, "[%d] SCAN_FETCHSOME: last_var=%d fixed=%s",
					 i,
					 step->d.fetch.last_var,
					 step->d.fetch.fixed ? "yes" : "no");
				break;

			case EEOP_INNER_VAR:
				elog(INFO, "[%d] INNER_VAR: attnum0=%d type=%u",
					 i,
					 step->d.var.attnum,
					 step->d.var.vartype);
				break;

			case EEOP_OUTER_VAR:
				elog(INFO, "[%d] OUTER_VAR: attnum0=%d type=%u",
					 i,
					 step->d.var.attnum,
					 step->d.var.vartype);
				break;

			case EEOP_SCAN_VAR:
				elog(INFO, "[%d] SCAN_VAR: attnum0=%d type=%u",
					 i,
					 step->d.var.attnum,
					 step->d.var.vartype);
				break;

			case EEOP_INNER_SYSVAR:
				elog(INFO, "[%d] INNER_SYSVAR: attnum=%d type=%u",
					 i,
					 step->d.var.attnum,
					 step->d.var.vartype);
				break;

			case EEOP_OUTER_SYSVAR:
				elog(INFO, "[%d] OUTER_SYSVAR: attnum=%d type=%u",
					 i,
					 step->d.var.attnum,
					 step->d.var.vartype);
				break;

			case EEOP_SCAN_SYSVAR:
				elog(INFO, "[%d] SCAN_SYSVAR: attnum=%d type=%u",
					 i,
					 step->d.var.attnum,
					 step->d.var.vartype);
				break;

			case EEOP_ASSIGN_INNER_VAR:
				elog(INFO, "[%d] ASSIGN_INNER_VAR: attnum0=%d resultnum=%d",
					 i,
					 step->d.assign_var.attnum,
					 step->d.assign_var.resultnum);
				break;

			case EEOP_ASSIGN_OUTER_VAR:
				elog(INFO, "[%d] ASSIGN_OUTER_VAR: attnum0=%d resultnum=%d",
					 i,
					 step->d.assign_var.attnum,
					 step->d.assign_var.resultnum);
				break;

			case EEOP_ASSIGN_SCAN_VAR:
				elog(INFO, "[%d] ASSIGN_SCAN_VAR: attnum0=%d resultnum=%d",
					 i,
					 step->d.assign_var.attnum,
					 step->d.assign_var.resultnum);
				break;

			case EEOP_ASSIGN_TMP:
				elog(INFO, "[%d] ASSIGN_TMP: resultnum=%d",
					 i,
					 step->d.assign_tmp.resultnum);
				break;

			case EEOP_ASSIGN_TMP_MAKE_RO:
				elog(INFO, "[%d] ASSIGN_TMP_MAKE_RO: resultnum=%d",
					 i,
					 step->d.assign_tmp.resultnum);
				break;

			case EEOP_CONST:
				{
					Datum val = step->d.constval.value;
					bool isnull = step->d.constval.isnull;

					if (isnull)
						elog(INFO, "[%d] CONST: NULL", i);
					else
						elog(INFO, "[%d] CONST: datum=0x%lx int4=%d int8=" INT64_FORMAT,
							 i,
							 (unsigned long) val,
							 DatumGetInt32(val),
							 DatumGetInt64(val));
				}
				break;

			case EEOP_FUNCEXPR:
			case EEOP_FUNCEXPR_STRICT:
			case EEOP_FUNCEXPR_FUSAGE:
			case EEOP_FUNCEXPR_STRICT_FUSAGE:
				elog(INFO, "[%d] FUNCEXPR: fn_oid=%u nargs=%d strict=%s fusage=%s",
					 i,
					 step->d.func.finfo ? step->d.func.finfo->fn_oid : InvalidOid,
					 step->d.func.nargs,
					 (ExecEvalStepOp(state, step) == EEOP_FUNCEXPR_STRICT ||
					  ExecEvalStepOp(state, step) == EEOP_FUNCEXPR_STRICT_FUSAGE) ? "yes" : "no",
					 (ExecEvalStepOp(state, step) == EEOP_FUNCEXPR_FUSAGE ||
					  ExecEvalStepOp(state, step) == EEOP_FUNCEXPR_STRICT_FUSAGE) ? "yes" : "no");
				break;

			case EEOP_BOOL_AND_STEP_FIRST:
				elog(INFO, "[%d] BOOL_AND_STEP_FIRST: jumpdone=%d",
					 i, step->d.boolexpr.jumpdone);
				break;

			case EEOP_BOOL_AND_STEP:
				elog(INFO, "[%d] BOOL_AND_STEP: jumpdone=%d",
					 i, step->d.boolexpr.jumpdone);
				break;

			case EEOP_BOOL_AND_STEP_LAST:
				elog(INFO, "[%d] BOOL_AND_STEP_LAST: jumpdone=%d",
					 i, step->d.boolexpr.jumpdone);
				break;

			case EEOP_BOOL_OR_STEP_FIRST:
				elog(INFO, "[%d] BOOL_OR_STEP_FIRST: jumpdone=%d",
					 i, step->d.boolexpr.jumpdone);
				break;

			case EEOP_BOOL_OR_STEP:
				elog(INFO, "[%d] BOOL_OR_STEP: jumpdone=%d",
					 i, step->d.boolexpr.jumpdone);
				break;

			case EEOP_BOOL_OR_STEP_LAST:
				elog(INFO, "[%d] BOOL_OR_STEP_LAST: jumpdone=%d",
					 i, step->d.boolexpr.jumpdone);
				break;

			case EEOP_BOOL_NOT_STEP:
				elog(INFO, "[%d] BOOL_NOT_STEP", i);
				break;

			case EEOP_QUAL:
				elog(INFO, "[%d] QUAL: jumpdone=%d",
					 i, step->d.qualexpr.jumpdone);
				break;

			case EEOP_JUMP:
				elog(INFO, "[%d] JUMP: target=%d",
					 i, step->d.jump.jumpdone);
				break;

			case EEOP_JUMP_IF_NULL:
				elog(INFO, "[%d] JUMP_IF_NULL: target=%d",
					 i, step->d.jump.jumpdone);
				break;

			case EEOP_JUMP_IF_NOT_NULL:
				elog(INFO, "[%d] JUMP_IF_NOT_NULL: target=%d",
					 i, step->d.jump.jumpdone);
				break;

			case EEOP_JUMP_IF_NOT_TRUE:
				elog(INFO, "[%d] JUMP_IF_NOT_TRUE: target=%d",
					 i, step->d.jump.jumpdone);
				break;

			case EEOP_PARAM_EXEC:
				elog(INFO, "[%d] PARAM_EXEC: paramid=%d type=%u",
					 i,
					 step->d.param.paramid,
					 step->d.param.paramtype);
				break;

			case EEOP_PARAM_EXTERN:
				elog(INFO, "[%d] PARAM_EXTERN: paramid=%d type=%u",
					 i,
					 step->d.param.paramid,
					 step->d.param.paramtype);
				break;

			case EEOP_PARAM_CALLBACK:
				elog(INFO, "[%d] PARAM_CALLBACK: paramid=%d type=%u",
					 i,
					 step->d.cparam.paramid,
					 step->d.cparam.paramtype);
				break;

			case EEOP_CASE_TESTVAL:
				elog(INFO, "[%d] CASE_TESTVAL", i);
				break;

			case EEOP_MAKE_READONLY:
				elog(INFO, "[%d] MAKE_READONLY", i);
				break;

			case EEOP_IOCOERCE:
				elog(INFO, "[%d] IOCOERCE", i);
				break;

			case EEOP_IOCOERCE_SAFE:
				elog(INFO, "[%d] IOCOERCE_SAFE", i);
				break;

			case EEOP_DISTINCT:
				elog(INFO, "[%d] DISTINCT: fn_oid=%u nargs=%d",
					 i,
					 step->d.func.finfo ? step->d.func.finfo->fn_oid : InvalidOid,
					 step->d.func.nargs);
				break;

			case EEOP_NOT_DISTINCT:
				elog(INFO, "[%d] NOT_DISTINCT: fn_oid=%u nargs=%d",
					 i,
					 step->d.func.finfo ? step->d.func.finfo->fn_oid : InvalidOid,
					 step->d.func.nargs);
				break;

			case EEOP_NULLIF:
				elog(INFO, "[%d] NULLIF: fn_oid=%u nargs=%d",
					 i,
					 step->d.func.finfo ? step->d.func.finfo->fn_oid : InvalidOid,
					 step->d.func.nargs);
				break;

			case EEOP_SQLVALUEFUNCTION:
				elog(INFO, "[%d] SQLVALUEFUNCTION", i);
				break;

			case EEOP_CURRENTOFEXPR:
				elog(INFO, "[%d] CURRENTOFEXPR", i);
				break;

			case EEOP_NEXTVALUEEXPR:
				elog(INFO, "[%d] NEXTVALUEEXPR: seqid=%u seqtypid=%u",
					 i,
					 step->d.nextvalueexpr.seqid,
					 step->d.nextvalueexpr.seqtypid);
				break;

			case EEOP_ARRAYEXPR:
				elog(INFO, "[%d] ARRAYEXPR: nelems=%d elemtype=%u multidims=%s",
					 i,
					 step->d.arrayexpr.nelems,
					 step->d.arrayexpr.elemtype,
					 step->d.arrayexpr.multidims ? "yes" : "no");
				break;

			case EEOP_ARRAYCOERCE:
				elog(INFO, "[%d] ARRAYCOERCE: resultelemtype=%u",
					 i,
					 step->d.arraycoerce.resultelemtype);
				break;

			case EEOP_ROW:
				elog(INFO, "[%d] ROW", i);
				break;

			case EEOP_ROWCOMPARE_STEP:
				elog(INFO, "[%d] ROWCOMPARE_STEP: jumpnull=%d jumpdone=%d",
					 i,
					 step->d.rowcompare_step.jumpnull,
					 step->d.rowcompare_step.jumpdone);
				break;

			case EEOP_ROWCOMPARE_FINAL:
				elog(INFO, "[%d] ROWCOMPARE_FINAL: rctype=%d",
					 i,
					 step->d.rowcompare_final.rctype);
				break;

			case EEOP_MINMAX:
				elog(INFO, "[%d] MINMAX: nelems=%d op=%d",
					 i,
					 step->d.minmax.nelems,
					 step->d.minmax.op);
				break;

			case EEOP_FIELDSELECT:
				elog(INFO, "[%d] FIELDSELECT: fieldnum=%d resulttype=%u tupdesc_id=%llu",
					 i,
					 step->d.fieldselect.fieldnum,
					 step->d.fieldselect.resulttype,
					 (unsigned long long) step->d.fieldselect.rowcache.tupdesc_id);
				break;

			case EEOP_FIELDSTORE_DEFORM:
				elog(INFO, "[%d] FIELDSTORE_DEFORM: ncolumns=%d",
					 i,
					 step->d.fieldstore.ncolumns);
				break;

			case EEOP_FIELDSTORE_FORM:
				elog(INFO, "[%d] FIELDSTORE_FORM: ncolumns=%d",
					 i,
					 step->d.fieldstore.ncolumns);
				break;

			case EEOP_SBSREF_SUBSCRIPTS:
				elog(INFO, "[%d] SBSREF_SUBSCRIPTS: jumpdone=%d",
					 i,
					 step->d.sbsref_subscript.jumpdone);
				break;

			case EEOP_SBSREF_OLD:
				elog(INFO, "[%d] SBSREF_OLD", i);
				break;

			case EEOP_SBSREF_ASSIGN:
				elog(INFO, "[%d] SBSREF_ASSIGN", i);
				break;

			case EEOP_SBSREF_FETCH:
				elog(INFO, "[%d] SBSREF_FETCH", i);
				break;

			case EEOP_DOMAIN_TESTVAL:
				elog(INFO, "[%d] DOMAIN_TESTVAL", i);
				break;

			case EEOP_DOMAIN_NOTNULL:
				elog(INFO, "[%d] DOMAIN_NOTNULL: resulttype=%u",
					 i,
					 step->d.domaincheck.resulttype);
				break;

			case EEOP_DOMAIN_CHECK:
				elog(INFO, "[%d] DOMAIN_CHECK: resulttype=%u constraint=%s",
					 i,
					 step->d.domaincheck.resulttype,
					 step->d.domaincheck.constraintname ? step->d.domaincheck.constraintname : "<null>");
				break;

			case EEOP_CONVERT_ROWTYPE:
				elog(INFO, "[%d] CONVERT_ROWTYPE: inputtype=%u outputtype=%u",
					 i,
					 step->d.convert_rowtype.inputtype,
					 step->d.convert_rowtype.outputtype);
				break;

			case EEOP_SCALARARRAYOP:
				elog(INFO, "[%d] SCALARARRAYOP: element_type=%u useOr=%s",
					 i,
					 step->d.scalararrayop.element_type,
					 step->d.scalararrayop.useOr ? "yes" : "no");
				break;

			case EEOP_HASHED_SCALARARRAYOP:
				elog(INFO, "[%d] HASHED_SCALARARRAYOP: has_nulls=%s inclause=%s",
					 i,
					 step->d.hashedscalararrayop.has_nulls ? "yes" : "no",
					 step->d.hashedscalararrayop.inclause ? "yes" : "no");
				break;

			case EEOP_XMLEXPR:
				elog(INFO, "[%d] XMLEXPR", i);
				break;

			case EEOP_JSON_CONSTRUCTOR:
				elog(INFO, "[%d] JSON_CONSTRUCTOR", i);
				break;

			case EEOP_IS_JSON:
				elog(INFO, "[%d] IS_JSON", i);
				break;

			case EEOP_JSONEXPR_PATH:
				elog(INFO, "[%d] JSONEXPR_PATH", i);
				break;

			case EEOP_JSONEXPR_COERCION:
				elog(INFO, "[%d] JSONEXPR_COERCION: targettype=%u targettypmod=%d",
					 i,
					 step->d.jsonexpr_coercion.targettype,
					 step->d.jsonexpr_coercion.targettypmod);
				break;

			case EEOP_JSONEXPR_COERCION_FINISH:
				elog(INFO, "[%d] JSONEXPR_COERCION_FINISH", i);
				break;

			case EEOP_AGGREF:
				elog(INFO, "[%d] AGGREF: aggno=%d",
					 i,
					 step->d.aggref.aggno);
				break;

			case EEOP_GROUPING_FUNC:
				elog(INFO, "[%d] GROUPING_FUNC", i);
				break;

			case EEOP_WINDOW_FUNC:
				elog(INFO, "[%d] WINDOW_FUNC", i);
				break;

			case EEOP_MERGE_SUPPORT_FUNC:
				elog(INFO, "[%d] MERGE_SUPPORT_FUNC", i);
				break;

			case EEOP_SUBPLAN:
				elog(INFO, "[%d] SUBPLAN", i);
				break;

			case EEOP_CALLLAMBDAEXPR:
				{
					CallLambdaExprState *clestate = step->d.calllambdaexpr.cle_state;
					CallLambdaExpr *cle = clestate ? clestate->expr : NULL;

					elog(INFO, "[%d] CALLLAMBDAEXPR: nargs=%d rettype=%u lambdatypmod=%d has_lambda_expr=%s lambda_isnull=%s",
						 i,
						 clestate ? clestate->nargs : -1,
						 cle ? cle->rettype : InvalidOid,
						 cle ? cle->lambdatypmod : -1,
						 (cle && cle->lambda_expr) ? "yes" : "no",
						 (clestate && clestate->lambda_isnull) ? "yes" : "no");
				}
				break;

			default:
				elog(INFO, "[%d] <SKIPPED>: opcode=%d",
					 i,
					 ExecEvalStepOp(state, step));
				break;
		}
	}
}

/*
 * Returns a pointer to the LambdaInputParam, that is located at *lambda*->argtypes[*rowIndex*][*colIndex*]
 * Returns NULL on "failed to find."
 */
LambdaInputParam *get_input_param_from_index(LambdaExpr *lambda, int rowIndex, int colIndex)
{
	List *rowList;
	Node *param_node;

	if (!lambda)
		return NULL;
	if (!lambda->argtypes)
		return NULL;

	if (rowIndex < 0 || rowIndex >= list_length(lambda->argtypes))
    {
        if(custom_lambda_debugging_enabled()) 
            elog(WARNING, "GetLambdaInputParam: row index %d out of bounds", rowIndex);
        return NULL;
    }

	rowList = (List *) list_nth(lambda->argtypes, rowIndex);

	if (colIndex < 0 || colIndex >= list_length(rowList))
    {
        if(custom_lambda_debugging_enabled()) 
            elog(WARNING, "GetLambdaInputParam: column index %d out of bounds in row %d", colIndex, rowIndex);
        return NULL;
    }
		

	param_node = (Node *) list_nth(rowList, colIndex);

	if (!IsA(param_node, LambdaInputParam))
    {
        if(custom_lambda_debugging_enabled()) 
            elog(WARNING, "GetLambdaInputParam: unexpected node type at [%d][%d]", rowIndex, colIndex);
        return NULL;
    }
		

	return (LambdaInputParam *) param_node;
}

/*
 * Returns a pointer to the LambdaInputParam in *lambda*
 * whose name matches the given one-part name List (.colName).
 * The name must be a List of one String nodes: e.g., '(a).x', '(b).f'.
 */
LambdaInputParam *get_input_param_from_name(LambdaExpr *lambda, List *name)
{
	String *rowAliasVal;
	String *colNameVal;
	const char *rowAlias;
	const char *colName;

	if (lambda == NULL || lambda->argtypes == NULL || name == NULL)
	{
		if (custom_lambda_debugging_enabled())
			elog(WARNING, "get_input_param_from_name: NULL input(s)");
		return NULL;
	}

	if (list_length(name) != 2)
	{
		if (custom_lambda_debugging_enabled())
			elog(WARNING, "get_input_param_from_name: name must be a two-part identifier (row.col)");
		return NULL;
	}

	rowAliasVal = (String *) linitial(name);
	colNameVal = (String *) lsecond(name);

	if (rowAliasVal->type != T_String || colNameVal->type != T_String)
	{
		if (custom_lambda_debugging_enabled())
			elog(WARNING, "get_input_param_from_name: name parts must be strings");
		return NULL;
	}

	rowAlias = strVal(rowAliasVal);
	colName  = strVal(colNameVal);

	/* Loop through each row group in argtypes */
	for (int rowIndex = 0; rowIndex < list_length(lambda->argtypes); rowIndex++)
	{
		List *rowList = (List *) list_nth(lambda->argtypes, rowIndex);

		for (int colIndex = 0; colIndex < list_length(rowList); colIndex++)
		{
			Node *param_node = (Node *) list_nth(rowList, colIndex);
			LambdaInputParam *param;
			String *paramRowAliasVal;
			String *paramColNameVal;
			const char *paramRowAlias;
			const char *paramColName;

			if (!IsA(param_node, LambdaInputParam))
				continue;

			param = (LambdaInputParam *) param_node;

			/* Ensure name is also a one-part list of strings */
			if (param->name == NULL || list_length(param->name) != 1)
				continue;

			paramRowAliasVal = (String *) list_nth(lambda->argnames, rowIndex);
			paramColNameVal  = (String *) linitial(param->name);

			if (!IsA(paramRowAliasVal, String) || !IsA(paramColNameVal, String))
				continue;

			paramRowAlias = strVal(paramRowAliasVal);
			paramColName  = strVal(paramColNameVal);

			if (strcmp(rowAlias, paramRowAlias) == 0 &&
				strcmp(colName, paramColName) == 0)
			{
				return param;
			}
		}
	}

	if (custom_lambda_debugging_enabled())
		elog(WARNING, "get_input_param_from_name: no matching param found for \"%s.%s\"", rowAlias, colName);

	return NULL;
}