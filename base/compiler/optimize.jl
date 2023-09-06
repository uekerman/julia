# This file is a part of Julia. License is MIT: https://julialang.org/license

#############
# constants #
#############

# The slot has uses that are not statically dominated by any assignment
# This is implied by `SLOT_USEDUNDEF`.
# If this is not set, all the uses are (statically) dominated by the defs.
# In particular, if a slot has `AssignedOnce && !StaticUndef`, it is an SSA.
const SLOT_STATICUNDEF  = 1 # slot might be used before it is defined (structurally)
const SLOT_ASSIGNEDONCE = 16 # slot is assigned to only once
const SLOT_USEDUNDEF    = 32 # slot has uses that might raise UndefVarError
# const SLOT_CALLED      = 64

# NOTE make sure to sync the flag definitions below with julia.h and `jl_code_info_set_ir` in method.c

const IR_FLAG_NULL        = UInt32(0)
# This statement is marked as @inbounds by user.
# Ff replaced by inlining, any contained boundschecks may be removed.
const IR_FLAG_INBOUNDS    = UInt32(1) << 0
# This statement is marked as @inline by user
const IR_FLAG_INLINE      = UInt32(1) << 1
# This statement is marked as @noinline by user
const IR_FLAG_NOINLINE    = UInt32(1) << 2
const IR_FLAG_THROW_BLOCK = UInt32(1) << 3
# This statement was proven :effect_free
const IR_FLAG_EFFECT_FREE = UInt32(1) << 4
# This statement was proven not to throw
const IR_FLAG_NOTHROW     = UInt32(1) << 5
# This is :consistent
const IR_FLAG_CONSISTENT  = UInt32(1) << 6
# An optimization pass has updated this statement in a way that may
# have exposed information that inference did not see. Re-running
# inference on this statement may be profitable.
const IR_FLAG_REFINED     = UInt32(1) << 7
# This is :noub == ALWAYS_TRUE
const IR_FLAG_NOUB        = UInt32(1) << 8

# TODO: Both of these should eventually go away once
# This is :effect_free == EFFECT_FREE_IF_INACCESSIBLEMEMONLY
const IR_FLAG_EFIIMO      = UInt32(1) << 9
# This is :inaccessiblememonly == INACCESSIBLEMEM_OR_ARGMEMONLY
const IR_FLAG_INACCESSIBLE_OR_ARGMEM = UInt32(1) << 10

const IR_FLAGS_EFFECTS = IR_FLAG_EFFECT_FREE | IR_FLAG_NOTHROW | IR_FLAG_CONSISTENT | IR_FLAG_NOUB

const TOP_TUPLE = GlobalRef(Core, :tuple)

# This corresponds to the type of `CodeInfo`'s `inlining_cost` field
const InlineCostType = UInt16
const MAX_INLINE_COST = typemax(InlineCostType)
const MIN_INLINE_COST = InlineCostType(10)
const MaybeCompressed = Union{CodeInfo, String}

is_inlineable(@nospecialize src::MaybeCompressed) =
    ccall(:jl_ir_inlining_cost, InlineCostType, (Any,), src) != MAX_INLINE_COST
set_inlineable!(src::CodeInfo, val::Bool) =
    src.inlining_cost = (val ? MIN_INLINE_COST : MAX_INLINE_COST)

function inline_cost_clamp(x::Int)::InlineCostType
    x > MAX_INLINE_COST && return MAX_INLINE_COST
    x < MIN_INLINE_COST && return MIN_INLINE_COST
    return convert(InlineCostType, x)
end

is_declared_inline(@nospecialize src::MaybeCompressed) =
    ccall(:jl_ir_flag_inlining, UInt8, (Any,), src) == 1

is_declared_noinline(@nospecialize src::MaybeCompressed) =
    ccall(:jl_ir_flag_inlining, UInt8, (Any,), src) == 2

#####################
# OptimizationState #
#####################

is_source_inferred(@nospecialize src::MaybeCompressed) =
    ccall(:jl_ir_flag_inferred, Bool, (Any,), src)

function inlining_policy(interp::AbstractInterpreter,
    @nospecialize(src), @nospecialize(info::CallInfo), stmt_flag::UInt32, mi::MethodInstance,
    argtypes::Vector{Any})
    if isa(src, MaybeCompressed)
        is_source_inferred(src) || return nothing
        src_inlineable = is_stmt_inline(stmt_flag) || is_inlineable(src)
        return src_inlineable ? src : nothing
    elseif src === nothing && is_stmt_inline(stmt_flag)
        # if this statement is forced to be inlined, make an additional effort to find the
        # inferred source in the local cache
        # we still won't find a source for recursive call because the "single-level" inlining
        # seems to be more trouble and complex than it's worth
        inf_result = cache_lookup(optimizer_lattice(interp), mi, argtypes, get_inference_cache(interp))
        inf_result === nothing && return nothing
        src = inf_result.src
        if isa(src, CodeInfo)
            src_inferred = is_source_inferred(src)
            return src_inferred ? src : nothing
        else
            return nothing
        end
    elseif isa(src, IRCode)
        return src
    elseif isa(src, SemiConcreteResult)
        if is_declared_noinline(mi.def::Method)
            # For `NativeInterpreter`, `SemiConcreteResult` may be produced for
            # a `@noinline`-declared method when it's marked as `@constprop :aggressive`.
            # Suppress the inlining here.
            return nothing
        end
        return src
    end
    return nothing
end

struct InliningState{Interp<:AbstractInterpreter}
    edges::Vector{Any}
    world::UInt
    interp::Interp
end
function InliningState(sv::InferenceState, interp::AbstractInterpreter)
    edges = sv.stmt_edges[1]::Vector{Any}
    return InliningState(edges, sv.world, interp)
end
function InliningState(interp::AbstractInterpreter)
    return InliningState(Any[], get_world_counter(interp), interp)
end

# get `code_cache(::AbstractInterpreter)` from `state::InliningState`
code_cache(state::InliningState) = WorldView(code_cache(state.interp), state.world)

mutable struct OptimizationState{Interp<:AbstractInterpreter}
    linfo::MethodInstance
    src::CodeInfo
    ir::Union{Nothing, IRCode}
    stmt_info::Vector{CallInfo}
    mod::Module
    sptypes::Vector{VarState}
    slottypes::Vector{Any}
    inlining::InliningState{Interp}
    cfg::CFG
    unreachable::BitSet
    bb_vartables::Vector{Union{Nothing,VarTable}}
    insert_coverage::Bool
end
function OptimizationState(sv::InferenceState, interp::AbstractInterpreter)
    inlining = InliningState(sv, interp)
    return OptimizationState(sv.linfo, sv.src, nothing, sv.stmt_info, sv.mod,
                             sv.sptypes, sv.slottypes, inlining, sv.cfg,
                             sv.unreachable, sv.bb_vartables, sv.insert_coverage)
