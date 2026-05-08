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

	/* Layout must match asm offsets exactly (all fields 8 bytes, no padding).
	   offset  0: bc             user bytecode ptr
	   offset  8: bc_len
	   offset 16: wrapper_bc     precompiled wrapper chunk (not owned)
	   offset 24: wrapper_len
	   offset 32: result         output: malloc'd serialized result (or NULL)
	   offset 40: result_len
	   offset 48: fn_newstate
	   offset 56: fn_openlibs
	   offset 64: fn_loadbufferx
	   offset 72: fn_pushlud     lua_pushlightuserdata
	   offset 80: fn_pcall
	   offset 88: fn_close
	   offset 96: name[8]        "entry\0\0\0" */
	typedef struct {
		char*  bc;
		size_t bc_len;
		char*  wrapper_bc;
		size_t wrapper_len;
		char*  result;
		size_t result_len;
		void*  fn_newstate;
		void*  fn_openlibs;
		void*  fn_loadbufferx;
		void*  fn_pushlud;
		void*  fn_pcall;
		void*  fn_close;
		char   name[8];
	} thread_data_t;

	void* malloc(size_t size);
	void  free(void* ptr);
	void* memcpy(void* dest, const void* src, size_t n);
	void* mmap(void* addr, size_t len, int prot, int flags, int fd, long offset);

	typedef unsigned long pthread_t;
	int pthread_create(pthread_t* thread, const void* attr, void*(*start)(void*), void* arg);
	int pthread_join(pthread_t thread, void** retval);

	int usleep(unsigned int usec);
]])

local threading     = {}

-- Compiled once. Runs inside the fresh lua_State created by the trampoline.
-- Receives thread_data_t* as a lightuserdata via vararg (...).
-- Calls the user bytecode, serializes the result, writes it to data.result.
local WRAPPER_BC    = string.dump(load([[
	local ffi = require("ffi")
	local buffer = require("string.buffer")

	ffi.cdef("typedef struct { char* bc; size_t bc_len; void* _w; size_t _wl; char* result; size_t result_len; } td_t; void* malloc(size_t); void free(void*); void* memcpy(void*,const void*,size_t);")

	local data = ffi.cast("td_t*", ...)
	local pkg = buffer.new()
	pkg:put(ffi.string(data.bc, data.bc_len))
	ffi.C.free(data.bc)
	data.bc = nil

	local bytecode = pkg:decode()
	local nups     = pkg:decode()
	local fn, err = load(bytecode)
	local b = buffer.new()
	if fn then
		for i = 1, nups do debug.setupvalue(fn, i, pkg:decode()) end
		local res = {pcall(fn)}
		local ok  = table.remove(res, 1)
		local n   = #res
		b:encode(ok)
		b:encode(n)
		for i = 1, n do b:encode(res[i]) end
	else
		b:encode(false)
		b:encode(1)
		b:encode(err)
	end
	local r = b:tostring()
	local n = #r
	data.result = ffi.C.malloc(n)
	ffi.C.memcpy(data.result, r, n)
	data.result_len = n
]]))

-- x86-64 thread entry trampoline (88 bytes).
-- rdi = thread_data_t*. Bootstraps a fresh lua_State, loads the precompiled
-- Lua wrapper, passes data* as a lightuserdata arg, runs it, then closes.
-- Never reads or writes the parent LuaJIT state.
--
-- rbx = data*  (callee-saved, no SIB needed for [rbx+N])
-- r14 = L      (callee-saved, no SIB needed for [r14+N])
--
-- Offsets used: fn_newstate=48(0x30) fn_openlibs=56(0x38)
--               fn_loadbufferx=64(0x40) fn_pushlud=72(0x48)
--               fn_pcall=80(0x50) fn_close=88(0x58) name=96(0x60)
--               wrapper_bc=16(0x10) wrapper_len=24(0x18)
local CODE          =
	"\x53"                 -- push rbx
	.. "\x41\x56"          -- push r14
	.. "\x48\x83\xEC\x08"  -- sub rsp, 8                 align
	.. "\x48\x89\xFB"      -- mov rbx, rdi              rbx = data*
	.. "\xFF\x53\x30"      -- call [rbx+48]             luaL_newstate()
	.. "\x48\x85\xC0"      -- test rax, rax
	.. "\x74\x3C"          -- jz .done                  78-18=60=0x3C
	.. "\x49\x89\xC6"      -- mov r14, rax              r14 = L
	.. "\x4C\x89\xF7"      -- mov rdi, r14
	.. "\xFF\x53\x38"      -- call [rbx+56]             luaL_openlibs(L)
	.. "\x4C\x89\xF7"      -- mov rdi, r14
	.. "\x48\x8B\x73\x10"  -- mov rsi, [rbx+16]         wrapper_bc
	.. "\x48\x8B\x53\x18"  -- mov rdx, [rbx+24]         wrapper_len
	.. "\x48\x8D\x4B\x60"  -- lea rcx, [rbx+96]         name
	.. "\x45\x31\xC0"      -- xor r8d, r8d              mode=NULL
	.. "\xFF\x53\x40"      -- call [rbx+64]             luaL_loadbufferx(...)
	.. "\x4C\x89\xF7"      -- mov rdi, r14
	.. "\x48\x89\xDE"      -- mov rsi, rbx              data*
	.. "\xFF\x53\x48"      -- call [rbx+72]             lua_pushlightuserdata(L, data)
	.. "\x4C\x89\xF7"      -- mov rdi, r14
	.. "\xBE\x01\x00\x00\x00" -- mov esi, 1                nargs=1
	.. "\x31\xD2"          -- xor edx, edx              nresults=0
	.. "\x31\xC9"          -- xor ecx, ecx              errfunc=0
	.. "\xFF\x53\x50"      -- call [rbx+80]             lua_pcall(L,1,0,0)
	.. "\x4C\x89\xF7"      -- mov rdi, r14
	.. "\xFF\x53\x58"      -- call [rbx+88]             lua_close(L)
	.. "\x31\xC0"          -- .done: xor eax, eax       return NULL
	.. "\x48\x83\xC4\x08"  -- add rsp, 8
	.. "\x41\x5E"          -- pop r14
	.. "\x5B"              -- pop rbx
	.. "\xC3"              -- ret

