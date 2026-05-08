local test = require("lde-test")
local threading = require("threading")

test.it("spawns and joins a no-op thread", function()
	local h = threading.spawn(function() end)
	h:join()
end)

test.it("rejects closures with non-serializable upvalues", function()
	local t = {}
	local ok, err = pcall(threading.spawn, function() return t end)
	assert(not ok, "expected error")
	assert(err:find("non%-serializable"), "wrong error: " .. tostring(err))
end)

test.it("serializes primitive upvalues into the thread", function()
	local x = 10
	local s = "hi"
	local b = true
	local h = threading.spawn(function() return x, s, b end)
	local a, c, d = h:join()
	assert(a == 10 and c == "hi" and d == true)
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

test.it("join returns a number", function()
	local h = threading.spawn(function() return 42 end)
	assert(h:join() == 42)
end)

test.it("join returns a string", function()
	local h = threading.spawn(function() return "hello" end)
	assert(h:join() == "hello")
end)

test.it("join returns nil for no return value", function()
	assert(threading.spawn(function() end):join() == nil)
end)

test.it("join returns multiple values", function()
	local a, b, c = threading.spawn(function() return 1, "two", true end):join()
	assert(a == 1 and b == "two" and c == true)
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
