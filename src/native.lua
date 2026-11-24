-- The C side of threading: the library build.lua compiles, and the Lua C API a thread makes its
-- state with. Nothing here starts a thread; `threading` does.
local ffi = require("ffi")

local native = {}

-- What the C library and a thread's runner agree on. Declared under names of this library's own,
-- once per state: a state that already declared them (a thread that starts threads) keeps them.
native.CDEF = [[
	typedef struct lua_State lua_State;

	typedef struct threading_api {
		lua_State* (*newstate)(void);
		void (*openlibs)(lua_State*);
		int (*loadbufferx)(lua_State*, const char*, size_t, const char*, const char*);
		void (*pushlightuserdata)(lua_State*, void*);
		int (*pcall)(lua_State*, int, int, int);
		const char* (*tolstring)(lua_State*, int, size_t*);
		void (*close)(lua_State*);
		void (*preload)(lua_State*);
		void* (*alloc)(size_t);
		void (*free)(void*);
	} threading_api;

	typedef struct threading_job {
		const threading_api* api;
		const char* runner;
		size_t runner_len;
		char* payload;
		size_t payload_len;
		char* result;
		size_t result_len;
		char* error;
		int done;
	} threading_job;

	typedef struct threading_worker {
		const threading_api* api;
		char* runner;
		size_t runner_len;
		char* input;
		size_t input_len;
	} threading_worker;

	typedef struct threading_channel threading_channel;

	threading_channel* threading_channel_new(void);
	void threading_channel_ref(threading_channel* channel);
	void threading_channel_unref(threading_channel* channel);
	void threading_channel_close(threading_channel* channel);
	int threading_channel_push(threading_channel* channel, const char* bytes, size_t len);
	char* threading_channel_pop(threading_channel* channel, size_t* length);
	int threading_channel_wait(threading_channel* channel, unsigned int milliseconds);
	size_t threading_channel_count(threading_channel* channel);

	int threading_start(threading_job* job);
	int threading_done(threading_job* job);
	void threading_join(threading_job* job);
	threading_worker* threading_worker_new(const threading_api* api, const char* runner, size_t runner_len, const char* input, size_t input_len);
	int threading_worker_start(threading_worker* worker);
	int threading_worker_push(threading_worker* worker, threading_job* job);
	threading_job* threading_worker_wait(threading_worker* worker);
	void threading_worker_finish(threading_worker* worker, threading_job* job);
	void threading_job_wait(threading_worker* worker, threading_job* job);
	void threading_worker_free_input(threading_worker* worker);
	void threading_worker_stop(threading_worker* worker);
	void threading_worker_free(threading_worker* worker);
	void* threading_alloc(size_t size);
	void threading_free(void* pointer);
	void threading_sleep(unsigned int milliseconds);
]]

pcall(ffi.cdef, native.CDEF)

-- The size of the platform's thread handle, which the job ends with and Lua never reads: a job is
-- allocated with room for it.
local HANDLE_ROOM = 16

--- The directory a file was loaded from, from the name the runtime knows it by.
---@param source string
local function directory(source)
	local file = source:sub(1, 1) == "@" and source:sub(2) or source
	return file:match("^(.*[/\\])") or ""
end

local libraryName = jit.os == "Windows" and "lthreading.dll" or "lthreading.so"

--- The library: on the cpath, which is where a project and a compiled program keep native
--- modules, or beside this file. An APK maps the bare name to the copy it installed.
---@return string
local function findLibrary()
	local found = package.searchpath and package.searchpath("threading/lthreading", package.cpath)
	return found or (directory(debug.getinfo(1, "S").source) .. libraryName)
end

native.lib = ffi.load(findLibrary())

pcall(ffi.cdef, [[
	lua_State* luaL_newstate(void);
	void luaL_openlibs(lua_State* L);
	int luaL_loadbufferx(lua_State* L, const char* buff, size_t sz, const char* name, const char* mode);
	void lua_pushlightuserdata(lua_State* L, void* p);
	int lua_pcall(lua_State* L, int nargs, int nresults, int errfunc);
	const char* lua_tolstring(lua_State* L, int idx, size_t* len);
	void lua_close(lua_State* L);
	void lde_preload(lua_State* L);
]])

--- Where the Lua C API is: the process, where the program exports it -- an executable lde made,
--- or the `luajit` running a script -- and otherwise wherever the platform's own module says.
---@return ffi.namespace*
local function luaLibrary()
	if pcall(function() return ffi.C.luaL_newstate end) then
		return ffi.C
	end

	-- Only bundled where a platform keeps its Lua runtime somewhere the process does not export:
	-- see the package's features.
	local ok, platform = pcall(require, "threading.android")
	if ok then
		return platform.luaLibrary()
	end

	error("threading: the Lua C API is not exported by this process")
end

local lua = luaLibrary()

---@param name string
local function symbol(name)
	local ok, found = pcall(function() return lua[name] end)
	return ok and found or nil
end

-- One for the process: every job points at it.
native.api = ffi.new("threading_api")
native.api.newstate = lua.luaL_newstate
native.api.openlibs = lua.luaL_openlibs
native.api.loadbufferx = lua.luaL_loadbufferx
native.api.pushlightuserdata = lua.lua_pushlightuserdata
native.api.pcall = lua.lua_pcall
native.api.tolstring = lua.lua_tolstring
native.api.close = lua.lua_close
-- A compiled program's modules, for a thread's own state to require: see lde's `lde_preload`.
-- A project run from source has none, and a thread finds its modules through the paths instead.
native.api.preload = symbol("lde_preload")
-- What a thread's runner allocates its answer with, and frees what it was handed with: the
-- library's allocator, the one the program frees with.
native.api.alloc = native.lib.threading_alloc
native.api.free = native.lib.threading_free

local JobPointer = ffi.typeof("threading_job*")

--- A job, in memory the C library owns: a thread writes to it after the program has moved on.
---@return ffi.cdata*
function native.newJob()
	local job = ffi.cast(JobPointer, native.lib.threading_alloc(ffi.sizeof("threading_job") + HANDLE_ROOM))
	assert(job ~= nil, "threading: out of memory")
	ffi.fill(job, ffi.sizeof("threading_job") + HANDLE_ROOM)
	job.api = native.api
	return job
end

--- A copy of a string in memory the C library owns.
---@param text string
---@return ffi.cdata* pointer
---@return number length
function native.copy(text)
	local pointer = ffi.cast("char*", native.lib.threading_alloc(#text))
	assert(pointer ~= nil or #text == 0, "threading: out of memory")
	ffi.copy(pointer, text, #text)
	return pointer, #text
end

--- A worker with its runner and startup payload copied in, ready to start.
---@param runner string
---@param payload string
---@return ffi.cdata* worker
function native.newWorker(runner, payload)
	local worker = native.lib.threading_worker_new(native.api, runner, #runner, payload, #payload)
	assert(worker ~= nil, "threading: out of memory")
	return worker
end

---@param worker ffi.cdata*
---@param job ffi.cdata*
---@return number refused # Nonzero when the worker is busy or stopping
function native.push(worker, job)
	return native.lib.threading_worker_push(worker, job)
end

---@param worker ffi.cdata*
---@param job ffi.cdata*
function native.waitJob(worker, job)
	native.lib.threading_job_wait(worker, job)
end

---@param worker ffi.cdata*
function native.stopWorker(worker)
	native.lib.threading_worker_stop(worker)
end

---@param worker ffi.cdata*
function native.freeWorker(worker)
	native.lib.threading_worker_free(worker)
end

return native
