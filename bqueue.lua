--
-- A "blocking queue" for the Lua Event Machine
--
-- Usage:
--
-- bqueue = require 'bqueue'
-- load the module
--
-- queue = bqueue.new()
-- create a new queue
--
-- queue:put(x)
-- put x into the queue, this always succeeds immediately
--
-- r, err = queue:get(timeout)
-- returns the first element in the queue or suspends the
-- current current coroutine until an element is put on the queue
-- if timeout is non-nil it shall return nil, 'timeout' if nothing is
-- put on the queue within timeout seconds
--

local utils = require 'lem.utils'

local remove     = table.remove

local BQueue = {}
BQueue.__index = BQueue

function BQueue:put(x)
	if self.sleeper:wakeup(x) then return end

	local n = self.n + 1
	self[n] = x
	self.n = n
end

function BQueue:get(timeout)
	local n = self.n
	if n == 0 then
		return self.sleeper:sleep(timeout)
	end

	self.n = n - 1
	return remove(self, 1)
end

local setmetatable, newsleeper = setmetatable, utils.newsleeper

local function new()
	return setmetatable({
		sleeper = newsleeper(),
		n = 0,
	}, BQueue)
end

return {
	BQueue = BQueue,
	new = new,
}

-- vim: set ts=2 sw=2 noet:
