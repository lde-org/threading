local ffi = require("ffi")
local buffer = require("string.buffer")

ffi.cdef([[
	typedef struct lua_State lua_State;

	lua_State* luaL_newstate(void);
	void luaL_openlibs(lua_State* L);
	void lua_close(lua_State* L);

	int luaL_loadbufferx(lua_State* L, const char* buff, size_t sz, const char* name, const char* mode);
	int lua_pcall(lua_State* L, int nargs, int nresults, int errfunc);
	void lua_pushlightuserdata(lua_State* L, void* p);

	int lua_gettop(lua_State* L);
	int lua_type(lua_State* L, int idx);
	const char* lua_tolstring(lua_State* L, int idx, size_t* len);
	double lua_tonumberx(lua_State* L, int idx, int* isnum);
	int64_t lua_tointegerx(lua_State* L, int idx, int* isnum);
	int lua_toboolean(lua_State* L, int idx);

	void* malloc(size_t size);
	void  free(void* ptr);
	void* memcpy(void* dest, const void* src, size_t n);

	typedef unsigned long pthread_t;
	int pthread_create(pthread_t* thread, const void* attr, void*(*start)(void*), void* arg);
	int pthread_join(pthread_t thread, void** retval);

	int usleep(unsigned int usec);
]])

ffi.cdef(require("threading.cdef"))

local threading  = {}

-- Compiled once. Runs inside the fresh lua_State created by the trampoline.
-- Receives thread_data_t* as a lightuserdata via vararg (...).
-- Calls the user bytecode, serializes the result, writes it to data.result.
local WRAPPER_BC = string.dump(load([[
	local ffi    = require("ffi")
	local buffer = require("string.buffer")
	ffi.cdef("typedef struct { char* bc; size_t bc_len; void* _w0; size_t _w1; char* result; size_t result_len; void* _fns[6]; char _name[8]; size_t nups; char* ups; size_t ups_len; } td_t; void* malloc(size_t); void free(void*); void* memcpy(void*,const void*,size_t);")

	local data = ffi.cast("td_t*", ...)
	local fn   = load(ffi.string(data.bc, data.bc_len))
	ffi.C.free(data.bc)
	data.bc = nil

	local nups = tonumber(data.nups)
	if nups > 0 then
		local ups = buffer.new()
		ups:put(ffi.string(data.ups, data.ups_len))
		ffi.C.free(data.ups)
		data.ups = nil
		for i = 1, nups do debug.setupvalue(fn, i, ups:decode()) end
	end

	local res = {pcall(fn)}
	local ok  = table.remove(res, 1)
	local n   = #res
	local b   = buffer.new()
	b:encode(ok)
	b:encode(n)
	for i = 1, n do b:encode(res[i]) end
	local ptr, rn = b:ref()
	data.result = ffi.C.malloc(rn)
	ffi.C.memcpy(data.result, ptr, rn)
	data.result_len = rn
]]))

local CODE       = require("threading.trampoline")
local exec_page
if ffi.os == "Windows" then
	ffi.cdef [[void* VirtualAlloc(void* addr, size_t size, unsigned long type, unsigned long protect);]]
	exec_page = ffi.C.VirtualAlloc(nil, 4096, 0x3000, 0x40)
	assert(exec_page ~= nil, "VirtualAlloc failed")
else
	ffi.cdef [[void* mmap(void* addr, size_t len, int prot, int flags, int fd, long offset);]]
	local map_flags = ffi.os == "OSX" and 0x1002 or 0x22
	exec_page = ffi.C.mmap(nil, 4096, 7, map_flags, -1, 0)
	assert(ffi.cast("intptr_t", exec_page) ~= -1, "mmap failed")
