/*-------------------------------------------------------------------------
 *
 * lambda_cache.c
 *	  Runtime cache of built lambda bodies for CallLambdaExpr.
 *
 * A lambda called outside a UDF has its body built (deserialized, flattened if
 * higher-order, const-folded, ExecInitExpr'd) once per lambda combination
 * instead of once per row. Each call site keeps an LRU hash table of at most
 * custom_lambda_cache_size combinations; every entry owns a memory context.
 *
 * Keys are the raw, not detoasted, bytes of the mother lambda and of every
 * lambda-typed argument, so a stored lambda is never decompressed per row. The
 * same value stored differently just gets a second entry. Atomic arguments are
 * bound per row and not part of the key. The cache is per process.
 *
 * Copyright (c) 2026, Clemens Ruck
 *
 * IDENTIFICATION
 *	  src/backend/utils/adt/lambda_cache.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "common/hashfn.h"
#include "executor/executor.h"
#include "jit/jit.h"
#include "lib/ilist.h"
#include "optimizer/optimizer.h"
#include "utils/datum.h"
#include "utils/lambda.h"
#include "utils/memutils.h"

/* hash table slot; entries are referenced, since simplehash moves its slots */
typedef struct LambdaCacheSlot
{
	LambdaCacheEntry *entry;
	uint32		hash;
	char		status;
} LambdaCacheSlot;

/*
 * Compare two keys part by part, by their raw bytes.
 */
static inline bool
lambda_cache_key_equal(const LambdaCacheEntry *a, const LambdaCacheEntry *b)
{
	for (int i = 0; i < a->nparts; i++)
	{
		struct varlena *va;
		struct varlena *vb;
		Size		len;

		if (a->keynull[i] != b->keynull[i])
			return false;
		if (a->keynull[i])
			continue;

		va = (struct varlena *) DatumGetPointer(a->key[i]);
		vb = (struct varlena *) DatumGetPointer(b->key[i]);
		if (va == vb)
			continue;

		len = VARSIZE_ANY(va);
		if (len != VARSIZE_ANY(vb) || memcmp(va, vb, len) != 0)
			return false;
	}

	return true;
}

#define SH_PREFIX			lcache
#define SH_ELEMENT_TYPE		LambdaCacheSlot
#define SH_KEY_TYPE			LambdaCacheEntry *
#define SH_KEY				entry
#define SH_HASH_KEY(tb, key)	((key)->hash)
#define SH_EQUAL(tb, a, b)	lambda_cache_key_equal(a, b)
#define SH_STORE_HASH
#define SH_GET_HASH(tb, a)	((a)->hash)
#define SH_SCOPE			static inline
#define SH_DECLARE
#define SH_DEFINE
#include "lib/simplehash.h"

/*
 * Create the cache of one call site.
 */
static LambdaCache *
lambda_cache_create(CallLambdaExprState *clestate, MemoryContext parent)
{
	MemoryContext cxt;
	LambdaCache *cache;
	int			nparts = 1 + clestate->n_cache_key_args;

	cxt = AllocSetContextCreate(parent, "CallLambdaExpr cache", ALLOCSET_DEFAULT_SIZES);
	cache = MemoryContextAllocZero(cxt, sizeof(LambdaCache));

	cache->cxt = cxt;
	cache->table = lcache_create(cxt, 16, NULL);
	dlist_init(&cache->lru);
	cache->probe.nparts = nparts;
	cache->probe.key = MemoryContextAlloc(cxt, sizeof(Datum) * nparts);
	cache->probe.keynull = MemoryContextAlloc(cxt, sizeof(bool) * nparts);

	return cache;
}

/*
 * Hash a key over the raw bytes of its parts.
 */
