-- source_policy.lua
--
-- 「来源平台 → 字数口径」的规则表。
--
-- ★ 数据从哪来：书档 `custom_metadata.lua` 里的 `custom_props.platform`。
--   就是元数据插件「写入来源平台」写进去、书架 `%platform` 显示的那个值
--   （豆瓣 / 晋江文学城 / 起点中文网 / 番茄小说 …）。
--
-- ★ 为什么不是 `require("metadata...")`：字数插件和元数据插件是**两个独立
--   插件**，任何一个都可能没装。这里只读**书档里的数据**，不碰对方插件的
--   代码和设置项 —— 元数据插件卸了，已经写进书里的 platform 照样有效。
--
-- ★ 没有 platform 的书：走「未标注来源」那条**单独的**口径设置，
--   与全局「字数口径」开关互不影响。
--
-- ★ 三态规则（每个来源）：true = 含标点；false = 只算文字；nil = 未单独设
--   → 回落到「未标注来源」的口径。
--
-- 设定项（都在 G_reader_settings 里，与元数据插件零重叠）：
--   word_count_source_policy     布尔，总开关
--   word_count_source_rules      { [来源键或 "@自定义名"] = true/false }
--   word_count_source_unlabeled  布尔，未标注来源的口径（默认 false）

local M = {}

local SET_ENABLED = "word_count_source_policy"
local SET_RULES = "word_count_source_rules"
local SET_UNLABELED = "word_count_source_unlabeled"

-- 读一次书档要开文件，翻页时绝不能每次问盘。
-- 5 分钟 TTL：读完一本几小时的书，最多重复读十来次小文件。
local MEMO_TTL = 300
local MEMO_CAP = 300

-- 预置来源。name = 菜单里显示的名字；aliases = 用来匹配 platform 的写法
-- （元数据插件允许给来源改名，所以按「包含」也要能认出来）。
-- preset = 首次启用时写入的默认口径（nil = 不预设，等用户自己选）。
M.SOURCES = {
    { key = "jjwxc", name = "晋江文学城",
      aliases = { "晋江文学城", "晋江", "jinjiang", "jjwxc" }, preset = true },
    { key = "qidian", name = "起点中文网",
      aliases = { "起点中文网", "起点", "qidian" }, preset = false },
    { key = "fanqie", name = "番茄小说",
      aliases = { "番茄小说", "番茄", "fanqie" }, preset = true },
    { key = "qimao", name = "七猫中文网",
      aliases = { "七猫中文网", "七猫", "qimao" } },
    { key = "xxsy", name = "潇湘书院",
      aliases = { "潇湘书院", "潇湘", "xxsy" } },
    { key = "changpei", name = "长佩文学",
      aliases = { "长佩文学", "长佩", "changpei" } },
    { key = "douban", name = "豆瓣",
      aliases = { "豆瓣", "豆瓣读书", "douban" } },
    { key = "weread", name = "微信读书",
      aliases = { "微信读书", "weread" } },
    { key = "google", name = "Google Books",
      aliases = { "google books", "googlebooks", "谷歌图书" } },
    { key = "bangumi", name = "Bangumi",
      aliases = { "bangumi", "bgm", "番组计划" } },
    { key = "po18", name = "PO阅读网",
      aliases = { "po阅读网", "po18", "po18镜像" } },
}

-- 模块内的设置快照（避免每次翻页都问 G_reader_settings）
local _enabled = nil
local _rules = nil
local _unlabeled = nil

local _memo = {}
local _memo_n = 0

local function settings()
    return G_reader_settings
end

-- 归一化：去掉首尾空白、转小写。
-- ⚠ 只动 ASCII 空白，别用 `%s` 去啃 UTF-8 中文（那会按字节切坏）。
local function normalize(name)
    if type(name) ~= "string" then return "" end
    local s = name:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")
    return s:lower()
end

M.normalize = normalize

local function findSourceByKey(key)
    for _i, src in ipairs(M.SOURCES) do
        if src.key == key then return src end
    end
    return nil
end

M.findSourceByKey = findSourceByKey

-- ---------------- 总开关 / 规则读写 ----------------

function M.enabled()
    if _enabled == nil then
        _enabled = (settings() ~= nil
            and settings():readSetting(SET_ENABLED) == true)
    end
    return _enabled
end

function M.setEnabled(value)
    _enabled = value == true
    if settings() then
        settings():saveSetting(SET_ENABLED, _enabled)
        settings():flush()
    end
    if _enabled then
        -- 首次启用：规则表是空的就铺一遍预设，否则开关看起来「没效果」
        if next(M.rules()) == nil then M.resetPresets() end
    end
    M.clearCache()
    return _enabled
end

function M.rules()
    if _rules == nil then
        local saved = settings() and settings():readSetting(SET_RULES)
        _rules = (type(saved) == "table") and saved or {}
    end
    return _rules
end

local function saveRules()
    if settings() then
        settings():saveSetting(SET_RULES, _rules or {})
        settings():flush()
    end
    M.clearCache()
end

-- 写一条规则。value = true / false / nil（nil = 删掉这条，回落到未标注默认）
function M.setRule(key, value)
    if type(key) ~= "string" or key == "" then return end
    local rules = M.rules()
    if value == true or value == false then
        rules[key] = value
    else
        rules[key] = nil
    end
    saveRules()