end
function OptimizationState(linfo::MethodInstance, src::CodeInfo, interp::AbstractInterpreter)
    # prepare src for running optimization passes if it isn't already
    nssavalues = src.ssavaluetypes
    if nssavalues isa Int
        src.ssavaluetypes = Any[ Any for i = 1:nssavalues ]
    else
        nssavalues = length(src.ssavaluetypes::Vector{Any})
    end
    sptypes = sptypes_from_meth_instance(linfo)
    nslots = length(src.slotflags)
    slottypes = src.slottypes
    if slottypes === nothing
        slottypes = Any[ Any for i = 1:nslots ]
    end
    stmt_info = CallInfo[ NoCallInfo() for i = 1:nssavalues ]
    # cache some useful state computations
    def = linfo.def
    mod = isa(def, Method) ? def.module : def
    # Allow using the global MI cache, but don't track edges.
    # This method is mostly used for unit testing the optimizer
    inlining = InliningState(interp)
    cfg = compute_basic_blocks(src.code)
    unreachable = BitSet()
    bb_vartables = Union{VarTable,Nothing}[]
    for block = 1:length(cfg.blocks)
        push!(bb_vartables, VarState[
            VarState(slottypes[slot], src.slotflags[slot] & SLOT_USEDUNDEF != 0)
            for slot = 1:nslots
        ])
    end
    return OptimizationState(linfo, src, nothing, stmt_info, mod, sptypes, slottypes, inlining, cfg, unreachable, bb_vartables, false)
end
function OptimizationState(linfo::MethodInstance, interp::AbstractInterpreter)
    world = get_world_counter(interp)
    src = retrieve_code_info(linfo, world)
    src === nothing && return nothing
    return OptimizationState(linfo, src, interp)
end

function argextype end # imported by EscapeAnalysis
function try_compute_field end # imported by EscapeAnalysis

include("compiler/ssair/heap.jl")
include("compiler/ssair/slot2ssa.jl")
include("compiler/ssair/inlining.jl")
include("compiler/ssair/verify.jl")
include("compiler/ssair/legacy.jl")
include("compiler/ssair/EscapeAnalysis/EscapeAnalysis.jl")
include("compiler/ssair/passes.jl")
include("compiler/ssair/irinterp.jl")

function ir_to_codeinf!(opt::OptimizationState)
    (; linfo, src) = opt
    src = ir_to_codeinf!(src, opt.ir::IRCode)
    opt.ir = nothing
    validate_code_in_debug_mode(linfo, src, "optimized")
    return src
end

function ir_to_codeinf!(src::CodeInfo, ir::IRCode)
    replace_code_newstyle!(src, ir)
    widen_all_consts!(src)
    src.inferred = true
    return src
end

# widen all Const elements in type annotations
function widen_all_consts!(src::CodeInfo)
    ssavaluetypes = src.ssavaluetypes::Vector{Any}
    for i = 1:length(ssavaluetypes)
        ssavaluetypes[i] = widenconst(ssavaluetypes[i])
    end

    for i = 1:length(src.code)
        x = src.code[i]
        if isa(x, PiNode)
            src.code[i] = PiNode(x.val, widenconst(x.typ))
        end
    end

    src.rettype = widenconst(src.rettype)

    return src
end

#########
# logic #
#########

_topmod(sv::OptimizationState) = _topmod(sv.mod)

is_stmt_inline(stmt_flag::UInt32)      = stmt_flag & IR_FLAG_INLINE      ≠ 0
is_stmt_noinline(stmt_flag::UInt32)    = stmt_flag & IR_FLAG_NOINLINE    ≠ 0
is_stmt_throw_block(stmt_flag::UInt32) = stmt_flag & IR_FLAG_THROW_BLOCK ≠ 0

function new_expr_effect_flags(𝕃ₒ::AbstractLattice, args::Vector{Any}, src::Union{IRCode,IncrementalCompact}, pattern_match=nothing)
    Targ = args[1]
    atyp = argextype(Targ, src)
    # `Expr(:new)` of unknown type could raise arbitrary TypeError.
    typ, isexact = instanceof_tfunc(atyp, true)
    if !isexact
        atyp = unwrap_unionall(widenconst(atyp))
        if isType(atyp) && isTypeDataType(atyp.parameters[1])
            typ = atyp.parameters[1]
        else
            return (false, false, false)
        end
        isabstracttype(typ) && return (false, false, false)
    else
        isconcretedispatch(typ) || return (false, false, false)
    end
    typ = typ::DataType
    fcount = datatype_fieldcount(typ)
    fcount === nothing && return (false, false, false)
    fcount >= length(args) - 1 || return (false, false, false)
    for fidx in 1:(length(args) - 1)
        farg = args[fidx + 1]
        eT = argextype(farg, src)
        fT = fieldtype(typ, fidx)
        if !isexact && has_free_typevars(fT)
            if pattern_match !== nothing && pattern_match(src, typ, fidx, Targ, farg)
                continue
            end
            return (false, false, false)
        end
        ⊑(𝕃ₒ, eT, fT) || return (false, false, false)
    end
    return (false, true, true)
end

