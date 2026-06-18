/*-------------------------------------------------------------------------
 *
 * pg_lambdasig.c
 *    routines for pg_lambdasig
 *
 * src/backend/catalog/pg_lambdasig.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include <errno.h>

#include "access/genam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/catalog.h"
#include "catalog/indexing.h"
#include "catalog/pg_lambdasig.h"
#include "catalog/pg_lambdasig_d.h"
#include "catalog/pg_type.h"
#include "lib/stringinfo.h"
#include "nodes/pg_list.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"


typedef struct LambdaSigParser
{
	const char *start;
	const char *ptr;
	const char *src;
} LambdaSigParser;


static int32 LambdaSigAllocateTypmod(Relation rel);
static int32 LambdaSigLookupTypmodByKeyInRelation(Relation rel,
												  const char *sigkey);

static void LambdaSigValidateSignature(const LambdaSignature *sig);
static void LambdaSigValidateType(const LambdaSigType *typ);
static void LambdaSigCheckScalarOid(Oid typeoid, ParseLoc location);

static void LambdaSigAppendKey(StringInfo buf, const LambdaSignature *sig);
static void LambdaSigTypeAppendKey(StringInfo buf, const LambdaSigType *typ);
static void LambdaSigAppendSource(StringInfo buf, const LambdaSignature *sig);
static void LambdaSigTypeAppendSource(StringInfo buf, const LambdaSigType *typ);

static LambdaSignature *LambdaSigParseKey(const char *sigkey,
										  const char *sigsrc);
static LambdaSignature *LambdaSigParseSignature(LambdaSigParser *parser);
static LambdaSigType *LambdaSigParseType(LambdaSigParser *parser);
static Oid LambdaSigParseOid(LambdaSigParser *parser);
static bool LambdaSigConsume(LambdaSigParser *parser, char ch);
static void LambdaSigExpect(LambdaSigParser *parser, char ch);
static void LambdaSigParseError(LambdaSigParser *parser, const char *msg);


/*
 * Allocate max(lamsigid) + 1. LambdaSigCreate() opens pg_lambdasig with
 * ExclusiveLock, so concurrent commands cant grab the same lamsigid here.
 * Within one command, LambdaSigCreate() bumps the command counter per insert
 * so the next allocation sees prior rows.
 */
static int32
LambdaSigAllocateTypmod(Relation rel)
{
	SysScanDesc scan;
	HeapTuple	tup;
	int32		maxid = -1;

	scan = systable_beginscan(rel, InvalidOid, false, NULL, 0, NULL);

	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_lambdasig form;

		form = (Form_pg_lambdasig) GETSTRUCT(tup);

		if (form->lamsigid > maxid)
			maxid = form->lamsigid;
	}

	systable_endscan(scan);

	if (maxid == PG_INT32_MAX)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("too many lambda signatures")));

	return maxid + 1;
}


/*
 * Lookup by canonical key. Scans on purpose instead of using syscache - the hot
 * path is typmod -> signature, not key -> typmod.
 */
static int32
LambdaSigLookupTypmodByKeyInRelation(Relation rel, const char *sigkey)
{
	SysScanDesc scan;
	HeapTuple	tup;
	int32		result = -1;

	scan = systable_beginscan(rel, InvalidOid, false, NULL, 0, NULL);

	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Datum		datum;
		bool		isnull;
		char	   *existing;

		datum = heap_getattr(tup,
							 Anum_pg_lambdasig_lamsigkey,
							 RelationGetDescr(rel),
							 &isnull);

		if (isnull)
			elog(ERROR, "null lamsigkey in pg_lambdasig");

		existing = TextDatumGetCString(datum);

		if (strcmp(existing, sigkey) == 0)
		{
			result = ((Form_pg_lambdasig) GETSTRUCT(tup))->lamsigid;
			pfree(existing);
			break;
		}

		pfree(existing);
	}

	systable_endscan(scan);

	return result;
}


