#!/usr/bin/env lem

local sha1    = require 'sha1'
local utils   = require 'lem.utils'
local streams = require 'lem.streams'
local sqlite  = require 'lem.sqlite3'
local bqueue  = require 'bqueue'

local assert, error  = assert, error
local type, tostring = type, tostring
local format = string.format

local db      = assert(sqlite.open(arg[1] or 'test.db', sqlite.READWRITE))
local timeout = 30

--- some helper functions ---

local rprint = print
local function print(...) return rprint(format(...)) end
local function clearscreen() rprint "\x1B[1J\x1B[H" end

local function main_menu()
	print "-------------------------------------------"
	print "   Swipe card to log in."
	print "   Scan barcode to check price of product."
	print ""
	print "  1  | Create new account."
	print "  2  | Update or create new product."
	print "  -  | Print this menu."
	print "-------------------------------------------"

	local r = assert(db:fetchone(
		"SELECT SUM(balance)/COUNT(1), MIN(balance) FROM users"))
	print(" Average balance:     %16.2f DKK", r[1])
	print(" Largest single debt: %16.2f DKK", r[2])
end

local function user_menu()
	print "-------------------------------------------"
	print "   Swipe card to switch user."
	print "   Scan barcode to buy product."
	print "   Press enter to log out."
	print ""
	print "  /  | Add money to account."
	print "  *  | Switch card."
	print " <n> | Buy <n> items."
	print "  -  | Print this menu."
	print "-------------------------------------------"
end

local function idle()
	clearscreen()
	main_menu()
	return 'IDLE'
end

