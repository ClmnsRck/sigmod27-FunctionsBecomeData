/*-------------------------------------------------------------------------
 *
 * llvmjit_inline.cpp
 *	  Cross module inlining suitable for postgres' JIT
 *
 * The inliner iterates over external functions referenced from the passed
 * module and attempts to inline those.  It does so by utilizing pre-built
 * indexes over both postgres core code and extension modules.  When a match
 * for an external function is found - not guaranteed! - the index will then
 * be used to judge their instruction count / inline worthiness. After doing
 * so for all external functions, all the referenced functions (and
 * prerequisites) will be imported.
 *
 * Copyright (c) 2016-2024, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/backend/lib/llvmjit/llvmjit_inline.cpp
 *
 *-------------------------------------------------------------------------
 */

extern "C"
{
#include "postgres.h"
}

#include "jit/llvmjit.h"

extern "C"
{
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "common/string.h"
#include "miscadmin.h"
#include "storage/fd.h"
#include "nodes/value.h"
}

#include <llvm-c/Core.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm-c/BitReader.h>
#include <llvm-c/BitWriter.h>

/* Avoid macro clash with LLVM's C++ headers */
#undef Min

#include <llvm/ADT/SetVector.h>
#include <llvm/ADT/StringSet.h>
#include <llvm/ADT/StringMap.h>
#include <llvm/Analysis/ModuleSummaryAnalysis.h>
#include <llvm/Transforms/Utils/BasicBlockUtils.h>
#include <llvm/Bitcode/BitcodeReader.h>
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/Attributes.h>
#include <llvm/IR/DebugInfo.h>
#include <llvm/IR/IntrinsicInst.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/ModuleSummaryIndex.h>
#include <llvm/IR/LegacyPassManager.h>
#include <llvm/IR/Verifier.h>
#include <llvm/Linker/IRMover.h>
#include <llvm/Linker/Linker.h>
#include <llvm/Support/ManagedStatic.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Transforms/Utils/Cloning.h>

#include <ctime>

/*
 * Type used to represent modules InlineWorkListItem's subject is searched for
 * in.
 */
typedef llvm::SmallVector<llvm::ModuleSummaryIndex *, 2> InlineSearchPath;

/*
 * Item in queue of to-be-checked symbols and corresponding queue.
 */
typedef struct InlineWorkListItem
{
	llvm::StringRef symbolName;
	llvm::SmallVector<llvm::ModuleSummaryIndex *, 2> searchpath;
} InlineWorkListItem;
typedef llvm::SmallVector<InlineWorkListItem, 128> InlineWorkList;

/*
 * Information about symbols processed during inlining. Used to prevent
 * repeated searches and provide additional information.
 */
typedef struct FunctionInlineState
{
	int costLimit;
	bool processed;
	bool inlined;
	bool allowReconsidering;
} FunctionInlineState;
typedef llvm::StringMap<FunctionInlineState> FunctionInlineStates;

/*
 * Map of modules that should be inlined, with a list of the to-be inlined
 * symbols.
 */
typedef llvm::StringMap<llvm::StringSet<> > ImportMapTy;


const float inline_cost_decay_factor = 0.5;
const int inline_initial_cost = 0; //determined very scientifically!

/*
 * These are managed statics so LLVM knows to deallocate them during an
 * LLVMShutdown(), rather than after (which'd cause crashes).
 */
typedef llvm::StringMap<std::unique_ptr<llvm::Module> > ModuleCache;
llvm::ManagedStatic<ModuleCache> module_cache;
typedef llvm::StringMap<std::unique_ptr<llvm::ModuleSummaryIndex> > SummaryCache;
llvm::ManagedStatic<SummaryCache> summary_cache;


static std::unique_ptr<ImportMapTy> llvm_build_inline_plan(LLVMContextRef lc, llvm::Module *mod);
static void llvm_execute_inline_plan(llvm::Module *mod,
									 ImportMapTy *globalsToInline);

static llvm::Module* load_module_cached(LLVMContextRef c, llvm::StringRef modPath);
static std::unique_ptr<llvm::Module> load_module(LLVMContextRef c, llvm::StringRef Identifier);
static std::unique_ptr<llvm::ModuleSummaryIndex> llvm_load_summary(llvm::StringRef path);


static llvm::Function* create_redirection_function(std::unique_ptr<llvm::Module> &importMod,
												   llvm::Function *F,
												   llvm::StringRef Name);

static bool function_inlinable(llvm::Function &F,
							   int threshold,
							   FunctionInlineStates &functionState,
							   InlineWorkList &worklist,
							   InlineSearchPath &searchpath,
							   llvm::SmallPtrSet<const llvm::Function *, 8> &visitedFunctions,
							   int &running_instcount,
							   llvm::StringSet<> &importVars);
static void function_references(llvm::Function &F,
								int &running_instcount,
								llvm::SmallPtrSet<llvm::GlobalVariable *, 8> &referencedVars,
								llvm::SmallPtrSet<llvm::Function *, 8> &referencedFunctions);

class LambdaInjectionPass : public llvm::FunctionPass {
	public:
		static char id;
		LambdaInjectionPass(LLVMJitContext* context, int numLambdas) : llvm::FunctionPass(id),
		m_context(context), m_numLambdas(numLambdas) {}
		virtual bool runOnFunction(llvm::Function &F) override;

	private:
		LLVMJitContext *m_context;
		int m_numLambdas;
};

