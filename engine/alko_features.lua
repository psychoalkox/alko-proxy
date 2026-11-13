-- ALKO Proxy feature pack for vinskeeper/GTProxy Lua API.
-- No credential collection, autoban suppression, or identity spoofing.
-- Compatibility with live game v5.61 NOT verified.
local function reply(ctx, message)
    ctx:reply('`6[ALKO] `w' .. tostring(message))
end

local function json_string(s)
    s = tostring(s or '')
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', ''):gsub('%c', '')
    return '"' .. s .. '"'
end

local function item_name(id)
    local item = item_database:get_item(id)
    if item and item.item_name then return tostring(item.item_name) end
    return 'Item #' .. tostring(id)
end

local function tally_to_json(t)
    local out = {}
    for id, n in pairs(t) do
        out[#out + 1] = '{"id":' .. tostring(id) .. ',"name":' .. json_string(item_name(id)) .. ',"count":' .. tostring(n) .. '}'
    end
    table.sort(out)
    return '[' .. table.concat(out, ',') .. ']'
end

command.register('alko', 'ALKO Proxy command guide', function(ctx)
    reply(ctx, '/gscan /counts ID /dropped /pos /people /farmreport /qdrop ID COUNT /qtrash ID COUNT')
    return true
end)

command.register('ping', 'Proxy ping check', function(ctx)
    reply(ctx, 'Pong! Lua feature pack is active.')
    return true
end)

command.register('pos', 'Show local tile position', function(ctx)
    local p = world:get_local_player()
    if not p then reply(ctx, 'Local player unavailable'); return false end
    reply(ctx, string.format('Position %.0f, %.0f', p.position.x, p.position.y))
    return true
end)

command.register('people', 'Count nearby players', function(ctx)
    local n = 0
    for _ in pairs(world:get_players()) do n = n + 1 end
    reply(ctx, 'Players in loaded world: ' .. n)
    return true
end)

command.register('gscan', 'Scan currently loaded world foreground, background and drops', function(ctx)
    local map = world:get_tile_map()
    local size = map:get_size()
    local fg, bg, dropped = {}, {}, {}
    local nonempty = 0
    for _, tile in ipairs(map:get_tiles()) do
        local f, b = tonumber(tile.foreground) or 0, tonumber(tile.background) or 0
        if f > 0 then fg[f] = (fg[f] or 0) + 1; nonempty = nonempty + 1 end
        if b > 0 then bg[b] = (bg[b] or 0) + 1 end
    end
    for _, obj in ipairs(world:get_object_map():get_objects()) do
        local id, n = tonumber(obj.item_id) or 0, tonumber(obj.amount) or 0
        if id > 0 and n > 0 then dropped[id] = (dropped[id] or 0) + n end
    end
    local payload = '{"world":"Current world","size":{"width":' .. (tonumber(size.x) or 0) .. ',"height":' .. (tonumber(size.y) or 0) .. '},' ..
        '"foreground":' .. tally_to_json(fg) .. ',"background":' .. tally_to_json(bg) .. ',"dropped":' .. tally_to_json(dropped) .. '}'
    if alko_emit then alko_emit('scan', payload) end
    reply(ctx, 'Scanned ' .. nonempty .. ' foreground tiles. Open ALKO Dashboard > Scanner.')
    return true
end)

command.register('counts', 'Count currently loaded world tiles by item ID', function(ctx)
    local id = tonumber(ctx.args[1])
    if not id or id < 1 then reply(ctx, 'Usage: /counts ITEM_ID'); return false end
    local n = 0
    for _, t in ipairs(world:get_tile_map():get_tiles()) do
        if tonumber(t.foreground) == id or tonumber(t.background) == id then n = n + 1 end
    end
    reply(ctx, item_name(id) .. ': ' .. n .. ' placed tiles')
    return true
end)

command.register('dropped', 'Summarize currently dropped world items', function(ctx)
    local totals = {}
    for _, obj in ipairs(world:get_object_map():get_objects()) do
        local id = tonumber(obj.item_id) or 0
        totals[id] = (totals[id] or 0) + (tonumber(obj.amount) or 0)
    end
    local top = {}
    for id, n in pairs(totals) do top[#top + 1] = {id=id, n=n} end
    table.sort(top, function(a,b) return a.n > b.n end)
    local lines = {}
    for i=1, math.min(#top, 6) do
        lines[#lines+1] = item_name(top[i].id) .. ' x' .. top[i].n
    end
    reply(ctx, #lines == 0 and 'No dropped items loaded' or table.concat(lines, ' | '))
    return true
end)

command.register('farmreport', 'Count seeds and report crop planning statistics', function(ctx)
    local seeds, tiles = 0, 0
    for _, t in ipairs(world:get_tile_map():get_tiles()) do
        tiles = tiles + 1
        if t.extra and t.extra:has_value() then
            local ok, seed = pcall(function() return t.extra:get_as_seed() end)
            if ok and seed then seeds = seeds + 1 end
        end
    end
    reply(ctx, 'Loaded tiles: ' .. tiles .. ', seed extras: ' .. seeds .. '. Farming actions remain manual.')
    return true
end)

-- Dialog-return formats are based on older community clients. May need revision for v5.61.
local function simple_inventory_action(ctx, operation)
    local id, amount = tonumber(ctx.args[1]), tonumber(ctx.args[2])
    if not id or id < 1 or id ~= math.floor(id) or not amount or amount < 1 or amount > 200 or amount ~= math.floor(amount) then
        reply(ctx, 'Usage: /q' .. operation .. ' ITEM_ID AMOUNT (1-200)')
        return false
    end
    local text = 'action|dialog_return\ndialog_name|' .. (operation == 'drop' and 'drop_item' or 'trash_item') ..
        '\nitemID|' .. id .. '\ncount|' .. amount .. '\n'
    packet.send_text(text, true, packet.NET_MESSAGE_GENERIC_TEXT)
    reply(ctx, operation .. ' request for ' .. amount .. ' x ' .. item_name(id) .. ' sent (unverified response)')
    return true
end

command.register('qdrop', 'Experimental fast drop: /qdrop ITEM_ID AMOUNT', function(ctx)
    return simple_inventory_action(ctx, 'drop')
end)
command.register('qtrash', 'Experimental fast trash: /qtrash ITEM_ID AMOUNT', function(ctx)
    return simple_inventory_action(ctx, 'trash')
end)
logger.info('[ALKO] feature pack registered: gscan, counts, dropped, people, pos, farmreport, qdrop, qtrash')
