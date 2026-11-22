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

test.it("runs many jobs on one worker", function()
	local pool = threading.pool(1, function(value) return value * 2 end)
	for index = 1, 5 do
		local handle = pool:run(index)
		test.truthy(handle ~= nil, "a free worker takes the job")
		test.equal(handle:join(), index * 2)
	end
	pool:close()
end)

test.it("hands jobs to a pool's free workers", function()
	local pool = threading.pool(2, function(value)
		require("threading").sleep(50)
		return value
	end)
	local first = pool:run(1)
	local second = pool:run(2)
	test.truthy(first ~= nil and second ~= nil, "both workers take a job")
	test.equal(pool:run(3), nil, "a busy pool refuses another job")
	test.equal(first:join(), 1)
	local third = pool:run(3)
	test.truthy(third ~= nil, "a joined worker is free again")
	test.equal(second:join(), 2)
	test.equal(third:join(), 3)
	pool:close()
end)

test.it("keeps a pool worker's state between jobs", function()
	local seen = 0
	local pool = threading.pool(1, function(delta)
		seen += delta
		return seen
	end)
	test.equal(pool:run(1):join(), 1)
	test.equal(pool:run(2):join(), 3)
	pool:close()
end)

test.it("raises a job's error without stopping the pool", function()
	local pool = threading.pool(1, function(fail)
		if fail then error("job failed") end
		return "ok"
	end)
	local bad = pool:run(true)
	local ok, err = pcall(bad.join, bad)
	test.falsy(ok)
	test.truthy(tostring(err):find("job failed", 1, true), err)
	test.equal(pool:run(false):join(), "ok")
	pool:close()
end)
