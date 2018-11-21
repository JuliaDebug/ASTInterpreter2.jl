using ASTInterpreter2, REPL

# From base, but copied here to make sure we don't fail bacause base changed
function my_gcd(a::T, b::T) where T<:Union{Int64,UInt64,Int128,UInt128}
    a == 0 && return abs(b)
    b == 0 && return abs(a)
    za = trailing_zeros(a)
    zb = trailing_zeros(b)
    k = min(za, zb)
    u = unsigned(abs(a >> za))
    v = unsigned(abs(b >> zb))
    while u != v
        if u > v
            u, v = v, u
        end
        v -= u
        v >>= trailing_zeros(v)
    end
    r = u << k
    # T(r) would throw InexactError; we want OverflowError instead
    r > typemax(T) && throw1(a, b)
    r % T
end

if Sys.isunix()
    using TerminalRegressionTests

    const thisdir = dirname(@__FILE__)
    TerminalRegressionTests.automated_test(
                    joinpath(thisdir,"ui/history.multiout"),
                ["n\n","`", "a\n", "\e[A", "\e[A", "\x3", "\x4"]) do emuterm
        repl = REPL.LineEditREPL(emuterm, true)
        repl.interface = REPL.setup_interface(repl)
        repl.specialdisplay = REPL.REPLDisplay(repl)
        stack = ASTInterpreter2.@make_stack my_gcd(10, 20)
        stack[1] = ASTInterpreter2.JuliaStackFrame(stack[1], stack[1].pc; fullpath=false)
        DebuggerFramework.RunDebugger(stack, repl, emuterm)
    end
end
