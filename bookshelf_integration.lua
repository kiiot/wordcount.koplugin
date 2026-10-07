local M = {}

local COUNT_KEY = "word_count_total_v1"
local COUNT_MTIME_KEY = "word_count_file_mtime_v1"
local COUNT_SIZE_KEY = "word_count_file_size_v1"
local READ_STATS_KEY = "word_count_read_stats_v1"
local CACHE_TTL = 5
local memo = {}
local memo_expires_at = 0
local TOKENS_MARKER = "_word_count_koplugin_expand_wrapper"

local TOKEN_NAMES = { "word_count_read", "word_speed", "word_count" }

--- 千分位。与 statistics_page.lua:groupDigits 同一份实现。
local function groupDigits(n)
    local reversed = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (reversed:gsub("^,", ""))
end

--- 合法的单位显示模式。37r 新增 k / qian 两种。
local function normalizeUnitMode(mode)
    if mode == "full" or mode == "wan" or mode == "auto"
            or mode == "k" or mode == "qian" then
        return mode
    end
    return "auto"
end

--- 把字数格式化成带单位的字符串。
--
--  ★★★ 37q：**必须与 `statistics_page.lua:formatCount` 语义完全一致**。
--
--  修的是一个用户直接看得见的显示不一致（37o 引入「单位显示」二级菜单后暴露）：
--    · 统计页（statistics_page.formatCount）在 wan 模式下、n < 10000 时
--      回退成完整数字 `1,234`；
--    · 而本文件旧实现（`mode == "wan" and n >= 10000` 之后直接落到 `return ...万`）
--      对 n < 10000 会算出 `0.1万` —— **1234 字被显示成「0.1万」**。
--  于是同一本书的字数在两处显示不同：统计页 `1,234`，书架占位符 `0.1万`。
--
--  修法：逐分支照抄 statistics_page.formatCount 的判定顺序，
--  三处（本文件 / statistics_page / main.unitFormatMode）口径统一。
--  ⚠ 改这里时务必同步 statistics_page.lua:formatCount —— 两处是同一份规则。
--
--  ★★★ 37r：新增 `k` 与 `qian` 两种「千」进制。
--    · k    → 358k    （英文千后缀，紧凑、适合跟数字混排）
--    · qian → 358千    （中文千，与「万/亿」同一套读法）
--    两者都只在 n >= 1000 时启用；不足 1000 一律回退完整数字
--    （否则 0.4千 / 0.4k 这种读数没有意义）。
--  ⚠ 新增/调整分支时，**必须同步 statistics_page.lua:formatCount 与
--    formatCountParts**，否则书架占位符与统计页会再次出现同一个数两种写法。
local function formatUnits(value)
    local n = math.max(0, math.floor(tonumber(value) or 0))
    local mode = G_reader_settings and G_reader_settings:readSetting("word_count_unit_format") or "auto"
    mode = normalizeUnitMode(mode)

    -- 与 statistics_page.formatCount 一一对应：
    --   1) full        → 完整数字（带千分位）
    --   2) k   且 >= 1千 → 「k」
    --   3) qian 且 >= 1千 → 「千」
    --   4) wan  且 >= 1万 → 强制「万」
    --   5) >= 1亿       → 「亿」
    --   6) 其余且 >= 1万（auto）→ 「万」
    --   7) 其余         → 完整数字（这就是旧实现漏掉的回退分支）
    if mode == "full" then
        return groupDigits(n)
    end
    if mode == "k" and n >= 1000 then
        return (string.format("%.1f", n / 1000):gsub("%.0$", "")) .. "k"
    end
    if mode == "qian" and n >= 1000 then
        return (string.format("%.1f", n / 1000):gsub("%.0$", "")) .. "千"
    end
    if mode == "wan" and n >= 10000 then
        return (string.format("%.1f", n / 10000):gsub("%.0$", "")) .. "万"
    end
    if n >= 100000000 then
        return (string.format("%.1f", n / 100000000):gsub("%.0$", "")) .. "亿"
    end
    if n >= 10000 then
        return (string.format("%.1f", n / 10000):gsub("%.0$", "")) .. "万"
    end
    return groupDigits(n)
end