local function login(hash, id)
	local r = assert(db:fetchone("\z
		SELECT id, name, balance \z
		FROM users \z
		WHERE hash = ?", hash))

	if r == true then
		if id then
			clearscreen()
			print " Unknown card swiped, logged out."
			main_menu()
		else
			print " Unknown card swiped.."
		end
		return 'MAIN'
	end

	clearscreen()
	print("-------------------------------------------")
	print(" Logged in as : %s", r[2])
	print(" Balance      : %.2f DKK", r[3])
	print("")
	print(" NB. If your name is just numbers,")
	print("     please tell Esmil to change it.")
	user_menu()
	return 'USER', r[1]
end

local function product_dump(p)
	print("-------------------------------------------")
	print(" Product : %s", p[1])
	print(" Price   : %.2f DKK", p[2])
	print("-------------------------------------------")
end

--- declare states ---

MAIN = {
	wait = timeout,
	timeout = idle,

	card = login,

	barcode = function(code)
		print " Price check.."

		local r = assert(db:fetchone(
			"SELECT name, price FROM products	WHERE barcode = ?", code))
		if r == true then
			print " Unknown product."
			return 'MAIN'
		end

		product_dump(r)
		return 'MAIN'
	end,

	keyboard = {
		['1'] = function()
			print " Please enter user name (or press enter to abort):"
			return 'NEWUSER_NAME'
		end,
		['2'] = function()
			print(" Scan barcode (or press enter to abort):")
			return 'PROD_CODE'
		end,
		['-'] = function()
			main_menu()
			return 'MAIN'
		end,
		[''] = function()
			print(" ENTAR!")
			return 'MAIN'
		end,
		function(cmd) --default
			print(" Unknown command '%s'.", cmd)
			main_menu()
			return 'MAIN'
		end,
	},
}

IDLE = {
	card     = MAIN.card,
	barcode  = MAIN.barcode,
	keyboard = MAIN.keyboard,
}

NEWUSER_NAME = {
	wait = 120, -- allow 2 minutes for typing account name
	timeout = function()
		print " Aborted due to inactivity."
		return 'MAIN'
	end,

	card = login,

	barcode = 'NEWUSER_NAME',

	keyboard = {
		[''] = function()
			print " Aborted."
			return 'MAIN'
		end,
		function(name) --default
			print(" Hello %s! Please swipe your card..", name)
			return 'NEWUSER_HASH', name
		end,
	},
}

NEWUSER_HASH = {
	wait = timeout,
	timeout = function()
		print " Aborted due to inactivity."
		return 'MAIN'
	end,

	card = function(hash, name)
		print " Card swiped, thank you! Creating account.."

		local ok, err = db:fetchone("\z
			INSERT INTO users (name, hash, balance) \z
			VALUES (?, ?, 0.0)", name, hash)

		if not ok then
			print(" Error creating account: %s", err)
			return 'MAIN'
		end

		return login(hash)
	end,

	barcode = 'NEWUSER_HASH',

	keyboard = function()
		print " Aborted."
		return 'MAIN'
	end,
}

PROD_CODE = {
	wait = timeout,
	timeout = function()
		print " Aborted due to inactivity."
		return 'MAIN'
	end,

	card = login,

	barcode = function(code)
		print(" Scanned: %s", code)

		local r = assert(db:fetchone("\z
			SELECT id, name, price \z
			FROM products \z
			WHERE barcode = ?", code))

		if r == true then
			print " Not found in database, creating new product."
			print " Type name of product (or press enter to abort):"
			return 'PROD_NEW_NAME', code
		end

		print(" Already in database, updating info.")
		print(" Type name of product (or press enter to keep '%s'):", r[2])
		return 'PROD_EDIT_NAME', { id = r[1], name = r[2], price = r[3] }
	end,

	keyboard = function()
		print " Aborted."
		return 'MAIN'
	end,
}

PROD_NEW_NAME = {
	wait = 120, -- allow 2 minutes for typing product name
	timeout = function()
		print " Aborted due to inactivity."
		return 'MAIN'
	end,

	card = login,

	barcode = 'PROD_NEW_NAME',

	keyboard = {
		[''] = function()
			print " Aborted."
			return 'MAIN'
		end,
		function(name, code) --default
			print " Enter price (or press enter to abort):"
			return 'PROD_NEW_PRICE', name, code
		end,
	},
}

PROD_NEW_PRICE = {
	wait = timeout,
	timeout = function()
		print " Aborted due to inactivity."
		return 'MAIN'
	end,

	card = login,

	barcode = 'PROD_NEW_PRICE',

	keyboard = {
		[''] = function()
			print " Aborted."
			return 'MAIN'
		end,
		function(price, name, code) --default
			local n = tonumber(price)
			if not n then
				print(" Unable to parse '%s', try again (or press enter to abort):", price)
				return 'PROD_NEW_PRICE', name, code
			end

			print " Creating new product.."

			local ok, err = db:fetchone("\z
				INSERT INTO products (barcode, price, name) \z
				VALUES (?, ?, ?)", code, n, name)

			if not ok then
				print(" Error creating product: %s", err)
				return 'MAIN'
			end

			product_dump(assert(db:fetchone(
				"SELECT name, price FROM products	WHERE barcode = ?", code)))
			return 'MAIN'
		end,
	},
}

PROD_EDIT_NAME = {
	wait = 120, -- allow 2 minutes for typing product name
	timeout = function()
		print " Aborted due to inactivity."
		return 'MAIN'
	end,

	card = login,

	barcode = 'PROD_EDIT_NAME',

	keyboard = function(name, product)
		if name ~= '' then
			product.name = name
		end

		print(" Type new price (or press enter to keep %.2f DKK):", product.price)
		return 'PROD_EDIT_PRICE', product
	end,
}

PROD_EDIT_PRICE = {
	wait = timeout,
	timeout = function()
		print " Aborted due to inactivity."
		return 'MAIN'
	end,

	card = login,

	barcode = 'PROD_EDIT_PRICE',

	keyboard = function(price, product)
		if price ~= '' then
			local n = tonumber(price)
			if not n then
				print(" Unable to parse '%s', try again (or press enter to keep %.2f DKK):",
					price, product.price)
				return 'PROD_EDIT_PRICE', product
			end
			product.price = n
		end

		print " Updating product.."

		local ok, err = db:fetchone("\z
			UPDATE products \z
			SET name = ?, price = ? \z
			WHERE id = ?", product.name, product.price, product.id)

		if not ok then
			print(" Error updating product: %s", err)
			return 'MAIN'
		end

		product_dump(assert(db:fetchone(
			"SELECT name, price FROM products WHERE id = ?", product.id)))
		return 'MAIN'
	end,
}

USER = {
	wait = timeout,
	timeout = idle,

	card = login,

	barcode = function(code, id, count)
		local r = assert(db:fetchone("\z
			SELECT id, name, price \z
			FROM products \z
			WHERE barcode = ?", code))

		if r == true then
			print " Unknown product.."
			return 'USER', id
		end

		local pid = r[1]
		local price = r[3]

		if count then
			print(" Buying %s for %d * %.2f = %.2f DKK",
				r[2], count, price, count * price)
		else
			print(" Buying %s for %.2f DKK", r[2], price)
			count = 1
		end

		assert(db:exec("\z
			BEGIN; \z
			UPDATE users SET balance = balance - @count * @price WHERE id = @id; \z
			INSERT INTO log (dt, uid, pid, count, price) \z
				VALUES (datetime('now'), @id, @pid, @count, @price); \z
			COMMIT", { id = id, pid = pid, count = count, price = price }))

		r = assert(db:fetchone(
			"SELECT balance FROM users WHERE id = ?", id))
		print(" New balance: %.2f DKK", r[1])

		return 'USER', id
	end,

	keyboard = {
		['/'] = function(id)
			print " Enter amount (or press enter to abort):"
			return 'DEPOSIT', id
		end,
		['*'] = function(id)
			print " Swipe new card (or press enter to abort):"
			return 'SWITCH_CARD', id
		end,
		['-'] = function(id)
			user_menu()
			return 'USER', id
		end,
		['n'] = function(id)
			print " Sigh. A number. That is [1-9][0-9]*"
			return 'USER', id
		end,
		[''] = function(id, count)
			if count then
				print " Aborted."
				return 'USER', id
			end

			return idle()
		end,
		function(cmd, id) --default
			local count = tonumber(cmd)
			if count then
				print(" Buying %d of the next thing scanned. Press ENTER to abort.",
					count)
				return 'USER', id, count
			end

			print(" Unknown command '%s'.", cmd)
			user_menu()
			return 'USER', id
		end,
	},
}

DEPOSIT = {
	wait = timeout,
	timeout = function(_, id)
		print " Aborted due to inactivity."
		return 'USER', id
	end,

	card = login,

	barcode = 'DEPOSIT',

	keyboard = {
		[''] = function(id)
			print " Aborted."
			return 'USER', id
		end,
		function(amount, id) --default
			local n = tonumber(amount)
			if not n then
				print(" Unable to parse '%s', try again (or press enter to abort):", amount)
				return 'DEPOSIT', id
			end

			print(" Inserting %.2f DKK", n)
			assert(db:fetchone("\z
				UPDATE users \z
				SET balance = balance + ? \z
				WHERE id = ?", n, id))

			local r = assert(db:fetchone(
				"SELECT balance FROM users WHERE id = ?", id))
			print(" New balance: %.2f DKK", r[1])

			return 'USER', id
		end,
	},
}

SWITCH_CARD = {
	wait = timeout,
	timeout = function(_, id)
		print " Aborted due to inactivity."
		return 'USER', id
	end,

	card = function(hash, id)
		print "Updating hash.."
		local ok, err = db:fetchone(
			"UPDATE users SET hash = ? WHERE id = ?", hash, id)
		if not ok then
			print("Error updating hash: %s", err)
		else
			print("Done.")
		end

		return 'USER', id
	end,

	barcode = 'SWITCH_CARD',

	keyboard = function(_, id)
		print " Aborted."
		return 'USER', id
	end,
}

--- the "engine" ---

-- all input events goes through this queue
local input = bqueue.new()

-- spawn coroutines to read from
-- inputs and add to the input queue
utils.spawn(function()
	local stdin = streams.stdin
	while true do
		local line = assert(stdin:read('*l'))
		input:put{ from = 'keyboard', data = line }
	end
end)

utils.spawn(function()
	local ins = assert(streams.open(arg[2] or 'card', 'r'))
	local ctx = sha1.new()
	while true do
		local line = assert(ins:read('*l', '\r'))
		input:put{ from = 'card', data = ctx:add(line):add('\r'):hex() }
	end
end)

utils.spawn(function()
	local ins = assert(streams.open(arg[3] or 'barcode', 'r'))
	while true do
		local line = assert(ins:read('*l', '\r'))
		input:put{ from = 'barcode', data = line }
	end
end)

-- this is function reads events from the
-- input queue and "runs" the state machine
local function run(...)
	local valid_sender = {
		timeout = true,
		card = true,
		barcode = true,
		keyboard = true
	}

	local handle_state

	local lookup = {
		['string']   = function(s, data, ...) return handle_state(s, ...) end,
		['function'] = function(f, data, ...) return handle_state(f(data, ...)) end,
		['table']    = function(t, data, ...)
			local f = t[data]
			if f then return handle_state(f(...)) end
			f = assert(t[1], 'no default handler found')
			return handle_state(f(data, ...))
		end,
	}

	function handle_state(str, ...)
		local state = _ENV[str]
		if not state then
			error(format("%s: invalid state", tostring(str)))
		end

		local cmd, err = input:get(state.wait)
		if not cmd then
			if err == 'timeout' then
				cmd = { from = 'timeout', data = 'timeout' }
			else
				error(err)
			end
		end

		if not valid_sender[cmd.from] then
			error(format("%s: spurirous command from '%s'", str, tostring(cmd.from)))
		end

		local edge = state[cmd.from]
		if not edge then
			error(format("%s: no edge defined for '%s'", str, cmd.from))
		end

		local handler = lookup[type(edge)]
		if not handler then
			error(format("%s: invalid edge '%s'", str, cmd.from))
		end

		return handler(edge, cmd.data, ...)
	end

	return handle_state(...)
end

return run(idle())

-- vim: set ts=2 sw=2 noet:
