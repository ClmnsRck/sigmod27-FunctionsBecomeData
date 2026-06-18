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
#include "utils/guc.h"
#include "catalog/namespace.h"
#include "catalog/pg_lambdasig.h"
#include "nodes/parsenodes.h"
#include "nodes/primnodes.h"
#include "nodes/plannodes.h"
#include "parser/parse_expr.h"
#include "parser/parser.h"
#include "executor/executor.h"
#include "utils/lambda.h"

/* ------------------------------------------------------------------------- */
/* SQL Input/Output Support                                                  */
/* ------------------------------------------------------------------------- */

/*
 * Turns any CString represented lambda into a SerializedLambda, in pre-transform form.
 * This means it will still contain ColumnRefs, A_Exprs, FuncCalls. These need to be resolved 
 * before they can be used in the executor via the defined Macros, as can be found in src/ext/<...>.c
 */
Datum lambda_in(PG_FUNCTION_ARGS)
{
    const char *str;
    char *sql;  // Wrap input as a SQL SELECT
    List *raw_parsetree_list;
    RawStmt *raw_stmt;
    SelectStmt *select_stmt;
    ResTarget *res;
    Node *expr;
    SerializedLambda *sl; 

    str = PG_GETARG_CSTRING(0);
    sql = psprintf("SELECT %s", str);

    raw_parsetree_list = raw_parser(sql, RAW_PARSE_DEFAULT);
    raw_stmt = linitial_node(RawStmt, raw_parsetree_list);
    select_stmt = castNode(SelectStmt, raw_stmt->stmt);
    res = linitial_node(ResTarget, select_stmt->targetList);
    expr = res->val;
    sl = lambdaExprToSerialLambda((LambdaExpr *) expr);

    PG_RETURN_POINTER(sl);
}

Datum lambda_out(PG_FUNCTION_ARGS)
{
    LambdaExpr *expr;
    SerializedLambda *sl;
    StringInfoData bufResult;

    //initialize Output string
    initStringInfo(&bufResult);

    //init local vars
    sl = PG_GETARG_SERIALIZEDLAMBDA_P(0);
    expr = lambda_deserialize(sl);

    //build final lambda function in string form
    appendStringInfoString(&bufResult, deparse_expression((Node *) expr, NIL, false, false));

    PG_RETURN_CSTRING(bufResult.data);
}

Datum lambda_typmodout(PG_FUNCTION_ARGS)
{
	int32 typmod = PG_GETARG_INT32(0);
	char *src;

	if (typmod < 0)
		PG_RETURN_CSTRING(pstrdup(""));

	src = LambdaSigGetSource(typmod);
	PG_RETURN_CSTRING(src);
}

bool custom_lambda_debugging_var = false;

bool
custom_lambda_debugging_enabled(void)
{
    return custom_lambda_debugging_var;
}

/*
 * When on(default), higher-order lambda calls on the plain-SQL path get flattened
 */
bool custom_lambda_hoisting_var = true;

bool
custom_lambda_hoisting_enabled(void)
{
    return custom_lambda_hoisting_var;
}
