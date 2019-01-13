# Implements a simple interpreter for julia's lowered AST

getlhs(pc) = SSAValue(pc.next_stmt)

isassign(fr) = isassign(fr, fr.pc)
isassign(fr, pc) = (pc.next_stmt in fr.used)

lookup_var(frame, val::SSAValue) = frame.ssavalues[val.id+1]
lookup_var(frame, ref::GlobalRef) = getfield(ref.mod, ref.name)
lookup_var(frame, slot::SlotNumber) = something(frame.locals[slot.id])
function lookup_var(frame, e::Expr)
    isexpr(e, :the_exception) && return frame.last_exception[]
    isexpr(e, :boundscheck) && return true
    isexpr(e, :static_parameter) || error()
    frame.sparams[e.args[1]]
end

function finish!(frame)
    pc = frame.pc
    while true
        new_pc = _step_expr(frame, pc)
        new_pc == nothing && return pc
        pc = new_pc
    end
end

instantiate_type_in_env(arg, spsig, spvals) =
    ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), arg, spsig, spvals)

function evaluate_call(frame, call_expr)
    args = Array{Any}(undef, length(call_expr.args))
    for i = 1:length(args)
        arg = call_expr.args[i]
        if isa(arg, QuoteNode)
            args[i] = arg.value
        elseif isa(arg, Union{SSAValue, GlobalRef, Slot})
            args[i] = lookup_var(frame, arg)
        elseif isexpr(arg, :&)
            args[i] = Expr(:&, lookup_var(frame, arg.args[1]))
        elseif isa(arg, Expr)
            args[i] = eval_rhs(frame, arg)
        else
            args[i] = arg
        end
    end
    # Don't go through eval since this may have unquoted symbols and
    # exprs
    if isexpr(call_expr, :foreigncall)
        args = map(args) do arg
            isa(arg, Symbol) ? QuoteNode(arg) : arg
        end
        if !isempty(frame.sparams) && frame.scope isa Method
            sig = frame.scope.sig
            args[2] = instantiate_type_in_env(args[2], sig, frame.sparams)
            args[3] = Core.svec(map(args[3]) do arg
                instantiate_type_in_env(arg, sig, frame.sparams)
            end...)
        end
        ret = Core.eval(moduleof(frame), Expr(:foreigncall, args...))
    else
        f = to_function(args[1])
        if isa(f, CodeInfo)
            ret = finish!(enter_call_expr(frame, call_expr))
        else
            # Don't go through eval since this may have unquoted symbols and
            # exprs
            ret = f(args[2:end]...)
        end
    end
    return ret
end

function do_assignment!(frame, lhs, rhs)
    if isa(lhs, SSAValue)
        frame.ssavalues[lhs.id+1] = rhs
    elseif isa(lhs, Slot)
        frame.locals[lhs.id] = Some(rhs)
        frame.last_reference[frame.code.slotnames[lhs.id]] =
            lhs.id
    elseif isa(lhs, GlobalRef)
        Base.eval(lhs.mod,:($(lhs.name) = $(QuoteNode(rhs))))
    end
end

eval_rhs(frame, node) = eval(node)
function eval_rhs(frame, node::Expr)
    if isexpr(node, :new)
        new_expr = Expr(:new, map(x->QuoteNode(lookup_var_if_var(frame, x)),
            node.args)...)
        rhs = Core.eval(moduleof(frame), new_expr)
    elseif isexpr(node, :isdefined)
        rhs = check_isdefined(frame, node.args[1])
    elseif isexpr(node, :enter)
        rhs = length(frame.exception_frames)
    else
        rhs = (isexpr(node, :call) || isexpr(node, :foreigncall)) ?
            evaluate_call(frame, node) :
            lookup_var_if_var(frame, node)
    end
    if isa(rhs, QuoteNode)
        rhs = rhs.value
    end
    return rhs
end

eval_rhs(frame, node::Union{SSAValue, GlobalRef, SlotNumber}) = lookup_var(frame, node)
eval_rhs(frame, node::QuoteNode) = node.value
check_isdefined(frame, node::Slot) = isassigned(frame.locals, slot.id)
function check_isdefined(frame, node::Expr)
    node.head == :static_parameter && return isassigned(frame.sparams, node.args[1])
end

