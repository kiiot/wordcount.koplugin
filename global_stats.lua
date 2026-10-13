-- Global, date-bucketed reading statistics for the Word Count plugin.
-- This module is pure Lua so period aggregation can be tested without KOReader.
local M = {}

local function dayTimestamp(year, month, day)
    return os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
end

local function parts(timestamp)
    local t = os.date("*t", tonumber(timestamp) or os.time())
    return t.year, t.month, t.day
end

local function dayKey(timestamp)
    return os.date("%Y-%m-%d", tonumber(timestamp) or os.time())
end

local function dateFromKey(key)
    local y, m, d = tostring(key or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

local function safeNumber(value)
    local n = tonumber(value)
    return n and n >= 0 and n or 0
end

local function dayRecord(store, key)
    local row = store.days[key]
    if type(row) ~= "table" then
        row = { seconds = 0, units = 0, pages = 0, notes = 0, books = {}, hours = {} }
        store.days[key] = row
    end
    row.seconds = safeNumber(row.seconds)
    row.units = safeNumber(row.units)
    row.pages = safeNumber(row.pages)
    row.notes = safeNumber(row.notes)
    row.books = type(row.books) == "table" and row.books or {}
    row.hours = type(row.hours) == "table" and row.hours or {}
    return row
end

local function bookRecord(store, path)
    local book = store.books[path]
    if type(book) ~= "table" then
        book = { read_units = 0, read_seconds = 0, read_pages = 0, notes = 0 }
        store.books[path] = book
    end
    book.read_units = safeNumber(book.read_units)
    book.read_seconds = safeNumber(book.read_seconds)
    book.read_pages = safeNumber(book.read_pages)
    book.notes = safeNumber(book.notes)
    return book
end

function M.newState()
    return { version = 1, days = {}, books = {}, created_at = os.time() }
end

function M.normalize(state)
    if type(state) ~= "table" or tonumber(state.version) ~= 1 then return M.newState() end
    state.days = type(state.days) == "table" and state.days or {}
    state.books = type(state.books) == "table" and state.books or {}
    return state
end

function M.dateKey(timestamp)
    return dayKey(timestamp)
end

function M.upsertBook(store, info)
    store = M.normalize(store)
    info = info or {}
    local path = info.path
    if type(path) ~= "string" or path == "" then return store end
    local units = safeNumber(info.read_units)
    local seconds = safeNumber(info.read_seconds)
    local pages = safeNumber(info.read_pages)
    -- ★★★ 37b：以前这里只看「读了没有」（units/seconds/pages），一条都没读就直接
    --   丢弃整条记录。但「重置设置」之后会出现一种合法情况：
    --     · 全书字数在全局缓存里（KEY_CACHE）—— 我们**知道这本书多少字**
    --     · 但阅读状态（KEY_READ_STATS）已被清掉 —— read_units = 0
    --   这时如果还按老判据丢弃，`total_units`（全书字数）就永远进不了聚合，
    --   用户看到的还是「总览里这本书 0 / 不显示」——正是他报的 bug。
    --   所以：**只要带了 total_units，就值得记一条**（哪怕还没读）。
    if units <= 0 and seconds <= 0 and pages <= 0 and not info.new_page
            and info.notes == nil
            and not (tonumber(info.total_units) and tonumber(info.total_units) > 0) then
        return store
    end

    local book = bookRecord(store, path)
    if info.title and info.title ~= "" then book.title = tostring(info.title) end
    if info.status and info.status ~= "" then book.status = tostring(info.status) end
    if info.total_units ~= nil then book.total_units = safeNumber(info.total_units) end
    if info.notes ~= nil then book.notes = safeNumber(info.notes) end
    book.read_units = units
    book.read_seconds = seconds
    book.read_pages = pages
    local date = info.date or dayKey(info.timestamp)
    book.first_read_date = book.first_read_date or date
    book.last_read_date = date
    if book.status == "complete" and not book.completed_date then
        book.completed_date = date
    end
    return store
end

--- 记录新增的笔记（KOReader 把标注/书签都存在 sidecar 的 "annotations" 里）。
--- info.notes 是"本次新增条数"，info.total_notes 是这本书当前的笔记总数。
function M.recordNotes(store, info)
    store = M.normalize(store)
    info = info or {}
    local path = info.path
    if type(path) ~= "string" or path == "" then return store end
    local added = math.floor(safeNumber(info.notes) + 0.5)
    if added <= 0 then return store end

    local timestamp = tonumber(info.timestamp) or os.time()
    local key = info.date or dayKey(timestamp)
    local day = dayRecord(store, key)
    day.notes = day.notes + added
    day.books[path] = true

    local book = bookRecord(store, path)
    if info.title and info.title ~= "" then book.title = tostring(info.title) end
    if info.status and info.status ~= "" then book.status = tostring(info.status) end
    if info.total_units ~= nil then book.total_units = safeNumber(info.total_units) end
    if info.total_notes ~= nil then
        book.notes = safeNumber(info.total_notes)
    else
        book.notes = book.notes + added
    end
    book.first_read_date = book.first_read_date or key
    book.last_read_date = key
    return store
end

--- 只回写某本书的笔记存量，不动阅读量（阅读量由 upsertBook 负责）。
function M.setBookNotes(store, info)
    store = M.normalize(store)
    info = info or {}
    local path = info.path
    if type(path) ~= "string" or path == "" then return store end
    local book = bookRecord(store, path)
    if info.title and info.title ~= "" then book.title = tostring(info.title) end
    if info.status and info.status ~= "" then book.status = tostring(info.status) end
    if info.total_units ~= nil then book.total_units = safeNumber(info.total_units) end
    book.notes = safeNumber(info.notes)
    local date = info.date or dayKey(info.timestamp)
    book.first_read_date = book.first_read_date or date
    book.last_read_date = book.last_read_date or date
    return store
end

function M.recordVisit(store, info)
    store = M.normalize(store)
    info = info or {}
    local path = info.path
    if type(path) ~= "string" or path == "" then return store end

    local timestamp = tonumber(info.timestamp) or os.time()
    local key = info.date or dayKey(timestamp)
    local hour = math.max(0, math.min(23, math.floor(tonumber(info.hour) or tonumber(os.date("%H", timestamp)) or 0)))
    local seconds = math.floor(safeNumber(info.seconds) + 0.5)
    local units = math.floor(safeNumber(info.new_units) + 0.5)
    local new_page = info.new_page == true
    local day = dayRecord(store, key)
    local hour_key = string.format("%02d", hour)
    local hour_row = day.hours[hour_key]
    if type(hour_row) ~= "table" then hour_row = { seconds = 0, units = 0 }; day.hours[hour_key] = hour_row end

    day.seconds = day.seconds + seconds
    hour_row.seconds = safeNumber(hour_row.seconds) + seconds
    if new_page then
        day.pages = day.pages + 1
        day.units = day.units + units
        hour_row.units = safeNumber(hour_row.units) + units
    end
    day.books[path] = true

    M.upsertBook(store, {
        path = path,
        title = info.title,
        status = info.status,
        total_units = info.total_units,
        read_units = info.read_units,
        read_seconds = info.read_seconds,
        read_pages = info.read_pages,
        new_page = new_page,
        date = key,
    })
    return store
end

function M.bounds(period, anchor)
    anchor = tonumber(anchor) or os.time()
    local year, month, day = parts(anchor)
    local day_start = dayTimestamp(year, month, day)
    if period == "day" then
        local key = dayKey(day_start)
        return key, key, os.date("%Y年%m月%d日", day_start)
    elseif period == "week" then
        local weekday = tonumber(os.date("%w", day_start)) or 0 -- Sunday = 0
        local monday = day_start - ((weekday + 6) % 7) * 86400
        local sunday = monday + 6 * 86400
        return dayKey(monday), dayKey(sunday), os.date("%m月%d日", monday) .. "–" .. os.date("%m月%d日", sunday)
    elseif period == "month" then
        local first = dayTimestamp(year, month, 1)
        local next_month = dayTimestamp(year, month + 1, 1)
        local last = next_month - 86400
        return dayKey(first), dayKey(last), os.date("%Y年%m月", first)
    elseif period == "year" then
        local first = dayTimestamp(year, 1, 1)
        local last = dayTimestamp(year + 1, 1, 1) - 86400
        return dayKey(first), dayKey(last), tostring(year) .. "年"
    end
    return nil, nil, "累计"
end

function M.shiftAnchor(period, anchor, delta)
    anchor = tonumber(anchor) or os.time()
    delta = tonumber(delta) or 0
    local year, month, day = parts(anchor)
    if period == "day" then return dayTimestamp(year, month, day + delta) end
    if period == "week" then return dayTimestamp(year, month, day + delta * 7) end
    if period == "month" then return dayTimestamp(year, month + delta, 1) end
    if period == "year" then return dayTimestamp(year + delta, month, 1) end
    return anchor
end

--- ★★★ 37b：周期导航的**双行标题**（用户要求）。
---
--- 用户原话：「日期做成双标题，第一行标题是年，第二行是月日，第二行的
---   内部是日切换，外部是月切换」。
---
--- 返回两行文字：
---   · line1 = 年（如 "2026年"）
---   · line2 = 月日（如 "10月03日"）—— ★ 任何粒度下都显示**锚点那天的月日**，
---     这样第二行的「内=日 / 外=月」热区在所有粒度下语义一致，不会出现
---     「年视图第二行写『全年』却点出个月视图」的割裂感。
---   · "total" 时只有一行「累计」，第二行返回 nil。
function M.navLabels(period, anchor)
    anchor = tonumber(anchor) or os.time()
    local year, month, day = parts(anchor)
    if period == "total" then
        return "累计", nil
    end
    local line1 = string.format("%d年", year)
    local line2 = string.format("%02d月%02d日", month, day)
    return line1, line2
end

--- ★★★ 37r：列出可选年份，供统计页「点年份直接跳转」用。
--
--   用户要求：「选择年份使用左右箭头切换可以，点击年份直接选择年份也可以」。
--   箭头是「一格一格翻」，这里提供的是「一次跳到目标年」。
--
--   口径：
--     · 年份来源是 `store.days` 的日期键（形如 "2026-10-03"）；
--     · **永远**把 anchor 所在年与今年也算进去 —— 否则「刚装上还没读过书」
--       或「今年还没开始读」时列表会是空的，用户点开一片空白；
--     · 从新到旧排序（最近的年份最常被点，放最上面）。
--
--   返回：{ { year = 2026, has_data = true }, ... }
--   `has_data` 供调用方把没数据的年份画灰（点了也不会白跑一趟）。
function M.availableYears(store, anchor)
    anchor = tonumber(anchor) or os.time()
    local anchor_year = parts(anchor)
    local today_year = parts(os.time())
    local seen = {}
    seen[anchor_year] = false      -- false = 目前还没有数据
    if seen[today_year] == nil then seen[today_year] = false end

    local days = type(store) == "table" and store.days or nil
    if type(days) == "table" then
        for key in pairs(days) do
            local year = tonumber(tostring(key):sub(1, 4))
            -- 只认像年份的四位数，脏键（nil / 短串 / 非数字）直接跳过
            if year and year >= 1970 and year <= 9999 then
                seen[year] = true
            end
        end
    end

    local years = {}
    for year in pairs(seen) do years[#years + 1] = year end
    table.sort(years, function(a, b) return a > b end)

    local list = {}
    for _i, year in ipairs(years) do
        list[#list + 1] = { year = year, has_data = seen[year] == true }
    end
    return list
end

--==========================================================================
-- ★★★ 43-pickers：周期选择器的数据源（月份列表 / 周列表）
--==========================================================================
--
-- 背景：用户要求「年的点击可以选择年份，月的点击可以选择月份，日的点击可以
--   选择月份，周的点击可以选择第几周（第几周后面跟着时间）」。
--   年份列表 37r 就有了（availableYears），这里补上月份和周。

--- 某一周（周一为一周之始）的周一零点时间戳。
--- ★ 口径必须与 `M.bounds("week", …)` 完全一致：都是
---   `day_start - ((weekday + 6) % 7) * 86400`（Sunday=0 ⇒ 周一偏移 6）。
---   两处一旦不一致，选择器里选的那一周和统计页显示的那一周就会差一天。
function M.weekStart(anchor)
    anchor = tonumber(anchor) or os.time()
    local year, month, day = parts(anchor)
    local day_start = dayTimestamp(year, month, day)
    local weekday = tonumber(os.date("%w", day_start)) or 0 -- Sunday = 0
    return day_start - ((weekday + 6) % 7) * 86400
end

--- 周序号（1 起）。
---
--- ★ 口径 = ISO 8601：「含当年**第一个周四**的那一周是第 1 周」。
---   等价说法：用「该周**周四**」所在的年 + 它距该年第一个周四几周。
---   跨年的那一周（例如 2025-12-29 周一 ~ 2026-01-04 周日）按周一算会被
---   归到上一年的第 53 周；按周四算它属于 2026 年第 1 周 —— 这才是大家
---   习惯的「第几周」。
---
--- ★ 全部用 `os.date("*t")` + `os.time` **自己算**，不用 `os.date("%W")`：
---   `%W` 虽然也是 C89，但插件没必要为了一个数字去赌 strftime 的实现；
---   而且自己算能在没有 KOReader 的环境里跑行为测试。
--- ★ 参数是「**任意一天**」，内部先归一到那一周的周一 —— 这样传周一、传周四、
---   传今天都对，不会因为调用方忘了归一而算出离谱的周号
---   （实测：直接把周四喂进来会得到 0）。
function M.weekNumber(any_day)
    local monday = M.weekStart(tonumber(any_day) or os.time())
    local thursday = monday + 3 * 86400
    local year = os.date("*t", thursday).year
    -- 该年 1 月 1 日，以及「第一个周四」是哪天
    local jan1 = os.time{ year = year, month = 1, day = 1, hour = 12, min = 0, sec = 0 }
    local jan1_wday = os.date("*t", jan1).wday          -- 1 = 周日 … 7 = 周六
    local offset = (5 - jan1_wday) % 7                  -- 1/1 到第一个周四的天数
    local first_thursday = jan1 + offset * 86400
    return math.floor((thursday - first_thursday) / (7 * 86400) + 0.5) + 1
end

--- 列出可选月份，供统计页「点月份直接跳转」用。
--
--   口径与 availableYears 一致：
--     · 来源是 `store.days` 的日期键（形如 "2026-10-03"）；
--     · **永远**把 anchor 所在月与本月算进去（刚装插件时列表不至于空白）；
--     · 从新到旧排序（最近的月份最常被点）。
--
--   返回：{ { year = 2026, month = 10, label = "2026年10月", has_data = true }, … }
function M.availableMonths(store, anchor)
    anchor = tonumber(anchor) or os.time()
    local anchor_year, anchor_month = parts(anchor)
    local today_year, today_month = parts(os.time())

    local seen = {}
    seen[string.format("%04d-%02d", anchor_year, anchor_month)] = false
    local today_key = string.format("%04d-%02d", today_year, today_month)
    if seen[today_key] == nil then seen[today_key] = false end

    local days = type(store) == "table" and store.days or nil
    if type(days) == "table" then
        for key in pairs(days) do
            local y, m = tostring(key):match("^(%d%d%d%d)%-(%d%d)%-")
            local yn, mn = tonumber(y), tonumber(m)
            -- 只认合法的 YYYY-MM，脏键（nil / 短串 / 13 月）直接跳过
            if yn and mn and yn >= 1970 and yn <= 9999 and mn >= 1 and mn <= 12 then
                seen[string.format("%04d-%02d", yn, mn)] = true
            end
        end
    end

    local list = {}
    for key, has_data in pairs(seen) do
        local y, m = key:match("^(%d%d%d%d)%-(%d%d)$")
        list[#list + 1] = {
            year = tonumber(y),
            month = tonumber(m),
            has_data = has_data == true,
        }
    end
    table.sort(list, function(a, b)
        if a.year ~= b.year then return a.year > b.year end
        return a.month > b.month
    end)
    for _i, item in ipairs(list) do
        -- ★★★ 44-month-label：**只显示月份**（用户原话「选择月份只显示月份」）。
        --   原来是 `"%d年%d月"`（「2026年10月」），在选择器里 7 个字太占宽。
        --   年份没丢，仍在 `item.year` 里；要拼回「2026年10月」随时可以。
        --   ⚠ 已知取舍：列表若跨年（如 2026年1月 与 2025年1月 同时出现），
        --     两行的「1月」会长得一模一样。当前列表是「有数据的月 ∪ anchor 月
        --     ∪ 当前月」，一般 ≤ 13 行、跨 1~2 年，实际很少撞。
        --     真撞了的话，选择器标题里会补一句「跨 20xx–20xx 年」提示。
        item.label = string.format("%d月", item.month)
    end
    return list
end

--- 列出某一年的所有周（含「第几周 + 日期区间」），从新到旧。
--
--   用户原话：「周的点击可以选择第几周（第几周后面跟着时间）」——
--   所以每一项都带 `range`（如 "10.05–10.11"），选择器里
--   拼成「第41周  10.05–10.11」。
--
--   ★ 只列 anchor 所在年（year_override 可指定别的年）：
--     一年最多 53 周，弹窗可控；要是把「有数据的周」全列出来，
--     读三年就是 150+ 行 —— 那种列表没人会去翻。
--     想看别的年，先在「年」标签里选年，再点「周」。
--
--   返回：{ { monday = ts, year = 2026, week_no = 41,
--            label = "第41周", range = "10.05–10.11", has_data = true }, … }
function M.availableWeeks(store, anchor, year_override)
    anchor = tonumber(anchor) or os.time()
    local anchor_year = parts(anchor)
    local year = tonumber(year_override) or anchor_year

    local has_data = {}
    local days = type(store) == "table" and store.days or nil
    if type(days) == "table" then
        for key in pairs(days) do has_data[key] = true end
    end

    -- 从「12 月 31 日所在那一周的周一」往回数 55 周 ——
    -- 覆盖完「周四落在本年内」的所有周（最多 53 个）绰绰有余。
    local dec31 = dayTimestamp(year, 12, 31)
    local weekday = tonumber(os.date("%w", dec31)) or 0
    local last_monday = dec31 - ((weekday + 6) % 7) * 86400

    local weeks = {}
    for i = 0, 54 do
        local monday = last_monday - i * 7 * 86400
        local thursday = monday + 3 * 86400
        local ty = parts(thursday)
        if ty == year then
            local sunday = monday + 6 * 86400
            local any = false
            for k = 0, 6 do
                if has_data[dayKey(monday + k * 86400)] then any = true break end
            end
            -- ⚠ weekNumber 只算一次：它内部要 os.date/os.time 三次，
            --   这里循环 55 次，重复调用纯属白烧 CPU（KPW4 是单核 1GHz）。
            local week_no = M.weekNumber(monday)
            weeks[#weeks + 1] = {
                monday = monday,
                year = year,
                week_no = week_no,
                has_data = any,
                label = string.format("第%d周", week_no),
                -- ★★★ 44-week-range：日期区间改成 `12.28–01.03` 这种「月.日」形式
                --   （用户原话「选择周的周后面的日期是12.28这种形式」）。
                --   原来是 `12月28日–01月03日`（14 字），一行塞不下、被裁；
                --   改成 `12.28–01.03`（11 字）后整行短了一大截。
                range = os.date("%m.%d", monday) .. "–" .. os.date("%m.%d", sunday),
            }
        end
    end
    table.sort(weeks, function(a, b) return a.monday > b.monday end)
    return weeks
end

local function inside(date, first, last)
    return first == nil or (date >= first and date <= last)
end
local function countSet(set)
    local n = 0
    for _i, value in pairs(set or {}) do if value then n = n + 1 end end
    return n
end

--- ★★★ 37b：某个周期内「该算进来的书」的路径集合。
---
--- 老实现只看 `store.days`（按天记录），所以**只知道「当天真的读过」的书**。
--- 但「重置设置」之后，我们只能靠 `_resyncBookFromCache` 把书补进
--- `store.books`（字数在、当天没有阅读记录）——这类书在 days 里根本不存在，
--- 于是总览的「累计读过」数字与明细列表都看不到它，用户看到的还是「重置后
--- 不显示」。
---
--- 所以统一在这里收口：
---   · total 周期：store.books 里全部（口径本来就是「所有统计过的书」）
---   · 其它周期：days 里出现过的书  ∪  「已知全书字数(total_units>0)」且
---               last_read_date 落在周期内（或没有日期）的书
--- 两个调用方（summarize / details）都用它，保证「数字」和「列表」一致。
local function booksInPeriod(store, period, first, last)
    local paths = {}
    if period == "total" then
        for path in pairs(store.books) do paths[path] = true end
        return paths
    end
    for date, row in pairs(store.days) do
        if type(row) == "table" and inside(date, first, last) then
            for path, seen in pairs(row.books or {}) do
                if seen then paths[path] = true end
            end
        end
    end
    for path, book in pairs(store.books) do
        if type(book) == "table" and not paths[path] then
            local known_units = tonumber(book.total_units) or 0
            if known_units > 0 then
                local last_date = book.last_read_date
                if last_date == nil or inside(last_date, first, last) then
                    paths[path] = true
                end
            end
        end
    end
    return paths
end

function M.summarize(store, period, anchor)
    store = M.normalize(store)
    local first, last = M.bounds(period, anchor)
    local result = { seconds = 0, recorded_seconds = 0, units = 0, pages = 0, days = 0, longest_day = 0,
        notes = 0, books_read = 0, books_completed = 0, books_in_progress = 0 }

    for date, row in pairs(store.days) do
        if type(row) == "table" and inside(date, first, last) then
            local sec = safeNumber(row.seconds)
            result.seconds = result.seconds + sec
            result.recorded_seconds = result.recorded_seconds + sec
            result.units = result.units + safeNumber(row.units)
            result.pages = result.pages + safeNumber(row.pages)
            result.notes = result.notes + safeNumber(row.notes)
            if sec > 0 then
                result.days = result.days + 1
                result.longest_day = math.max(result.longest_day, sec)
            end
        end
    end

    if period == "total" then
        result.seconds, result.units, result.pages, result.days = 0, 0, 0, 0
        -- 总览的笔记数按书累计：书里的 book.notes 是这本书的标注总数（
        -- 打开书时会把已有的存量标注写进去），比按天累加更接近真实。
        result.notes = 0
        for path, book in pairs(store.books) do
            if type(book) == "table" then
                result.books_read = result.books_read + 1
                result.seconds = result.seconds + safeNumber(book.read_seconds)
                result.units = result.units + safeNumber(book.read_units)
                result.pages = result.pages + safeNumber(book.read_pages)
                result.notes = result.notes + safeNumber(book.notes)
                if book.status == "complete" then
                    result.books_completed = result.books_completed + 1
                elseif book.status == "reading" or book.status == nil then
                    result.books_in_progress = result.books_in_progress + 1
                end
            end
        end
        for _i, row in pairs(store.days) do
            if type(row) == "table" and safeNumber(row.seconds) > 0 then
                result.days = result.days + 1
                result.longest_day = math.max(result.longest_day, safeNumber(row.seconds))
            end
        end
    else
        -- ★★★ 37b：用 booksInPeriod 而不是只数 days —— 这样「重置后靠缓存
        --   补写进 store.books、但当天没读过」的书也能计入「累计读过」，
        --   与 details() 的口径完全一致（数字和列表不会打架）。
        local period_books = booksInPeriod(store, period, first, last)
        result.books_read = countSet(period_books)
        for path in pairs(period_books) do
            local book = store.books[path]
            if type(book) == "table" then
                if book.completed_date and inside(book.completed_date, first, last) then
                    result.books_completed = result.books_completed + 1
                end
                if book.status == "reading" or book.status == nil then
                    result.books_in_progress = result.books_in_progress + 1
                end
            end
        end
    end

    local average_base = period == "total" and result.recorded_seconds or result.seconds
    result.average_day_seconds = result.days > 0 and math.floor(average_base / result.days + 0.5) or 0
    result.speed = result.seconds > 0 and math.floor(result.units * 60 / result.seconds + 0.5) or 0
    result.first_date = first
    result.last_date = last
    return result
end

--- 下钻明细，供统计页卡片上的 ">" 使用。
--- kind: "days"（按天，降序）| "books_read" | "books_completed" | "books_in_progress"
function M.details(store, period, anchor, kind)
    store = M.normalize(store)
    local first, last = M.bounds(period, anchor)
    local result = {}

    if kind == "days" then
        for date, row in pairs(store.days) do
            if type(row) == "table" and inside(date, first, last) then
                local seconds = safeNumber(row.seconds)
                if seconds > 0 then
                    result[#result + 1] = {
                        date = date,
                        seconds = seconds,
                        units = safeNumber(row.units),
                        pages = safeNumber(row.pages),
                        notes = safeNumber(row.notes),
                    }
                end
            end
        end
        table.sort(result, function(a, b)
            if a.seconds ~= b.seconds then return a.seconds > b.seconds end
            return a.date > b.date
        end)
        return result
    end

    local paths = booksInPeriod(store, period, first, last)

    for path in pairs(paths) do
        local book = store.books[path]
        if type(book) == "table" then
            local include = false
            if kind == "books_read" then
                include = true
            elseif kind == "books_completed" then
                include = book.status == "complete"
                    and (book.completed_date == nil or inside(book.completed_date, first, last))
            elseif kind == "books_in_progress" then
                include = book.status == "reading" or book.status == nil
            end
            if include then
                result[#result + 1] = {
                    path = path,
                    title = book.title or path,
                    status = book.status,
                    read_units = safeNumber(book.read_units),
                    read_seconds = safeNumber(book.read_seconds),
                    read_pages = safeNumber(book.read_pages),
                    total_units = tonumber(book.total_units),
                    notes = safeNumber(book.notes),
                    last_read_date = book.last_read_date,
                }
            end
        end
    end

    table.sort(result, function(a, b)
        if (a.last_read_date or "") ~= (b.last_read_date or "") then
            return (a.last_read_date or "") > (b.last_read_date or "")
        end
        if a.read_units ~= b.read_units then return a.read_units > b.read_units end
        return tostring(a.title) < tostring(b.title)
    end)
    return result
end

local function emptyBucket(label)
    return { label = label, seconds = 0, units = 0, pages = 0, days = 0 }
end
local function accumulate(bucket, row)
    if type(row) == "table" then
        bucket.seconds = bucket.seconds + safeNumber(row.seconds)
        bucket.units = bucket.units + safeNumber(row.units)
        bucket.pages = bucket.pages + safeNumber(row.pages)
        if safeNumber(row.seconds) > 0 then bucket.days = bucket.days + 1 end
    end
end

function M.trend(store, period, anchor, metric)
    store = M.normalize(store)
    metric = metric or "units"
    local buckets = {}
    local year, month, day = parts(anchor)
    local start_ts = dayTimestamp(year, month, day)

    if period == "day" then
        local key = dayKey(start_ts)
        local row = store.days[key]
        for hour = 0, 23 do
            local label = string.format("%02d", hour)
            local bucket = emptyBucket(label)
            local hour_row = row and row.hours and row.hours[label]
            accumulate(bucket, hour_row)
            buckets[#buckets + 1] = bucket
        end
    elseif period == "week" then
        local first = M.bounds("week", anchor)
        local y, m, d = dateFromKey(first)
        local monday = dayTimestamp(y, m, d)
        for i = 0, 6 do
            local ts = monday + i * 86400
            local key = dayKey(ts)
            local weekdays = { "一", "二", "三", "四", "五", "六", "日" }
            local bucket = emptyBucket(weekdays[i + 1])
            accumulate(bucket, store.days[key])
            buckets[#buckets + 1] = bucket
        end
    elseif period == "month" then
        local last_day = os.date("*t", dayTimestamp(year, month + 1, 0)).day
        local days_in_month = last_day
        for d = 1, days_in_month do
            local key = dayKey(dayTimestamp(year, month, d))
            local bucket = emptyBucket(string.format("%02d", d))
            accumulate(bucket, store.days[key])
            buckets[#buckets + 1] = bucket
        end
    else
        local first_year, first_month
        if period == "year" then
            first_year, first_month = year, 1
        else
            -- Total view shows a rolling 12-month trend ending in the anchor month.
            first_year, first_month = year, month - 11
            local normalized = dayTimestamp(first_year, first_month, 1)
            first_year, first_month = parts(normalized)
        end
        for i = 0, 11 do
            local ts = dayTimestamp(first_year, first_month + i, 1)
            local yy, mm = parts(ts)
            local prefix = string.format("%04d-%02d-", yy, mm)
            local label = period == "total" and os.date("%y年%m月", ts) or string.format("%02d月", mm)
            local bucket = emptyBucket(label)
            for date, row in pairs(store.days) do
                if date:sub(1, 8) == prefix then accumulate(bucket, row) end
            end
            buckets[#buckets + 1] = bucket
        end
    end

    for _i, bucket in ipairs(buckets) do
        if metric == "seconds" then
            bucket.value = bucket.seconds
        elseif metric == "speed" then
            bucket.value = bucket.seconds > 0 and bucket.units * 60 / bucket.seconds or 0
        elseif metric == "average" then
            bucket.value = bucket.days > 0 and bucket.seconds / bucket.days or 0
        else
            bucket.value = bucket.units
        end
    end
    return buckets
end

return M
