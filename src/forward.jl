import Core: CodeInfo, svec, ReturnNode, SlotNumber, SSAValue, LineInfoNode

function forward_callable(@nospecialize f)
    @assert isdefined(Base, nameof(f))
    for m in methods(f)
        forward_method(m)
    end
end

function forward_method(m::Method)
    local src
    try
        src = make_forward_method(m)
        isnothing(src) && return
        Core.eval(@__MODULE__, Expr(:thunk, src))
    catch err
        if !@isdefined(src)
            @error "failed to create a method to forward `Core.Compiler` types, inspect `$(@__MODULE__).m`"
            Core.eval(@__MODULE__, :(m = $m))
        else
            @error "failed to define a method to forward `Core.Compiler` types, inspect `$(@__MODULE__).m` and `$(@__MODULE__).src`"
            Core.eval(@__MODULE__, :(m = $m; src = $(QuoteNode(src))))
        end
        rethrow(err)
    end
end

function make_forward_method(m::Method)
    # step 0: check if the exact same method already exists
    # the method might be defined already, because:
    # - some are defined manually within `Base.IRShow`
    # - some methods work only with `Core` types
    f = getfield(Base, m.name)
    let
        tt1 = Base.unwrap_unionall(m.sig).parameters[2:end]
        for m in methods(f)
            tt2 = Base.unwrap_unionall(m.sig).parameters[2:end]
            if tt1 == tt2
                # this method is defined already, because:
                # - some are defined manually within `Base.IRShow`
                # - some methods work only with `Core` types
                return nothing
            end
        end
    end

    # step 1. change the method signature to work with `Core.Compiler` types
    msig = m.sig
    sparams = TypeVar[]
    while isa(msig, UnionAll)
        push!(sparams, msig.var)
        msig = msig.body
    end
    msig = msig::DataType
    atype = collect(msig.parameters)
    atype[1] = typeof(f)
    # step 0 is not enough to catch all cases, mostly because of typevars with different identities
    # and so here we make an extra effort to avoid such methods by checking if the signature
    # actually interacts with any of `Core.Compiler` types
    local shouldforward = false
    for t in atype
        if is_corecompiler_type(t)
            shouldforward |= true
            break
        end
    end
    shouldforward || return nothing
    atype = svec(atype...)
    sparams = svec(sparams...)
    loc = LineNumberNode(@__LINE__, @__FILE__)
    sig = svec(atype, sparams, loc)

    # step 2. create a method body to forward the call to the corresponding `Core.Compiler` definition
    slotnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), m.slot_syms)
    body = let body = Any[]
        local bodyidx::Int = 0
        function insertbody!(@nospecialize x)
            push!(body, x)
            bodyidx += 1
        end
        if m.nospecialize ≠ 0
            nospecialize = Expr(:meta, :nospecialize)
            for i in 1:m.nargs
                if m.nospecialize & (1 << (i - 1)) ≠ 0
                    push!(nospecialize.args, SlotNumber(i))
                end
            end
            insertbody!(nospecialize)
        end
        if m.isva
            if m.nargs-1 > 1
                tpl = Expr(:call, GlobalRef(Core, :tuple))
                for i in 2:(m.nargs-1)
                    push!(tpl.args, SlotNumber(i))
                end
                insertbody!(tpl)
                call = Expr(:call, GlobalRef(Core, :_apply_iterate),
                    GlobalRef(Core.Compiler, :iterate), GlobalRef(Core.Compiler, m.name),
                    SSAValue(bodyidx), SlotNumber(Int(m.nargs)))
                insertbody!(call)
            else
                call = Expr(:call, GlobalRef(Core, :_apply_iterate),
                    GlobalRef(Core.Compiler, :iterate), GlobalRef(Core.Compiler, m.name),
                    SlotNumber(Int(m.nargs)))
                insertbody!(call)
            end
        else
            call = Expr(:call, GlobalRef(Core.Compiler, m.name))
            for i in 2:m.nargs
                push!(call.args, SlotNumber(i))
            end
            insertbody!(call)
        end
        insertbody!(ReturnNode(SSAValue(bodyidx)))
        make_codeinfo(body;
                      slotnames,
                      inlineable=true, # force inlining and eliminate the (possible) overhead of the forwarding
                      )
    end

    # step 3. make a definition thunk
    def = Any[]
    local defidx::Int = 0
    function insertdef!(@nospecialize x)
        push!(def, x)
        defidx += 1
    end
    insertdef!(Expr(:method, nothing, sig, body))
    insertdef!(ReturnNode(SSAValue(defidx)))

    return make_codeinfo(def)
end

function make_codeinfo(code::Vector{Any};
                       slotnames::Vector{Symbol} = Symbol[],
                       inlineable::Bool = false,
                       )
    codeinfo = ccall(:jl_new_code_info_uninit, Ref{CodeInfo}, ())
    codeinfo.code = code
    n = length(codeinfo.code)
    codeinfo.codelocs = Int32[1 for _ in 1:n]
    codeinfo.linetable = Any[LineInfoNode(@__MODULE__, :none, Symbol(@__FILE__), @__LINE__, 0)]
    codeinfo.ssavaluetypes = n
    codeinfo.ssaflags = UInt8[0x00 for _ in 1:n]
    codeinfo.slotnames = slotnames
    codeinfo.slotflags = UInt8[0x00 for _ in 1:length(slotnames)]
    if inlineable
        codeinfo.inlineable = inlineable
        for i in 1:length(codeinfo.ssaflags)
            codeinfo.ssaflags[i] |= Core.Compiler.IR_FLAG_INLINE
        end
    end
    return codeinfo
end

let
    mods = Module[]
    for name in names(Core.Compiler; all=true)
        x = getfield(Core.Compiler, name)
        if isa(x, Module)
            push!(mods, x)
        end
    end

    global function is_corecompiler_type(@nospecialize t)
        if t === Union{}
            return false
        elseif Base.isvarargtype(t)
            return is_corecompiler_type(t.T)
        elseif isa(t, Union)
            return is_corecompiler_type(t.a) || is_corecompiler_type(t.b)
        elseif isa(t, TypeVar)
            return is_corecompiler_type(t.lb) || is_corecompiler_type(t.ub)
        elseif isa(t, UnionAll)
            return is_corecompiler_type(Base.unwrap_unionall(t))
        end
        return parentmodule(t) in mods
    end
end
