-- Run through tests/run.sh with qbcore and qbsql checked out beside qbhousing.
-- Only the FiveM host and SQL driver callbacks are simulated, not purchase,
-- housing copy/persistence, the money ledger, or the qbsql consumer adapter.
local core = '../qbcore/'
local h = dofile(core .. 'test/harness.lua')
dofile(core .. 'test/mocks.lua').install()
for _, path in ipairs({
    'config.lua', 'shared/items.lua', 'shared/jobs.lua', 'shared/gangs.lua',
    'shared/vehicles.lua', 'shared/weapons.lua', 'shared/locations.lua',
    'modules/util/shared.lua', 'modules/registry/shared.lua', 'modules/registry/server.lua',
    'modules/player/shared.lua', 'modules/replication/server.lua',
    'modules/persistence/server.lua', 'modules/player/server.lua', 'modules/money/server.lua',
}) do dofile(core .. path) end

local buyer, realtor, seller, secondBuyer = 8, 9, 10, 11
local buyerCid, realtorCid, sellerCid, secondCid = 'HOUSE_BUYER', 'HOUSE_REALTOR', 'HOUSE_SELLER', 'HOUSE_SECOND'
for src, cid in pairs({ [buyer] = buyerCid, [realtor] = realtorCid, [seller] = sellerCid, [secondBuyer] = secondCid }) do
    local data = CoreInternal.player.freshData(cid, 'license:' .. cid, 1, { firstname = cid, lastname = 'Test' })
    assert(Core.player.login(src, cid, data))
end
assert(Core.player.setPath(realtor, { 'job', 'name' }, 'realestate'))

local now = os.time()
local busyMessage = 'This property is being updated. Please try again.'
local writeError = 'ER_LOCK_WAIT_TIMEOUT: simulated database write failure'

local function definition(id, owner)
    return {
        id = id, owner = owner, state = 'listed', keys = { OLD_KEYHOLDER = true },
        listing = { price = 5000, type = 'open_market', realtor = realtorCid },
        pending = { buyer = buyerCid, expires = now + 300 },
        interior = { type = 'mlo' }, furniture = { { model = 'chair' } },
        -- Opaque required definition data; no integration or flow is exercised.
        garage = { coords = {}, spawn = {}, slots = 2 },
    }
end