function _step_expr(frame, pc)
    node = pc_expr(frame, pc)
    try
        handled = false
        if isassign(frame, pc)
            lhs = getlhs(pc)
            rhs = eval_rhs(frame, node)
            do_assignment!(frame, lhs, rhs)
            handled = !isexpr(node, :enter)
        end
        if !handled
            if isa(node, Expr)
                if node.head == :(=)
                    lhs = node.args[1]
                    rhs = eval_rhs(frame, node.args[2])
                    do_assignment!(frame, lhs, rhs)
                    # Special case hack for readability.
                    # ret = rhs
                elseif node.head == :&
                elseif node.head == :gotoifnot
                    arg = eval_rhs(frame, node.args[1])
                    if !isa(arg, Bool)
                        throw(TypeError(nameof(frame), "if", Bool, node.args[1]))
                    end
                    if !arg
                        return JuliaProgramCounter(node.args[2])
                    end
                elseif node.head == :call || node.head == :foreigncall
                    evaluate_call(frame, node)
                elseif node.head == :static_typeof
                elseif node.head == :type_goto || node.head == :inbounds
                elseif node.head == :enter
                    push!(frame.exception_frames, node.args[1])
                elseif node.head == :leave
                    for _ = 1:node.args[1]
                        pop!(frame.exception_frames)
                    end
                elseif node.head == :pop_exception
                    n = lookup_var(frame, node.args[1])
                    deleteat!(frame.exception_frames, n+1:length(frame.exception_frames))
                elseif node.head == :static_parameter
                elseif node.head == :gc_preserve_end || node.head == :gc_preserve_begin
                elseif node.head == :return
                    return nothing
                else
                    ret = eval(node)
                end
            elseif isa(node, GotoNode)
                return JuliaProgramCounter(node.label)
            elseif isa(node, QuoteNode)
                ret = node.value
            else
                ret = eval_rhs(frame, node)
            end
        end
    catch err
        isempty(frame.exception_frames) && rethrow(err)
        frame.last_exception[] = err
        return JuliaProgramCounter(frame.exception_frames[end])
    end
    return pc + 1
end
step_expr(frame) = _step_expr(frame, frame.pc)

function is_call(node)
    isexpr(node, :call) ||
    (isexpr(node, :(=)) && isexpr(node.args[2], :call))
end

function next_until!(f, frame, pc=frame.pc)
    while (pc = _step_expr(frame, pc)) != nothing
        f(pc_expr(frame, pc)) && return pc
    end
    return nothing
end
next_call!(frame, pc=frame.pc) = next_until!(node->is_call(node)||isexpr(node,:return), frame, pc)

function changed_line!(expr, line, fls)
    if length(fls) == 1 && isa(expr, LineNumberNode)
        return expr.line != line
    elseif length(fls) == 1 && isa(expr, Expr) && isexpr(expr, :line)
        return expr.args[1] != line
    else
        if is_loc_meta(expr, :pop_loc)
            pop!(fls)
        elseif is_loc_meta(expr, :push_loc)
            push!(fls,(expr.args[2],0))
        end
        return false
    end
end

isgotonode(node) = isa(node, GotoNode) || isexpr(node, :gotoifnot)

"""
Determine whether we are calling a function for which the current function
is a wrapper (either because of optional arguments or becaue of keyword arguments).
"""
function iswrappercall(expr)
    isexpr(expr, :(=)) && (expr = expr.args[2])
    isexpr(expr, :call) && any(x->x==SlotNumber(1), expr.args)
end

pc_expr(frame, pc) = frame.code.code[pc.next_stmt]
pc_expr(frame) = pc_expr(frame, frame.pc)

function find_used(code::CodeInfo)
    used = BitSet()
    stmts = code.code
    for stmt in stmts
        Core.Compiler.scan_ssa_use!(push!, used, stmt)
    end
    return used
end

function maybe_next_call!(frame, pc)
    call_or_return(node) = is_call(node) || isexpr(node, :return)
    call_or_return(pc_expr(frame, pc)) ||
        (pc = next_until!(call_or_return, frame, pc))
    pc
end
maybe_next_call!(frame) = maybe_next_call!(frame, frame.pc)

location(frame) = location(frame, frame.pc)
function location(frame, pc)
    ln = frame.code.codelocs[pc.next_stmt]
    return frame.scope isa Method ? ln + frame.scope.line - 1 : ln
end
function next_line!(frame, stack = nothing)
    initial = location(frame)
    first = true
    pc = frame.pc
    while location(frame, pc) == initial
        # If this is a return node, interrupt execution. This is the same
        # special case as in `s`.
        (!first && isexpr(pc_expr(frame, pc), :return)) && return pc
        first = false
        # If this is a goto node, step it and reevaluate
        if isgotonode(pc_expr(frame, pc))
            pc = _step_expr(frame, pc)
            pc == nothing && return nothing
        elseif stack !== nothing && iswrappercall(pc_expr(frame, pc))
            # With splatting it can happen that we do something like ssa = tuple(#self#), _apply(ssa), which
            # confuses the logic here, just step into the first call that's not a builtin
            while true
                stack[1] = JuliaStackFrame(frame, pc; wrapper = true)
                call_expr = pc_expr(frame, pc)
                isexpr(call_expr, :(=)) && (call_expr = call_expr.args[2])
                call_expr = Expr(:call, map(x->lookup_var_if_var(frame, x), call_expr.args)...)
                new_frame = enter_call_expr(call_expr)
                if new_frame !== nothing
                    pushfirst!(stack, new_frame)
                    frame = new_frame
                    pc = frame.pc
                    break
                else
                    pc = _step_expr(frame, pc)
                    pc == nothing && return nothing
                end
            end
        elseif isa(pc_expr(frame, pc), LineNumberNode)
            line != pc_expr(frame, pc).line && break
            pc = _step_expr(frame, pc)
        else
            pc = _step_expr(frame, pc)
            pc == nothing && return nothing
        end
    end
    maybe_next_call!(frame, pc)
end
