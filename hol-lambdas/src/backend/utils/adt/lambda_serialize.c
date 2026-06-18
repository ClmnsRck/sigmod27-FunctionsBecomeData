/*-------------------------------------------------------------------------
 *
 * lambda_serialize.c
 *	  Misc user-visible lambda support functions for serialization and deserialization
 *    Assume all Lambda functions in query execution to be in serialized
 *    form, except for those directly passed to a UDF as an argument.
 *    Serialized LambdaFunctions generally capture a pre-Transform, Parse-Node AST tree,
 *    as certain information cannot be obtained during the parsing of "naked" lambdas,
 *    like input types, operator OIDs, etcs
 *
 * Copyright (c) 2003-2024, PostgreSQL Global Development Group
 *                    2025, XXXX XXXX
 *
 * IDENTIFICATION
 *	  src/backend/utils/adt/lambda_serialize.c
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
#include "nodes/parsenodes.h"
#include "nodes/primnodes.h"
#include "nodes/plannodes.h"
#include "parser/parse_expr.h"
#include "parser/parser.h"
#include "executor/executor.h"
#include "utils/lambda.h"


/* ------------------------------------------------------------------------- */
/* Internal serializer/deserializer funcs                                    */
/* ------------------------------------------------------------------------- */

/* Walks a LambdaExpr and emits a SerializedLambda (bytearray, varlena-compatible, allows toasting) */
SerializedLambda *lambdaExprToSerialLambda(LambdaExpr *expr)
{
    int32 size;

    StringInfoData buf;
    SerializedLambda *result;

    // Serialize the expression body, lead by the actual lambda node
    char *s = nodeToString((Node *) expr);

    // Init buffer to hold data whilst tree traversal
    initStringInfo(&buf);
    appendStringInfoString(&buf, s);

    //allocate and populate final SerializedLambda
    size = ALIGN_TO_4(sizeof(SerializedLambda) + buf.len);
    result = (SerializedLambda *) palloc0(size);
    SET_VARSIZE(result, size);
    result->nargs = (int32) list_length(expr->argnames);
    result->magic = SERIAL_LAMBDA_MAGIC;

    //populate result->data with the buffered OpSteps
    memcpy(result->data, buf.data, buf.len); 

    //free the buffer
    pfree(buf.data);

    return result;
}

/* Deserializes SerializedLambda into an in-memory LambdaExpr */
LambdaExpr *lambda_deserialize(SerializedLambda *sl)
{
    LambdaExpr *res;

    //check for proper alignemnt before trying to read the expr-body
    if(sl->magic != SERIAL_LAMBDA_MAGIC) {
        elog(ERROR, "Memory is not aligned properly! Was this lambda created in an older version of Postgres or on a different system?");
    }

    res = (LambdaExpr *) stringToNode((char *) sl->data);

    return res;
}
