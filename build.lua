-- Compiles the thread entry point in src/native for the target being built: the host for a
-- project, and the phone or the other platform for `lde compile --target`, with the compiler lde
-- picks for it. What comes out is a shared library beside the modules, which lde ships with the
-- program like any other native module.
local build = require("lde-build")

local target = build.target
local isWindows = target:find("windows", 1, true) ~= nil or target:find("mingw", 1, true) ~= nil
local isMac = target:find("apple", 1, true) ~= nil or target:find("darwin", 1, true) ~= nil
local isAndroid = target:find("android", 1, true) ~= nil
-- The clang that targets MSVC hands its arguments to link.exe, which takes neither -fPIC nor the
-- GNU linker's options.
local isMsvc = target:find("msvc", 1, true) ~= nil

local library = isWindows and "lthreading.dll" or "lthreading.so"

local args = { "-O2", "-o", library, "native/threading.c" }

if isMac then
	args[#args + 1] = "-dynamiclib"
else
	args[#args + 1] = "-shared"
end

if not isWindows then
	args[#args + 1] = "-fPIC"
	-- Bionic has threads in its libc; everywhere else they are asked for.
	if not isAndroid then
		args[#args + 1] = "-pthread"
	end
end

if not isWindows and not isMac then
	-- A missing symbol is a link error here rather than a crash the first time a thread starts.
	args[#args + 1] = "-Wl,--no-undefined"
end

if isMsvc then
	args[#args + 1] = "-Wl,/OPT:REF"
end

build:cc(args)

if not build:exists(library) then
	error("threading's native library did not build: " .. library)
end
