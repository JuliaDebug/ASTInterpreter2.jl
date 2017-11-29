
# ASTInterpreter2

[![Build Status](https://travis-ci.org/Keno/ASTInterpreter2.jl.svg?branch=master)](https://travis-ci.org/Keno/ASTInterpreter2.jl)
[![codecov.io](http://codecov.io/github/Keno/ASTInterpreter2.jl/coverage.svg?branch=master)](http://codecov.io/github/Keno/ASTInterpreter2.jl?branch=master)

# Installation
```
Pkg.add("ASTInterpreter2")
```
Then use the `@enter` macro as on older versions of ASTInterpreter.

The AST Interpreter component of Gallium (i.e. does not include any breakpoint,
  stuff, etc.). This is a development prototype and comes with it's own debug
  prompt for that purpose.

Usage:
```
using ASTInterpreter2

function foo(n)
    x = n+1
    ((BigInt[1 1; 1 0])^x)[2,1]
end

@enter foo(20)
```
Basic Commands:
  - `n` steps to the next line
  - `s` steps into the next call
  - `finish` runs to the end of the function
  - `bt` shows a simple backtrace
  - `` `stuff`` (backtick) run `stuff` the current frame's context
  - `fr v` will show all variables in the current frame
  - `f n` where n is an integer, will go to the n-th frame.

Advanced commands:
  - `nc` steps to the next call
  - `se` does one expression step
  - `si` does the same but steps into a call if a call is the next expression
  - `sg` steps into a generated function



This is a prototype, do not expect it to be correct or usable.
