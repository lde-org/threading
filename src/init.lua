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

-- What runs in a worker kept for more than one job. It loads the pool's function once, then waits
-- for jobs and runs each with the arguments the job was given. The state, the modules the function
-- requires and the traces the JIT compiles all stay: that is the point of a worker rather than a
-- thread a job.
local WORKER_RUNNER = string.dump(assert(load(string.format([==[
	local ffi = require("ffi")
	local buffer = require("string.buffer")
	pcall(ffi.cdef, %q)

	local worker = ffi.cast("threading_worker*", ...)
	local startup = buffer.decode(ffi.string(worker.input, worker.input_len))

	package.path = startup.path
	package.cpath = startup.cpath

	local native = require("threading.native")
	local lib = native.lib
	lib.threading_worker_free_input(worker)

	local fn = assert(load(startup.code, "=thread"))
	for index = 1, startup.count do
		debug.setupvalue(fn, index, startup.upvalues[index])
	end

	local function pack(...) return { n = select("#", ...), ... } end

	local function fail(job, text)
		local packed = buffer.encode({ n = 2, false, text })
		local out = ffi.cast("char*", job.api.alloc(#packed))
		ffi.copy(out, packed, #packed)
		job.result = out
		job.result_len = #packed
	end

	local function run(job)
		local bytes = ffi.string(job.payload, job.payload_len)
		job.api.free(job.payload)
		job.payload = nil
		local input = buffer.decode(bytes)
		local ok, packed = pcall(buffer.encode, pack(pcall(fn, unpack(input, 1, input.n))))
		if not ok then
			packed = buffer.encode({ n = 2, false, "a thread's answer cannot be copied back: " .. tostring(packed) })
		end

		local out = ffi.cast("char*", job.api.alloc(#packed))
		ffi.copy(out, packed, #packed)
		job.result = out
		job.result_len = #packed
	end

	while true do
		local job = lib.threading_worker_wait(worker)
		if job == nil then break end
		local ok, err = pcall(run, job)
		if not ok then fail(job, "thread: " .. tostring(err)) end
		lib.threading_worker_finish(worker, job)
	end
]==], native.CDEF), "=threading.worker")))

---@class threading.Handle
---@field private job ffi.cdata?
---@field private results table? # What the thread answered, once joined
local Handle = {}
Handle.__index = Handle

--- What a finished job answered, and the job's memory given back.
---@param job ffi.cdata*
---@return table results
local function takeResults(job)
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
	return results
end

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
		self.results = takeResults(job)
	end

	local results = assert(self.results)
	if not results[1] then
		error("thread: " .. tostring(results[2]), 2)
	end
	return unpack(results, 2, results.n)
end

--- The upvalues of a function, checked to be copies string.buffer can carry.
---@param fn function
---@return number count
---@return table upvalues
local function upvaluesOf(fn)
	local count = debug.getinfo(fn, "u").nups
	local upvalues = {}
	for index = 1, count do
		local name, value = debug.getupvalue(fn, index)
		local kind = type(value)
		if kind == "function" or kind == "userdata" or kind == "thread" or kind == "cdata" then
			error("upvalue '" .. tostring(name) .. "' cannot be copied to a thread: it is a " .. kind, 3)
		end
		upvalues[index] = value
	end
	return count, upvalues
end

--- Runs `fn` on a thread of its own. Its upvalues are copied into the thread, so each must be
--- something string.buffer can copy -- nil, a boolean, a number, a string, or a table of those --
--- and a change the thread makes to one is its own copy's.
---@param fn function
---@return threading.Handle
function threading.spawn(fn)
	local count, upvalues = upvaluesOf(fn)

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

---@class threading.PoolWorker
---@field native ffi.cdata*
---@field handle threading.PoolHandle? # The job it is running or holding for a join, if any

---@class threading.Pool
---@field private workers threading.PoolWorker[]
local Pool = {}
Pool.__index = Pool

---@class threading.PoolHandle
---@field private job ffi.cdata?
---@field private worker threading.PoolWorker
---@field private results table?
local PoolHandle = {}
PoolHandle.__index = PoolHandle

--- Whether the worker has finished this job, without waiting for it.
---@return boolean
function PoolHandle:done()
	return self.job == nil or lib.threading_done(self.job) ~= 0
end

--- Waits for the job and answers with what the pool's function returned. The worker is free for
--- another `run` as soon as this returns. Joining again answers the same.
---@return any ...
function PoolHandle:join()
	local job = self.job
	if job ~= nil then
		self.job = nil
		local worker = self.worker
		native.waitJob(worker.native, job)
		self.results = takeResults(job)
		worker.handle = nil
		self.worker = nil --[[@as any]]
	end

	local results = assert(self.results)
	if not results[1] then
		error("thread: " .. tostring(results[2]), 2)
	end
	return unpack(results, 2, results.n)
end

--- A pool of `count` threads that run one function over many jobs. `run` hands it the arguments
--- of a call, so a function that decodes a file takes the path and the size rather than closing
--- over them: the function's own upvalues are copied once, when the pool is made.
---
--- A pool starts its threads now. A program that may never use one should make it when it first
--- has a job.
---@param count number
---@param fn function
---@return threading.Pool
function threading.pool(count, fn)
	assert(type(count) == "number" and count >= 1 and count % 1 == 0, "threading: a pool needs a whole number of threads")
	assert(type(fn) == "function", "threading: a pool needs a function to run")

	local upvalueCount, upvalues = upvaluesOf(fn)
	local startup = buffer.encode({
		code = string.dump(fn),
		count = upvalueCount,
		upvalues = upvalues,
		path = package.path,
		cpath = package.cpath,
	})

	local workers = {}
	for index = 1, count do
		local worker = native.newWorker(WORKER_RUNNER, startup)
		local failed = lib.threading_worker_start(worker)
		if failed ~= 0 then
			native.freeWorker(worker)
			for at = 1, #workers do
				native.stopWorker(workers[at].native)
				native.freeWorker(workers[at].native)
			end
			error("threading: a worker could not be started (" .. tonumber(failed) .. ")", 2)
		end
		workers[index] = { native = worker }
	end

	return setmetatable({ workers = workers }, Pool)
end

--- Runs the pool's function with these arguments on a free worker, or answers nil when every
--- worker is still busy. The arguments must be something string.buffer can copy.
---@return threading.PoolHandle?
function Pool:run(...)
	local workers = self.workers
	---@type threading.PoolWorker?
	local worker
	for index = 1, #workers do
		local candidate = workers[index]
		if candidate.handle == nil then
			worker = candidate
			break
		end
	end
	if worker == nil then return nil end

	local ok, payload = pcall(buffer.encode, { n = select("#", ...), ... })
	if not ok then
		error("a job's arguments cannot be copied to a thread: " .. tostring(payload), 2)
	end

	local job = native.newJob()
	job.payload, job.payload_len = native.copy(payload)
	local handle = setmetatable({ job = job, worker = worker }, PoolHandle)
	worker.handle = handle

	---@cast worker -threading.PoolWorker?
	if native.push(worker.native, job) ~= 0 then
		worker.handle = nil
		lib.threading_free(job.payload)
		lib.threading_free(job)
		return nil
	end

	return handle
end

--- Stops every worker, first letting a job it is running finish. What a program calls before it
--- goes, or when it will not need the pool again.
function Pool:close()
	local workers = self.workers
	for index = 1, #workers do
		local worker = workers[index]
		local handle = worker.handle
		if handle ~= nil then pcall(handle.join, handle) end
		native.stopWorker(worker.native)
		native.freeWorker(worker.native)
	end
	self.workers = {}
end

--- Sleeps the calling thread.
---@param milliseconds number
function threading.sleep(milliseconds)
	lib.threading_sleep(math.max(0, math.floor(milliseconds)))
end

return threading