Oid
LambdaSigGetOidByTypmod(int32 typmod, bool missing_ok)
{
	HeapTuple	tup;
	Oid			result;

	tup = SearchSysCache1(LAMBDASIGID, Int32GetDatum(typmod));

	if (!HeapTupleIsValid(tup))
	{
		if (missing_ok)
			return InvalidOid;

		elog(ERROR, "cache lookup failed for lambda signature typmod %d",
			 typmod);
	}

	result = ((Form_pg_lambdasig) GETSTRUCT(tup))->oid;

	ReleaseSysCache(tup);

	return result;
}


char *
LambdaSigGetSource(int32 typmod)
{
	HeapTuple	tup;
	Datum		datum;
	bool		isnull;
	char	   *result;

	tup = SearchSysCache1(LAMBDASIGID, Int32GetDatum(typmod));

	if (!HeapTupleIsValid(tup))
		elog(ERROR, "cache lookup failed for lambda signature typmod %d",
			 typmod);

	datum = SysCacheGetAttr(LAMBDASIGID,
							tup,
							Anum_pg_lambdasig_lamsigsrc,
							&isnull);

	if (isnull)
		elog(ERROR, "null lamsigsrc for lambda signature typmod %d",
			 typmod);

	result = TextDatumGetCString(datum);

	ReleaseSysCache(tup);

	return result;
}


char *
LambdaSigGetKey(int32 typmod)
{
	HeapTuple	tup;
	Datum		datum;
	bool		isnull;
	char	   *result;

	tup = SearchSysCache1(LAMBDASIGID, Int32GetDatum(typmod));

	if (!HeapTupleIsValid(tup))
		elog(ERROR, "cache lookup failed for lambda signature typmod %d",
			 typmod);

	datum = SysCacheGetAttr(LAMBDASIGID,
							tup,
							Anum_pg_lambdasig_lamsigkey,
							&isnull);

	if (isnull)
		elog(ERROR, "null lamsigkey for lambda signature typmod %d",
			 typmod);

	result = TextDatumGetCString(datum);

	ReleaseSysCache(tup);

	return result;
}


int32
LambdaSigGetTypmodByKey(const char *sigkey, bool missing_ok)
{
	Relation	rel;
	int32		result;

	Assert(sigkey != NULL);

	rel = table_open(LambdaSigRelationId, AccessShareLock);
	result = LambdaSigLookupTypmodByKeyInRelation(rel, sigkey);
	table_close(rel, AccessShareLock);

	if (result < 0 && !missing_ok)
		elog(ERROR, "cache lookup failed for lambda signature key \"%s\"",
			 sigkey);

	return result;
}


/*
 * Create or reuse a lambda signature row. sigkey must be canonical and
 * OID-resolved, sigsrc is display-only.
 */
int32
LambdaSigCreate(const char *sigkey, const char *sigsrc)
{
	Relation	rel;
	HeapTuple	tup;
	Datum		values[Natts_pg_lambdasig];
	bool		nulls[Natts_pg_lambdasig];
	int32		lamsigid;
	Oid			oid;

	Assert(sigkey != NULL);
	Assert(sigsrc != NULL);

	rel = table_open(LambdaSigRelationId, ExclusiveLock);

	lamsigid = LambdaSigLookupTypmodByKeyInRelation(rel, sigkey);

	if (lamsigid >= 0)
	{
		table_close(rel, ExclusiveLock);
		return lamsigid;
	}

	lamsigid = LambdaSigAllocateTypmod(rel);

	memset(values, 0, sizeof(values));
	memset(nulls, false, sizeof(nulls));

	oid = GetNewOidWithIndex(rel,
							 LambdaSigOidIndexId,
							 Anum_pg_lambdasig_oid);

	values[Anum_pg_lambdasig_oid - 1] =
		ObjectIdGetDatum(oid);
	values[Anum_pg_lambdasig_lamsigid - 1] =
		Int32GetDatum(lamsigid);
	values[Anum_pg_lambdasig_lamsigkey - 1] =
		CStringGetTextDatum(sigkey);
	values[Anum_pg_lambdasig_lamsigsrc - 1] =
		CStringGetTextDatum(sigsrc);

	tup = heap_form_tuple(RelationGetDescr(rel), values, nulls);

	CatalogTupleInsert(rel, tup);

	heap_freetuple(tup);
	table_close(rel, ExclusiveLock);

	/*
	 * Make this row visible to later allocations in the same command (e.g. a
	 * CREATE TABLE with two lambda columns), else they reuse this lamsigid and
	 * hit the unique index.
	 */
	CommandCounterIncrement();

	return lamsigid;
}


