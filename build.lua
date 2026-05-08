local build = require("lde-build")

-- Embed trampoline.h as a cdef Lua module
build:write("cdef.lua", "return [=[\n" .. io.open("trampoline.h"):read("*a") .. "]=]")

-- Compile trampoline.c and extract machine code bytes via objdump, parsed in Lua
local tmp = os.tmpname()
build:sh(string.format('gcc -O2 -c -x c trampoline.c -o "%s"', tmp))

local bytes = {}
local f = assert(io.popen(string.format('objdump -d "%s"', tmp)))
for line in f:lines() do
    -- Both GNU and LLVM objdump use: "  addr:\tbytes\tinstruction"
    local hex = line:match("^%s+%x+:\t([%x ]+)\t")
    if hex then
        for b in hex:gmatch("%x%x") do
            bytes[#bytes + 1] = "\\x" .. b
        end
    end
end
f:close()
os.remove(tmp)

build:write("trampoline.lua", 'return "' .. table.concat(bytes) .. '"')
