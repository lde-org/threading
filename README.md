# threading

Threads for LuaJIT.

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

### Passing data via upvalues

Upvalues of types `nil`, `boolean`, `number`, and `string` are serialized into the thread:

```lua
local x = 10
local s = "world"

local handle = threading.spawn(function()
    return x * 2, "hello " .. s
end)

print(handle:join())  --> 20  hello world
```

### Multiple concurrent threads

```lua
local handles = {}
for i = 1, 8 do
    handles[i] = threading.spawn(function()
        return i * i
    end)
end

for _, h in ipairs(handles) do
    print(h:join())
end
```

### Sleeping

```lua
threading.sleep(500)  -- sleep for 500ms
```

### Error handling

If a thread errors, the error is re-raised in the calling thread on `join()`:

```lua
local handle = threading.spawn(function()
    error("something went wrong")
end)

local ok, err = pcall(handle.join, handle)
print(err)  --> thread: something went wrong
```