/* Public store API: LambdaSignature * -> int32 typmod */
int32
LambdaSigCreateFromSignature(const LambdaSignature *sig)
{
	StringInfoData keybuf;
	StringInfoData srcbuf;
	int32		typmod;

	if (sig == NULL)
		elog(ERROR, "cannot create lambda typmod from null signature");

	LambdaSigValidateSignature(sig);

	initStringInfo(&keybuf);
	initStringInfo(&srcbuf);

	LambdaSigAppendKey(&keybuf, sig);
	LambdaSigAppendSource(&srcbuf, sig);

	typmod = LambdaSigCreate(keybuf.data, srcbuf.data);

	pfree(keybuf.data);
	pfree(srcbuf.data);

	return typmod;
}


/*
 * Public lookup API: int32 typmod -> LambdaSignature *. Returned tree is palloc'd
 * in the current memory context.
 */
LambdaSignature *
LambdaSigGetSignature(int32 typmod)
{
	char		   *sigkey;
	char		   *sigsrc;
	LambdaSignature *sig;

	if (typmod < 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("lambda typmod %d does not reference a stored lambda signature",
						typmod)));

	sigkey = LambdaSigGetKey(typmod);
	sigsrc = LambdaSigGetSource(typmod);

	sig = LambdaSigParseKey(sigkey, sigsrc);

	pfree(sigkey);
	pfree(sigsrc);

	return sig;
}


/*
 * Partial-application(hole) support, see pg_lambdasig.h. Keep the arg positions
 * flagged in keep[], drop(bind away) the rest. Binding args never changes the
 * lambda's ultimate result, so the return type carries over verbatim. Kept arg
 * types and the return type are deep-copied, so the result shares no nodes with
 * the input.
 */
LambdaSignature *
LambdaSigNarrow(const LambdaSignature *sig, const bool *keep, int nargs)
{
	LambdaSignature *result;
	List	   *kept = NIL;
	ListCell   *lc;
	int			i = 0;

	if (sig == NULL)
		elog(ERROR, "cannot narrow a null lambda signature");

	if (nargs != list_length(sig->argtypes))
		elog(ERROR, "lambda signature has %d arguments, narrow mask has %d",
			 list_length(sig->argtypes), nargs);

	foreach(lc, sig->argtypes)
	{
		if (keep[i])
			kept = lappend(kept, copyObject(lfirst(lc)));
		i++;
	}

	result = makeNode(LambdaSignature);
	result->argtypes = kept;
	result->rettype = copyObject(sig->rettype);
	result->location = -1;

	return result;
}


int32
LambdaSigNarrowTypmod(int32 typmod, const bool *keep, int nargs)
{
	LambdaSignature *narrowed;

	narrowed = LambdaSigNarrow(LambdaSigGetSignature(typmod), keep, nargs);

	return LambdaSigCreateFromSignature(narrowed);
}


/*
 * Validation.
 */