"""
    stmt_effect_flags(stmt, rt, src::Union{IRCode,IncrementalCompact}) ->
        (consistent::Bool, effect_free_and_nothrow::Bool, nothrow::Bool)

Returns a tuple of `(:consistent, :effect_free_and_nothrow, :nothrow)` flags for a given statement.
"""
function stmt_effect_flags(𝕃ₒ::AbstractLattice, @nospecialize(stmt), @nospecialize(rt), src::Union{IRCode,IncrementalCompact})
    # TODO: We're duplicating analysis from inference here.
    isa(stmt, PiNode) && return (true, true, true)
    isa(stmt, PhiNode) && return (true, true, true)
    isa(stmt, ReturnNode) && return (true, false, true)
    isa(stmt, GotoNode) && return (true, false, true)
    isa(stmt, GotoIfNot) && return (true, false, ⊑(𝕃ₒ, argextype(stmt.cond, src), Bool))
    if isa(stmt, GlobalRef)
        nothrow = isdefined(stmt.mod, stmt.name)
        consistent = nothrow && isconst(stmt.mod, stmt.name)
        return (consistent, nothrow, nothrow)
    elseif isa(stmt, Expr)
        (; head, args) = stmt
        if head === :static_parameter
            # if we aren't certain enough about the type, it might be an UndefVarError at runtime
            sptypes = isa(src, IRCode) ? src.sptypes : src.ir.sptypes
            nothrow = !sptypes[args[1]::Int].undef
            return (true, nothrow, nothrow)
        end
        if head === :call
            f = argextype(args[1], src)
            f = singleton_type(f)
            f === nothing && return (false, false, false)
            if f === UnionAll
                # TODO: This is a weird special case - should be determined in inference
                argtypes = Any[argextype(args[arg], src) for arg in 2:length(args)]
                nothrow = _builtin_nothrow(𝕃ₒ, f, argtypes, rt)
                return (true, nothrow, nothrow)
            end
            if f === Intrinsics.cglobal
                # TODO: these are not yet linearized
                return (false, false, false)
            end
            isa(f, Builtin) || return (false, false, false)
            # Needs to be handled in inlining to look at the callee effects
            f === Core._apply_iterate && return (false, false, false)
            argtypes = Any[argextype(args[arg], src) for arg in 1:length(args)]
            effects = builtin_effects(𝕃ₒ, f, ArgInfo(args, argtypes), rt)
            consistent = is_consistent(effects)
            effect_free = is_effect_free(effects)
            nothrow = is_nothrow(effects)
            return (consistent, effect_free & nothrow, nothrow)
        elseif head === :new
            return new_expr_effect_flags(𝕃ₒ, args, src)
        elseif head === :foreigncall
            effects = foreigncall_effects(stmt) do @nospecialize x
                argextype(x, src)
            end
            consistent = is_consistent(effects)
            effect_free = is_effect_free(effects)
            nothrow = is_nothrow(effects)
            return (consistent, effect_free & nothrow, nothrow)
        elseif head === :new_opaque_closure
            length(args) < 4 && return (false, false, false)
            typ = argextype(args[1], src)
            typ, isexact = instanceof_tfunc(typ, true)
            isexact || return (false, false, false)
            ⊑(𝕃ₒ, typ, Tuple) || return (false, false, false)
            rt_lb = argextype(args[2], src)
            rt_ub = argextype(args[3], src)
            source = argextype(args[4], src)
            if !(⊑(𝕃ₒ, rt_lb, Type) && ⊑(𝕃ₒ, rt_ub, Type) && ⊑(𝕃ₒ, source, Method))
                return (false, false, false)
            end
            return (false, true, true)
        elseif head === :inbounds
            return (true, true, true)
        elseif head === :boundscheck || head === :isdefined || head === :the_exception || head === :copyast
            return (false, true, true)
        else
            # e.g. :loopinfo
            return (false, false, false)
        end
    end
    isa(stmt, SlotNumber) && error("unexpected IR elements")
    return (true, true, true)
end

"""
    argextype(x, src::Union{IRCode,IncrementalCompact}) -> t
    argextype(x, src::CodeInfo, sptypes::Vector{VarState}) -> t

Return the type of value `x` in the context of inferred source `src`.
Note that `t` might be an extended lattice element.
Use `widenconst(t)` to get the native Julia type of `x`.
"""
argextype(@nospecialize(x), ir::IRCode, sptypes::Vector{VarState} = ir.sptypes) =
    argextype(x, ir, sptypes, ir.argtypes)
function argextype(@nospecialize(x), compact::IncrementalCompact, sptypes::Vector{VarState} = compact.ir.sptypes)
    isa(x, AnySSAValue) && return types(compact)[x]
    return argextype(x, compact, sptypes, compact.ir.argtypes)
end
argextype(@nospecialize(x), src::CodeInfo, sptypes::Vector{VarState}) = argextype(x, src, sptypes, src.slottypes::Vector{Any})
function argextype(
    @nospecialize(x), src::Union{IRCode,IncrementalCompact,CodeInfo},
    sptypes::Vector{VarState}, slottypes::Vector{Any})
    if isa(x, Expr)
        if x.head === :static_parameter
            return sptypes[x.args[1]::Int].typ
        elseif x.head === :boundscheck
            return Bool
        elseif x.head === :copyast
            return argextype(x.args[1], src, sptypes, slottypes)
        end
        Core.println("argextype called on Expr with head ", x.head,
                     " which is not valid for IR in argument-position.")
        @assert false
    elseif isa(x, SlotNumber)
        return slottypes[x.id]
    elseif isa(x, SSAValue)
        return abstract_eval_ssavalue(x, src)
    elseif isa(x, Argument)
        return slottypes[x.n]
    elseif isa(x, QuoteNode)
        return Const(x.value)
    elseif isa(x, GlobalRef)
        return abstract_eval_globalref(x)
    elseif isa(x, PhiNode)
        return Any
    elseif isa(x, PiNode)
        return x.typ
    else
        return Const(x)
    end
end
abstract_eval_ssavalue(s::SSAValue, src::CodeInfo) = abstract_eval_ssavalue(s, src.ssavaluetypes::Vector{Any})
abstract_eval_ssavalue(s::SSAValue, src::Union{IRCode,IncrementalCompact}) = types(src)[s]

"""
    finish(interp::AbstractInterpreter, opt::OptimizationState,
           ir::IRCode, caller::InferenceResult)

Post-process information derived by Julia-level optimizations for later use.
In particular, this function determines the inlineability of the optimized code.
"""
function finish(interp::AbstractInterpreter, opt::OptimizationState,
                ir::IRCode, caller::InferenceResult)
    (; src, linfo) = opt
    (; def, specTypes) = linfo

    force_noinline = is_declared_noinline(src)

    # compute inlining and other related optimizations
    result = caller.result
    @assert !(result isa LimitedAccuracy)
    result = widenslotwrapper(result)

    opt.ir = ir

    # determine and cache inlineability
    if !force_noinline
        sig = unwrap_unionall(specTypes)
        if !(isa(sig, DataType) && sig.name === Tuple.name)
            force_noinline = true
        end
        if !is_declared_inline(src) && result === Bottom
            force_noinline = true
        end
    end
    if force_noinline
        set_inlineable!(src, false)
    elseif isa(def, Method)
        if is_declared_inline(src) && isdispatchtuple(specTypes)
            # obey @inline declaration if a dispatch barrier would not help
            set_inlineable!(src, true)
        else
            # compute the cost (size) of inlining this code
            params = OptimizationParams(interp)
            cost_threshold = default = params.inline_cost_threshold
            if ⊑(optimizer_lattice(interp), result, Tuple) && !isconcretetype(widenconst(result))
                cost_threshold += params.inline_tupleret_bonus
            end
            # if the method is declared as `@inline`, increase the cost threshold 20x
            if is_declared_inline(src)
                cost_threshold += 19*default
            end
            # a few functions get special treatment
            if def.module === _topmod(def.module)
                name = def.name
                if name === :iterate || name === :unsafe_convert || name === :cconvert
                    cost_threshold += 4*default
                end
            end
            src.inlining_cost = inline_cost(ir, params, cost_threshold)
        end
    end
    return nothing
end

function visit_bb_phis!(callback, ir::IRCode, bb::Int)
    stmts = ir.cfg.blocks[bb].stmts
    for idx in stmts
        stmt = ir[SSAValue(idx)][:stmt]
        if !isa(stmt, PhiNode)
            if !is_valid_phiblock_stmt(stmt)
                return
            end
        else
            callback(idx)
        end
    end
end

function any_stmt_may_throw(ir::IRCode, bb::Int)
    for stmt in ir.cfg.blocks[bb].stmts
        if (ir[SSAValue(stmt)][:flag] & IR_FLAG_NOTHROW) != 0
            return true
        end
    end
    return false
