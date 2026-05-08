local ffi = require("ffi")
local buffer = require("string.buffer")

ffi.cdef([[
typedef struct lua_State lua_State;

lua_State* luaL_newstate(void);
void luaL_openlibs(lua_State* L);
void lua_close(lua_State* L);

int luaL_loadbufferx(lua_State* L, const char* buff, size_t sz, const char* name, const char* mode);
int lua_pcall(lua_State* L, int nargs, int nresults, int errfunc);

int lua_gettop(lua_State* L);
int lua_type(lua_State* L, int idx);
const char* lua_tolstring(lua_State* L, int idx, size_t* len);
double lua_tonumberx(lua_State* L, int idx, int* isnum);
int64_t lua_tointegerx(lua_State* L, int idx, int* isnum);
int lua_toboolean(lua_State* L, int idx);

/* Layout must match the assembly offsets below exactly.
   All fields are 8 bytes; no padding on x86-64.
   offset  0: bc
   offset  8: len
   offset 16: fn_newstate
   offset 24: fn_openlibs
   offset 32: fn_loadbufferx
   offset 40: fn_pcall
   offset 48: fn_close
   offset 56: fn_free
   offset 64: name[8]  */
typedef struct {
    char*  bc;
    size_t len;
    void*  fn_newstate;
    void*  fn_openlibs;
    void*  fn_loadbufferx;
    void*  fn_pcall;
    void*  fn_close;
    void*  fn_free;
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

local LUA_TNIL      = 0
local LUA_TBOOLEAN  = 1
local LUA_TNUMBER   = 3
local LUA_TSTRING   = 4

-- x86-64 thread entry trampoline (91 bytes).
-- rdi = thread_data_t*. Reads all function pointers from the struct,
-- creates an isolated lua_State, runs the bytecode, frees everything.
-- Never touches the parent LuaJIT state.
--
-- push rbx / push r12 / sub rsp,8     ; callee-save + 16-byte align
-- mov rbx, rdi                         ; rbx = data*
-- call [rbx+16]                        ; luaL_newstate()
-- test rax,rax / jz .done             ; bail if alloc failed
-- mov r12, rax                         ; r12 = L
-- mov rdi,r12 / call [rbx+24]         ; luaL_openlibs(L)
-- mov rdi,r12 / mov rsi,[rbx]         ; L, bc
-- mov rdx,[rbx+8] / lea rcx,[rbx+64] ; len, name
-- xor r8d,r8d / call [rbx+32]        ; luaL_loadbufferx(L,bc,len,name,NULL)
-- test eax,eax / jnz .close
-- mov rdi,r12 / xor esi,esi/edx/ecx
-- call [rbx+40]                        ; lua_pcall(L,0,0,0)
-- .close: mov rdi,r12 / call [rbx+48] ; lua_close(L)
-- .done: mov rdi,[rbx] / call [rbx+56]; free(bc)
--        mov rdi,rbx   / call [rbx+56] ; free(data)
-- xor eax,eax / add rsp,8 / pop r12 / pop rbx / ret
local CODE          =
	"\x53"               -- push rbx
	.. "\x41\x54"        -- push r12
	.. "\x48\x83\xEC\x08" -- sub rsp, 8
	.. "\x48\x89\xFB"    -- mov rbx, rdi
	.. "\xFF\x53\x10"    -- call [rbx+16]        luaL_newstate()
	.. "\x48\x85\xC0"    -- test rax, rax
	.. "\x74\x33"        -- jz .done             69-18 = 51 = 0x33
	.. "\x49\x89\xC4"    -- mov r12, rax
	.. "\x4C\x89\xE7"    -- mov rdi, r12
	.. "\xFF\x53\x18"    -- call [rbx+24]        luaL_openlibs(L)
	.. "\x4C\x89\xE7"    -- mov rdi, r12
	.. "\x48\x8B\x33"    -- mov rsi, [rbx]       bc
	.. "\x48\x8B\x53\x08" -- mov rdx, [rbx+8]     len
	.. "\x48\x8D\x4B\x40" -- lea rcx, [rbx+64]    name
	.. "\x45\x31\xC0"    -- xor r8d, r8d         mode=NULL
	.. "\xFF\x53\x20"    -- call [rbx+32]        luaL_loadbufferx(...)
	.. "\x85\xC0"        -- test eax, eax
	.. "\x75\x0C"        -- jnz .close           63-51 = 12 = 0x0C
	.. "\x4C\x89\xE7"    -- mov rdi, r12
	.. "\x31\xF6"        -- xor esi, esi
	.. "\x31\xD2"        -- xor edx, edx
	.. "\x31\xC9"        -- xor ecx, ecx
	.. "\xFF\x53\x28"    -- call [rbx+40]        lua_pcall(L,0,0,0)
	.. "\x4C\x89\xE7"    -- .close: mov rdi, r12
	.. "\xFF\x53\x30"    -- call [rbx+48]        lua_close(L)
	.. "\x48\x8B\x3B"    -- .done: mov rdi, [rbx]  bc
	.. "\xFF\x53\x38"    -- call [rbx+56]        free(bc)
	.. "\x48\x89\xDF"    -- mov rdi, rbx         data
	.. "\xFF\x53\x38"    -- call [rbx+56]        free(data)
	.. "\x31\xC0"        -- xor eax, eax         return NULL
	.. "\x48\x83\xC4\x08" -- add rsp, 8
	.. "\x41\x5C"        -- pop r12
	.. "\x5B"            -- pop rbx
	.. "\xC3"            -- ret

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

---@class threading.Handle
---@field private _tid ffi.cdata*
local Handle = {}
Handle.__index = Handle

---@param tid ffi.cdata*
---@return threading.Handle
function Handle.new(tid)
	return setmetatable({ _tid = tid }, Handle)
end

--- Block until the thread completes.
function Handle:join()
	ffi.C.pthread_join(self._tid, nil)
end

---@param state ffi.cdata*
---@param i number # Index on lua stack
---@return string.buffer
local function serialize(state, i)
	local ty = ffi.C.lua_type(state, i)
	local b = buffer.new()
	b:encode(ty)
	if ty == LUA_TNUMBER then
		local isnum = ffi.new("int[1]")
		b:encode(ffi.C.lua_tonumberx(state, i, isnum))
	elseif ty == LUA_TSTRING then
		local len = ffi.new("size_t[1]")
		local s = ffi.C.lua_tolstring(state, i, len)
		b:encode(ffi.string(s, len[0]))
	elseif ty == LUA_TBOOLEAN then
		b:encode(ffi.C.lua_toboolean(state, i) == 1)
	end
	return b
end

---@param b string.buffer
---@return any
local function deserialize(b)
	local ty = b:decode()
	if ty == LUA_TNUMBER then return b:decode() end
	if ty == LUA_TSTRING then return b:decode() end
	if ty == LUA_TBOOLEAN then return b:decode() end
	return nil
end

---@param closure fun()
---@return threading.Handle
function threading.spawn(closure)
	local ups = debug.getinfo(closure, "u").nups
	if ups > 0 then
		error("Cannot have upvalues in thread")
	end

	local bc = string.dump(closure)
	local len = #bc

	local data = ffi.cast("thread_data_t*", ffi.C.malloc(ffi.sizeof("thread_data_t")))
	data.bc = ffi.C.malloc(len)
	ffi.C.memcpy(data.bc, bc, len)
	data.len            = len
	data.fn_newstate    = ffi.cast("void*", ffi.C.luaL_newstate)
	data.fn_openlibs    = ffi.cast("void*", ffi.C.luaL_openlibs)
	data.fn_loadbufferx = ffi.cast("void*", ffi.C.luaL_loadbufferx)
	data.fn_pcall       = ffi.cast("void*", ffi.C.lua_pcall)
	data.fn_close       = ffi.cast("void*", ffi.C.lua_close)
	data.fn_free        = ffi.cast("void*", ffi.C.free)
	ffi.copy(data.name, "thread")

	local tid = ffi.new("pthread_t[1]")
	local ret = ffi.C.pthread_create(tid, nil, thread_entry, ffi.cast("void*", data))
	if ret ~= 0 then
		ffi.C.free(data.bc)
		ffi.C.free(ffi.cast("void*", data))
		error("pthread_create failed: " .. ret)
	end

	return Handle.new(tid[0])
end

---@param ms number
function threading.sleep(ms)
	ffi.C.usleep(math.floor(ms * 1000))
end

return threading