end

function M.resetPresets()
    _rules = {}
    for _i, src in ipairs(M.SOURCES) do
        if src.preset ~= nil then _rules[src.key] = src.preset end
    end
    saveRules()
end

function M.clearRules()
    _rules = {}
    saveRules()
end

-- 「未标注来源」的口径（默认只算文字）
function M.unlabeledPunct()
    if _unlabeled == nil then
        _unlabeled = (settings() ~= nil
            and settings():readSetting(SET_UNLABELED) == true)
    end
    return _unlabeled
end

function M.setUnlabeledPunct(value)
    _unlabeled = value == true
    if settings() then
        settings():saveSetting(SET_UNLABELED, _unlabeled)
        settings():flush()
    end
    M.clearCache()
end

-- 自定义来源：键统一加 `@` 前缀，避免和预置键撞车
function M.addCustomSource(name)
    name = normalize(name)
    if name == "" then return false, "名称不能为空" end
    local rules = M.rules()
    local key = "@" .. name
    if rules[key] == nil then
        rules[key] = nil          -- 占位：让它出现在菜单里
        saveRules()
    end
    return true, key
end

-- 菜单用：把一个来源键的口径说成人话
function M.ruleLabel(key)
    local rules = M.rules()
    local v = rules[key]
    if v == true then return "含标点" end
    if v == false then return "只算文字" end
    return "跟随未标注"
end

-- ---------------- platform 匹配 ----------------

-- 把 platform 字符串匹配到预置来源键；匹配不上返回 nil
function M.matchKey(platform)
    local norm = normalize(platform)
    if norm == "" then return nil end
    -- ① 先做精确匹配（改名成 "晋江" 也能对上，因为别名里有）
    for _i, src in ipairs(M.SOURCES) do
        for _j, alias in ipairs(src.aliases) do
            if normalize(alias) == norm then return src.key end
        end
    end
    -- ② 再做包含匹配（"晋江文学城（手机版）" 之类）
    --    取最长的别名，避免 "起点" 误吃 "起点女生网"? 反而应该吃。
    local best_key, best_len = nil, 0
    for _i, src in ipairs(M.SOURCES) do
        for _j, alias in ipairs(src.aliases) do
            local a = normalize(alias)
            if #a >= 2 and norm:find(a, 1, true) and #a > best_len then
                best_key, best_len = src.key, #a
            end
        end
    end
    return best_key
end

-- 显示名：认得出的来源用规范名，认不出的原样返回 platform
function M.displayName(platform)
    if type(platform) ~= "string" or platform == "" then return nil end
    local key = M.matchKey(platform)
    local src = key and findSourceByKey(key)
    if src then return src.name end
    return platform
end

-- ---------------- 读书档里的 platform ----------------

local function readPlatformFromDisk(path)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not (ok_ds and DocSettings and DocSettings.findCustomMetadataFile) then
        return nil
    end
    local ok_find, cmf = pcall(DocSettings.findCustomMetadataFile, DocSettings, path)
    if not (ok_find and cmf) then return nil end
    local ok, cp = pcall(function()
        return DocSettings.openSettingsFile(cmf):readSetting("custom_props")
    end)
    if ok and type(cp) == "table" and type(cp.platform) == "string"
            and cp.platform ~= "" then
        return cp.platform
    end
    return nil
end

-- 某本书的来源平台（nil = 没标注）
function M.platformOf(path)
    if type(path) ~= "string" or path == "" then return nil end
    local now = os.time()
    local hit = _memo[path]
    if type(hit) == "table" and (now - hit.at) < MEMO_TTL then
        return hit.value or nil
    end
    local value = readPlatformFromDisk(path)
    if _memo[path] == nil then
        _memo_n = _memo_n + 1
        if _memo_n > MEMO_CAP then
            _memo = {}
            _memo_n = 1
        end
    end
    _memo[path] = { at = now, value = value or false }
    return value
end

-- ---------------- 对外主入口 ----------------

-- 这本书该用什么口径。
-- @return boolean|nil  开关关闭时返回 nil（调用方回落到全局「字数口径」）
function M.punctFor(path)
    if not M.enabled() then return nil end
    local platform = M.platformOf(path)
    if platform then
        local rules = M.rules()
        local key = M.matchKey(platform)
        if key and type(rules[key]) == "boolean" then return rules[key] end
        -- 自定义来源：名字完全一致才算
        local custom = rules["@" .. normalize(platform)]
        if type(custom) == "boolean" then return custom end
    end
    return M.unlabeledPunct()
end

-- 当前这本书的完整信息（菜单 / 提示文案用）
function M.describe(path)
    local platform = M.platformOf(path)
    local punct = M.punctFor(path)
    return {
        path = path,
        platform = platform,
        name = M.displayName(platform),
        punct = punct,
        labeled = platform ~= nil,
    }
end

function M.clearCache()
    _memo = {}
    _memo_n = 0
end

-- 测试用：把内部缓存清干净（含设置快照）
function M._resetSnapshots()
    _enabled = nil
    _rules = nil
    _unlabeled = nil
    M.clearCache()
end

return M