end

function conditional_successors_may_throw(lazypostdomtree::LazyPostDomtree, ir::IRCode, bb::Int)
    visited = BitSet((bb,))
    worklist = Int[bb]
    while !isempty(worklist)
        thisbb = pop!(worklist)
        for succ in ir.cfg.blocks[thisbb].succs
            succ in visited && continue
            push!(visited, succ)
            postdominates(get!(lazypostdomtree), succ, thisbb) && continue
            any_stmt_may_throw(ir, succ) && return true
            push!(worklist, succ)
        end
    end
    return false
end

struct AugmentedDomtree
    cfg::CFG
    domtree::DomTree
end

mutable struct LazyAugmentedDomtree
    const ir::IRCode
    agdomtree::AugmentedDomtree
    LazyAugmentedDomtree(ir::IRCode) = new(ir)
end

function get!(lazyagdomtree::LazyAugmentedDomtree)
    isdefined(lazyagdomtree, :agdomtree) && return lazyagdomtree.agdomtree
    ir = lazyagdomtree.ir
    cfg = copy(ir.cfg)
    # Add a virtual basic block to represent the exit
    push!(cfg.blocks, BasicBlock(StmtRange(0:-1)))
    for bb = 1:(length(cfg.blocks)-1)
        terminator = ir[SSAValue(last(cfg.blocks[bb].stmts))][:stmt]
        if isa(terminator, ReturnNode) && isdefined(terminator, :val)
            cfg_insert_edge!(cfg, bb, length(cfg.blocks))
        end
    end
    domtree = construct_domtree(cfg.blocks)
    return lazyagdomtree.agdomtree = AugmentedDomtree(cfg, domtree)
end

# TODO refine `:effect_free` using EscapeAnalysis
mutable struct PostOptAnalysisState
    const result::InferenceResult
    const ir::IRCode
    const inconsistent::BitSetBoundedMinPrioritySet
    const tpdum::TwoPhaseDefUseMap
    const lazypostdomtree::LazyPostDomtree
    const lazyagdomtree::LazyAugmentedDomtree
    const ea_analysis_pending::Vector{Int}
    all_retpaths_consistent::Bool
    all_effect_free::Bool
    effect_free_if_argmem_only::Union{Nothing,Bool}
    all_nothrow::Bool
    all_noub::Bool
    any_conditional_ub::Bool
    function PostOptAnalysisState(result::InferenceResult, ir::IRCode)
        inconsistent = BitSetBoundedMinPrioritySet(length(ir.stmts))
        tpdum = TwoPhaseDefUseMap(length(ir.stmts))
        lazypostdomtree = LazyPostDomtree(ir)
        lazyagdomtree = LazyAugmentedDomtree(ir)
        return new(result, ir, inconsistent, tpdum, lazypostdomtree, lazyagdomtree, Int[],
                   true, true, nothing, true, true, false)
    end
end

give_up_refinements!(sv::PostOptAnalysisState) =
    sv.all_retpaths_consistent = sv.all_effect_free = sv.all_nothrow = sv.all_noub = false

function any_refinable(sv::PostOptAnalysisState)
    effects = sv.result.ipo_effects
    return ((!is_consistent(effects) & sv.all_retpaths_consistent) |
            (!is_effect_free(effects) & sv.all_effect_free) |
            (!is_nothrow(effects) & sv.all_nothrow) |
            (!is_noub(effects) & sv.all_noub))
end

struct GetNativeEscapeCache{CodeCache}
    code_cache::CodeCache
    GetNativeEscapeCache(code_cache::CodeCache) where CodeCache = new{CodeCache}(code_cache)
    GetNativeEscapeCache(interp::AbstractInterpreter) = GetNativeEscapeCache(code_cache(interp))
end
function ((; code_cache)::GetNativeEscapeCache)(mi::MethodInstance)
    codeinst = get(code_cache, mi, nothing)
    codeinst isa CodeInstance || return nothing
    return traverse_analysis_results(codeinst) do @nospecialize result
        return result isa EscapeAnalysis.ArgEscapeCache ? result : nothing
    end
end

function refine_effects!(interp::AbstractInterpreter, sv::PostOptAnalysisState)
    if sv.all_effect_free && !isempty(sv.ea_analysis_pending)
        ir = sv.ir
        nargs = length(ir.argtypes)
        estate = EscapeAnalysis.analyze_escapes(ir, nargs, GetNativeEscapeCache(interp))
        stack_analysis_result!(sv.result, EscapeAnalysis.ArgEscapeCache(estate))
        validate_mutable_arg_escapes!(estate, sv)
    end

    any_refinable(sv) || return false
    effects = sv.result.ipo_effects
    sv.result.ipo_effects = Effects(effects;
        consistent = sv.all_retpaths_consistent ? ALWAYS_TRUE : effects.consistent,
        effect_free = sv.all_effect_free ? ALWAYS_TRUE :
                      sv.effect_free_if_argmem_only === true ? EFFECT_FREE_IF_INACCESSIBLEMEMONLY : effects.effect_free,
        nothrow = sv.all_nothrow ? true : effects.nothrow,
        noub = sv.all_noub ? (sv.any_conditional_ub ? NOUB_IF_NOINBOUNDS : ALWAYS_TRUE) : effects.noub)
    return true
end

function is_ipo_dataflow_analysis_profitable(effects::Effects)
    return !(is_consistent(effects) && is_effect_free(effects) &&
             is_nothrow(effects) && is_noub(effects))
end

function is_getfield_with_boundscheck_arg(@nospecialize(stmt), sv::PostOptAnalysisState)
    is_known_call(stmt, getfield, sv.ir) || return false
    length(stmt.args) < 4 && return false
    boundscheck = stmt.args[end]
    argextype(boundscheck, sv.ir) === Bool || return false
    isa(boundscheck, SSAValue) || return false
    return true
end

function check_all_args_noescape!(sv::PostOptAnalysisState, ir::IRCode, stmt::Expr, estate::EscapeAnalysis.EscapeState)
    if !(isexpr(stmt, :invoke) || isexpr(stmt, :new))
        # COMBAK Are there any situations where we want to keep analysis going for `:call` expression?
        return false
    end
    for arg in (isexpr(stmt, :invoke) ? stmt.args[2:end] : stmt.args)
        argt = argextype(arg, ir)
        if is_mutation_free_argtype(argt)
            continue
        end
        # See if we can find the allocation
        if isa(arg, Argument)
            if EscapeAnalysis.has_no_escape(EscapeAnalysis.ignore_argescape(estate[arg]))
                # Even if we prove everything else effect_free, the best we can
                # say is :effect_free_if_argmem_only
                if sv.effect_free_if_argmem_only === nothing
                    sv.effect_free_if_argmem_only = true
                end
            else
                sv.effect_free_if_argmem_only = false
            end
            return false
        elseif isa(arg, SSAValue)
            argstmt = ir[arg][:stmt]
            if !isexpr(argstmt, :new)
                # TODO: We should be able to use our EscapeInfo to lookup
                # through trivial identities, etc.
                # TODO: To support :invoke, we probably need to run EA for all frames with
                # :effect_free_if_argmem_only & :consistent_if_notreturned
                return false
            end
            argstate = estate[arg]
            EscapeAnalysis.has_no_escape(argstate) || return false
            check_all_args_noescape!(sv, ir, argstmt, estate) || return false
        else
            return false
        end
    end
    return true