local function setup(owner)
    for _, src in ipairs({ buyer, realtor, seller, secondBuyer }) do
        assert(Core.money.setMoney(src, 'bank', 10000))
    end
    local f = { callbacks = {}, provided = {}, sqlCalls = {}, moneyCalls = {}, commissions = {}, events = {} }
    local driver = {}
    local function submit(kind, statement, params, callback)
        local request = { kind = kind, statement = statement, params = params, callback = callback }
        f.sqlCalls[#f.sqlCalls + 1] = request
        if f.beforeWrite then f.beforeWrite(request) end
        if f.pauseNextWrite then
            f.pauseNextWrite, f.pending = false, request
        elseif f.failWrite then
            if f.falseResult then callback(false) else callback(nil, writeError) end
        else
            callback(kind == 'transaction' and true or { affectedRows = 1 })
        end
    end
    function driver.execute(_, statement, params, callback) submit('execute', statement, params, callback) end
    -- Lets the same checks run against the pre-fix source as a negative control.
    function driver.transaction(_, statements, callback) submit('transaction', statements, nil, callback) end

    local resourceExports = { qbsql = driver, qbcore = {}, qbbanking = {} }
    function resourceExports.qbcore.getPlayer(_, src) return Core.player.getPlayer(src) end
    function resourceExports.qbcore.getPlayerByCitizenId(_, cid) return Core.player.getPlayerByCitizenId(cid) end
    function resourceExports.qbcore.removeMoney(_, src, account, amount, reason, ignoreTax)
        f.moneyCalls[#f.moneyCalls + 1] = { action = 'remove', src = src, account = account, amount = amount, reason = reason, ignoreTax = ignoreTax }
        if f.rejectDebit then
            -- Controlled rejection branch, not a claim about real FiveM scheduling:
            -- spend to the configured account floor after housing's balance read.
            f.rejectDebit = false
            assert(Core.money.removeMoney(src, account, Core.money.getMoney(src, account) - Config.money.minusLimit, 'Other purchase', true))
        end
        return Core.money.removeMoney(src, account, amount, reason, ignoreTax)
    end
    function resourceExports.qbcore.addMoney(_, src, account, amount, reason, ignoreTax)
        f.moneyCalls[#f.moneyCalls + 1] = { action = 'add', src = src, account = account, amount = amount, reason = reason, ignoreTax = ignoreTax }
        return Core.money.addMoney(src, account, amount, reason, ignoreTax)
    end
    function resourceExports.qbbanking.AddMoney(_, account, amount, reason)
        if f.beforeCommission then f.beforeCommission() end
        f.commissions[#f.commissions + 1] = { account = account, amount = amount, reason = reason }
        return true
    end
    -- FiveM's exports global must be both callable and indexable.
    setmetatable(resourceExports, { __call = function(_, name, fn) f.provided[name] = fn end })
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env.Config, env.Housing = nil, nil
    env.exports = resourceExports
    env.QB = {
        callback = { register = function(name, fn) f.callbacks[name] = fn end },
        permissions = { hasPermission = function() return false end },
    }
    env.GetCurrentResourceName = function() return 'qbhousing' end
    env.CreateThread, env.RegisterNetEvent = function() end, function() end
    env.TriggerClientEvent = function(name, target, ...) f.events[#f.events + 1] = { name = name, target = target, args = { ... } } end
    env.os = { time = function() return now end }
    env.promise = { new = function()
        return {
            resolve = function(p, value) p.settled, p.value = true, value end,
            reject = function(p, err) p.settled, p.err = true, err end,
        }
    end }
    env.Citizen = { Await = function(p)
        if not p.settled then coroutine.yield('database wait') end
        assert(p.settled, 'Resolve the controlled SQL callback before resuming')
        if p.err then error(p.err, 0) end
        return p.value
    end }
    local function load(path) assert(loadfile(path, 't', env))() end
    load('../qbsql/init.lua')
    load('config.lua'); load('shared/schema.lua'); load('server/state.lua')
    load(arg[1] or 'server/main.lua')
    f.env, f.state = env, env.Housing.state
    f.state.ready = true
    f.state.properties.home = assert(env.Housing.normalise(definition('home', owner)))
    f.state.properties.other = assert(env.Housing.normalise(definition('other')))
    f.state.properties.other.pending.buyer = secondCid
    function f.call(name, ...) return assert(f.callbacks['qbhousing:' .. name])(...) end
    function f.complete(thread, value, err)
        assert(f.pending, 'Expected a pending SQL request').callback(value, err)
        f.pending = nil
        local ok, result, failure = coroutine.resume(thread)
        assert(ok, result)
        assert(coroutine.status(thread) == 'dead', 'Callback should finish after one SQL write')
        return result, failure
    end
    return f
end

local function start(fn)
    local thread = coroutine.create(fn)
    local ok, err = coroutine.resume(thread)
    assert(ok, err)
    assert(coroutine.status(thread) == 'suspended', 'Expected the SQL consumer adapter to wait')
    return thread
end

local function assertListed(f, original)
    h.assertEqual(f.state.properties.home, original, 'Keep the original live table on failure')
    h.assertEqual(original.owner, nil)
    h.assertEqual(original.state, 'listed')
    h.assertEqual(original.pending.buyer, buyerCid)
    h.assertEqual(f.provided.HasAccess(buyer, 'home'), false, 'Failed purchase must not grant access')
end

h.test('invalid, expired, wrong-buyer and insufficient-balance confirmations have no side effects', function()
    local f = setup()
    h.assertEqual(f.call('confirmPurchase', buyer, 'missing'), nil)
    f.state.properties.home.pending.expires = now - 1
    h.assertEqual(f.call('confirmPurchase', buyer, 'home'), nil)
    f.state.properties.home.pending.expires = now + 300
    h.assertEqual(f.call('confirmPurchase', secondBuyer, 'home'), nil)
    assert(Core.money.setMoney(buyer, 'bank', 4999))
    h.assertEqual(f.call('confirmPurchase', buyer, 'home'), nil)
    h.assertEqual(#f.sqlCalls, 0); h.assertEqual(#f.moneyCalls, 0)
    assertListed(f, f.state.properties.home)
end)

for _, falseResult in ipairs({ false, true }) do
    h.test((falseResult and 'false' or 'nil/error') .. ' persistence failure refunds without changing live ownership, and allows retry', function()
        local f = setup()
        local original = f.state.properties.home
        local before = json.encode(original)
        f.failWrite, f.falseResult = true, falseResult
        local saved, err = f.call('confirmPurchase', buyer, 'home')
        h.assertEqual(saved, nil); h.assertTrue(type(err) == 'string')
        assertListed(f, original)
        h.assertEqual(json.encode(original), before, 'All original property fields survive')
        h.assertEqual(Core.money.getMoney(buyer, 'bank'), 10000)
        h.assertEqual(#f.sqlCalls, 1); h.assertEqual(#f.events, 0); h.assertEqual(#f.commissions, 0)
        local refund = f.moneyCalls[2]
        h.assertEqual(refund.action, 'add'); h.assertEqual(refund.account, 'bank')
        h.assertEqual(refund.amount, 5000); h.assertEqual(refund.reason, 'Property purchase rollback')
        h.assertEqual(refund.ignoreTax, true)
        f.failWrite = false
        h.assertTrue(f.call('confirmPurchase', buyer, 'home'), 'A failed write must release the guard')
        h.assertEqual(#f.sqlCalls, 2)
    end)
end

h.test('controlled actual money rejection keeps the listing unchanged, performs no SQL and releases the guard', function()
    local f = setup()
    local original = f.state.properties.home
    f.rejectDebit = true
    local saved, err = f.call('confirmPurchase', buyer, 'home')
    h.assertEqual(saved, nil); h.assertEqual(err, 'Payment failed; no changes were made.')
    assertListed(f, original)
    h.assertEqual(#f.sqlCalls, 0); h.assertEqual(#f.moneyCalls, 1)
    h.assertEqual(Core.money.getMoney(buyer, 'bank'), Config.money.minusLimit)
    assert(Core.money.setMoney(buyer, 'bank', 10000))
    h.assertTrue(f.call('confirmPurchase', buyer, 'home'))
    h.assertEqual(#f.sqlCalls, 1)
end)

h.test('successful purchase writes once before publication and commissions, preserving the returned property', function()
    local f = setup(sellerCid)
    f.beforeWrite = function()
        h.assertEqual(f.state.properties.home.owner, sellerCid, 'Ownership stays old until write succeeds')
        h.assertEqual(f.provided.HasAccess(buyer, 'home'), false)
        h.assertEqual(Core.money.getMoney(buyer, 'bank'), 5000, 'Payment precedes persistence')
        h.assertEqual(Core.money.getMoney(seller, 'bank'), 10000)
        h.assertEqual(#f.commissions, 0); h.assertEqual(#f.events, 0)
    end
    f.beforeCommission = function() h.assertEqual(f.provided.HasAccess(buyer, 'home'), true) end
    local saved, err = f.call('confirmPurchase', buyer, 'home')
    h.assertEqual(err, nil); h.assertEqual(saved.id, 'home'); h.assertEqual(saved.owner, buyerCid)
    h.assertEqual(saved.state, 'owned'); h.assertEqual(saved.pending, nil)
    h.assertEqual(next(saved.keys), nil); h.assertEqual(saved.soldPrice, 5000); h.assertEqual(saved.soldAt, now)
    h.assertEqual(saved.furniture[1].model, 'chair')
    h.assertTrue(saved ~= f.state.properties.home, 'Return the existing save helper snapshot')
    h.assertEqual(#f.sqlCalls, 1); h.assertEqual(f.sqlCalls[1].kind, 'execute')
    h.assertTrue(f.sqlCalls[1].statement:find('ON DUPLICATE KEY UPDATE', 1, true))
    h.assertEqual(f.sqlCalls[1].params[1], 'home'); h.assertEqual(f.sqlCalls[1].params[2], buyerCid)
    h.assertEqual(json.decode(f.sqlCalls[1].params[3]).owner, buyerCid)
    h.assertEqual(Core.money.getMoney(seller, 'bank'), 14750)
    h.assertEqual(f.commissions[1].account, f.env.Config.societyAccount)
    h.assertEqual(f.commissions[1].amount, 150)
    h.assertEqual(#f.events, 1); h.assertEqual(f.events[1].name, 'qbhousing:client:synced')
    local debit, proceeds = f.moneyCalls[1], f.moneyCalls[2]
    h.assertEqual(debit.reason, 'Property purchase'); h.assertEqual(debit.ignoreTax, true)
    h.assertEqual(proceeds.src, seller); h.assertEqual(proceeds.amount, 4750); h.assertEqual(proceeds.ignoreTax, true)
    h.assertEqual(f.call('confirmPurchase', buyer, 'home'), nil, 'A completed offer cannot be charged again')
    h.assertEqual(#f.sqlCalls, 1)
end)

h.test('reads and another property remain available while checkout waits, then checkout publishes once', function()
    local f = setup()
    local original = f.state.properties.home
    f.pauseNextWrite = true
    local thread = start(function() return f.call('confirmPurchase', buyer, 'home') end)
    assertListed(f, original)
    local copy = f.provided.GetProperty('home')
    copy.owner = 'UNRELATED'
    h.assertEqual(original.owner, nil)
    h.assertEqual(f.call('hydrate', buyer).properties.home.state, 'listed')
    h.assertTrue(f.call('confirmPurchase', secondBuyer, 'other'), 'Other property must progress independently')
    h.assertEqual(f.state.properties.other.owner, secondCid)
    local saved = f.complete(thread, { affectedRows = 1 })
    h.assertEqual(saved.owner, buyerCid)
    h.assertEqual(f.provided.HasAccess(buyer, 'home'), true)
    h.assertEqual(#f.sqlCalls, 2)
end)

local writers = {
    { name = 'saveProperty', call = function(f) local value = definition('h@o!me'); return f.call('saveProperty', realtor, value) end },
    { name = 'removeProperty', call = function(f) return f.call('removeProperty', realtor, 'home') end },
    { name = 'offer', call = function(f) return f.call('offer', buyer, 'home', buyerCid) end },
    { name = 'confirmPurchase', call = function(f) return f.call('confirmPurchase', buyer, 'home') end },
    { name = 'keys', owner = buyerCid, call = function(f) return f.call('keys', buyer, 'home', 'give', 'NEW_KEYHOLDER') end },
    { name = 'update', owner = buyerCid, call = function(f) return f.call('update', buyer, 'home', 'furniture', { { model = 'table' } }) end },
}
for _, writer in ipairs(writers) do
    h.test('checkout blocks ' .. writer.name .. ' until failure releases the same-property guard', function()
        local f = setup(writer.owner)
        f.pauseNextWrite = true
        local thread = start(function() return f.call('confirmPurchase', buyer, 'home') end)
        local before = json.encode(f.state.properties.home)
        local result, err = writer.call(f)
        h.assertEqual(result, nil); h.assertEqual(err, busyMessage)
        h.assertEqual(#f.sqlCalls, 1); h.assertEqual(#f.moneyCalls, 1)
        h.assertEqual(json.encode(f.state.properties.home), before)
        result, err = f.complete(thread, nil, writeError)
        h.assertEqual(result, nil); h.assertTrue(err:find(writeError, 1, true))
        h.assertEqual(Core.money.getMoney(buyer, 'bank'), 10000)
        h.assertTrue(writer.call(f), 'Purchase failure must release the guard for ' .. writer.name)
        h.assertEqual(#f.sqlCalls, 2)
    end)
    h.test(writer.name .. ' blocks a later checkout until its failed write releases the guard', function()
        local f = setup(writer.owner)
        f.pauseNextWrite = true
        local thread = start(function() return writer.call(f) end)
        local before = json.encode(f.state.properties.home)
        local bank = Core.money.getMoney(buyer, 'bank')
        local result, err = f.call('confirmPurchase', buyer, 'home')
        h.assertEqual(result, nil); h.assertEqual(err, busyMessage)
        h.assertEqual(#f.sqlCalls, 1)
        h.assertEqual(Core.money.getMoney(buyer, 'bank'), bank)
        h.assertEqual(json.encode(f.state.properties.home), before)
        result, err = f.complete(thread, nil, writeError)
        h.assertEqual(result, nil); h.assertTrue(type(err) == 'string')
        h.assertTrue(f.call('confirmPurchase', buyer, 'home'), writer.name .. ' failure must allow checkout retry')
        h.assertEqual(#f.sqlCalls, 2)
    end)
end

h.test('invalid key/update actions do not leave a property guard behind', function()
    local f = setup(buyerCid)
    h.assertEqual(f.call('keys', buyer, 'home', 'invalid', 'NEW_KEYHOLDER'), nil)
    h.assertTrue(f.call('keys', buyer, 'home', 'give', 'NEW_KEYHOLDER'))
    h.assertEqual(f.call('update', buyer, 'home', 'invalid', {}), nil)
    h.assertTrue(f.call('update', buyer, 'home', 'clothing', {}))
    h.assertEqual(#f.sqlCalls, 2)
end)

h.report('housing purchase')