static uint32
lambda_cache_hash_key(const LambdaCacheEntry *key)
{
	uint32		hash = 0;

	for (int i = 0; i < key->nparts; i++)
	{
		struct varlena *v;

		if (key->keynull[i])
		{
			hash = hash_combine(hash, 0);
			continue;
		}

		v = (struct varlena *) DatumGetPointer(key->key[i]);
		hash = hash_combine(hash, hash_bytes((const unsigned char *) v, (int) VARSIZE_ANY(v)));
	}

	return hash;
}

/*
 * Build the body for the combination in cache->probe. It starts interpreted
 * unless custom_lambda_jit_after_uses is 0, see lambda_cache_jit.
 */
static LambdaCacheEntry *
lambda_cache_build(ExprState *state, CallLambdaExprState *clestate, LambdaCache *cache)
{
	EState	   *estate = state->parent ? state->parent->state : NULL;
	int			nparts = cache->probe.nparts;
	MemoryContext cxt;
	MemoryContext oldcxt;
	LambdaCacheEntry *entry;
	SerializedLambda *serialized;
	LambdaExpr *le;

	cxt = AllocSetContextCreate(cache->cxt, "CallLambdaExpr cache entry", ALLOCSET_SMALL_SIZES);
	oldcxt = MemoryContextSwitchTo(cxt);

	entry = palloc0(sizeof(LambdaCacheEntry));
	entry->cxt = cxt;
	entry->nparts = nparts;
	entry->hash = cache->probe.hash;
	entry->key = palloc(sizeof(Datum) * nparts);
	entry->keynull = palloc(sizeof(bool) * nparts);

	/* raw copies, possibly still compressed: the bytes are the key */
	for (int i = 0; i < nparts; i++)
	{
		entry->keynull[i] = cache->probe.keynull[i];
		entry->key[i] = entry->keynull[i] ? (Datum) 0 :
			datumCopy(cache->probe.key[i], false, -1);
	}

	serialized = (SerializedLambda *) PG_DETOAST_DATUM(clestate->lambda_value);
	le = lambda_deserialize(serialized);

	if (le == NULL || le->expr == NULL)
		elog(ERROR, "deserialized lambda has no expression body");

	/* the body's param frame has one slot per call argument */
	if (list_length(le->argnames) > clestate->nargs)
		elog(ERROR, "lambda takes %d arguments, call passes %d",
			 list_length(le->argnames), clestate->nargs);

	/* a higher-order mother is flattened into one first-order body */
	if (custom_lambda_hoisting_enabled() && lambda_body_has_lfa(le))
	{
		LambdaExpr *injected;
		int		   *idxbuf = palloc(sizeof(int) * clestate->nargs);
		int			nfunc = lambda_scalar_func_inputs(le,
													  clestate->argvalues,
													  clestate->argnulls,
													  clestate->nargs,
													  idxbuf);

		/* every argument the injector embeds must be part of the key */
		for (int i = 0; i < nfunc; i++)
		{
			int			k = 0;

			while (k < clestate->n_cache_key_args && clestate->cache_key_idx[k] != idxbuf[i])
				k++;
			if (k == clestate->n_cache_key_args)
				elog(ERROR, "lambda argument %d is embedded into the body, but is not lambda-typed",
					 idxbuf[i] + 1);
		}

		injected = lambda_injector_scalar(le,
										  clestate->argvalues,
										  clestate->argnulls,
										  clestate->nargs);
		injected->expr = (Expr *) eval_const_expressions(NULL, (Node *) injected->expr);
		entry->tree = injected->expr;
	}
	else
		entry->tree = le->expr;

	if (estate != NULL && custom_lambda_jit_after_uses != 0)
	{
		int			saved_jit_flags = estate->es_jit_flags;

		estate->es_jit_flags = PGJIT_NONE;
		entry->body = ExecInitExpr(entry->tree, state->parent);
		estate->es_jit_flags = saved_jit_flags;
	}
	else
	{
		/* compiled right away if the query is JIT-compiled, nothing left to do */
		entry->body = ExecInitExpr(entry->tree, state->parent);
		entry->jit_done = true;
	}

	/* the tree was copied out of it, so only keep the detoasted copy if it is the original */
	if ((Pointer) serialized != DatumGetPointer(clestate->lambda_value))
		pfree(serialized);

	MemoryContextSwitchTo(oldcxt);

	return entry;
}