static void
LambdaSigValidateSignature(const LambdaSignature *sig)
{
	ListCell   *lc;

	if (sig == NULL)
		elog(ERROR, "null lambda signature");

	if (sig->rettype == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("lambda signature has no return type")));

	foreach(lc, sig->argtypes)
	{
		LambdaSigType *argtyp;

		argtyp = lfirst_node(LambdaSigType, lc);
		LambdaSigValidateType(argtyp);
	}

	LambdaSigValidateType(castNode(LambdaSigType, sig->rettype));
}


static void
LambdaSigValidateType(const LambdaSigType *typ)
{
	if (typ == NULL)
		elog(ERROR, "null lambda signature type");

	if (typ->is_function)
	{
		if (typ->signature == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_SYNTAX_ERROR),
					 errmsg("nested lambda signature has no signature")));

		LambdaSigValidateSignature(castNode(LambdaSignature,
											typ->signature));
	}
	else
	{
		LambdaSigCheckScalarOid(typ->typeoid, typ->location);
	}
}


static void
LambdaSigCheckScalarOid(Oid typeoid, ParseLoc location)
{
	HeapTuple	tup;
	Form_pg_type typform;

	if (!OidIsValid(typeoid))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("invalid type in lambda signature"),
				 parser_errposition(NULL, location)));

	tup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typeoid));

	if (!HeapTupleIsValid(tup))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("cache lookup failed for type %u", typeoid),
				 parser_errposition(NULL, location)));

	typform = (Form_pg_type) GETSTRUCT(tup);

	if (!typform->typisdefined)
	{
		char *typname;

		typname = pstrdup(NameStr(typform->typname));

		ReleaseSysCache(tup);

		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("type \"%s\" is only a shell", typname),
				 parser_errposition(NULL, location)));
	}

	if (typform->typtype == TYPTYPE_PSEUDO)
	{
		char *typname;

		typname = pstrdup(NameStr(typform->typname));

		ReleaseSysCache(tup);

		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TABLE_DEFINITION),
				 errmsg("pseudo-type \"%s\" is not allowed in a stored lambda signature",
						typname),
				 parser_errposition(NULL, location)));
	}

	ReleaseSysCache(tup);
}


/*
 * LambdaSignature -> canonical key.
 */
static void
LambdaSigAppendKey(StringInfo buf, const LambdaSignature *sig)
{
	ListCell   *lc;
	bool		first = true;

	appendStringInfoChar(buf, '(');

	foreach(lc, sig->argtypes)
	{
		LambdaSigType *argtyp;

		if (!first)
			appendStringInfoChar(buf, ',');

		argtyp = lfirst_node(LambdaSigType, lc);
		LambdaSigTypeAppendKey(buf, argtyp);

		first = false;
	}

	appendStringInfoString(buf, ")->");
	LambdaSigTypeAppendKey(buf, castNode(LambdaSigType, sig->rettype));
}


static void
LambdaSigTypeAppendKey(StringInfo buf, const LambdaSigType *typ)
{
	if (typ->is_function)
		LambdaSigAppendKey(buf, castNode(LambdaSignature, typ->signature));
	else
		appendStringInfo(buf, "%u", typ->typeoid);
}


/*
 * LambdaSignature -> canonical display source.
 */
static void
LambdaSigAppendSource(StringInfo buf, const LambdaSignature *sig)
{
	ListCell   *lc;
	bool		first = true;

	appendStringInfoChar(buf, '(');

	foreach(lc, sig->argtypes)
	{
		LambdaSigType *argtyp;

		if (!first)
			appendStringInfoString(buf, ", ");

		argtyp = lfirst_node(LambdaSigType, lc);
		LambdaSigTypeAppendSource(buf, argtyp);

		first = false;
	}

	appendStringInfoString(buf, ") -> ");
	LambdaSigTypeAppendSource(buf, castNode(LambdaSigType, sig->rettype));
}