static void add_module_to_inline_search_path(InlineSearchPath& path, llvm::StringRef modpath);
static llvm::SmallVector<llvm::GlobalValueSummary *, 1>
summaries_for_guid(const InlineSearchPath& path, llvm::GlobalValue::GUID guid);

/* verbose debugging for inliner development */
/* #define INLINE_DEBUG */
#ifdef INLINE_DEBUG
#define ilog		elog
#else
#define ilog(...)	(void) 0
#endif

char LambdaInjectionPass::id = 0;

/*
 * This LLVM pass will directly inject lambda expression evaluation calls into
 * a tablefunction by searching for calls to ExecEvalLambdaExpr or
 * ExecEvalSimpleLambdaExpr and afterwards replacing
 * them by calls to the JIT-compiled lambda expression. In addition, they get
 * flagged as AlwaysInline, so they will eventually be inlined by the optimizer.
 */
bool LambdaInjectionPass::runOnFunction(llvm::Function &F) {
	llvm::Function* fn;
	llvm::LLVMContext &Context = F.getContext();
	llvm::IRBuilder<> Builder(Context);
	llvm::SmallVector<std::pair<llvm::Instruction*, llvm::Instruction*>, 8> replacements;

	bool changed = false;

	for (llvm::BasicBlock &BB : F)
	{
		for (llvm::Instruction &II : BB)
		{
			llvm::Instruction *I = &II;
			llvm::CallInst *op;

			if ((op = llvm::dyn_cast<llvm::CallInst>(I)) && (fn = op->getCalledFunction()))
			{
				if (fn->getName() == "ExecEvalLambdaExpr")
				{
					char *funcname;

					int idx = -1;

					if (auto argIdx = llvm::dyn_cast<llvm::ConstantInt>(op->getArgOperand(3)))
					{
						idx = argIdx->getSExtValue();
					}

					if (idx < 0 || idx >= list_length(m_context->funcnames))
					{
						ereport(ERROR,
								(errcode(ERRCODE_INTERNAL_ERROR),
								 errmsg("Invalid lambda expression index passed to"
										"PG_LAMBDA_INJECT. Plese give an immediate between 0 and %i.",
										list_length(m_context->funcnames) - 1)));
					}

					funcname = strVal(list_nth(m_context->funcnames, idx));
					F.getParent()->getFunction(funcname)->addFnAttr(llvm::Attribute::AlwaysInline);
					op->setCalledFunction(F.getParent()->getFunction(funcname));
					changed = true;
				}
				else if (fn->getName() == "ExecEvalSimpleLambdaExpr")
				{
					char *funcname = NULL;
					llvm::CallInst *newCall;

					int idx = -1;

					if (auto argIdx = llvm::dyn_cast<llvm::ConstantInt>(op->getArgOperand(1)))
					{
						idx = argIdx->getSExtValue();
					}

					if (idx < 0 || idx >= list_length(m_context->simpleFuncnames))
					{
						ereport(ERROR,
								(errcode(ERRCODE_INTERNAL_ERROR),
								 errmsg("Invalid lambda expression index passed to"
										"PG_SIMPLE_LAMBDA_INJECT. Plese give an immediate between 0 and %i.",
										list_length(m_context->simpleFuncnames) - 1)));
					}

					funcname = strVal(list_nth(m_context->simpleFuncnames, idx));
					F.getParent()->getFunction(funcname)->addFnAttr(llvm::Attribute::AlwaysInline);

					newCall = llvm::CallInst::Create(F.getParent()->getFunction(funcname),
													 {op->getArgOperand(0)});
					replacements.push_back(std::make_pair(llvm::dyn_cast<llvm::Instruction>(op),
														  llvm::dyn_cast<llvm::Instruction>(newCall)));
					changed = true;
				}
				else if (fn->getName() == "ExecEvalSimpleLambdaDerive") //for derivation
				{
					char *funcname = NULL;
					llvm::CallInst *newCall;

					int idx = -1;

					if (auto argIdx = llvm::dyn_cast<llvm::ConstantInt>(op->getArgOperand(2)))
					{
						idx = argIdx->getSExtValue();
					}

					if (idx < 0 || idx >= list_length(m_context->simpleFuncnames))
					{
						ereport(ERROR,
								(errcode(ERRCODE_INTERNAL_ERROR),
								 errmsg("Invalid lambda expression index passed to"
										"PG_SIMPLE_LAMBDA_INJECT_DERIV. Please give an idx between 0 and %i.",
										list_length(m_context->simpleFuncnames) - 1)));
					}

					funcname = strVal(list_nth(m_context->simpleFuncnames, idx));
					F.getParent()->getFunction(funcname)->addFnAttr(llvm::Attribute::AlwaysInline);

					newCall = llvm::CallInst::Create(F.getParent()->getFunction(funcname),
													 {op->getArgOperand(0), op->getArgOperand(1)});
					replacements.push_back(std::make_pair(llvm::dyn_cast<llvm::Instruction>(op),
														  llvm::dyn_cast<llvm::Instruction>(newCall)));
					changed = true;
				}
			}
		}
	}

	for (auto& el : replacements)
    {
    	llvm::ReplaceInstWithInst(el.first, el.second);
    }

	m_context->funcnames = NIL;
	m_context->simpleFuncnames = NIL;

    return changed;
}

/*
 * Reset inlining related state. This needs to be called before the currently
 * used LLVMContextRef is disposed (and a new one create), otherwise we would
 * have dangling references to deleted modules.
 */
