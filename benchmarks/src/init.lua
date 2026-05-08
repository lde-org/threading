local threading = require("threading")

local function bench(name, n, fn)
	local t0 = os.clock()
	for _ = 1, n do fn() end
	local elapsed = os.clock() - t0
	local us = (elapsed / n) * 1e6
	io.write(string.format("%-40s  %6d iters  %8.2f us/op  %8.0f ops/s\n",
		name, n, us, n / elapsed))
end

-- spawn + join, no return value
bench("spawn+join (no-op)", 200, function()
	threading.spawn(function() end):join()
end)

-- spawn + join, return a number
bench("spawn+join (return number)", 200, function()
	local v = threading.spawn(function() return 42 end):join()
	assert(v == 42)
end)

-- spawn + join, return a string
bench("spawn+join (return string)", 200, function()
	local v = threading.spawn(function() return "hello" end):join()
	assert(v == "hello")
end)

-- spawn + join with primitive upvalues
local x, s, b = 99, "world", true
bench("spawn+join (3 upvalues)", 200, function()
	local a, c, d = threading.spawn(function() return x, s, b end):join()
	assert(a == 99 and c == "world" and d == true)
end)

-- concurrent: spawn N then join all
local function concurrent(n)
	bench("concurrent spawn+join x" .. n, 20, function()
		local handles = {}
		for i = 1, n do
			handles[i] = threading.spawn(function() return 1 end)
		end
		for i = 1, n do
			assert(handles[i]:join() == 1)
		end
	end)
end
concurrent(4)
concurrent(8)
concurrent(16)

-- parallel compute vs serial
local N = 1000000
local function serial_sum()
	local t0 = os.clock()
	local sum = 0
	for i = 1, N do sum = sum + i end
	return os.clock() - t0, sum
end

local function parallel_sum(nthreads)
	local chunk = N / nthreads
	local t0 = os.clock()
	local handles = {}
	for t = 1, nthreads do
		local lo = (t - 1) * chunk + 1
		local hi = t * chunk
		handles[t] = threading.spawn(function()
			local acc = 0
			for i = lo, hi do acc = acc + i end
			return acc
		end)
	end
	local total = 0
	for t = 1, nthreads do total = total + handles[t]:join() end
	return os.clock() - t0, total
end

local st, ss = serial_sum()
local pt2, ps2 = parallel_sum(2)
local pt4, ps4 = parallel_sum(4)

assert(ss == ps2 and ss == ps4, "sum mismatch")
io.write(string.format("\nsum 1..%d\n", N))
io.write(string.format("  serial:      %.4f s\n", st))
io.write(string.format("  parallel x2: %.4f s  (%.2fx)\n", pt2, st / pt2))
io.write(string.format("  parallel x4: %.4f s  (%.2fx)\n", pt4, st / pt4))
