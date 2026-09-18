Housing.state = { properties = {}, ready = false }

local State = Housing.state

function State.get(id)
    return type(id) == 'string' and State.properties[id] or nil
end

function State.snapshot()
    return Housing.copy(State.properties)
end

function State.broadcast(target)
    TriggerClientEvent('qbhousing:client:synced', target or -1, State.snapshot())
end

function State.persist(property)
    local value, err = Housing.normalise(Housing.copy(property))
    if not value then return nil, err end
    local ok, writeErr = QB.sql.execute([[INSERT INTO `qbhousing_properties` (`id`,`owner`,`definition`) VALUES (?,?,?)
        ON DUPLICATE KEY UPDATE `owner` = VALUES(`owner`), `definition` = VALUES(`definition`)]],
        { value.id, value.owner, json.encode(value) })
    if not ok then return nil, writeErr end
    State.properties[value.id] = value
    return Housing.copy(value)
end

function State.load()
    local rows, err = QB.sql.query('SELECT `id`, `definition` FROM `qbhousing_properties`')
    if not rows then return false, err end
    local loaded = {}
    for _, row in ipairs(rows) do
        local ok, raw = pcall(json.decode, row.definition or '')
        local property = ok and Housing.normalise(raw) or nil
        if property then loaded[row.id] = property else print(('^3[qbhousing]^7 skipped invalid property %s'):format(row.id)) end
    end
    State.properties = loaded
    return true
end