void
llvm_inline_reset_caches(void)
{
	module_cache->clear();
	summary_cache->clear();
}

/*
 * Perform inlining of external function references in M based on a simple
 * cost based analysis.
 */
void
llvm_inline(LLVMModuleRef M)
{
	LLVMContextRef lc = LLVMGetModuleContext(M);
	llvm::Module *mod = llvm::unwrap(M);

	std::unique_ptr<ImportMapTy> globalsToInline = llvm_build_inline_plan(lc, mod);
	if (!globalsToInline)
		return;
	llvm_execute_inline_plan(mod, globalsToInline.get());
}


/*
 * Loads the bitcode of a C extension named bcModule, locates the function named
 * funcName in it and injects numLambdas lambda expressions into it. The lambda
 * expressions must be contained in the passed LLVMJitContext after having been
 * initialized via a call to ExecInitLambdaExpr.
 * 
 * In the C extension, the PG_LAMBDA_INJECT or PG_SIMPLE_LAMBDA_INJECT macros must
 * be used as placeholders for the lambda return values as follows: 
 *
 * [1] PG_LAMBDA_INJECT(LambdaExpr *, int, bool *)
 * [2] PG_SIMPLE_LAMBDA_INJECT(Datum **, int)
 *
 * For fully-featured lambda expressions [1], the LambdaExpr must be passed to 
 * the macro and a bool value indicating whether the lambda result is NULL
 * will be written to the specified bool pointer. The lambda parameters must
 * have been set with the PG_LAMBDA_SETARG macro beforehand.
 *
 * For fast ("simple") lambda expressions [2], a Datum** pointer holding the
 * parameters must be passed to the macro. The first indirection selects 
 * a row and the second indirection selects a Datum value from the row.
 *
 * For both [1] and [2], the int parameter specifies the index of the lambda
 * expression in the order all the lambda expressions have been initialized with
 * ExecInitLambdaExpr, i.e. the int value must be in [0, n) with n being the total
 * number of lambda expressions used in the function.  
 *
 * The function returns a pointer to the ready-to-be-executed function having the
 * same signature as the C function it originates from.
 * 
 * EDIT:
 * 
 * For derivation functions, the following MACRO will be added:
 * 
 * [3] PG_SIMPLE_LAMBDA_DERIVE(Datum **, Datum *, int)
 * 
 * where the first Datum pointer pointer is the pointer to the input values, 
 * whilst the second one is the pointer, where the result derivations
 * should be stored after the derivation-evaluation. The int denotes the number 
 * of the lambda function in the function call, which currently is only the one.
 */
