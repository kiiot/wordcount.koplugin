-- Per-page reading tracker that mirrors KOReader Reading statistics' useful
-- defaults without requiring that separate plugin: ignore visits shorter than
-- min_sec and cap accumulated time on one page at max_sec. Page text units are
-- counted once per page identity; revisits can add time up to the cap.
local M = {}

function M.newState(page_count, mtime, size)
    return {
        page_count = tonumber(page_count) or 0,
        file_mtime = tonumber(mtime),
        file_size = tonumber(size),
        page_units = {},
        page_seconds = {},
        -- ★★★ 30-estimate-shadow-fix：「抽页估算垫进来的」页 key 集合。
        --   这些 page_units[key] 是**样本均值**，不是该页真实字数。
        --   留着这个集合的意义：_getPageUnits 读到某页时，若发现它是估算值，
        --   就**照常走真实文本抽取并覆盖**，而不是被 `page_units[key] ~= nil`
        --   短路掉 —— 否则用户真读到的页会永远显示平均字数，逐页精度再也回不来。
        page_units_estimated = {},
        read_units = 0,
        read_seconds = 0,
        speed_units_per_minute = nil,
    }
end

function M.setPageUnits(state, key, units)
    if type(state) ~= "table" or key == nil then return end
    units = tonumber(units)
    if units and units >= 0 then
        state.page_units[key] = math.floor(units + 0.5)
        -- 写入真实值 ⇒ 从「估算」集合里摘掉（若曾标过）。
        if type(state.page_units_estimated) == "table" then
            state.page_units_estimated[key] = nil
        end
    end
end

-- 只在 writeEstimated 时把 key 记入「估算」集合；抽页垫数据走这个。
function M.setEstimatedPageUnits(state, key, units)
    M.setPageUnits(state, key, units)
    if type(state) == "table" and key ~= nil and type(state.page_units_estimated) == "table" then
        if state.page_units[key] ~= nil then
            state.page_units_estimated[key] = true
        end
    end
end

function M.isEstimatedPageUnit(state, key)
    return type(state) == "table"
        and type(state.page_units_estimated) == "table"
        and state.page_units_estimated[key] == true
end

function M.addPageVisit(state, key, units, elapsed, min_sec, max_sec)
    if type(state) ~= "table" or key == nil then return false, false, 0 end
    elapsed = tonumber(elapsed) or 0
    min_sec = tonumber(min_sec) or 5
    max_sec = tonumber(max_sec) or 120
    if elapsed < min_sec then return false, false, 0 end

    if units ~= nil then M.setPageUnits(state, key, units) end
    local old = math.min(max_sec, tonumber(state.page_seconds[key]) or 0)
    local new_page = old <= 0
    state.page_seconds[key] = math.min(max_sec, old + math.min(elapsed, max_sec))
    local added_seconds = math.max(0, state.page_seconds[key] - old)
    M.recompute(state)
    return true, new_page, added_seconds
end

function M.recompute(state)
    local units, seconds = 0, 0
    local page_units = state.page_units or {}
    for key, page_seconds in pairs(state.page_seconds or {}) do
        local duration = tonumber(page_seconds) or 0
        if duration > 0 then
            units = units + (tonumber(page_units[key]) or 0)
            seconds = seconds + duration
        end
    end
    state.read_units = math.floor(units + 0.5)
    state.read_seconds = math.floor(seconds + 0.5)
    if seconds > 0 then
        state.speed_units_per_minute = math.floor(units * 60 / seconds + 0.5)
    else
        state.speed_units_per_minute = nil
    end
    return state.read_units, state.read_seconds, state.speed_units_per_minute
end

function M.isValidForFile(state, page_count, mtime, size)
    return type(state) == "table"
        and tonumber(state.page_count) == tonumber(page_count)
        and tonumber(state.file_mtime) == tonumber(mtime)
        and tonumber(state.file_size) == tonumber(size)
        and type(state.page_units) == "table"
        and type(state.page_seconds) == "table"
end

return M