end

function validate_mutable_arg_escapes!(estate::EscapeAnalysis.EscapeState, sv::PostOptAnalysisState)
    ir = sv.ir
    for idx in sv.ea_analysis_pending
        # See if any mutable memory was allocated in this function and determined
        # not to escape.
        inst = ir[SSAValue(idx)]
        stmt = inst[:stmt]
        if !(isa(stmt, Expr) && check_all_args_noescape!(sv, ir, stmt, estate))
            return sv.all_effect_free = false
        end
    end
    return true
end

function is_conditional_noub(inst::Instruction, sv::PostOptAnalysisState)
    # Special case: `:boundscheck` into `getfield`
    stmt = inst[:stmt]
    is_getfield_with_boundscheck_arg(stmt, sv) || return false
    barg = stmt.args[end]
    bstmt = sv.ir[barg][:stmt]
    isexpr(bstmt, :boundscheck) || return false
    # If IR_FLAG_INBOUNDS is already set, no more conditional ub
    (!isempty(bstmt.args) && bstmt.args[1] === false) && return false
    sv.any_conditional_ub = true
    return true
end

const IR_FLAGS_NEEDS_EA_REFINMENT = IR_FLAG_EFIIMO | IR_FLAG_INACCESSIBLE_OR_ARGMEM

function scan_non_dataflow_flags!(inst::Instruction, sv::PostOptAnalysisState)
    flag = inst[:flag]
    # If we can prove that the argmem does not escape the current function, we can
    # refine this to :effect_free.
    needs_ea_validation = (flag & IR_FLAGS_NEEDS_EA_REFINMENT) == IR_FLAGS_NEEDS_EA_REFINMENT
    if !needs_ea_validation
        stmt = inst[:stmt]
        if !isterminator(stmt) && stmt !== nothing
            # ignore control flow node – they are not removable on their own and thus not
            # have `IR_FLAG_EFFECT_FREE` but still do not taint `:effect_free`-ness of
            # the whole method invocation
            sv.all_effect_free &= !iszero(flag & IR_FLAG_EFFECT_FREE)
        end
    elseif sv.all_effect_free
        push!(sv.ea_analysis_pending, inst.idx)
    end
    sv.all_nothrow &= !iszero(flag & IR_FLAG_NOTHROW)
    if iszero(flag & IR_FLAG_NOUB)
        if !is_conditional_noub(inst, sv)
            sv.all_noub = false
        end
    end
end

function scan_inconsistency!(inst::Instruction, idx::Int, sv::PostOptAnalysisState)
    flag = inst[:flag]
    stmt_inconsistent = iszero(flag & IR_FLAG_CONSISTENT)
    stmt = inst[:stmt]
    # Special case: For getfield, we allow inconsistency of the :boundscheck argument
    (; inconsistent, tpdum) = sv
    if is_getfield_with_boundscheck_arg(stmt, sv)
        for i = 1:(length(stmt.args)-1)
            val = stmt.args[i]
            if isa(val, SSAValue)
                stmt_inconsistent |= val.id in inconsistent
                count!(tpdum, val)
            end
        end
    else
        for ur in userefs(stmt)
            val = ur[]
            if isa(val, SSAValue)
                stmt_inconsistent |= val.id in inconsistent
                count!(tpdum, val)
            end
        end
    end
    stmt_inconsistent && push!(inconsistent, idx)
    return stmt_inconsistent
end

struct ScanStmt
    sv::PostOptAnalysisState
end

function ((; sv)::ScanStmt)(inst::Instruction, idx::Int, lstmt::Int, bb::Int)
    stmt = inst[:stmt]
    flag = inst[:flag]

    if isexpr(stmt, :enter)
        # try/catch not yet modeled
        give_up_refinements!(sv)
        return nothing
    end

    scan_non_dataflow_flags!(inst, sv)

    stmt_inconsistent = scan_inconsistency!(inst, idx, sv)

    if stmt_inconsistent && idx == lstmt
        if isa(stmt, ReturnNode) && isdefined(stmt, :val)
            sv.all_retpaths_consistent = false
        elseif isa(stmt, GotoIfNot)
            # Conditional Branch with inconsistent condition.
            # If we do not know this function terminates, taint consistency, now,
            # :consistent requires consistent termination. TODO: Just look at the
            # inconsistent region.
            if !sv.result.ipo_effects.terminates
                sv.all_retpaths_consistent = false
            elseif conditional_successors_may_throw(sv.lazypostdomtree, sv.ir, bb)
                # Check if there are potential throws that require
                sv.all_retpaths_consistent = false
            else
                (; cfg, domtree) = get!(sv.lazyagdomtree)
                for succ in iterated_dominance_frontier(cfg, BlockLiveness(sv.ir.cfg.blocks[bb].succs, nothing), domtree)
                    if succ == length(cfg.blocks)
                        # Phi node in the virtual exit -> We have a conditional
                        # return. TODO: Check if all the retvals are egal.
                        sv.all_retpaths_consistent = false
                    else
                        visit_bb_phis!(sv.ir, succ) do phiidx::Int
                            push!(sv.inconsistent, phiidx)
                        end
                    end
                end
            end
        end
    end

    # bail out early if there are no possibilities to refine the effects
    if !any_refinable(sv)
        return nothing
    end

    return true
end

function check_inconsistentcy!(sv::PostOptAnalysisState, scanner::BBScanner)
    scan!(ScanStmt(sv), scanner, true)
    complete!(sv.tpdum); push!(scanner.bb_ip, 1)
    populate_def_use_map!(sv.tpdum, scanner)
    (; ir, inconsistent, tpdum) = sv
    stmt_ip = BitSetBoundedMinPrioritySet(length(ir.stmts))
    for def in sv.inconsistent
        for use in tpdum[def]
            if !(use in inconsistent)
                push!(inconsistent, use)
                append!(stmt_ip, tpdum[use])
            end
        end
    end
    while !isempty(stmt_ip)
        idx = popfirst!(stmt_ip)
        inst = ir[SSAValue(idx)]
        stmt = inst[:stmt]
        if is_getfield_with_boundscheck_arg(stmt, sv)
            any_non_boundscheck_inconsistent = false
            for i = 1:(length(stmt.args)-1)
                val = stmt.args[i]
                if isa(val, SSAValue)
                    any_non_boundscheck_inconsistent |= val.id in inconsistent
                    any_non_boundscheck_inconsistent && break
                end
            end
            any_non_boundscheck_inconsistent || continue
        elseif isa(stmt, ReturnNode)
            sv.all_retpaths_consistent = false
        else isa(stmt, GotoIfNot)
            bb = block_for_inst(ir, idx)
            cfg = ir.cfg
            blockliveness = BlockLiveness(cfg.blocks[bb].succs, nothing)
            domtree = construct_domtree(cfg.blocks)
            for succ in iterated_dominance_frontier(cfg, blockliveness, domtree)
                visit_bb_phis!(ir, succ) do phiidx::Int
                    push!(inconsistent, phiidx)
                    push!(stmt_ip, phiidx)
                end
            end
        end
        sv.all_retpaths_consistent || break
        append!(inconsistent, tpdum[idx])
        append!(stmt_ip, tpdum[idx])
    end