local PROT_READ     = 0x1
local PROT_WRITE    = 0x2
local PROT_EXEC     = 0x4
local MAP_PRIVATE   = 0x02
local MAP_ANONYMOUS = 0x20

local exec_page     = ffi.C.mmap(nil, 4096,
	PROT_READ + PROT_WRITE + PROT_EXEC,
	MAP_PRIVATE + MAP_ANONYMOUS,
	-1, 0)
assert(ffi.cast("intptr_t", exec_page) ~= -1, "mmap failed")
ffi.C.memcpy(exec_page, CODE, #CODE)

local thread_entry = ffi.cast("void*(*)(void*)", exec_page)

---@class threading.Handle<T>
---@field private _tid ffi.cdata*
---@field private _data ffi.cdata*
local Handle = {}
Handle.__index = Handle

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
	local result
	if data.result_len > 0 then
		local b = buffer.new()
		b:put(ffi.string(data.result, data.result_len))
		ffi.C.free(data.result)
		local ok = b:decode()
		local n  = b:decode()
		if not ok then
			ffi.C.free(ffi.cast("void*", data))
			error("thread: " .. tostring(b:decode()), 2)
		end
		local results = {}
		for i = 1, n do results[i] = b:decode() end
		ffi.C.free(ffi.cast("void*", data))
		return unpack(results, 1, n)
	end
	ffi.C.free(ffi.cast("void*", data))
end

local SERIALIZABLE = { ["nil"]=true, boolean=true, number=true, string=true }

---@generic T
---@param closure fun(): T
---@return threading.Handle<T>
function threading.spawn(closure)
	local nups = debug.getinfo(closure, "u").nups
	for i = 1, nups do
		local name, val = debug.getupvalue(closure, i)
		if not SERIALIZABLE[type(val)] then
			error("upvalue '" .. name .. "' has non-serializable type: " .. type(val))
		end
	end

	local pkg = buffer.new()
	pkg:encode(string.dump(closure))
	pkg:encode(nups)
	for i = 1, nups do
		local _, val = debug.getupvalue(closure, i)
		pkg:encode(val)
	end

	local bc   = pkg:tostring()
	local len  = #bc

	local data = ffi.cast("thread_data_t*", ffi.C.malloc(ffi.sizeof("thread_data_t")))
	data.bc    = ffi.C.malloc(len)
	ffi.C.memcpy(data.bc, bc, len)
	data.bc_len         = len
	data.wrapper_bc     = ffi.cast("char*", WRAPPER_BC) -- WRAPPER_BC kept alive as module var
	data.wrapper_len    = #WRAPPER_BC
	data.result         = nil
	data.result_len     = 0
	data.fn_newstate    = ffi.cast("void*", ffi.C.luaL_newstate)
	data.fn_openlibs    = ffi.cast("void*", ffi.C.luaL_openlibs)
	data.fn_loadbufferx = ffi.cast("void*", ffi.C.luaL_loadbufferx)
	data.fn_pushlud     = ffi.cast("void*", ffi.C.lua_pushlightuserdata)
	data.fn_pcall       = ffi.cast("void*", ffi.C.lua_pcall)
	data.fn_close       = ffi.cast("void*", ffi.C.lua_close)
	ffi.copy(data.name, "entry")

	local tid = ffi.new("pthread_t[1]")
	local ret = ffi.C.pthread_create(tid, nil, thread_entry, ffi.cast("void*", data))
	if ret ~= 0 then
		ffi.C.free(data.bc)
		ffi.C.free(ffi.cast("void*", data))
		error("pthread_create failed: " .. ret)
	end

	return Handle.new(tid[0], data)
end

---@param ms number
function threading.sleep(ms)
	ffi.C.usleep(math.floor(ms * 1000))
end

return threading
