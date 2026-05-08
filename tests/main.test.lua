local test = require("lde-test")
local threading = require("threading")

test.it("spawns and joins a no-op thread", function()
	local h = threading.spawn(function() end)
	h:join()
end)

test.it("rejects closures with upvalues", function()
	local x = 42
	local ok, err = pcall(threading.spawn, function() return x end)
	assert(not ok, "expected error for upvalue closure")
	assert(err:find("upvalue"), "wrong error: " .. tostring(err))
end)

test.it("thread actually executes code", function()
	local flag = "/tmp/lde_thread_test_flag"
	os.remove(flag)
	local h = threading.spawn(function()
		local f = io.open("/tmp/lde_thread_test_flag", "w")
		if f then
			f:write("ran"); f:close()
		end
	end)
	h:join()
	local f = io.open(flag, "r")
	assert(f, "thread did not create flag file")
	local content = f:read("*a")
	f:close()
	os.remove(flag)
	assert(content == "ran", "unexpected content: " .. content)
end)

test.it("spawns multiple threads concurrently", function()
	local handles = {} ---@type threading.Handle[]
	for i = 1, 8 do
		handles[i] = threading.spawn(function() end)
	end

	for _, h in ipairs(handles) do
		h:join()
	end
end)

test.it("sleep does not error", function()
	threading.sleep(10)
end)