end
ffi.C.memcpy(exec_page, CODE, #CODE)
local thread_entry   = ffi.cast("void*(*)(void*)", exec_page)

-- Cached once at load time — never recomputed per spawn.
local DATA_SIZE      = ffi.sizeof("thread_data_t")
local WRAPPER_PTR    = ffi.cast("char*", WRAPPER_BC)
local WRAPPER_LEN    = #WRAPPER_BC
local FN_NEWSTATE    = ffi.cast("void*", ffi.C.luaL_newstate)
local FN_OPENLIBS    = ffi.cast("void*", ffi.C.luaL_openlibs)
local FN_LOADBUFFERX = ffi.cast("void*", ffi.C.luaL_loadbufferx)
local FN_PUSHLUD     = ffi.cast("void*", ffi.C.lua_pushlightuserdata)
local FN_PCALL       = ffi.cast("void*", ffi.C.lua_pcall)
local FN_CLOSE       = ffi.cast("void*", ffi.C.lua_close)

---@class threading.Handle<T>
---@field private _tid ffi.cdata*
---@field private _data ffi.cdata*
local Handle         = {}
Handle.__index       = Handle

---@param tid ffi.cdata*
---@param data ffi.cdata*
---@return threading.Handle
function Handle.new(tid, data)
	return setmetatable({ _tid = tid, _data = data }, Handle)
end

--- Block until the thread finishes and return its return value.
--- Re-raises if the thread errored.
---@return T
function Handle:join()
	ffi.C.pthread_join(self._tid, nil)
	local data = self._data
	if data.result_len > 0 then
		local b = buffer.new()
		b:put(ffi.string(data.result, data.result_len))
		ffi.C.free(data.result)
		local ok = b:decode()
		local n  = b:decode()
		if not ok then
			ffi.C.free(data)
			error("thread: " .. tostring(b:decode()), 2)
		end
		local results = {}
		for i = 1, n do results[i] = b:decode() end
		ffi.C.free(data)
		return unpack(results, 1, n)
	end
	ffi.C.free(data)
end

local SERIALIZABLE = { ["nil"] = true, boolean = true, number = true, string = true }

---@generic T
---@param closure fun(): T
---@return threading.Handle<T>
function threading.spawn(closure)
	local nups   = debug.getinfo(closure, "u").nups
	local bc_raw = string.dump(closure)

	local data   = ffi.cast("thread_data_t*", ffi.C.malloc(DATA_SIZE))
	data.bc      = ffi.C.malloc(#bc_raw)
	ffi.C.memcpy(data.bc, bc_raw, #bc_raw)
	data.bc_len         = #bc_raw
	data.wrapper_bc     = WRAPPER_PTR
	data.wrapper_len    = WRAPPER_LEN
	data.result         = nil
	data.result_len     = 0
	data.nups           = nups
	data.ups            = nil
	data.ups_len        = 0
	data.fn_newstate    = FN_NEWSTATE
	data.fn_openlibs    = FN_OPENLIBS
	data.fn_loadbufferx = FN_LOADBUFFERX
	data.fn_pushlud     = FN_PUSHLUD
	data.fn_pcall       = FN_PCALL
	data.fn_close       = FN_CLOSE
	ffi.copy(data.name, "entry")

	if nups > 0 then
		local pkg = buffer.new()
		for i = 1, nups do
			local name, val = debug.getupvalue(closure, i)
			if not SERIALIZABLE[type(val)] then
				ffi.C.free(data.bc)
				ffi.C.free(data)
				error("upvalue '" .. name .. "' has non-serializable type: " .. type(val))
			end
			pkg:encode(val)
		end
		local ptr, len = pkg:ref()
		data.ups       = ffi.C.malloc(len)
		ffi.C.memcpy(data.ups, ptr, len)
		data.ups_len = len
	end

	local tid = ffi.new("pthread_t[1]")
	local ret = ffi.C.pthread_create(tid, nil, thread_entry, ffi.cast("void*", data))
	if ret ~= 0 then
		ffi.C.free(data.bc)
		if nups > 0 then ffi.C.free(data.ups) end
		ffi.C.free(data)
		error("pthread_create failed: " .. ret)
	end

	return Handle.new(tid[0], data)
end

---@param ms number
function threading.sleep(ms)
	ffi.C.usleep(math.floor(ms * 1000))
end

return threading
