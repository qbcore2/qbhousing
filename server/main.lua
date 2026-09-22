local State = Housing.state
local RESOURCE = GetCurrentResourceName()

local function player(src) return exports.qbcore:getPlayer(src) end
local function citizenId(src) local data = player(src); return data and data.citizenid end
local function isRealtor(src)
    local data = player(src)
    return data and data.job and data.job.name == Config.realtorJob
end
local function isAdmin(src) return QB.permissions.hasPermission(src, 'admin', 'qbcore') end
local function canManage(src, property)
    local cid = citizenId(src)
    return isAdmin(src) or (isRealtor(src) and (not property.owner or property.listing and property.listing.realtor == cid or property.owner == cid))
end
local function coordsNear(src, coords, distance)
    if type(coords) ~= 'table' then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local here = GetEntityCoords(ped)
    return #(here - vector3(coords.x, coords.y, coords.z)) <= (distance or 8.0)
end
local function fail(message) return nil, message end

CreateThread(function()
    if not QB.sql.ready(60000) then return print('^1[qbhousing]^7 qbsql was not ready; resource disabled.') end
    local ok, err = QB.sql.migrateFiles(RESOURCE, {{ version = 1, name = 'housing', file = 'sql/001_housing.sql' }})
    if not ok then return print(('^1[qbhousing]^7 migration failed: %s'):format(err)) end
    local loaded, loadErr = State.load()
    if not loaded then return print(('^1[qbhousing]^7 load failed: %s'):format(loadErr)) end
    State.ready = true
    State.broadcast()
end)

local function register(name, fn, max)
    QB.callback.register('qbhousing:' .. name, fn, { rateLimit = { max = max or 10, window = 10000 } })
end

register('hydrate', function(src)
    return { properties = State.snapshot(), realtor = isRealtor(src), citizenid = citizenId(src), ready = State.ready }
end)

register('saveProperty', function(src, payload)
    if not State.ready or not isRealtor(src) then return fail('Only realtors can create or edit properties.') end
    if type(payload) ~= 'table' then return fail('Invalid property data.') end
    local property = Housing.copy(payload)
    property.id = type(property.id) == 'string' and property.id:gsub('[^%w_-]', '') or ''
    if property.id == '' or #property.id > 64 then return fail('Use a valid property id.') end
    local existing = State.get(property.id)
    if existing and not canManage(src, existing) then return fail('You cannot edit this property.') end
    property.listing = property.listing or {}
    property.listing.realtor = citizenId(src)
    property.listing.type = property.listing.type == 'direct' and 'direct' or 'open_market'
    property.interior = property.interior or {}
    property.interior.type = property.interior.type == 'mlo' and 'mlo' or 'shell'
    if property.interior.type == 'shell' then
        local shell = Config.shells[property.interior.name]
        if not shell then return fail('That shell is not available.') end
        local price = math.floor(tonumber(property.listing.price) or 0)
        if price < shell.basePrice * 0.75 or price > shell.basePrice * 1.25 then return fail('Shell prices must stay within 25% of the base price.') end
        property.interior.model = shell.model
    else
        local price = math.floor(tonumber(property.listing.price) or 0)
        if price < 1 then return fail('MLO price must be positive.') end
    end
    if not property.garage or type(property.garage.coords) ~= 'table' or type(property.garage.spawn) ~= 'table' then return fail('A garage and vehicle spawn are required.') end
    property.owner = existing and existing.owner or nil
    property.state = property.owner and 'owned' or 'listed'
    local saved, err = State.persist(property)
    if not saved then return fail(err or 'Property could not be saved.') end
    State.broadcast()
    return saved
end)

