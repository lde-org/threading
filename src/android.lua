-- Where an Android app's Lua runtime is. A NativeActivity loads the library holding it -- lde's
-- `libmain.so` -- privately, so the process does not export it the way an executable does; the
-- library is opened again by its name, which hands back the one already loaded.
local ffi = require("ffi")

local android = {}

-- What the manifest names the activity's library (android.app.lib_name), which is lde's.
local LIBRARY = "main"

---@return ffi.namespace*
function android.luaLibrary()
	local ok, library = pcall(ffi.load, LIBRARY)
	if not ok then
		error("threading: the Lua runtime library (lib" .. LIBRARY .. ".so) could not be opened: " .. tostring(library))
	end
	return library
end

return android
