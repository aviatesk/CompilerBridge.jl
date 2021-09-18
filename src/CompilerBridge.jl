module CompilerBridge

const CC = Core.Compiler

import Base.Meta: Meta, lower

# include("forward-ast.jl") # wasn't so successful
include("forward.jl")

const BRIDGES = [
    CC.iterate, CC.length, CC.push!, CC.pop!, CC.first, CC.last, CC.isempty, CC.size,
    CC.any, CC.all,
    CC.get, CC.getindex, CC.get!, CC.setindex!, CC.haskey, CC.delete!,
    CC.copy,
]
for f in BRIDGES
    forward_callable(f)
end

# for inspection
macro lwr(ex) QuoteNode(lower(__module__, ex)) end
macro src(ex) QuoteNode(first(lower(__module__, ex).args)) end

end # module CompilerBridge