Datum (*llvm_prepare_lambda_tablefunc(LLVMJitContext *context,
	char* bcModule, char* funcName, int numLambdas))(PG_FUNCTION_ARGS)
{
	#define DIAG_STREAM (*debugOut)
	static const bool enableDiagnostics = true;
	const std::string diagFolder = "/tmp/llvm_lambda_debug/";

	llvm::SmallVector<llvm::Function*, 8> funcsToDelete;
	llvm::Module* mod;
	llvm::Function* func;
	Datum (*funcPtr)(FunctionCallInfo);

	// Ensure diagnostic directory exists
	if (enableDiagnostics)
	{
		llvm::sys::fs::create_directory(diagFolder);
	}

	// Redirect llvm::errs() to a debug log file once using a custom stream
	static std::unique_ptr<llvm::raw_fd_ostream> debugOut;
	if (enableDiagnostics && !debugOut)
	{
		std::error_code EC;
		auto stream = std::make_unique<llvm::raw_fd_ostream>(diagFolder + "diag.txt", EC, llvm::sys::fs::OF_Text);
		if (EC)
			ereport(ERROR, (errmsg("Could not open diag file: %s", EC.message().c_str())));
		stream->SetUnbuffered();
		time_t now = time(nullptr);
		*stream << "=== llvm_prepare_lambda_tablefunc diagnostics ===\n";
		*stream << "Timestamp: " << std::asctime(std::localtime(&now)) << "\n";
		debugOut = std::move(stream);
	}

	// Load bitcode module from disk
	auto path_str = std::string(pkglib_path) + "/bitcode/" + bcModule;
	auto buffer = llvm::MemoryBuffer::getFile(path_str);
	if (!buffer)
	{
		ereport(ERROR,
			(errcode(ERRCODE_INTERNAL_ERROR),
			 errmsg("Error reading bitcode file: %s", bcModule)));
	}
	auto bufferSanitized = std::move(buffer.get());
	auto lc = LLVMGetModuleContext(llvm_mutable_module(context));
	auto moduleLoaded = llvm::parseBitcodeFile(bufferSanitized->getMemBufferRef(),
												 *reinterpret_cast<llvm::LLVMContext *>((lc)));
	if (!moduleLoaded)
	{
		ereport(ERROR,
			(errcode(ERRCODE_INTERNAL_ERROR),
			 errmsg("Error parsing bitcode file: %s", bcModule)));
	}
	auto tfMod = std::move(moduleLoaded.get());

	// Check if target function exists in tfMod
	if (enableDiagnostics)
	{
		auto tfFunc = tfMod->getFunction(funcName);
		if (!tfFunc)
		{
			DIAG_STREAM << "[ERROR] Function " << funcName << " not found in tfMod before linking\n";
		}
		else
		{
			DIAG_STREAM << "[OK] Function " << funcName << " exists in tfMod before linking\n";
		}
	}

	// Prepare target module context from JIT environment
	if (!context->compiled)
	{
		if (list_length(context->funcnames) > numLambdas)
			context->moduleCopy = LLVMCloneModule(context->module);

		mod = llvm::unwrap(context->module);

		if (enableDiagnostics && llvm::verifyModule(*mod, &llvm::errs()))
		{
			DIAG_STREAM << "[FATAL] LLVMVerifyModule failed immediately after unwrap (context->module)\n";
			DIAG_STREAM << "[SKIP] Skipped bitcode write due to broken module (would crash).\n";
		}
	}
	else
	{
		context->compiled = false;
		context->module = LLVMCloneModule(context->moduleCopy);
		mod = llvm::unwrap(context->module);

		if (enableDiagnostics && llvm::verifyModule(*mod, &llvm::errs()))
		{
			DIAG_STREAM << "[FATAL] LLVMVerifyModule failed after LLVMCloneModule\n";
			DIAG_STREAM << "[SKIP] Skipped bitcode write due to broken module (would crash).\n";
		}
	}

	// Ensure both modules are valid before proceeding
	if (!mod)
		ereport(ERROR, (errmsg("llvm_prepare_lambda_tablefunc: mod is NULL")));
	if (!tfMod)
		ereport(ERROR, (errmsg("llvm_prepare_lambda_tablefunc: tfMod is NULL")));

	if (enableDiagnostics)
	{
		DIAG_STREAM << "Context equality check: "
		             << (mod->getContext().pImpl == tfMod->getContext().pImpl ? "SAME" : "DIFFERENT") << "\n";
		DIAG_STREAM << "DataLayout string: " << mod->getDataLayout().getStringRepresentation() << "\n";

		DIAG_STREAM << "--- tfMod BEFORE LINK ---\n";
		tfMod->print(DIAG_STREAM, nullptr);
		DIAG_STREAM << "Functions in tfMod: " << tfMod->getFunctionList().size() << "\n";
		for (auto &F : tfMod->functions())
			DIAG_STREAM << " - " << F.getName() << "\n";

		DIAG_STREAM << "--- mod BEFORE LINK ---\n";
		DIAG_STREAM << "Functions in mod: " << mod->getFunctionList().size() << "\n";
		DIAG_STREAM << "Struct types in mod: " << mod->getIdentifiedStructTypes().size() << "\n";
		if (!llvm::verifyModule(*mod, &llvm::errs())) {
			std::error_code EC;
			llvm::raw_fd_ostream out(diagFolder + "mod_valid_beforelink.bc", EC);
			llvm::WriteBitcodeToFile(*mod, out);
		} else {
			DIAG_STREAM << "LLVMVerifyModule failed BEFORE print\n";
			DIAG_STREAM << "[SKIP] Skipped bitcode write due to broken module (would crash).\n";
		}
	}

	// Link tfMod into mod using safer linker API and automatic function filtering
	llvm::legacy::FunctionPassManager FPM(tfMod.get());
	llvm::Linker linker(*mod);
	llvm::Linker::Flags linkFlags = llvm::Linker::Flags::None; //LinkOnlyNeeded;
	bool failed = linker.linkInModule(std::move(tfMod), linkFlags);
	if (failed)
		ereport(ERROR, (errmsg("Linking module failed.")));

	// Retrieve function from mod
	func = mod->getFunction(funcName);
	if (!func)
	{
		if (enableDiagnostics)
			DIAG_STREAM << "[ERROR] Function " << funcName << " not found in mod after linking\n";
		ereport(ERROR, (errmsg("Function %s not found after linking", funcName)));
	}

	// Run lambda inlining optimization pass
	FPM.add(new LambdaInjectionPass(context, numLambdas));
	FPM.run(*func);

	// Retrieve JIT entry point to compiled function
	funcPtr = (Datum (*)(FunctionCallInfo)) llvm_get_function(context, funcName);
	return funcPtr;
}

/*
* JIT-compiles a simple lambda expression.
*/
Datum (*llvm_prepare_simple_expression(ExprState *state))(Datum **)
{
	CompiledExprState *cstate = (CompiledExprState *) state->evalfunc_simple_private;
	Datum (*func)(Datum**);

	llvm_enter_fatal_on_oom();
	func = (Datum (*)(Datum **)) llvm_get_function(cstate->context,
												cstate->funcname);
	llvm_leave_fatal_on_oom();
	Assert(func);
	return func;
}

/*
* JIT-compiles a simple lambda expression.
*/
Datum (*llvm_prepare_simple_expression_derivation(ExprState *state))(Datum **, Datum *)
{
	if(state->derivefunc_simple_private == NULL) {
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				errmsg("Derive_func(L3) could not be compiled! Is jit enabled? (set jit='on';)")));
	}
	CompiledExprState *cstate = (CompiledExprState *)state->derivefunc_simple_private;
	Datum (*func)(Datum **, Datum *);

	llvm_enter_fatal_on_oom();
	func = (Datum(*)(Datum **, Datum *))llvm_get_function(cstate->context,
														cstate->funcname);
	llvm_leave_fatal_on_oom();
	Assert(func);
	return func;
}

/*
 * Build information necessary for inlining external function references in
 * mod.
 */
