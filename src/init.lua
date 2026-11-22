-- Threads for LuaJIT. A thread runs a function in a Lua state of its own, at the same time as the
-- program: what it is handed, and what it hands back, is copied across with string.buffer, so the
-- two never share a Lua value.
--
--   local handle = threading.spawn(function() return heavyWork(input) end)
--   ...
--   if handle:done() then print(handle:join()) end
--
-- A thread's state has the standard libraries, the program's package paths, and -- in a program lde
-- compiled -- the program's own modules, so `require` inside a thread finds what it finds outside.
local ffi = require("ffi")
local buffer = require("string.buffer")
local native = require("threading.native")

local lib = native.lib

local threading = {}

-- What runs first in a thread's state: handed the job, it unpacks the function and what it closed
-- over, runs it, and writes back what it answered. Compiled once, and kept for the life of the
-- module: every job points at these bytes.
local RUNNER = string.dump(assert(load(string.format([==[
	local ffi = require("ffi")
	local buffer = require("string.buffer")
	pcall(ffi.cdef, %q)

	local job = ffi.cast("threading_job*", ...)
	local api = job.api
	local input = buffer.decode(ffi.string(job.payload, job.payload_len))
	api.free(job.payload)
	job.payload = nil

	package.path = input.path
	package.cpath = input.cpath

	local fn = assert(load(input.code, "=thread"))
	for index = 1, input.count do
		debug.setupvalue(fn, index, input.upvalues[index])
	end

	local function pack(...) return { n = select("#", ...), ... } end
	local ok, packed = pcall(buffer.encode, pack(pcall(fn)))
	if not ok then
		packed = buffer.encode({ n = 2, false, "a thread's answer cannot be copied back: " .. tostring(packed) })
	end

	local out = ffi.cast("char*", api.alloc(#packed))
	ffi.copy(out, packed, #packed)
	job.result = out
	job.result_len = #packed
]==], native.CDEF), "=threading.runner")))

local RUNNER_POINTER = ffi.cast("const char*", RUNNER)

---@class threading.Handle
---@field private job ffi.cdata?
---@field private results table? # What the thread answered, once joined
local Handle = {}
Handle.__index = Handle

--- Whether the thread has finished, without waiting for it: what a program that has a frame to
--- draw asks. A finished thread is joined with `join`, which then does not wait.
---@return boolean
function Handle:done()
	return self.job == nil or lib.threading_done(self.job) ~= 0
end

--- Waits for the thread, and answers with what its function returned. An error in the thread is
--- raised here. A handle is joined once; asking again answers the same.
---@return any ...
function Handle:join()
	local job = self.job
	if job ~= nil then
		self.job = nil
		lib.threading_join(job)

		local results
		if job.error ~= nil then
			results = { n = 2, false, ffi.string(job.error) }
			lib.threading_free(job.error)
		elseif job.result ~= nil then
			results = buffer.decode(ffi.string(job.result, job.result_len))
			lib.threading_free(job.result)
		else
			results = { n = 2, false, "the thread ended without an answer" }
		end
		lib.threading_free(job)
		self.results = results
	end

	local results = assert(self.results)
	if not results[1] then
		error("thread: " .. tostring(results[2]), 2)
	end
	return unpack(results, 2, results.n)
end

--- Runs `fn` on a thread of its own. Its upvalues are copied into the thread, so each must be
--- something string.buffer can copy -- nil, a boolean, a number, a string, or a table of those --
--- and a change the thread makes to one is its own copy's.
---@param fn function
---@return threading.Handle
function threading.spawn(fn)
	local count = debug.getinfo(fn, "u").nups
	local upvalues = {}
	for index = 1, count do
		local name, value = debug.getupvalue(fn, index)
		local kind = type(value)
		if kind == "function" or kind == "userdata" or kind == "thread" or kind == "cdata" then
			error("upvalue '" .. tostring(name) .. "' cannot be copied to a thread: it is a " .. kind, 2)
		end
		upvalues[index] = value
	end

	local ok, payload = pcall(buffer.encode, {
		code = string.dump(fn),
		count = count,
		upvalues = upvalues,
		path = package.path,
		cpath = package.cpath,
	})
	if not ok then
		error("a thread's upvalues cannot be copied to it: " .. tostring(payload), 2)
	end

	local job = native.newJob()
	job.runner = RUNNER_POINTER
	job.runner_len = #RUNNER
	job.payload, job.payload_len = native.copy(payload)

	local failed = lib.threading_start(job)
	if failed ~= 0 then
		lib.threading_free(job.payload)
		lib.threading_free(job)
		error("threading: the thread could not be started (" .. tonumber(failed) .. ")", 2)
	end

	return setmetatable({ job = job }, Handle)
end

--- Sleeps the calling thread.
---@param milliseconds number
function threading.sleep(milliseconds)
	lib.threading_sleep(math.max(0, math.floor(milliseconds)))
end

return threading
