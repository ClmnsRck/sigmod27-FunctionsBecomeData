/*-------------------------------------------------------------------------
 *
 * lambda_print.c
 *	  Misc user-visible lambda pretty-print support.
 *    Assume all Lambda functions in query execution to be in serialized
 *    form, except for those directly passed to a UDF as an argument.
 *
 * Copyright (c) 2003-2024, PostgreSQL Global Development Group
 *                    2025, XXXX XXXX
 *
 * IDENTIFICATION
 *	  src/backend/utils/adt/lambda_print.c
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
#include "utils/ruleutils.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/regproc.h"
#include "catalog/namespace.h"
#include "nodes/parsenodes.h"
#include "nodes/primnodes.h"
#include "nodes/plannodes.h"
#include "nodes/nodeFuncs.h"
#include "parser/parse_expr.h"
#include "parser/parser.h"
#include "executor/executor.h"
#include "utils/lambda.h"


static void print_lambda_param_type_recursive(StringInfo buf, LambdaInputParam *param);

/* ------------------------------------------------------------------------- */
/* Misc Helpers                                                              */
/* ------------------------------------------------------------------------- */

/*
 * Helps transformTargetEntry print a lambda column with its typmod 
 * signature lookup.
 */
char *
lambdaDecorateTargetName(Node *expr, char *colname)
{
	int32	typmod;
	char   *suffix;
	size_t	colname_len,
			suffix_len;

	if (colname == NULL)
		return NULL;

	typmod = exprTypmod(expr);

	if (typmod < 0)
		return colname;

	/*
	 * Idempotent: don't re-decorate a name already ending in its "(id:N)"
	 * suffix, else a CTAS'd lambda column re-expanded by SELECT * becomes
	 * "f(id:0)(id:0)" and no longer resolves back to "f".
	 */
	suffix = psprintf("(id:%d)", typmod);
	colname_len = strlen(colname);
	suffix_len = strlen(suffix);

	if (colname_len >= suffix_len &&
		strcmp(colname + colname_len - suffix_len, suffix) == 0)
	{
		pfree(suffix);
		return colname;
	}

	pfree(suffix);
	return psprintf("%s(id:%d)", colname, typmod);
}

/*
 * Inverse of lambdaDecorateTargetName: strip the display-only "(id:typmod)"
 * suffix from a lambda column's name so name resolution sees the real name.
 * Only the suffix matching expr's own typmod is removed, so a column that just
 * happens to end in "(id:...)" is left alone; non-lambda/undecorated names are
 * returned unchanged.
 */
char *
lambdaUndecorateName(Node *expr, const char *colname)
{
	int32	typmod;
	char   *suffix;
	size_t	colname_len,
			suffix_len;

	if (colname == NULL)
		return NULL;

	typmod = exprTypmod(expr);

	if (typmod < 0)
		return pstrdup(colname);

	suffix = psprintf("(id:%d)", typmod);
	colname_len = strlen(colname);
	suffix_len = strlen(suffix);

	if (colname_len > suffix_len &&
		strcmp(colname + colname_len - suffix_len, suffix) == 0)
	{
		char *result = pnstrdup(colname, colname_len - suffix_len);

		pfree(suffix);
		return result;
	}

	pfree(suffix);
	return pstrdup(colname);
}

/* 
 * Prints the expected inputs of a lambda-expression
 * With full typing support, including nested lambdas.
 */
void
printLambdaInputsWithType(LambdaExpr *expr, StringInfo buf) 
{
	ListCell *alias_cell;
	ListCell *paramlist_cell;
	int idx = 0;

	int len_aliases = list_length(expr->argnames);
	int len_paramlists = list_length(expr->argtypes);

	if(expr->lambdakind == LAMBDA_SCALAR_CONTEXT)
	{
		foreach(alias_cell, expr->argnames)
		{
			String *alias = lfirst_node(String, alias_cell);

			if (idx > 0)
				appendStringInfoString(buf, ", ");

			appendStringInfo(buf, "%s", strVal(alias));
			idx++;
		}
		return;
	}

	if (len_aliases != len_paramlists)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("lambda argument row list lengths do not match"),
				 errdetail("Found %d row aliases, %d parameter lists.",
						   len_aliases, len_paramlists)));

	forboth(alias_cell, expr->argnames, paramlist_cell, expr->argtypes)
	{
		String *alias = lfirst_node(String, alias_cell);
		List *param_list = lfirst(paramlist_cell); // List of LambdaInputParam
		ListCell *param_cell;
		int pidx = 0;

		if (idx > 0)
			appendStringInfoString(buf, ", ");

		appendStringInfo(buf, "%s: [", strVal(alias));

		foreach(param_cell, param_list)
		{
			LambdaInputParam *param = lfirst_node(LambdaInputParam, param_cell);

			if (pidx > 0)
				appendStringInfoString(buf, ", ");

			appendStringInfo(buf, "%s: ", strVal(linitial(param->name)));
			print_lambda_param_type_recursive(buf, param);

			pidx++;
		}

		appendStringInfoChar(buf, ']');
		idx++;
	}
}

/*
 * Pretty-prints a LambdaInputParam's type recursively.
 * Supports both atomic and function-typed inputs.
 */
static void
print_lambda_param_type_recursive(StringInfo buf, LambdaInputParam *param)
{
	if (param->isAtomic)
	{
		appendStringInfoString(buf, format_type_be(param->type));
	}
	else
	{
		ListCell *lc;
		int i = 0;
		appendStringInfoChar(buf, '(');

		foreach(lc, param->input_types)
		{
			LambdaInputParam *subparam = lfirst_node(LambdaInputParam, lc);

			if (i > 0)
				appendStringInfoString(buf, ", ");

			print_lambda_param_type_recursive(buf, subparam);
			i++;
		}

		appendStringInfo(buf, " -> %s)", format_type_be(param->type));
	}
}