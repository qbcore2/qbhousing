Housing = Housing or {}

local function number(value, fallback)
    value = tonumber(value)
    return value or fallback
end

function Housing.copy(value)
    return json.decode(json.encode(value))
end

function Housing.normalise(value)
    if type(value) ~= 'table' or type(value.id) ~= 'string' or value.id == '' then return nil, 'Property id is required.' end
    if value.interior and value.interior.type ~= 'shell' and value.interior.type ~= 'mlo' then return nil, 'Invalid interior type.' end
    value.state = value.state or 'unowned'
    value.keys = type(value.keys) == 'table' and value.keys or {}
    value.furniture = type(value.furniture) == 'table' and value.furniture or {}
    value.stashes = type(value.stashes) == 'table' and value.stashes or {}
    value.clothing = type(value.clothing) == 'table' and value.clothing or {}
    value.doorlocks = type(value.doorlocks) == 'table' and value.doorlocks or {}
    if value.garage then value.garage.slots = math.max(1, math.min(Config.maxGarageSlots, number(value.garage.slots, Config.defaultGarageSlots))) end
    return value
end