local function cachedDataFor(book)
    local path = book and (book.filepath or book.path)
    if type(path) ~= "string" or path == "" or path:find("^OPDS://") then
        return {}
    end
    local now = os.time()
    if now >= memo_expires_at then
        memo = {}
        memo_expires_at = now + CACHE_TTL
    end
    local hit = memo[path]
    if hit ~= nil then return hit or {} end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not (ok_lfs and lfs and ok_ds and DocSettings) then
        memo[path] = false
        return {}
    end
    local ok_attr, attr = pcall(lfs.attributes, path)
    if not ok_attr or type(attr) ~= "table" then
        memo[path] = false
        return {}
    end
    local ok_has, has = pcall(function() return DocSettings:hasSidecarFile(path) end)
    if not ok_has or not has then
        memo[path] = false
        return {}
    end

    local ok, result = pcall(function()
        local ds = DocSettings:open(path)
        if not ds then return nil end
        local current_mtime = tonumber(attr.modification)
        local current_size = tonumber(attr.size)
        local saved_mtime = tonumber(ds:readSetting(COUNT_MTIME_KEY))
        local saved_size = tonumber(ds:readSetting(COUNT_SIZE_KEY))
        local data = {}
        local count = tonumber(ds:readSetting(COUNT_KEY))
        if saved_mtime == current_mtime and saved_size == current_size
                and count and count >= 0 and count % 1 == 0 then
            data.word_count = math.floor(count)
        end
        local reading = ds:readSetting(READ_STATS_KEY)
        if type(reading) == "table"
                and tonumber(reading.file_mtime) == current_mtime
                and tonumber(reading.file_size) == current_size then
            local read_units = tonumber(reading.read_units)
            local speed = tonumber(reading.speed_units_per_minute)
            if read_units and read_units >= 0 then data.word_count_read = math.floor(read_units) end
            if speed and speed > 0 then data.word_speed = math.floor(speed + 0.5) end
        end
        return next(data) and data or nil
    end)
    if not ok or result == nil then
        memo[path] = false
        return {}
    end
    memo[path] = result
    return result
end

local function containsToken(catalogue, token)
    for _i, entry in ipairs(catalogue) do
        if entry.token == token then return true end
    end
    return false
end

function M.register(Tokens, data_reader)
    if type(Tokens) ~= "table" or type(Tokens.expanders) ~= "table"
            or type(Tokens.CATALOGUE) ~= "table" or type(Tokens.expand) ~= "function" then
        return false, "Bookshelf token module has an unsupported shape"
    end
    if Tokens._word_count_koplugin_registered then return true, "already enabled" end

    local read_data = data_reader or cachedDataFor
    local descriptions = {
        { "word_count", "Total reading units counted by the KOReader Word count plugin" },
        { "word_count_read", "Reading units on pages actually read" },
        { "word_speed", "Average reading units per minute" },
    }
    local gettext_ok, gettext = pcall(require, "gettext")
    local gettext_fn = gettext_ok and gettext or function(s) return s end
    for _i, item in ipairs(descriptions) do
        local name, description = item[1], item[2]
        local token_name = name
        if not containsToken(Tokens.CATALOGUE, "%" .. token_name) then
            Tokens.CATALOGUE[#Tokens.CATALOGUE + 1] = {
                category = token_name == "word_count" and "Book" or "Progress",
                token = "%" .. token_name,
                description = gettext_fn(description),
            }
        end
        if not Tokens.expanders[token_name] then
            Tokens.expanders[token_name] = function(book)
                local value = book and tonumber(book[token_name])
                if value == nil then value = (read_data(book) or {})[token_name] end
                if value == nil or (token_name == "word_speed" and value <= 0) then return "" end
                return formatUnits(value)
            end
        end
    end

    -- Bookshelf memoises its sorted token-name list the first time Tokens.expand
    -- runs. Wrap the public entry point so tokens registered after that first
    -- render are still expanded. The normal Bookshelf pass runs first, including
    -- conditionals (which can use the expanders above); this fallback only
    -- replaces custom placeholders left literal by an older cached name list.
    if not Tokens[TOKENS_MARKER] then
        local original_expand = Tokens.expand
        Tokens[TOKENS_MARKER] = original_expand
        Tokens.expand = function(format, book, state)
            local result = original_expand(format, book, state)
            if type(result) ~= "string" then return result end
            local needs_data = false
            for _i, name in ipairs(TOKEN_NAMES) do
                if result:find("%" .. name, 1, true) then needs_data = true; break end
            end
            if not needs_data then return result end
            local data = read_data(book) or {}
            for _i, name in ipairs(TOKEN_NAMES) do
                if result:find("%" .. name, 1, true) then
                    result = result:gsub("%%" .. name, function()
                        local value = book and tonumber(book[name]) or tonumber(data[name])
                        if value == nil or (name == "word_speed" and value <= 0) then return "" end
                        return formatUnits(value)
                    end)
                end
            end
            return result
        end
    end

    Tokens._word_count_koplugin_registered = true
    return true, "enabled"
end

function M.install()
    local ok, Tokens = pcall(require, "lib/bookshelf_tokens")
    if not ok then
        return false, "Bookshelf is not available: " .. tostring(Tokens)
    end
    return M.register(Tokens)
end

function M.clearCache()
    memo = {}
    memo_expires_at = 0
end

return M