static std::unique_ptr<ImportMapTy>
llvm_build_inline_plan(LLVMContextRef lc, llvm::Module *mod)
{
	std::unique_ptr<ImportMapTy> globalsToInline(new ImportMapTy());
	FunctionInlineStates functionStates;
	InlineWorkList worklist;

	InlineSearchPath defaultSearchPath;

	/* attempt to add module to search path */
	add_module_to_inline_search_path(defaultSearchPath, "$libdir/postgres");
	/* if postgres isn't available, no point continuing */
	if (defaultSearchPath.empty())
		return nullptr;

	/*
	 * Start inlining with current references to external functions by putting
	 * them on the inlining worklist. If, during inlining of those, new extern
	 * functions need to be inlined, they'll also be put there, with a lower
	 * priority.
	 */
	for (const llvm::Function &funcDecl : mod->functions())
	{
		InlineWorkListItem item = {};
		FunctionInlineState inlineState = {};

		/* already has a definition */
		if (!funcDecl.isDeclaration())
			continue;

		/* llvm provides implementation */
		if (funcDecl.isIntrinsic())
			continue;

		item.symbolName = funcDecl.getName();
		item.searchpath = defaultSearchPath;
		worklist.push_back(item);
		inlineState.costLimit = inline_initial_cost;
		inlineState.processed = false;
		inlineState.inlined = false;
		inlineState.allowReconsidering = false;
		functionStates[funcDecl.getName()] = inlineState;
	}

	/*
	 * Iterate over pending worklist items, look them up in index, check
	 * whether they should be inlined.
	 */
	while (!worklist.empty())
	{
		InlineWorkListItem item = worklist.pop_back_val();
		llvm::StringRef symbolName = item.symbolName;
		char *cmodname;
		char *cfuncname;
		FunctionInlineState &inlineState = functionStates[symbolName];
		llvm::GlobalValue::GUID funcGUID;

		llvm_split_symbol_name(symbolName.data(), &cmodname, &cfuncname);

		funcGUID = llvm::GlobalValue::getGUID(cfuncname);

		/* already processed */
		if (inlineState.processed)
			continue;


		if (cmodname)
			add_module_to_inline_search_path(item.searchpath, cmodname);

		/*
		 * Iterate over all known definitions of function, via the index. Then
		 * look up module(s), check if function actually is defined (there
		 * could be hash conflicts).
		 */
		for (const auto &gvs : summaries_for_guid(item.searchpath, funcGUID))
		{
			const llvm::FunctionSummary *fs;
			llvm::StringRef modPath = gvs->modulePath();
			llvm::Module *defMod;
			llvm::Function *funcDef;

			fs = llvm::cast<llvm::FunctionSummary>(gvs);

			if (gvs->notEligibleToImport())
			{
				ilog(DEBUG1, "ineligibile to import %s due to summary",
					 symbolName.data());
				continue;
			}

			if ((int) fs->instCount() > inlineState.costLimit && !(symbolName == "ExecEvalLambdaExpr" || symbolName == "ExecEvalFastParamExtern" || symbolName == "ExecEvalFastFieldSelect"))
			{
				ilog(DEBUG1, "ineligibile to import %s due to early threshold: %u vs %u",
					 symbolName.data(), fs->instCount(), inlineState.costLimit);
				inlineState.allowReconsidering = true;
				continue;
			}

			defMod = load_module_cached(lc, modPath);
			if (defMod->materializeMetadata())
				elog(FATAL, "failed to materialize metadata");

			funcDef = defMod->getFunction(cfuncname);

			/*
			 * This can happen e.g. in case of a hash collision of the
			 * function's name.
			 */
			if (!funcDef)
				continue;

			if (funcDef->materialize())
				elog(FATAL, "failed to materialize metadata");

			Assert(!funcDef->isDeclaration());
			Assert(funcDef->hasExternalLinkage());

			llvm::StringSet<> importVars;
			llvm::SmallPtrSet<const llvm::Function *, 8> visitedFunctions;
			int running_instcount = 0;

			/*
			 * Check whether function, and objects it depends on, are
			 * inlinable.
			 */
			if (function_inlinable(*funcDef,
								   inlineState.costLimit,
								   functionStates,
								   worklist,
								   item.searchpath,
								   visitedFunctions,
								   running_instcount,
								   importVars))
			{
				/*
				 * Check whether function and all its dependencies are too
				 * big. Dependencies already counted for other functions that
				 * will get inlined are not counted again. While this make
				 * things somewhat order dependent, I can't quite see a point
				 * in a different behaviour.
				 */
				if (running_instcount > inlineState.costLimit)
				{
					ilog(DEBUG1, "skipping inlining of %s due to late threshold %d vs %d",
						 symbolName.data(), running_instcount, inlineState.costLimit);
					inlineState.allowReconsidering = true;
					continue;
				}

				ilog(DEBUG1, "inline top function %s total_instcount: %d, partial: %d",
					 symbolName.data(), running_instcount, fs->instCount());

				/* import referenced function itself */
				importVars.insert(symbolName);

				{
					llvm::StringSet<> &modGlobalsToInline = (*globalsToInline)[modPath];
					for (auto& importVar : importVars)
						modGlobalsToInline.insert(importVar.first());
					Assert(modGlobalsToInline.size() > 0);
				}

				/* mark function as inlined */
				inlineState.inlined = true;

				/*
				 * Found definition to inline, don't look for further
				 * potential definitions.
				 */
				break;
			}
			else
			{
				ilog(DEBUG1, "had to skip inlining %s",
					 symbolName.data());

				/* It's possible there's another definition that's inlinable. */
			}
		}

		/*
		 * Signal that we're done with symbol, whether successful (inlined =
		 * true above) or not.
		 */
		inlineState.processed = true;
	}

	return globalsToInline;
}

