/*-------------------------------------------------------------------------
 *
 * pg_lambdasig.h
 *    definition of the "lambda signature" system catalog (pg_lambdasig)
 *
 * src/include/catalog/pg_lambdasig.h
 *
 *-------------------------------------------------------------------------
 */

#ifndef PG_LAMBDASIG_H
#define PG_LAMBDASIG_H

#include "catalog/genbki.h"
#include "catalog/pg_lambdasig_d.h"
#include "nodes/parsenodes.h"

#include "utils/rel.h"
#include "parser/parse_node.h"

/*
 * pg_lambdasig stores canonical lambda signatures for lambda column typmods.
 *
 * pg_attribute.atttypid  = LAMBDAOID
 * pg_attribute.atttypmod = pg_lambdasig.lamsigid
 *
 * lamsigid is the int32 value stored directly in pg_attribute.atttypmod.
 *
 * lamsigkey is the canonical machine-readable signature:
 *
 *     ()->23
 *     (23,25)->16
 *     ((23)->16,25)->114
 *
 * lamsigsrc is the canonical display form:
 *
 *     () -> integer
 *     (integer, text) -> boolean
 *     ((integer) -> boolean, text) -> json
 *
 * lamsigkey determines identity. lamsigsrc is for display/debug output.
 */
CATALOG(pg_lambdasig,8520,LambdaSigRelationId)
{
	Oid		oid;		/* oid */

	/*
	 * Small positive int stored in pg_attribute.atttypmod. -1 stays PG's normal
	 * "no typmod", lambda signatures use values >= 0.
	 */
	int32	lamsigid BKI_FORCE_NOT_NULL;

#ifdef CATALOG_VARLEN
	text	lamsigkey BKI_FORCE_NOT_NULL;
	text	lamsigsrc BKI_FORCE_NOT_NULL;
#endif
} FormData_pg_lambdasig;

typedef FormData_pg_lambdasig *Form_pg_lambdasig;

/* keep DECLARE_*INDEX and MAKE_SYSCACHE macros on one physical line */
DECLARE_UNIQUE_INDEX_PKEY(pg_lambdasig_oid_index, 8521, LambdaSigOidIndexId, pg_lambdasig, btree(oid oid_ops));
DECLARE_UNIQUE_INDEX(pg_lambdasig_sigid_index, 8522, LambdaSigIdIndexId, pg_lambdasig, btree(lamsigid int4_ops));
DECLARE_UNIQUE_INDEX(pg_lambdasig_key_index, 8523, LambdaSigKeyIndexId, pg_lambdasig, btree(lamsigkey text_ops));

MAKE_SYSCACHE(LAMBDASIGOID, pg_lambdasig_oid_index, 8);
MAKE_SYSCACHE(LAMBDASIGID, pg_lambdasig_sigid_index, 8);

/* low-level catalog helpers */
extern Oid LambdaSigGetOidByTypmod(int32 typmod, bool missing_ok);
extern char *LambdaSigGetSource(int32 typmod);
extern char *LambdaSigGetKey(int32 typmod);

extern int32 LambdaSigGetTypmodByKey(const char *sigkey, bool missing_ok);
extern int32 LambdaSigCreate(const char *sigkey, const char *sigsrc);

/*
 * Main public API.
 *   LambdaSigCreateFromSignature: LambdaSignature tree -> pg_lambdasig row -> int32 typmod
 *   LambdaSigGetSignature:        int32 typmod -> pg_lambdasig row -> LambdaSignature tree
 */
extern int32 LambdaSigCreateFromSignature(const LambdaSignature *sig);
extern LambdaSignature *LambdaSigGetSignature(int32 typmod);

/*
 * Partial-application(hole) support.
 *
 * LambdaSigNarrow: signature + keep-mask -> signature of the partial application.
 *   Keeps exactly the arg positions whose keep[] is true(the holes), return type
 *   unchanged. Freshly built tree, no catalog access. nargs must equal the
 *   signature's arg count.
 * LambdaSigNarrowTypmod: same one level up, stored typmod + keep-mask -> typmod of
 *   the result(created or reused). The single call a hole call site needs.
 */
extern LambdaSignature *LambdaSigNarrow(const LambdaSignature *sig,
										const bool *keep, int nargs);
extern int32 LambdaSigNarrowTypmod(int32 typmod, const bool *keep, int nargs);

#endif							/* PG_LAMBDASIG_H */