/*
 * Build the entry for cache->probe and add it, evicting least recently used
 * entries while the cache is full.
 */
static LambdaCacheEntry *
lambda_cache_insert(ExprState *state, CallLambdaExprState *clestate, LambdaCache *cache)
{
	LambdaCacheEntry *entry;
	bool		found;

	while (cache->nentries > 0 && cache->nentries >= custom_lambda_cache_size)
	{
		LambdaCacheEntry *victim = dlist_tail_element(LambdaCacheEntry, lru, &cache->lru);

		dlist_delete(&victim->lru);
		lcache_delete(cache->table, victim);
		if (cache->last == victim)
			cache->last = NULL;
		cache->nentries--;
		cache->evictions++;
		MemoryContextDelete(victim->cxt);
	}

	entry = lambda_cache_build(state, clestate, cache);

	lcache_insert_hash(cache->table, entry, entry->hash, &found);
	Assert(!found);
	dlist_push_head(&cache->lru, &entry->lru);
	cache->nentries++;

	return entry;
}

/*
 * Rebuild a body used custom_lambda_jit_after_uses times with the query's JIT
 * flags. JIT code lives until the query ends, so a call site that keeps
 * evicting stops compiling.
 */
static void
lambda_cache_jit(ExprState *state, LambdaCache *cache, LambdaCacheEntry *entry)
{
	MemoryContext oldcxt;

	entry->jit_done = true;

	if (state->parent == NULL ||
		!(state->parent->state->es_jit_flags & PGJIT_PERFORM) ||
		cache->evictions > (uint64) custom_lambda_cache_size)
		return;

	oldcxt = MemoryContextSwitchTo(entry->cxt);
	entry->body = ExecInitExpr(entry->tree, state->parent);
	MemoryContextSwitchTo(oldcxt);
}

/*
 * lambda_cache_body
 *		Return the built body for the current row's lambda combination.
 *
 * The previous row's entry is checked before hashing.
 */
ExprState *
lambda_cache_body(ExprState *state, CallLambdaExprState *clestate)
{
	LambdaCache *cache = clestate->cache;
	LambdaCacheEntry *entry;

	if (cache == NULL)
	{
		/* a cache nested in a cached body is freed with its entry */
		cache = lambda_cache_create(clestate, GetMemoryChunkContext(clestate));
		clestate->cache = cache;
	}

	cache->probe.key[0] = clestate->lambda_value;
	cache->probe.keynull[0] = false;
	for (int i = 0; i < clestate->n_cache_key_args; i++)
	{
		int			idx = clestate->cache_key_idx[i];

		cache->probe.key[i + 1] = clestate->argvalues[idx];
		cache->probe.keynull[i + 1] = clestate->argnulls[idx];
	}

	entry = cache->last;
	if (entry == NULL || !lambda_cache_key_equal(entry, &cache->probe))
	{
		LambdaCacheSlot *slot;

		cache->probe.hash = lambda_cache_hash_key(&cache->probe);
		slot = lcache_lookup_hash(cache->table, &cache->probe, cache->probe.hash);

		if (slot != NULL)
		{
			entry = slot->entry;
			dlist_move_head(&cache->lru, &entry->lru);
		}
		else
			entry = lambda_cache_insert(state, clestate, cache);

		cache->last = entry;
	}

	entry->uses++;
	if (!entry->jit_done && custom_lambda_jit_after_uses > 0 &&
		entry->uses >= (uint64) custom_lambda_jit_after_uses)
		lambda_cache_jit(state, cache, entry);

	return entry->body;
}
