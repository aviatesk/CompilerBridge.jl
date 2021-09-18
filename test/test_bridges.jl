"""
This is a test usecase of `CompilerBridge`, which is really not complete.
Here we define `BridgeChecker <: AbstractInterpreter` and overload the `Core.Compiler`
functions defined  within base/compiler/abstractinterpretation.jl
by literally copy-and-pasting their definitions, but within our own module context.
So if the coverage of "`Base.function(::Core.Compiler.Types)` bridge" is not enough,
the `typeinf(::BridgeChecker)` may result in an error somewhere.
"""
module TestBridge

const CC = Core.Compiler

for name in names(Core; all = true)
    isdefined(@__MODULE__, name) && continue
    Core.eval(@__MODULE__, :(import Core: $name))
end

for name in names(Core.Compiler; all = true)
    startswith(string(name), "#") && continue
    isdefined(@__MODULE__, name) && continue
    Core.eval(@__MODULE__, :(import .CC: $name))
end

struct BridgeChecker <: CC.AbstractInterpreter
    native::CC.NativeInterpreter
end
BridgeChecker() = BridgeChecker(NativeInterpreter())
InferenceParams(interp::BridgeChecker) = InferenceParams(interp.native)
OptimizationParams(interp::BridgeChecker) = OptimizationParams(interp.native)
get_world_counter(interp::BridgeChecker) = get_world_counter(interp.native)
get_inference_cache(interp::BridgeChecker) = get_inference_cache(interp.native)
code_cache(interp::BridgeChecker) = code_cache(interp.native)

let
    JULIA_DIR = normpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
    # JULIA_DIR = normpath(Sys.BINDIR, "..", "..")
    ABSTRACTINTERPRETATION = normpath(JULIA_DIR, "base", "compiler", "abstractinterpretation.jl")
    s = read(ABSTRACTINTERPRETATION, String)
    s = replace(s, "AbstractInterpreter" => "BridgeChecker")
    ex = Base.parse_input_line(s)
    @assert Meta.isexpr(ex, :toplevel)
    for x in ex.args
        isa(x, LineNumberNode) && continue
        occursin("BridgeChecker", string(x)) || continue # skip if this code block doesn't contain an overload
        Core.eval(@__MODULE__, x)
    end
end

using Test
code_typed(sin, (Int,); interp=BridgeChecker())
code_typed(println, (QuoteNode,); interp=BridgeChecker())
@test true

end # module TestBridge