register('catalog', function(src)
    local result = {}
    for _, property in pairs(State.properties) do
        if property.state == 'listed' and property.listing then result[#result + 1] = property end
    end
    return result
end)

register('realtorDashboard', function(src)
    if not isRealtor(src) then return fail('Only realtors can view the dashboard.') end
    local result, total, count = { forSale = {}, sold = {}, averagePrice = 0, soldCount = 0 }, 0, 0
    for _, property in pairs(State.properties) do
        if property.state == 'listed' and property.listing then
            result.forSale[#result.forSale + 1] = property
            total, count = total + (tonumber(property.listing.price) or 0), count + 1
        end
        if property.soldAt then result.sold[#result.sold + 1] = property; result.soldCount = result.soldCount + 1 end
    end
    result.averagePrice = count > 0 and math.floor(total / count) or 0
    return result
end)

register('removeProperty', function(src, id)
    if not isRealtor(src) then return fail('Only realtors can remove properties.') end
    local property = State.get(id)
    if not property or property.owner then return fail('Owned properties cannot be removed.') end
    local ok, err = QB.sql.execute('DELETE FROM `qbhousing_properties` WHERE `id` = ?', { id })
    if not ok then return fail(err or 'Property could not be removed.') end
    State.properties[id] = nil
    State.broadcast()
    return true
end)

register('offer', function(src, id, buyer)
    local property = State.get(id)
    if not property or property.state ~= 'listed' or not property.listing then return fail('This property is not available.') end
    local cid = citizenId(src)
    if property.listing.type == 'direct' and not canManage(src, property) then return fail('You are not authorized to list this property.') end
    if property.listing.type == 'direct' and buyer ~= citizenId(src) then
        local target = exports.qbcore:getPlayerByCitizenId(buyer)
        if not target then return fail('The buyer must be online for a direct offer.') end
    end
    property.pending = { buyer = buyer or cid, realtor = property.listing.realtor, expires = os.time() + 300 }
    local saved, err = State.persist(property)
    if not saved then return fail(err) end
    local target = exports.qbcore:getPlayerByCitizenId(property.pending.buyer)
    if target and target.source then TriggerClientEvent('qbhousing:client:purchaseOffer', target.source, saved) end
    return true
end)

register('confirmPurchase', function(src, id)
    local property = State.get(id)
    local cid = citizenId(src)
    if not property or property.state ~= 'listed' or not property.pending or property.pending.buyer ~= cid then return fail('This purchase offer is no longer valid.') end
    if property.pending.expires < os.time() then return fail('This purchase offer expired.') end
    local amount = math.floor(tonumber(property.listing.price) or 0)
    local buyer = player(src)
    if not buyer or tonumber(buyer.money and buyer.money.bank) < amount then return fail('You do not have enough money in the bank.') end
    local oldOwner = property.owner
    local society = math.floor(amount * Config.societyCommission)
    local sellerFee = math.floor(amount * Config.sellerCommission)
    local proceeds = amount - society - sellerFee
    property.owner, property.keys, property.state, property.pending = cid, {}, 'owned', nil
    property.soldAt, property.soldPrice = os.time(), amount
    if not exports.qbcore:removeMoney(src, 'bank', amount, 'Property purchase', true) then return fail('Payment failed; no changes were made.') end
    local ok, err = QB.sql.transaction({
        { sql = 'UPDATE `qbhousing_properties` SET `owner` = ?, `definition` = ? WHERE `id` = ?', params = { cid, json.encode(property), property.id } },
    })
    if not ok then
        exports.qbcore:addMoney(src, 'bank', amount, 'Property purchase rollback', true)
        return fail(err or 'The purchase could not be completed.')
    end
    if Config.societyAccount ~= '' then exports.qbbanking:AddMoney(Config.societyAccount, society, 'Real-estate society commission') end
    if oldOwner then
        local ownerSource = exports.qbcore:getPlayerByCitizenId(oldOwner)
        if ownerSource then exports.qbcore:addMoney(ownerSource.source, 'bank', proceeds, 'Property sale proceeds', true)
        else
            local offline = exports['qb-core']:GetOfflinePlayerByCitizenId(oldOwner)
            if offline and offline.Functions then offline.Functions.AddMoney('bank', proceeds, 'Property sale proceeds') end
        end
    end
    local saved = State.persist(property)
    State.broadcast()
    return saved or true
end)

register('keys', function(src, id, action, targetCid)
    local property = State.get(id)
    if not property or property.owner ~= citizenId(src) then return fail('Only the homeowner can manage keys.') end
    if type(targetCid) ~= 'string' or #targetCid < 3 or #targetCid > 50 or targetCid == property.owner then return fail('Invalid keyholder.') end
    property.keys = property.keys or {}
    if action == 'give' then property.keys[targetCid] = true elseif action == 'remove' then property.keys[targetCid] = nil else return fail('Invalid key action.') end
    local saved, err = State.persist(property)
    if not saved then return fail(err) end
    State.broadcast()
    return saved.keys
end)

register('update', function(src, id, field, value)
    local property = State.get(id)
    if not property or property.owner ~= citizenId(src) then return fail('Only the homeowner can manage this property.') end
    if field == 'furniture' and type(value) == 'table' and #value <= Config.maxFurniture then property.furniture = value
    elseif field == 'stashes' and type(value) == 'table' and #value <= Config.maxStashes then property.stashes = value
    elseif field == 'clothing' and type(value) == 'table' and #value <= Config.maxClothingSpots then property.clothing = value
    else return fail('Invalid property update.') end
    local saved, err = State.persist(property)
    if not saved then return fail(err) end
    State.broadcast()
    return saved
end)

RegisterNetEvent('qbhousing:server:enter', function(id)
    local src = source
    local property = State.get(id)
    local cid = citizenId(src)
    if not property or not property.interior or property.interior.type ~= 'shell' then return end
    if property.owner ~= cid and not (property.keys and property.keys[cid]) then return end
    if not coordsNear(src, property.interior.entrance, 12.0) then return end
    TriggerClientEvent('qbhousing:client:enterShell', src, property)
end)

exports('GetProperty', function(id) return Housing.copy(State.get(id)) end)
exports('HasAccess', function(src, id)
    local property = State.get(id); local cid = citizenId(src)
    return property and cid and (property.owner == cid or property.keys and property.keys[cid]) or false
end)
