local Properties, Me = {}, {}
local shellObjects, currentProperty = {}, nil
local leavePrompt

local function notify(message, kind) QB.notify.send({ title = 'Housing', message = message, type = kind or 'inform' }) end
local function money(value) return ('$%s'):format(('%.0f'):format(tonumber(value) or 0)) end

local function rebuildZones()
    for id in pairs(Properties) do QB.interact.removeZone('qbhousing:' .. id) end
    for id, property in pairs(Properties) do
        if property.interior and property.interior.entrance and property.state ~= 'unowned' then
            QB.interact.addBoxZone('qbhousing:' .. id,
                vector3(property.interior.entrance.x, property.interior.entrance.y, property.interior.entrance.z),
                { x = 2.0, y = 2.0, z = 2.5, w = property.interior.entrance.w or 0.0 }, {
                    options = {{ label = property.owner and 'Enter property' or 'View property', icon = 'house',
                        action = function() TriggerServerEvent('qbhousing:server:enter', id) end }},
                })
        end
    end
end

local function hydrate()
    local payload, err = QB.callback.trigger('qbhousing:hydrate')
    if not payload then return notify(err or 'Housing is unavailable.', 'error') end
    Properties, Me = payload.properties or {}, payload
    rebuildZones()
end

local function openMarket()
    local listings = QB.callback.trigger('qbhousing:catalog') or {}
    local choices = {}
    for _, property in ipairs(listings) do
        choices[#choices + 1] = { id = property.id, label = property.id, description = ('%s · %s'):format(property.interior.type:upper(), money(property.listing.price)), icon = 'house' }
    end
    if #choices == 0 then return notify('There are no open listings right now.', 'inform') end
    local selected = QB.nui.openMenu(choices, 'Open market')
    if not selected or selected.cancelled then return end
    local property = Properties[selected.selectedId]
    if not property then return end
    local confirm = QB.nui.openMenu({{ id = 'buy', label = 'Request purchase', description = 'You will receive a confirmation prompt.', icon = 'file-signature' }}, property.id .. ' · ' .. money(property.listing.price))
    if confirm and not confirm.cancelled then
        local ok, err = QB.callback.trigger('qbhousing:offer', property.id, Me.citizenid)
        notify(ok and 'Purchase confirmation sent.' or err or 'Could not create an offer.', ok and 'success' or 'error')
    end
end

local function createProperty()
    local kind = QB.nui.openMenu({{ id = 'shell', label = 'Shell property', description = 'Use one of the supplied qbinterior shells.', icon = 'house' }, { id = 'mlo', label = 'MLO property', description = 'Use a streamed building and an outside zone.', icon = 'building' }}, 'Property type')
    if not kind or kind.cancelled then return end
    local idInput = QB.nui.openInputDialog({{ id = 'id', label = 'Property id', type = 'text', required = true, maxLength = 64 }, { id = 'price', label = 'Listing price', type = 'number', required = true }}, 'Property details')
    if not idInput or idInput.cancelled then return end
    local values = idInput.values
    local interior = { type = kind.selectedId }
    local propertyExterior
    if kind.selectedId == 'shell' then
        local shellChoices = {}
        for name, shell in pairs(Config.shells) do shellChoices[#shellChoices + 1] = { id = name, label = shell.label, description = ('Base %s · range %s–%s'):format(money(shell.basePrice), money(shell.basePrice * 0.75), money(shell.basePrice * 1.25)), icon = 'house' } end
        local selectedShell = QB.nui.openMenu(shellChoices, 'Choose shell')
        if not selectedShell or selectedShell.cancelled then return end
        interior.name = selectedShell.selectedId
        interior.model = Config.shells[interior.name].model
        local entrance = QB.nui.openInputDialog({{ id = 'x', label = 'Entrance X', type = 'number', required = true }, { id = 'y', label = 'Entrance Y', type = 'number', required = true }, { id = 'z', label = 'Entrance Z', type = 'number', required = true }, { id = 'w', label = 'Entrance heading', type = 'number', required = true }}, 'Front door coordinates')
        if not entrance or entrance.cancelled then return end
        interior.entrance = { x = tonumber(entrance.values.x), y = tonumber(entrance.values.y), z = tonumber(entrance.values.z), w = tonumber(entrance.values.w) }
        interior.exit = Config.shells[interior.name].exit
    else
        local zone = QB.zones.startCreator('poly')
        if not zone then return notify('MLO zone creation cancelled.', 'inform') end
        local points = {}
        for _, point in ipairs(zone.opts.points or {}) do points[#points + 1] = { x = point.x, y = point.y, z = point.z } end
        if #points < 3 then return notify('An MLO requires at least three outside points.', 'error') end
        propertyExterior = { polyzone = points, minZ = zone.opts.minZ, maxZ = zone.opts.maxZ, thickness = zone.opts.thickness }
        local entrance = QB.nui.openInputDialog({{ id = 'x', label = 'Entrance X', type = 'number', required = true }, { id = 'y', label = 'Entrance Y', type = 'number', required = true }, { id = 'z', label = 'Entrance Z', type = 'number', required = true }, { id = 'w', label = 'Entrance heading', type = 'number', required = true }}, 'MLO entrance coordinates')
        if not entrance or entrance.cancelled then return end
        interior.entrance = { x = tonumber(entrance.values.x), y = tonumber(entrance.values.y), z = tonumber(entrance.values.z), w = tonumber(entrance.values.w) }
    end
    local garage = QB.nui.openInputDialog({{ id = 'x', label = 'Garage X', type = 'number', required = true }, { id = 'y', label = 'Garage Y', type = 'number', required = true }, { id = 'z', label = 'Garage Z', type = 'number', required = true }, { id = 'sx', label = 'Vehicle spawn X', type = 'number', required = true }, { id = 'sy', label = 'Vehicle spawn Y', type = 'number', required = true }, { id = 'sz', label = 'Vehicle spawn Z', type = 'number', required = true }, { id = 'slots', label = 'Garage slots', type = 'number', required = true }}, 'Garage configuration')
    if not garage or garage.cancelled then return end
    local v = garage.values
    local property = { id = values.id, interior = interior, exterior = propertyExterior, garage = { coords = { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = 0.0 }, spawn = { x = tonumber(v.sx), y = tonumber(v.sy), z = tonumber(v.sz), w = 0.0 }, slots = tonumber(v.slots) }, listing = { price = tonumber(values.price), type = 'open_market' } }
    local saved, err = QB.callback.trigger('qbhousing:saveProperty', property)
    if not saved then return notify(err or 'Property could not be created.', 'error') end
    Properties[saved.id] = saved
    notify('Property created and listed.', 'success')
    rebuildZones()
end

local function homeownerMenu()
    local choices = {}
    for id, property in pairs(Properties) do
        if property.owner == Me.citizenid then choices[#choices + 1] = { id = id, label = id, description = 'Manage keys and property settings', icon = 'house' } end
    end
    local selected = QB.nui.openMenu(choices, 'My homes')
    if not selected or selected.cancelled then return end
    local property = Properties[selected.selectedId]
    if not property then return end
    local action = QB.nui.openMenu({
        { id = 'keys', label = 'Manage keys', description = 'Give or revoke persistent access.', icon = 'key' },
        { id = 'garage', label = 'Open garage', description = 'Uses the existing qbgarages vehicle system.', icon = 'car' },
    }, 'Manage ' .. property.id)
    if not action or action.cancelled then return end
    if action.selectedId == 'garage' then
        if property.garage and property.garage.resourceId then exports.qbgarages:openGarage(property.garage.resourceId) else notify('This property garage is not linked to qbgarages yet.', 'error') end
    else
        local input = QB.nui.openInputDialog({{ id = 'citizenid', label = 'Citizen ID', type = 'text', required = true, maxLength = 50 }}, 'Give or remove a key')
        if not input or input.cancelled then return end
        local verb = QB.nui.openMenu({{ id = 'give', label = 'Give key', icon = 'key' }, { id = 'remove', label = 'Remove key', icon = 'key' }}, 'Key action')
        if not verb or verb.cancelled then return end
        local ok, err = QB.callback.trigger('qbhousing:keys', property.id, verb.selectedId, input.values.citizenid)
        notify(ok and 'Property access updated.' or err or 'Could not update keys.', ok and 'success' or 'error')
    end
end

local APP_ID = 'qbhousing:real-estate'
local dashboard
local function listingItem(property)
    local shell = property.interior and Config.shells[property.interior.name]
    local entrance = property.interior and property.interior.entrance or {}
    return { id = property.id, label = property.id, description = shell and ('SHELL · %s'):format(shell.label) or 'MLO',
        metadata = {
            { label = 'Price', value = money(property.listing and property.listing.price) },
            { label = 'Location', value = ('%.2f, %.2f, %.2f'):format(tonumber(entrance.x) or 0, tonumber(entrance.y) or 0, tonumber(entrance.z) or 0) },
        }, actions = {
            { id = 'qbhousing:edit', label = 'Edit', icon = 'pencil' },
            { id = 'qbhousing:remove', label = 'Remove', icon = 'trash-2', variant = 'destructive', confirm = 'Remove this property from the real estate inventory?' },
        } }
end

local function realtorApp()
    local data, err = QB.callback.trigger('qbhousing:realtorDashboard')
    if not data then return notify(err or 'The real estate dashboard is unavailable.', 'error') end
    dashboard = data
    local listings, sold = {}, {}
    for _, property in ipairs(data.forSale or {}) do listings[#listings + 1] = listingItem(property) end
    for _, property in ipairs(data.sold or {}) do
        local entrance = property.interior and property.interior.entrance or {}
        sold[#sold + 1] = { id = property.id, label = property.id, description = property.interior.type:upper(), metadata = {
            { label = 'Price', value = money(property.soldPrice or property.listing and property.listing.price) },
            { label = 'Location', value = ('%.2f, %.2f, %.2f'):format(tonumber(entrance.x) or 0, tonumber(entrance.y) or 0, tonumber(entrance.z) or 0) },
        } }
    end
    QB.nui.registerApp({ id = APP_ID, title = 'Real Estate', description = 'Property management', icon = 'building-2', width = 1180, height = 760,
        defaultView = 'home', navigation = {
            { id = 'home', label = 'Home', icon = 'house', content = { title = 'Portfolio overview', blocks = { { type = 'stats', items = {
                { label = 'For Sale', value = #listings, icon = 'tags', tone = 'primary' }, { label = 'Overall Sold', value = data.soldCount or 0, icon = 'badge-check', tone = 'success' }, { label = 'Average Price', value = money(data.averagePrice), icon = 'chart-no-axes-combined', tone = 'warning' }, } } } } },
            { id = 'sale', label = 'For Sale', icon = 'tags', content = { title = 'Active listings', blocks = { { type = 'list', items = listings, empty = 'No Properties For Sale' } } } },
            { id = 'new', label = 'New House', icon = 'plus', content = { title = 'New House', description = 'Create a property listing with the guided creator.', actions = { { id = 'qbhousing:new', label = 'Open property creator', icon = 'plus', variant = 'primary' } }, blocks = { { type = 'empty', title = 'Property creator', description = 'Choose MLO or Shell, then place the entrance and garage in the world.' } } } },
            { id = 'sold', label = 'Sold Houses', icon = 'badge-check', content = { title = 'Sold property history', blocks = { { type = 'list', items = sold, empty = 'No Sold Properties' } } } },
        }, onAction = function(action, context)
            local property = Properties[context and (context.id or context.itemId)]
            if action == 'qbhousing:new' then QB.nui.closeApp(APP_ID); createProperty()
            elseif action == 'qbhousing:edit' and property then QB.nui.closeApp(APP_ID); createProperty(property)
            elseif action == 'qbhousing:remove' and property then
                local ok, removeErr = QB.callback.trigger('qbhousing:removeProperty', property.id)
                notify(ok and 'Property removed.' or removeErr or 'Property could not be removed.', ok and 'success' or 'error')
                if ok then realtorApp() end
            end
        end })
    QB.nui.openApp(APP_ID)
end

RegisterCommand(Config.command, function()
    local player = exports.qbcore:getPlayer()
    if player and player.job and player.job.name == Config.realtorJob then realtorApp()
    else openMarket() end
end, false)

RegisterCommand(Config.homeCommand, homeownerMenu, false)

RegisterNetEvent('qbhousing:client:synced', function(properties) Properties = properties or {}; rebuildZones() end)
RegisterNetEvent('qbhousing:client:purchaseOffer', function(property)
    local decision = QB.nui.openMenu({{ id = 'confirm', label = 'Confirm purchase', description = money(property.listing.price) .. ' · This is final.', icon = 'check' }, { id = 'decline', label = 'Decline', icon = 'x' }}, 'Purchase ' .. property.id)
    if not decision or decision.selectedId ~= 'confirm' then return end
    local saved, err = QB.callback.trigger('qbhousing:confirmPurchase', property.id)
    notify(saved and 'Property purchased.' or err or 'Purchase failed.', saved and 'success' or 'error')
end)

RegisterNetEvent('qbhousing:client:enterShell', function(property)
    if currentProperty then return notify('You are already inside a property.', 'error') end
    currentProperty = property
    local spawn = vector3(property.interior.entrance.x, property.interior.entrance.y, property.interior.entrance.z)
    local interior = exports['qbinterior']:createShell(vector3(spawn.x, spawn.y, spawn.z), property.interior.exit, property.interior.model)
    shellObjects = interior and interior[1] or {}
    SetEntityCoords(PlayerPedId(), spawn.x + (property.interior.exit.x or 0.0), spawn.y + (property.interior.exit.y or 0.0), spawn.z + (property.interior.exit.z or 0.0), false, false, false, false)
end)

CreateThread(function()
    while true do
        if not currentProperty then Wait(1000) goto continue end
        Wait(0)
        local exit = currentProperty.interior.exit
        local coords = GetEntityCoords(PlayerPedId())
        local distance = #(coords - vector3(exit.x, exit.y, exit.z))
        if distance < 1.5 then
            leavePrompt = leavePrompt or QB.textui.show('Leave property', { key = 'E' })
            if IsControlJustReleased(0, 38) then
                local entrance = currentProperty.interior.entrance
                for _, object in ipairs(shellObjects) do if DoesEntityExist(object) then DeleteEntity(object) end end
                shellObjects, currentProperty = {}, nil
                if entrance then SetEntityCoords(PlayerPedId(), entrance.x, entrance.y, entrance.z, false, false, false, false) end
                if leavePrompt then QB.textui.hide(leavePrompt); leavePrompt = nil end
            end
        elseif leavePrompt then QB.textui.hide(leavePrompt); leavePrompt = nil end
        ::continue::
    end
end)

CreateThread(function() Wait(1000); hydrate() end)
AddEventHandler('QBCore:Client:OnPlayerLoaded', hydrate)