/*
 * Perform the actual inlining of external functions (and their dependencies)
 * into mod.
 */
static void
llvm_execute_inline_plan(llvm::Module *mod, ImportMapTy *globalsToInline)
{
	llvm::IRMover Mover(*mod);

	for (const auto& toInline : *globalsToInline)
	{
		const llvm::StringRef& modPath = toInline.first();
		const llvm::StringSet<>& modGlobalsToInline = toInline.second;
		llvm::SetVector<llvm::GlobalValue *> GlobalsToImport;

		Assert(module_cache->count(modPath));
		std::unique_ptr<llvm::Module> importMod(std::move((*module_cache)[modPath]));
		module_cache->erase(modPath);

		if (modGlobalsToInline.empty())
			continue;

		for (auto &glob: modGlobalsToInline)
		{
			llvm::StringRef SymbolName = glob.first();
			char *modname;
			char *funcname;

			llvm_split_symbol_name(SymbolName.data(), &modname, &funcname);

			llvm::GlobalValue *valueToImport = importMod->getNamedValue(funcname);

			if (!valueToImport)
				elog(FATAL, "didn't refind value %s to import", SymbolName.data());
			
			ilog(DEBUG1, "Inlining %s\n", funcname);
			/*
			 * For functions (global vars are only inlined if already static),
			 * mark imported variables as being clones from other
			 * functions. That a) avoids symbol conflicts b) allows the
			 * optimizer to perform inlining.
			*/
			if (llvm::isa<llvm::Function>(valueToImport))
			{
				llvm::Function *F = llvm::dyn_cast<llvm::Function>(valueToImport);
				typedef llvm::GlobalValue::LinkageTypes LinkageTypes;

				/*
				 * Per-function info isn't necessarily stripped yet, as the
				 * module is lazy-loaded when stripped above.
				 */
				llvm::stripDebugInfo(*F);

				/*
				 * If the to-be-imported function is one referenced including
				 * its module name, create a tiny inline function that just
				 * forwards the call. One might think a GlobalAlias would do
				 * the trick, but a) IRMover doesn't override a declaration
				 * with an alias pointing to a definition (instead renaming
				 * it), b) Aliases can't be AvailableExternally.
				 */
				if (modname)
				{
					llvm::Function *AF;

					AF = create_redirection_function(importMod, F, SymbolName);

					GlobalsToImport.insert(AF);
					llvm::stripDebugInfo(*AF);
				}

				if (valueToImport->hasExternalLinkage())
				{
					valueToImport->setLinkage(LinkageTypes::AvailableExternallyLinkage);
				}
			}

			GlobalsToImport.insert(valueToImport);
			ilog(DEBUG1, "performing import of %s %s",
				 modPath.data(), SymbolName.data());

		}

		if (Mover.move(std::move(importMod), GlobalsToImport.getArrayRef(),
					   [](llvm::GlobalValue &, llvm::IRMover::ValueAdder) {},
					   /*IsPerformingImport=*/false))
			elog(FATAL, "function import failed with linker error");
	}
}

/*
 * Return a module identified by modPath, caching it in memory.
 *
 * Note that such a module may *not* be modified without copying, otherwise
 * the cache state would get corrupted.
 */
static llvm::Module*
load_module_cached(LLVMContextRef lc, llvm::StringRef modPath)
{
	auto it = module_cache->find(modPath);
	if (it == module_cache->end())
	{
		it = module_cache->insert(
			std::make_pair(modPath, load_module(lc, modPath))).first;
	}

	return it->second.get();
}

static std::unique_ptr<llvm::Module>
load_module(LLVMContextRef lc, llvm::StringRef Identifier)
{
	LLVMMemoryBufferRef buf;
	LLVMModuleRef mod;
	char path[MAXPGPATH];
	char *msg;

	snprintf(path, MAXPGPATH,"%s/bitcode/%s", pkglib_path, Identifier.data());

	if (LLVMCreateMemoryBufferWithContentsOfFile(path, &buf, &msg))
		elog(FATAL, "failed to open bitcode file \"%s\": %s",
			 path, msg);
	if (LLVMGetBitcodeModuleInContext2(lc, buf, &mod))
		elog(FATAL, "failed to parse bitcode in file \"%s\"", path);

	/*
	 * Currently there's no use in more detailed debug info for JITed
	 * code. Until that changes, not much point in wasting memory and cycles
	 * on processing debuginfo.
	 */
	llvm::StripDebugInfo(*llvm::unwrap(mod));

	return std::unique_ptr<llvm::Module>(llvm::unwrap(mod));
}

/*
 * Compute list of referenced variables, functions and the instruction count
 * for a function.
 */
