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

test.it("queues messages on a channel and pops them in order", function()
	local channel = threading.channel()
	test.truthy(channel:push({ kind = "one", value = 1 }))
	test.truthy(channel:push("two", true, nil, 3))
	test.equal(channel:count(), 2)

	local first = channel:pop()
	test.equal(first.kind, "one")
	test.equal(first.value, 1)

	local text, flag, nothing, number = channel:pop()
	test.equal(text, "two")
	test.equal(flag, true)
	test.equal(nothing, nil)
	test.equal(number, 3)
	test.equal(channel:pop(), nil)
	channel:close()
end)

test.it("waits for a message or the time running out", function()
	local channel = threading.channel()
	local started = os.clock()
	test.falsy(channel:wait(10))
	channel:push("ready")
	test.truthy(channel:wait(10))
	test.equal(channel:pop(), "ready")
	channel:close()
end)

test.it("waits without a timeout until another thread pushes", function()
	local channel = threading.channel()
	local address = channel:address()

	local handle = threading.spawn(function()
		local threading = require("threading")
		local inbox = threading.channelFromAddress(address)
		local available = inbox:wait(math.huge)
		return available, inbox:pop()
	end)

	threading.sleep(100)
	test.falsy(handle:done())
	test.truthy(channel:push("wake"))

	local available, message = handle:join()
	test.truthy(available)
	test.equal(message, "wake")
	channel:close()
end)

test.it("wakes a wait without a timeout when the channel closes", function()
	local channel = threading.channel()
	local address = channel:address()
	local ready = threading.channel()
	local readyAddress = ready:address()

	local handle = threading.spawn(function()
		local threading = require("threading")
		local inbox = threading.channelFromAddress(address)
		local signal = threading.channelFromAddress(readyAddress)
		signal:push(true)
		threading.sleep(100)
		inbox:close()
	end)

	test.truthy(ready:wait(2000))
	test.falsy(channel:wait(math.huge))
	handle:join()
	ready:close()
	channel:close()
end)

test.it("carries tables and keeps a nil in the middle", function()
	local channel = threading.channel()
	channel:push({ n = 3, 1, nil, 3 })
	local message = channel:pop()
	test.equal(message.n, 3)
	test.equal(message[1], 1)
	test.equal(message[2], nil)
	test.equal(message[3], 3)
	channel:close()
end)

test.it("passes messages between threads by address", function()
	local commands = threading.channel()
	local events = threading.channel()
	local commandAddress, eventAddress = commands:address(), events:address()

	local handle = threading.spawn(function()
		local threading = require("threading")
		local inbox = threading.channelFromAddress(commandAddress)
		local outbox = threading.channelFromAddress(eventAddress)

		local command = inbox:pop()
		outbox:push({ kind = "answer", got = command.kind, value = command.value + 1 })

		local quit = inbox:pop()
		while quit == nil do
			inbox:wait(100)
			quit = inbox:pop()
		end
		outbox:push({ kind = "bye", said = quit.kind })
		inbox:close()
		outbox:close()
	end)

	commands:push({ kind = "question", value = 41 })
	test.truthy(events:wait(2000))
	local answer = events:pop()
	test.equal(answer.kind, "answer")
	test.equal(answer.got, "question")
	test.equal(answer.value, 42)

	commands:push({ kind = "quit" })
	test.truthy(events:wait(2000))
	test.equal(events:pop().said, "quit")

	handle:join()
	commands:close()
	events:close()
end)

test.it("refuses a push on a closed channel", function()
	local channel = threading.channel()
	channel:push("last")
	test.equal(channel:pop(), "last")
	channel:close()
	test.falsy(channel:push("after"))
end)
