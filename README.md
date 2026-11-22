# threading

Threads for LuaJIT. A thread runs a function in a Lua state of its own, at the same time as the
program; what goes in and what comes back is copied with `string.buffer`, so no Lua value is ever
shared between threads.

Runs on Linux, macOS, FreeBSD and Android (pthreads) and Windows (`CreateThread`), on x86-64 and
ARM64. The thread entry point is a small C library that `build.lua` compiles for whichever target
lde is building, with the compiler lde picks for it, so `lde compile --target ...` and Android APKs
get a library for their own platform.

## Usage

Set up [lde](https://lde.sh)

```
lde add threading --git https://github.com/lde-org/threading
```

```lua
local threading = require("threading")
```

### Spawn and join

```lua
local handle = threading.spawn(function()
    return 42, "hello"
end)

-- do other work while the thread runs...

local num, str = handle:join()
print(num, str)  --> 42  hello
```

`join` waits for the thread and answers with what its function returned. Joining again answers the
same.

### Polling without waiting

A program with a frame to draw asks whether a thread has finished instead of waiting for it:

```lua
local handle = threading.spawn(function() return decode(path) end)

-- every frame:
if handle:done() then
    local result = handle:join() -- does not wait: the thread has finished
end
```

### A pool of workers

Starting a thread makes a Lua state and fills it with modules, which is too much to pay per item
when a program decodes many similar things -- covers, thumbnails, samples. A pool keeps a few
threads (and their states, modules and JIT traces) and runs one function over many jobs:

```lua
local pool = threading.pool(2, function(path, size)
    local image = require("image")
    return image.load(path, { width = size, height = size })
end)

local handle = pool:run("cover.jpg", 512)
if handle ~= nil then
    -- every frame:
    if handle:done() then
        local picture = handle:join()
        -- the worker that ran this job is free for another `run`
    end
end
```

The function takes the arguments `run` was given rather than closing over them. Its own upvalues
are copied once, when the pool is made, and must be something `string.buffer` can copy.
`run` answers `nil` while every worker is busy; `close` stops the pool after letting a running job
finish.

### Passing data in

A thread's upvalues are copied into it. Each must be something `string.buffer` can copy: `nil`, a
boolean, a number, a string, or a table of those. A function, a userdata or a cdata upvalue is an
error at `spawn`.

```lua
local paths = { "a.png", "b.png" }
local scale = 2

local handle = threading.spawn(function()
    local out = {}
    for i, p in ipairs(paths) do out[i] = p .. "@" .. scale end
    return out
end)

print(handle:join()[1])  --> a.png@2
```

A thread changing an upvalue changes its own copy.

### Requiring modules in a thread

A thread's state has the standard libraries and the program's `package.path` and `package.cpath`,
so `require` inside a thread finds what it finds outside:

```lua
threading.spawn(function()
    local json = require("json")
    return json.encode({ ok = true })
end):join()
```

In a program `lde compile` built -- an executable or an APK -- the modules are inside the program
rather than on disk. lde exports `lde_preload` from what it compiles, and a thread's state is given
the program's modules through it, so the same `require` works there too. A host lde did not build
has no `lde_preload`, and a thread there finds modules through the paths alone.

### Errors

An error in a thread is raised by `join`:

```lua
local handle = threading.spawn(function()
    error("something went wrong")
end)

local ok, err = pcall(handle.join, handle)
print(err)  --> thread: ...: something went wrong
```

### Sleeping

```lua
threading.sleep(500)  -- sleeps the calling thread for 500ms
```

## Notes

- Join every handle: a thread's memory is given back by `join`.
- Starting a thread makes a Lua state, so it costs a few hundred microseconds; it is for work that
  takes longer than that.
- On Android the Lua runtime lives in the app's `libmain.so`, which the process does not export;
  the `android` feature brings the module that opens it.
