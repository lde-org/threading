local build = require("lde-build")

-- Embed trampoline.h as a cdef Lua module
build:write("cdef.lua", "return [=[\n" .. io.open("trampoline.h"):read("*a") .. "]=]")

local trampolineOutput = build.outDir .. "/trampoline.lua"

-- Compile trampoline code to lua script in hex
build:sh([[
    tmp=$(mktemp ${TEMP:-/tmp}/trampoline_XXXXXX.o) && \
    gcc -O2 -c -x c trampoline.c -o "$tmp" && \
    objdump -d "$tmp" \
    | grep -oP '^\s+[0-9a-f]+:\s+\K([0-9a-f]{2}\s+)+' \
    | tr -d ' \t\n' \
    | sed 's/../\\\\x&/g' \
    | xargs -I{} echo 'return "{}"' \
    > ]] .. trampolineOutput .. [[ && \
    rm "$tmp"
]])
