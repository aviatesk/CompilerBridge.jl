# CompilerBridge

This is a small module that defines "bridging utilities" to work with `Core.Compiler` types.

## Background

`Core.Compiler` module is essentially a copy of `Base` module subset and `Core.Compiler` functions and types are (mostly) separated from those of `Base`,
so that any extension of `Base` doesn't break the whole compilation process.

But when working with the `Core.Compiler.AbstractInterpreter` framework, we may want to make `Base` functions to work with `Core.Compiler` types
(and possibly even want `Base` types to work with `Core.Compiler` functions), because we usually describe customized compiler behavior with general Julia code.

The purpose of this module is to define _standardized_ bridges to make it easier to work with `Core.Compiler`, because it will lead to compilation problems
if multiple different modules define their own overloads to bridge `Base` and `Core.Compiler`.

## `Base.function(::Core.Compiler.Types)` bridge

`CompilerBridge` overloads a set of `Base` function so that they can work with the corresponding `Core.Compiler` types.
If you load the `CompilerBridge` module, `Base` functions will work with `Core.Compiler` types as like `Base` types:
```julia
julia> length(methods(push!))
26

julia> @time using CompilerBridge # load bridging methods
  0.043703 seconds (50.52 k allocations: 3.164 MiB)

julia> length(methods(push!))
36

julia> bs = Core.Compiler.BitSet((0,1,2,3))
Core.Compiler.BitSet(UInt64[0x000000000000000f], 0)

julia> push!(bs, 4,5,6)
Core.Compiler.BitSet(UInt64[0x000000000000007f], 0)
```

See `CompilerBridge.BRIDGES` for the supported functions, and please suggest any other functions that are better to work with `Core.Compiler` types.

Internally, a "bridge" methods is defined so that it takes `Core.Compiler` types and just forwards them to the corresponding `Core.Compiler` method.
The bridge method should inherit `@nospecialize` configurations of the original `Core.Compiler` method,
and also the forwarding should be fully inlined so that the possible overhead of the forwarding would be eliminated.

## `Core.Compiler.function(::Base.Types)` bridge

Currently `CompilerBridge` does NOT offer bridges to make `Core.Compiler` functions work with `Base` types.
So the following snippet won't work even with `CompilerBridge`, because `Core.Compiler.BitSet(1:10)` will internally call `Core.Compiler.push!(::Base.UnitRange{Int})`:
```julia
julia> Core.Compiler.BitSet(1:10)
ERROR: MethodError: no method matching size(::UnitRange{Int64})
You may have intended to import Base.size
Closest candidates are:
  size(::AbstractArray{T, N}, ::Any) where {T, N} at abstractarray.jl:42
  size(::Core.Compiler.IdentityUnitRange) at indices.jl:389
  size(::Core.Compiler.LinearIndices) at indices.jl:476
  ...
Stacktrace:
 [1] axes
   @ ./abstractarray.jl:95 [inlined]
 [2] axes1
   @ ./abstractarray.jl:116 [inlined]
 [3] eachindex
   @ ./abstractarray.jl:279 [inlined]
 [4] iterate(A::UnitRange{Int64})
   @ Core.Compiler ./abstractarray.jl:1142
 [5] union!(s::Core.Compiler.BitSet, itr::UnitRange{Int64})
   @ Core.Compiler ./bitset.jl:33
 [6] Core.Compiler.BitSet(itr::UnitRange{Int64})
   @ Core.Compiler ./bitset.jl:29
 [7] top-level scope
   @ REPL[3]:1
```

**COMBAK**: is it safe to overload `Core.Compiler` functions to work with `Base` types ... ? It sounds like destroying all the purpose of the `Core.Compiler` separation.