static void
function_references(llvm::Function &F,
					int &running_instcount,
					llvm::SmallPtrSet<llvm::GlobalVariable *, 8> &referencedVars,
					llvm::SmallPtrSet<llvm::Function *, 8> &referencedFunctions)
{
	llvm::SmallPtrSet<const llvm::User *, 32> Visited;

	for (llvm::BasicBlock &BB : F)
	{
		for (llvm::Instruction &I : BB)
		{
			if (llvm::isa<llvm::DbgInfoIntrinsic>(I))
				continue;

			llvm::SmallVector<llvm::User *, 8> Worklist;
			Worklist.push_back(&I);

			running_instcount++;

			while (!Worklist.empty()) {
				llvm::User *U = Worklist.pop_back_val();

				/* visited before */
				if (!Visited.insert(U).second)
					continue;

				for (auto &OI : U->operands()) {
					llvm::User *Operand = llvm::dyn_cast<llvm::User>(OI);
					if (!Operand)
						continue;
					if (llvm::isa<llvm::BlockAddress>(Operand))
						continue;
					if (auto *GV = llvm::dyn_cast<llvm::GlobalVariable>(Operand)) {
						referencedVars.insert(GV);
						if (GV->hasInitializer())
							Worklist.push_back(GV->getInitializer());
						continue;
					}
					if (auto *CF = llvm::dyn_cast<llvm::Function>(Operand)) {
						referencedFunctions.insert(CF);
						continue;
					}
					Worklist.push_back(Operand);
				}
			}
		}
	}
}

/*
 * Check whether function F is inlinable and, if so, what globals need to be
 * imported.
 *
 * References to external functions from, potentially recursively, inlined
 * functions are added to the passed in worklist.
 */
static bool
function_inlinable(llvm::Function &F,
				   int threshold,
				   FunctionInlineStates &functionStates,
				   InlineWorkList &worklist,
				   InlineSearchPath &searchpath,
				   llvm::SmallPtrSet<const llvm::Function *, 8> &visitedFunctions,
				   int &running_instcount,
				   llvm::StringSet<> &importVars)
{
	int subThreshold = threshold * inline_cost_decay_factor;
	llvm::SmallPtrSet<llvm::GlobalVariable *, 8> referencedVars;
	llvm::SmallPtrSet<llvm::Function *, 8> referencedFunctions;

	/* can't rely on what may be inlined */
	if (F.isInterposable())
		return false;

	/*
	 * Can't rely on function being present. Alternatively we could create a
	 * static version of these functions?
	 */
	if (F.hasAvailableExternallyLinkage())
		return false;

	ilog(DEBUG1, "checking inlinability of %s", F.getName().data());

	if (F.materialize())
		elog(FATAL, "failed to materialize metadata");

#if LLVM_VERSION_MAJOR < 14
#define hasFnAttr hasFnAttribute
#endif

	if (F.getAttributes().hasFnAttr(llvm::Attribute::NoInline))
	{
		ilog(DEBUG1, "ineligibile to import %s due to noinline",
			 F.getName().data());
		return false;
	}

	function_references(F, running_instcount, referencedVars, referencedFunctions);

	for (llvm::GlobalVariable* rv: referencedVars)
	{
		if (rv->materialize())
			elog(FATAL, "failed to materialize metadata");

		/*
		 * Don't inline functions that access thread local variables.  That
		 * doesn't work on current LLVM releases (but might in future).
		 */
		if (rv->isThreadLocal())
		{
			ilog(DEBUG1, "cannot inline %s due to thread-local variable %s",
				 F.getName().data(), rv->getName().data());
			return false;
		}

		/*
		 * Never want to inline externally visible vars, cheap enough to
		 * reference.
		 */
		if (rv->hasExternalLinkage() || rv->hasAvailableExternallyLinkage())
			continue;

		/*
		 * If variable is file-local, we need to inline it, to be able to
		 * inline the function itself. Can't do that if the variable can be
		 * modified, because they'd obviously get out of sync.
		 *
		 * XXX: Currently not a problem, but there'd be problems with
		 * nontrivial initializers if they were allowed for postgres.
		 */
		if (!rv->isConstant())
		{
			ilog(DEBUG1, "cannot inline %s due to uncloneable variable %s",
				 F.getName().data(), rv->getName().data());
			return false;
		}

		ilog(DEBUG1, "memorizing global var %s linkage %d for inlining",
			 rv->getName().data(), (int)rv->getLinkage());

		importVars.insert(rv->getName());
		/* small cost attributed to each cloned global */
		running_instcount += 5;
	}

	visitedFunctions.insert(&F);

	/*
	 * Check referenced functions. Check whether used static ones are
	 * inlinable, and remember external ones for inlining.
	 */
	for (llvm::Function* referencedFunction: referencedFunctions)
	{
		llvm::StringSet<> recImportVars;

		if (referencedFunction->materialize())
			elog(FATAL, "failed to materialize metadata");

		if (referencedFunction->isIntrinsic())
			continue;

		/* if already visited skip, otherwise remember */
		if (!visitedFunctions.insert(referencedFunction).second)
			continue;

		/*
		 * We don't inline external functions directly here, instead we put
		 * them on the worklist if appropriate and check them from
		 * llvm_build_inline_plan().
		 */
		if (referencedFunction->hasExternalLinkage())
		{
			llvm::StringRef funcName = referencedFunction->getName();

			/*
			 * Don't bother checking for inlining if remaining cost budget is
			 * very small.
			 */
			if (subThreshold < 5)
				continue;

			auto it = functionStates.find(funcName);
			if (it == functionStates.end())
			{
				FunctionInlineState inlineState;

				inlineState.costLimit = subThreshold;
				inlineState.processed = false;
				inlineState.inlined = false;
				inlineState.allowReconsidering = false;

				functionStates[funcName] = inlineState;
				worklist.push_back({funcName, searchpath});

				ilog(DEBUG1,
					 "considering extern function %s at %d for inlining",
					 funcName.data(), subThreshold);
			}
			else if (!it->second.inlined &&
					 (!it->second.processed || it->second.allowReconsidering) &&
					 it->second.costLimit < subThreshold)
			{
				/*
				 * Update inlining threshold if higher. Need to re-queue
				 * to be processed if already processed with lower
				 * threshold.
				 */
				if (it->second.processed)
				{
					ilog(DEBUG1,
						 "reconsidering extern function %s at %d for inlining, increasing from %d",
						 funcName.data(), subThreshold, it->second.costLimit);

					it->second.processed = false;
					it->second.allowReconsidering = false;
					worklist.push_back({funcName, searchpath});
				}
				it->second.costLimit = subThreshold;
			}
			continue;
		}

		/* can't rely on what may be inlined */
		if (referencedFunction->isInterposable())
			return false;

		if (!function_inlinable(*referencedFunction,
								subThreshold,
								functionStates,
								worklist,
								searchpath,
								visitedFunctions,
								running_instcount,
								recImportVars))
		{
			ilog(DEBUG1,
				 "cannot inline %s due to required function %s not being inlinable",
				 F.getName().data(), referencedFunction->getName().data());
			return false;
		}

		/* import referenced function itself */
		importVars.insert(referencedFunction->getName());

		/* import referenced function and its dependents */
		for (auto& recImportVar : recImportVars)
			importVars.insert(recImportVar.first());
	}

	return true;
}