end

function ipo_dataflow_analysis!(interp::AbstractInterpreter, ir::IRCode, result::InferenceResult)
    is_ipo_dataflow_analysis_profitable(result.ipo_effects) || return false

    sv = PostOptAnalysisState(result, ir)
    scanner = BBScanner(ir)

    completed_scan = scan!(ScanStmt(sv), scanner, true)

    if !completed_scan
        if sv.all_retpaths_consistent
            check_inconsistentcy!(sv, scanner)
        else
            # No longer any dataflow concerns, just scan the flags
            scan!(scanner, false) do inst::Instruction, idx::Int, lstmt::Int, bb::Int
                scan_non_dataflow_flags!(inst, sv)
                # bail out early if there are no possibilities to refine the effects
                if !any_refinable(sv)
                    return nothing
                end
                return true
            end
        end
    end

    return refine_effects!(interp, sv)
end

# run the optimization work
function optimize(interp::AbstractInterpreter, opt::OptimizationState, caller::InferenceResult)
    @timeit "optimizer" ir = run_passes_ipo_safe(opt.src, opt, caller)
    ipo_dataflow_analysis!(interp, ir, caller)
    return finish(interp, opt, ir, caller)
end

macro pass(name, expr)
    optimize_until = esc(:optimize_until)
    stage = esc(:__stage__)
    macrocall = :(@timeit $(esc(name)) $(esc(expr)))
    macrocall.args[2] = __source__  # `@timeit` may want to use it
    quote
        $macrocall
        matchpass($optimize_until, ($stage += 1), $(esc(name))) && $(esc(:(@goto __done__)))
    end
end

matchpass(optimize_until::Int, stage, _) = optimize_until == stage
matchpass(optimize_until::String, _, name) = optimize_until == name
matchpass(::Nothing, _, _) = false

function run_passes_ipo_safe(
    ci::CodeInfo,
    sv::OptimizationState,
    caller::InferenceResult,
    optimize_until = nothing,  # run all passes by default
)
    __stage__ = 0  # used by @pass
    # NOTE: The pass name MUST be unique for `optimize_until::AbstractString` to work
    @pass "convert"   ir = convert_to_ircode(ci, sv)
    @pass "slot2reg"  ir = slot2reg(ir, ci, sv)
    # TODO: Domsorting can produce an updated domtree - no need to recompute here
    @pass "compact 1" ir = compact!(ir)
    @pass "Inlining"  ir = ssa_inlining_pass!(ir, sv.inlining, ci.propagate_inbounds)
    # @timeit "verify 2" verify_ir(ir)
    @pass "compact 2" ir = compact!(ir)
    @pass "SROA"      ir = sroa_pass!(ir, sv.inlining)
    @pass "ADCE"      ir = adce_pass!(ir, sv.inlining)
    @pass "compact 3" ir = compact!(ir, true)
    if JLOptions().debug_level == 2
        @timeit "verify 3" (verify_ir(ir, true, false, optimizer_lattice(sv.inlining.interp)); verify_linetable(ir.linetable))
    end
    @label __done__  # used by @pass
    return ir
end