static void
LambdaSigTypeAppendSource(StringInfo buf, const LambdaSigType *typ)
{
	if (typ->is_function)
	{
		LambdaSigAppendSource(buf, castNode(LambdaSignature,
										   typ->signature));
	}
	else
	{
		char *typname;

		typname = format_type_be(typ->typeoid);
		appendStringInfoString(buf, typname);
		pfree(typname);
	}
}


/*
 * Canonical key -> LambdaSignature. Parses only lamsigkey, lamsigsrc is just for
 * nicer error messages.
 */
static LambdaSignature *
LambdaSigParseKey(const char *sigkey, const char *sigsrc)
{
	LambdaSigParser parser;
	LambdaSignature *sig;

	if (sigkey == NULL)
		elog(ERROR, "cannot parse null lambda signature key");

	parser.start = sigkey;
	parser.ptr = sigkey;
	parser.src = sigsrc;

	sig = LambdaSigParseSignature(&parser);

	if (*parser.ptr != '\0')
		LambdaSigParseError(&parser,
							"trailing junk after lambda signature key");

	LambdaSigValidateSignature(sig);

	return sig;
}


static LambdaSignature *
LambdaSigParseSignature(LambdaSigParser *parser)
{
	LambdaSignature *sig;
	List	   *argtypes = NIL;

	LambdaSigExpect(parser, '(');

	if (!LambdaSigConsume(parser, ')'))
	{
		for (;;)
		{
			argtypes = lappend(argtypes, LambdaSigParseType(parser));

			if (LambdaSigConsume(parser, ','))
				continue;

			LambdaSigExpect(parser, ')');
			break;
		}
	}

	LambdaSigExpect(parser, '-');
	LambdaSigExpect(parser, '>');

	sig = makeNode(LambdaSignature);
	sig->argtypes = argtypes;
	sig->rettype = (Node *) LambdaSigParseType(parser);
	sig->location = -1;

	return sig;
}


static LambdaSigType *
LambdaSigParseType(LambdaSigParser *parser)
{
	LambdaSigType *typ;

	typ = makeNode(LambdaSigType);
	typ->location = -1;

	if (*parser->ptr == '(')
	{
		typ->is_function = true;
		typ->typeoid = InvalidOid;
		typ->signature = (Node *) LambdaSigParseSignature(parser);
	}
	else
	{
		typ->is_function = false;
		typ->typeoid = LambdaSigParseOid(parser);
		typ->signature = NULL;
	}

	return typ;
}


static Oid
LambdaSigParseOid(LambdaSigParser *parser)
{
	unsigned long value;
	char	   *endptr;

	if (*parser->ptr < '0' || *parser->ptr > '9')
		LambdaSigParseError(parser,
							"expected type OID in lambda signature key");

	errno = 0;
	value = strtoul(parser->ptr, &endptr, 10);

	if (endptr == parser->ptr || errno == ERANGE || value > PG_UINT32_MAX)
		LambdaSigParseError(parser,
							"invalid type OID in lambda signature key");

	parser->ptr = endptr;

	return (Oid) value;
}


static bool
LambdaSigConsume(LambdaSigParser *parser, char ch)
{
	if (*parser->ptr == ch)
	{
		parser->ptr++;
		return true;
	}

	return false;
}


static void
LambdaSigExpect(LambdaSigParser *parser, char ch)
{
	if (!LambdaSigConsume(parser, ch))
	{
		char msg[64];

		snprintf(msg, sizeof(msg),
				 "expected '%c' in lambda signature key", ch);

		LambdaSigParseError(parser, msg);
	}
}


static void
LambdaSigParseError(LambdaSigParser *parser, const char *msg)
{
	int offset;

	offset = (int) (parser->ptr - parser->start);

	if (parser->src != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid lambda signature key \"%s\"",
						parser->start),
				 errdetail("%s at byte offset %d; source signature is \"%s\".",
						   msg, offset, parser->src)));
	else
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid lambda signature key \"%s\"",
						parser->start),
				 errdetail("%s at byte offset %d.",
						   msg, offset)));
}