/*
 * Attempt to load module summary located at path. Return empty pointer when
 * loading fails.
 */
static std::unique_ptr<llvm::ModuleSummaryIndex>
llvm_load_summary(llvm::StringRef path)
{
	llvm::ErrorOr<std::unique_ptr<llvm::MemoryBuffer> > MBOrErr =
		llvm::MemoryBuffer::getFile(path);

	if (std::error_code EC = MBOrErr.getError())
	{
		ilog(DEBUG1, "failed to open %s: %s", path.data(),
			 EC.message().c_str());
	}
	else
	{
		llvm::MemoryBufferRef ref(*MBOrErr.get().get());

		llvm::Expected<std::unique_ptr<llvm::ModuleSummaryIndex> > IndexOrErr =
			llvm::getModuleSummaryIndex(ref);
		if (IndexOrErr)
			return std::move(IndexOrErr.get());
		elog(FATAL, "failed to load summary \"%s\": %s",
			 path.data(),
			 toString(IndexOrErr.takeError()).c_str());
	}
	return nullptr;
}

/*
 * Attempt to add modpath to the search path.
 */
static void
add_module_to_inline_search_path(InlineSearchPath& searchpath, llvm::StringRef modpath)
{
	/* only extension in libdir are candidates for inlining for now */
#if LLVM_VERSION_MAJOR < 16
#define starts_with startswith
#endif
	if (!modpath.starts_with("$libdir/"))
		return;

	/* if there's no match, attempt to load */
	auto it = summary_cache->find(modpath);
	if (it == summary_cache->end())
	{
		std::string path(modpath);
		path = path.replace(0, strlen("$libdir"), std::string(pkglib_path) + "/bitcode");
		path += ".index.bc";
		(*summary_cache)[modpath] = llvm_load_summary(path);
		it = summary_cache->find(modpath);
	}

	Assert(it != summary_cache->end());

	/* if the entry isn't NULL, it's validly loaded */
	if (it->second)
		searchpath.push_back(it->second.get());
}

/*
 * Search for all references for functions hashing to guid in the search path,
 * and return them in search path order.
 */
static llvm::SmallVector<llvm::GlobalValueSummary *, 1>
summaries_for_guid(const InlineSearchPath& path, llvm::GlobalValue::GUID guid)
{
	llvm::SmallVector<llvm::GlobalValueSummary *, 1> matches;

	for (auto index : path)
	{
		llvm::ValueInfo funcVI = index->getValueInfo(guid);

		/* if index doesn't know function, we don't have a body, continue */
		if (funcVI)
			for (auto &gv : funcVI.getSummaryList())
				matches.push_back(gv.get());
	}

	return matches;
}

/*
 * Create inline wrapper with the name Name, redirecting the call to F.
 */
static llvm::Function*
create_redirection_function(std::unique_ptr<llvm::Module> &importMod,
							llvm::Function *F,
							llvm::StringRef Name)
{
	typedef llvm::GlobalValue::LinkageTypes LinkageTypes;

	llvm::LLVMContext &Context = F->getContext();
	llvm::IRBuilder<> Builder(Context);
	llvm::Function *AF;
	llvm::BasicBlock *BB;
	llvm::CallInst *fwdcall;
#if LLVM_VERSION_MAJOR < 14
	llvm::Attribute inlineAttribute;
#endif

	AF = llvm::Function::Create(F->getFunctionType(),
								LinkageTypes::AvailableExternallyLinkage,
								Name, importMod.get());
	BB = llvm::BasicBlock::Create(Context, "entry", AF);

	Builder.SetInsertPoint(BB);
	fwdcall = Builder.CreateCall(F, &*AF->arg_begin());
#if LLVM_VERSION_MAJOR < 14
	inlineAttribute = llvm::Attribute::get(Context,
										   llvm::Attribute::AlwaysInline);
	fwdcall->addAttribute(~0U, inlineAttribute);
#else
	fwdcall->addFnAttr(llvm::Attribute::AlwaysInline);
#endif
	Builder.CreateRet(fwdcall);

	return AF;
}
