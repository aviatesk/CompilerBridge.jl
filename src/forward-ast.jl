function forward_callable(@nospecialize f)
    @assert isdefined(Base, nameof(f))
    for m in methods(f)
        local ex
        try
            ex = forward_method(m)
            isnothing(ex) && continue
            Core.eval(@__MODULE__, ex)
        catch err
            if @isdefined(ex)
                @error "failed to create a method to forward `Core.Compiler` types, inspect `$(@__MODULE__).m`"
                Core.eval(@__MODULE__, :(m = $m))
            else
                @error "failed to define a method to forward `Core.Compiler` types, inspect `$(@__MODULE__).m` and `$(@__MODULE__).ex`"
                Core.eval(@__MODULE__, :(m = $m; ex = $(QuoteNode(ex))))
            end
            rethrow(err)
        end
    end
end

function forward_method(m::Method)
    argnames = Symbol[]
    isva = false

    # step 1. change the method signature to work with `Core.Compiler` types
    msig = m.sig
    sparams = TypeVar[]
    while isa(msig, UnionAll)
        push!(sparams, msig.var)
        msig = msig.body
    end

    msig = msig::DataType
    let
        tt = msig.parameters[2:end]
        for m in methods(getfield(Base, m.name))
            sig = Base.unwrap_unionall(m.sig)
            if tt == sig.parameters[2:end]
                # this method is defined already, because:
                # - some are defined manually within `Base.IRShow`
                # - some methods work only with `Core` types
                return nothing
            end
        end
    end

    local shouldforward = false
    sig = Expr(:call)
    push!(sig.args, GlobalRef(Base, m.name))
    slotnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), m.slot_syms)
    for (i, (argname, argtype)) in enumerate(zip(slotnames, msig.parameters))
        i == 1 && continue
        push!(argnames, argname)
        if isa(argtype, TypeVar)
            var = sparams[findfirst(==(argtype), sparams)::Int]
            argtypeex = var.name
        elseif Base.isvarargtype(argtype)
            shouldforward |= iscorecompilertype(argtype.T)
            argtypeex = typeex(argtype.T)
            isva = true
        elseif isa(argtype, Union)
            argtypeex = Expr(:curly, :Union)
            while isa(argtype, Union)
                shouldforward |= iscorecompilertype(argtype.a)
                push!(argtypeex.args, typeex(argtype.a))
                argtype = argtype.b
            end
            shouldforward |= iscorecompilertype(argtype)
            push!(argtypeex.args, typeex(argtype))
        else
            if isa(Base.unwrap_unionall(argtype), Union)
                @warn "too complex signature" m
                return nothing
            end
            shouldforward |= iscorecompilertype(argtype)
            argtypeex = typeex(argtype)
        end
        sigx = Expr(:(::), argname, argtypeex)
        if isva
            sigx = Expr(:..., sigx)
        end
        push!(sig.args, sigx)
    end
    if !shouldforward
        return nothing # work with `Core` types
    end

    for var in sparams
        newvar = Expr(:comparison, typeex(var.lb), :<:, var.name, :<:, typeex(var.ub))
        sig = Expr(:where, sig, newvar)
    end

    # step 2. create a method body to forward the call to the corresponding `Core.Compiler` definition
    body = Expr(:block, LineNumberNode(@__LINE__, @__FILE__))
    if m.nospecialize ≠ 0
        nospecialize = :(@nospecialize)
        for (i, argname) in zip(1:m.nargs, argnames)
            if m.nospecialize & (1 << (i - 1)) ≠ 0
                push!(nospecialize.args, argname)
            end
        end
        push!(body.args, nospecialize)
    end
    call = Expr(:call)
    push!(call.args, GlobalRef(Core.Compiler, m.name))
    for (i, arg) in enumerate(argnames)
        if i == length(argnames) && isva
            arg = Expr(:..., arg)
        end
        push!(call.args, arg)
    end
    push!(body.args, call)

    return Expr(:(=), sig, body)
end

let
    mods = Module[]
    for name in names(Core.Compiler; all=true)
        x = getfield(Core.Compiler, name)
        if isa(x, Module)
            push!(mods, x)
        end
    end

    global iscorecompilertype(@nospecialize t) = parentmodule(t) in mods
end

function typeex(@nospecialize t)
    if t === Union{}
        return Union{}
    elseif isa(t, TypeVar)
        return t.name
    elseif isa(t, DataType) || isa(t, UnionAll)
        typename = nameof(t)
        mod = parentmodule(t)
        ret = GlobalRef(mod, typename)
        mod === Core && return ret
        if isa(t, DataType) && !isempty(t.parameters)
            ret = Expr(:curly, ret)
            for t′ in t.parameters
                push!(ret.args, typeex(t′))
            end
        end
        return ret
    else
        @warn t typeof(t)
        return t
    end
end