function convert_to_ircode(ci::CodeInfo, sv::OptimizationState)
    linetable = ci.linetable
    if !isa(linetable, Vector{LineInfoNode})
        linetable = collect(LineInfoNode, linetable::Vector{Any})::Vector{LineInfoNode}
    end

    # Update control-flow to reflect any unreachable branches.
    ssavaluetypes = ci.ssavaluetypes::Vector{Any}
    code = copy_exprargs(ci.code)
    for i = 1:length(code)
        expr = code[i]
        if !(i in sv.unreachable) && isa(expr, GotoIfNot)
            # Replace this live GotoIfNot with:
            # - no-op if :nothrow and the branch target is unreachable
            # - cond if :nothrow and both targets are unreachable
            # - typeassert if must-throw
            block = block_for_inst(sv.cfg, i)
            if ssavaluetypes[i] === Bottom
                destblock = block_for_inst(sv.cfg, expr.dest)
                cfg_delete_edge!(sv.cfg, block, block + 1)
                ((block + 1) != destblock) && cfg_delete_edge!(sv.cfg, block, destblock)
                expr = Expr(:call, Core.typeassert, expr.cond, Bool)
            elseif i + 1 in sv.unreachable
                @assert (ci.ssaflags[i] & IR_FLAG_NOTHROW) != 0
                cfg_delete_edge!(sv.cfg, block, block + 1)
                expr = GotoNode(expr.dest)
            elseif expr.dest in sv.unreachable
                @assert (ci.ssaflags[i] & IR_FLAG_NOTHROW) != 0
                cfg_delete_edge!(sv.cfg, block, block_for_inst(sv.cfg, expr.dest))
                expr = nothing
            end
            code[i] = expr
        end
    end

    # Go through and add an unreachable node after every
    # Union{} call. Then reindex labels.
    stmtinfo = sv.stmt_info
    codelocs = ci.codelocs
    ssaflags = ci.ssaflags
    meta = Expr[]
    idx = 1
    oldidx = 1
    nstmts = length(code)
    ssachangemap = labelchangemap = blockchangemap = nothing
    prevloc = zero(eltype(ci.codelocs))
    while idx <= length(code)
        codeloc = codelocs[idx]
        if sv.insert_coverage && codeloc != prevloc && codeloc != 0
            # insert a side-effect instruction before the current instruction in the same basic block
            insert!(code, idx, Expr(:code_coverage_effect))
            insert!(codelocs, idx, codeloc)
            insert!(ssavaluetypes, idx, Nothing)
            insert!(stmtinfo, idx, NoCallInfo())
            insert!(ssaflags, idx, IR_FLAG_NULL)
            if ssachangemap === nothing
                ssachangemap = fill(0, nstmts)
            end
            if labelchangemap === nothing
                labelchangemap = fill(0, nstmts)
            end
            ssachangemap[oldidx] += 1
            if oldidx < length(labelchangemap)
                labelchangemap[oldidx + 1] += 1
            end
            if blockchangemap === nothing
                blockchangemap = fill(0, length(sv.cfg.blocks))
            end
            blockchangemap[block_for_inst(sv.cfg, oldidx)] += 1
            idx += 1
            prevloc = codeloc
        end
        if ssavaluetypes[idx] === Union{} && !(oldidx in sv.unreachable)
            # We should have converted any must-throw terminators to an equivalent w/o control-flow edges
            @assert !isterminator(code[idx])

            block = block_for_inst(sv.cfg, oldidx)
            block_end = last(sv.cfg.blocks[block].stmts) + (idx - oldidx)

            # Delete all successors to this basic block
            for succ in sv.cfg.blocks[block].succs
                preds = sv.cfg.blocks[succ].preds
                deleteat!(preds, findfirst(x::Int->x==block, preds)::Int)
            end
            empty!(sv.cfg.blocks[block].succs)

            if !(idx < length(code) && isa(code[idx + 1], ReturnNode) && !isdefined((code[idx + 1]::ReturnNode), :val))
                # Any statements from here to the end of the block have been wrapped in Core.Const(...)
                # by type inference (effectively deleting them). Only task left is to replace the block
                # terminator with an explicit `unreachable` marker.
                if block_end > idx
                    code[block_end] = ReturnNode()
                    codelocs[block_end] = codelocs[idx]
                    ssavaluetypes[block_end] = Union{}
                    stmtinfo[block_end] = NoCallInfo()
                    ssaflags[block_end] = IR_FLAG_NOTHROW

                    # Verify that type-inference did its job
                    if JLOptions().debug_level == 2
                        for i = (oldidx + 1):last(sv.cfg.blocks[block].stmts)
                            @assert i in sv.unreachable
                        end
                    end

                    idx += block_end - idx
                else
                    insert!(code, idx + 1, ReturnNode())
                    insert!(codelocs, idx + 1, codelocs[idx])
                    insert!(ssavaluetypes, idx + 1, Union{})
                    insert!(stmtinfo, idx + 1, NoCallInfo())
                    insert!(ssaflags, idx + 1, IR_FLAG_NOTHROW)
                    if ssachangemap === nothing
                        ssachangemap = fill(0, nstmts)
                    end
                    if labelchangemap === nothing
                        labelchangemap = sv.insert_coverage ? fill(0, nstmts) : ssachangemap
                    end
                    if oldidx < length(ssachangemap)
                        ssachangemap[oldidx + 1] += 1
                        sv.insert_coverage && (labelchangemap[oldidx + 1] += 1)
                    end
                    if blockchangemap === nothing
                        blockchangemap = fill(0, length(sv.cfg.blocks))
                    end
                    blockchangemap[block] += 1
                    idx += 1
                end
                oldidx = last(sv.cfg.blocks[block].stmts)
            end
        end
        idx += 1
        oldidx += 1
    end

    if ssachangemap !== nothing && labelchangemap !== nothing
        renumber_ir_elements!(code, ssachangemap, labelchangemap)
    end
    if blockchangemap !== nothing
        renumber_cfg_stmts!(sv.cfg, blockchangemap)
    end

    for i = 1:length(code)
        code[i] = process_meta!(meta, code[i])
    end
    strip_trailing_junk!(ci, sv.cfg, code, stmtinfo)
    types = Any[]
    stmts = InstructionStream(code, types, stmtinfo, codelocs, ssaflags)
    # NOTE this `argtypes` contains types of slots yet: it will be modified to contain the
    # types of call arguments only once `slot2reg` converts this `IRCode` to the SSA form
    # and eliminates slots (see below)
    argtypes = sv.slottypes
    return IRCode(stmts, sv.cfg, linetable, argtypes, meta, sv.sptypes)
end

function process_meta!(meta::Vector{Expr}, @nospecialize stmt)
    if isexpr(stmt, :meta) && length(stmt.args) ≥ 1
        push!(meta, stmt)
        return nothing
    end
    return stmt
end

function slot2reg(ir::IRCode, ci::CodeInfo, sv::OptimizationState)
    # need `ci` for the slot metadata, IR for the code
    svdef = sv.linfo.def
    nargs = isa(svdef, Method) ? Int(svdef.nargs) : 0
    @timeit "domtree 1" domtree = construct_domtree(ir.cfg.blocks)
    defuse_insts = scan_slot_def_use(nargs, ci, ir.stmts.stmt)
    𝕃ₒ = optimizer_lattice(sv.inlining.interp)
    @timeit "construct_ssa" ir = construct_ssa!(ci, ir, sv, domtree, defuse_insts, 𝕃ₒ) # consumes `ir`
    # NOTE now we have converted `ir` to the SSA form and eliminated slots
    # let's resize `argtypes` now and remove unnecessary types for the eliminated slots
    resize!(ir.argtypes, nargs)
    return ir
end

## Computing the cost of a function body

# saturating sum (inputs are non-negative), prevents overflow with typemax(Int) below
plus_saturate(x::Int, y::Int) = max(x, y, x+y)

# known return type
isknowntype(@nospecialize T) = (T === Union{}) || isa(T, Const) || isconcretetype(widenconst(T))

function statement_cost(ex::Expr, line::Int, src::Union{CodeInfo, IRCode}, sptypes::Vector{VarState},
                        params::OptimizationParams, error_path::Bool = false)
    head = ex.head
    if is_meta_expr_head(head)
        return 0
    elseif head === :call
        farg = ex.args[1]
        ftyp = argextype(farg, src, sptypes)
        if ftyp === IntrinsicFunction && farg isa SSAValue
            # if this comes from code that was already inlined into another function,
            # Consts have been widened. try to recover in simple cases.
            farg = isa(src, CodeInfo) ? src.code[farg.id] : src[farg][:stmt]
            if isa(farg, GlobalRef) || isa(farg, QuoteNode) || isa(farg, IntrinsicFunction) || isexpr(farg, :static_parameter)
                ftyp = argextype(farg, src, sptypes)
            end
        end
        f = singleton_type(ftyp)
        if isa(f, IntrinsicFunction)
            iidx = Int(reinterpret(Int32, f::IntrinsicFunction)) + 1
            if !isassigned(T_IFUNC_COST, iidx)
                # unknown/unhandled intrinsic
                return params.inline_nonleaf_penalty
            end
            return T_IFUNC_COST[iidx]
        end
        if isa(f, Builtin) && f !== invoke
            # The efficiency of operations like a[i] and s.b
            # depend strongly on whether the result can be
            # inferred, so check the type of ex
            if f === Core.getfield || f === Core.tuple || f === Core.getglobal
                # we might like to penalize non-inferrability, but
                # tuple iteration/destructuring makes that impossible
                # return plus_saturate(argcost, isknowntype(extyp) ? 1 : params.inline_nonleaf_penalty)
                return 0
            elseif (f === Core.arrayref || f === Core.const_arrayref || f === Core.arrayset) && length(ex.args) >= 3
                atyp = argextype(ex.args[3], src, sptypes)
                return isknowntype(atyp) ? 4 : error_path ? params.inline_error_path_cost : params.inline_nonleaf_penalty
            elseif f === typeassert && isconstType(widenconst(argextype(ex.args[3], src, sptypes)))
                return 1
            end
            fidx = find_tfunc(f)
            if fidx === nothing
                # unknown/unhandled builtin
                # Use the generic cost of a direct function call
                return 20
            end
            return T_FFUNC_COST[fidx]
        end
        extyp = line == -1 ? Any : argextype(SSAValue(line), src, sptypes)
        if extyp === Union{}
            return 0
        end
        return error_path ? params.inline_error_path_cost : params.inline_nonleaf_penalty
    elseif head === :foreigncall || head === :invoke || head === :invoke_modify
        # Calls whose "return type" is Union{} do not actually return:
        # they are errors. Since these are not part of the typical
        # run-time of the function, we omit them from
        # consideration. This way, non-inlined error branches do not
        # prevent inlining.
        extyp = line == -1 ? Any : argextype(SSAValue(line), src, sptypes)
        return extyp === Union{} ? 0 : 20
    elseif head === :(=)
        if ex.args[1] isa GlobalRef
            cost = 20
        else
            cost = 0
        end
        a = ex.args[2]
        if a isa Expr
            cost = plus_saturate(cost, statement_cost(a, -1, src, sptypes, params, error_path))
        end
        return cost
    elseif head === :copyast
        return 100
    elseif head === :enter
        # try/catch is a couple function calls,
        # but don't inline functions with try/catch
        # since these aren't usually performance-sensitive functions,
        # and llvm is more likely to miscompile them when these functions get large
        return typemax(Int)
    end
    return 0
