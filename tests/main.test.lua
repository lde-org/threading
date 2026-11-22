local test = require("lde-test")
local threading = require("threading")

test.it("spawns and joins a no-op thread", function()
	threading.spawn(function() end):join()
end)

test.it("rejects an upvalue that cannot be copied", function()
	local helper = function() end
	local ok, err = pcall(threading.spawn, function() return helper() end)
	test.falsy(ok)
	test.truthy(tostring(err):find("helper", 1, true), err)
end)

test.it("copies primitive upvalues into the thread", function()
	local x, s, b = 10, "hi", true
	local a, c, d = threading.spawn(function() return x, s, b end):join()
	test.equal(a, 10)
	test.equal(c, "hi")
	test.equal(d, true)
end)

test.it("copies tables both ways", function()
	local input = { 1, 2, 3, name = "list" }
	local out = threading.spawn(function()
		local sum = 0
		for _, value in ipairs(input) do sum = sum + value end
		return { sum = sum, name = input.name }
	end):join()
	test.equal(out.sum, 6)
	test.equal(out.name, "list")
end)

test.it("keeps nils in the middle of what a thread returns", function()
	local a, b, c = threading.spawn(function() return 1, nil, 3 end):join()
	test.equal(a, 1)
	test.equal(b, nil)
	test.equal(c, 3)
end)

test.it("returns nothing for a function that returns nothing", function()
	test.equal(select("#", threading.spawn(function() end):join()), 0)
end)

test.it("raises a thread's error on join", function()
	local handle = threading.spawn(function() error("something went wrong") end)
	local ok, err = pcall(handle.join, handle)
	test.falsy(ok)
	test.truthy(tostring(err):find("something went wrong", 1, true), err)
end)

test.it("says whether a thread is done without waiting", function()
	local handle = threading.spawn(function()
		local threading = require("threading")
		threading.sleep(150)
		return "slept"
	end)
	test.falsy(handle:done())
	while not handle:done() do threading.sleep(5) end
	test.equal(handle:join(), "slept")
	test.truthy(handle:done())
end)

test.it("answers the same when joined again", function()
	local handle = threading.spawn(function() return 7 end)
	test.equal(handle:join(), 7)
	test.equal(handle:join(), 7)
end)

test.it("requires modules inside a thread", function()
	local kind = threading.spawn(function()
		return type(require("threading").spawn)
	end):join()
	test.equal(kind, "function")
end)

test.it("runs threads at the same time", function()
	local handles = {}
	local started = os.time()
	for index = 1, 8 do
		handles[index] = threading.spawn(function()
			require("threading").sleep(200)
			return index * index
		end)
	end
	for index, handle in ipairs(handles) do
		test.equal(handle:join(), index * index)
	end
	-- Eight 200 ms sleeps one after another are well over a second.
	test.truthy(os.time() - started <= 1)
end)

test.it("starts and joins many threads in a row", function()
	for index = 1, 200 do
		test.equal(threading.spawn(function() return index end):join(), index)
	end
end)