end

function statement_or_branch_cost(@nospecialize(stmt), line::Int, src::Union{CodeInfo, IRCode}, sptypes::Vector{VarState},
                                  params::OptimizationParams)
    thiscost = 0
    dst(tgt) = isa(src, IRCode) ? first(src.cfg.blocks[tgt].stmts) : tgt
    if stmt isa Expr
        thiscost = statement_cost(stmt, line, src, sptypes, params,
                                  is_stmt_throw_block(isa(src, IRCode) ? src.stmts.flag[line] : src.ssaflags[line]))::Int
    elseif stmt isa GotoNode
        # loops are generally always expensive
        # but assume that forward jumps are already counted for from
        # summing the cost of the not-taken branch
        thiscost = dst(stmt.label) < line ? 40 : 0
    elseif stmt isa GotoIfNot
        thiscost = dst(stmt.dest) < line ? 40 : 0
    end
    return thiscost
end

function inline_cost(ir::IRCode, params::OptimizationParams,
                       cost_threshold::Integer=params.inline_cost_threshold)::InlineCostType
    bodycost::Int = 0
    for line = 1:length(ir.stmts)
        stmt = ir[SSAValue(line)][:stmt]
        thiscost = statement_or_branch_cost(stmt, line, ir, ir.sptypes, params)
        bodycost = plus_saturate(bodycost, thiscost)
        bodycost > cost_threshold && return MAX_INLINE_COST
    end
    return inline_cost_clamp(bodycost)
end

function statement_costs!(cost::Vector{Int}, body::Vector{Any}, src::Union{CodeInfo, IRCode}, sptypes::Vector{VarState}, params::OptimizationParams)
    maxcost = 0
    for line = 1:length(body)
        stmt = body[line]
        thiscost = statement_or_branch_cost(stmt, line, src, sptypes,
                                            params)
        cost[line] = thiscost
        if thiscost > maxcost
            maxcost = thiscost
        end
    end
    return maxcost
end

function renumber_ir_elements!(body::Vector{Any}, cfg::Union{CFG,Nothing}, ssachangemap::Vector{Int})
    return renumber_ir_elements!(body, cfg, ssachangemap, ssachangemap)
end

function cumsum_ssamap!(ssachangemap::Vector{Int})
    any_change = false
    rel_change = 0
    for i = 1:length(ssachangemap)
        val = ssachangemap[i]
        any_change |= val ≠ 0
        rel_change += val
        if val == -1
            # Keep a marker that this statement was deleted
            ssachangemap[i] = typemin(Int)
        else
            ssachangemap[i] = rel_change
        end
    end
    return any_change
end

function renumber_ir_elements!(body::Vector{Any}, ssachangemap::Vector{Int}, labelchangemap::Vector{Int})
    any_change = cumsum_ssamap!(labelchangemap)
    if ssachangemap !== labelchangemap
        any_change |= cumsum_ssamap!(ssachangemap)
    end
    any_change || return
    for i = 1:length(body)
        el = body[i]
        if isa(el, GotoNode)
            body[i] = GotoNode(el.label + labelchangemap[el.label])
        elseif isa(el, GotoIfNot)
            cond = el.cond
            if isa(cond, SSAValue)
                cond = SSAValue(cond.id + ssachangemap[cond.id])
            end
            was_deleted = labelchangemap[el.dest] == typemin(Int)
            body[i] = was_deleted ? cond : GotoIfNot(cond, el.dest + labelchangemap[el.dest])
        elseif isa(el, ReturnNode)
            if isdefined(el, :val)
                val = el.val
                if isa(val, SSAValue)
                    body[i] = ReturnNode(SSAValue(val.id + ssachangemap[val.id]))
                end
            end
        elseif isa(el, SSAValue)
            body[i] = SSAValue(el.id + ssachangemap[el.id])
        elseif isa(el, PhiNode)
            i = 1
            edges = el.edges
            values = el.values
            while i <= length(edges)
                was_deleted = ssachangemap[edges[i]] == typemin(Int)
                if was_deleted
                    deleteat!(edges, i)
                    deleteat!(values, i)
                else
                    edges[i] += ssachangemap[edges[i]]
                    val = values[i]
                    if isa(val, SSAValue)
                        values[i] = SSAValue(val.id + ssachangemap[val.id])
                    end
                    i += 1
                end
            end
        elseif isa(el, Expr)
            if el.head === :(=) && el.args[2] isa Expr
                el = el.args[2]::Expr
            end
            if el.head === :enter
                tgt = el.args[1]::Int
                el.args[1] = tgt + labelchangemap[tgt]
            elseif !is_meta_expr_head(el.head)
                args = el.args
                for i = 1:length(args)
                    el = args[i]
                    if isa(el, SSAValue)
                        args[i] = SSAValue(el.id + ssachangemap[el.id])
                    end
                end
            end
        end
    end
end

function renumber_cfg_stmts!(cfg::CFG, blockchangemap::Vector{Int})
    cumsum_ssamap!(blockchangemap) || return
    for i = 1:length(cfg.blocks)
        old_range = cfg.blocks[i].stmts
        new_range = StmtRange(first(old_range) + ((i > 1) ? blockchangemap[i - 1] : 0),
                              last(old_range) + blockchangemap[i])
        cfg.blocks[i] = BasicBlock(cfg.blocks[i], new_range)
        if i <= length(cfg.index)
            cfg.index[i] = cfg.index[i] + blockchangemap[i]
        end
    end
end
