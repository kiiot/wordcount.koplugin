-- Small, dependency-free Unicode counter shared by the KOReader plugin and
-- its standalone tests. It counts English/European word-like runs and each
-- CJK ideograph/kana/hangul syllable as one reading unit. KOReader's LuaJIT
-- builds do not expose Lua 5.3's utf8 library everywhere, so decode UTF-8 here.
local M = {}

local function decodeAt(s, i)
    local b1 = s:byte(i)
    if not b1 then return nil, i end
    if b1 < 0x80 then return b1, i + 1 end

    local b2, b3, b4 = s:byte(i + 1, i + 3)
    if b1 >= 0xC2 and b1 <= 0xDF and b2 and b2 >= 0x80 and b2 <= 0xBF then
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80), i + 2
    elseif b1 >= 0xE0 and b1 <= 0xEF and b2 and b3
            and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
        local cp = (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
        if cp >= 0x800 and not (cp >= 0xD800 and cp <= 0xDFFF) then
            return cp, i + 3
        end
    elseif b1 >= 0xF0 and b1 <= 0xF4 and b2 and b3 and b4
            and b2 >= 0x80 and b2 <= 0xBF
            and b3 >= 0x80 and b3 <= 0xBF
            and b4 >= 0x80 and b4 <= 0xBF then
        local cp = (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000
            + (b3 - 0x80) * 0x40 + (b4 - 0x80)
        if cp >= 0x10000 and cp <= 0x10FFFF then return cp, i + 4 end
    end
    -- Treat malformed bytes as separators, advancing one byte so the scan
    -- always makes progress and never throws on a damaged text extraction.
    return -1, i + 1
end

local function isCjkUnit(cp)
    return (cp >= 0x3400 and cp <= 0x9FFF)      -- Han, incl. Extension A
        or (cp >= 0xF900 and cp <= 0xFAFF)      -- compatibility ideographs
        or (cp >= 0x20000 and cp <= 0x3134F)    -- supplementary Han planes
        or (cp >= 0x3040 and cp <= 0x30FF)      -- Hiragana and Katakana
        or (cp >= 0x31F0 and cp <= 0x31FF)      -- Katakana extensions
        or (cp >= 0xAC00 and cp <= 0xD7AF)      -- Hangul syllables
        or (cp >= 0x1100 and cp <= 0x11FF)      -- Hangul jamo
end

local function isWordRune(cp)
    if cp >= 0x30 and cp <= 0x39 then return true end
    if cp >= 0x41 and cp <= 0x5A then return true end
    if cp >= 0x61 and cp <= 0x7A then return true end
    -- Approximate alphabetic ranges for languages that use whitespace word
    -- boundaries. Punctuation is excluded by the selected block ranges in
    -- most scripts; this is deliberately a reading-unit estimate, not a
    -- linguistic tokenizer.
    return (cp >= 0x00C0 and cp <= 0x02AF)  -- Latin and IPA
        or (cp >= 0x0300 and cp <= 0x036F)  -- combining marks
        or (cp >= 0x0370 and cp <= 0x052F)  -- Greek and Cyrillic
        or (cp >= 0x0530 and cp <= 0x1FFF)  -- other alphabetic scripts
        or (cp >= 0x2C00 and cp <= 0x2DFF)  -- supplemental alphabets
        or (cp >= 0xA640 and cp <= 0xA7FF)  -- Cyrillic extensions
        or (cp >= 0xFF10 and cp <= 0xFF19)  -- full-width digits
        or (cp >= 0xFF21 and cp <= 0xFF3A)  -- full-width A-Z
        or (cp >= 0xFF41 and cp <= 0xFF5A)  -- full-width a-z
end

--- 「全角标点」：晋江 / 起点 / 番茄等网文平台的字数**包含**这些字符。
--- 注意只认全角（中文正文里的标点几乎都是全角），半角 ASCII 标点不计 ——
--- 网文平台按字节折算，半角标点只值半个字，硬算 1 会反而偏高。
local function isPunctUnit(cp)
    return (cp >= 0x3001 and cp <= 0x303F)  -- 、。〈〉《》「」『』【】etc.
        or (cp >= 0x2010 and cp <= 0x2027)  -- — – ‘ ’ “ ” … ‥
        or (cp >= 0x2030 and cp <= 0x205E)  -- ‰ ′ ″ ※ etc.
        or (cp >= 0xFE10 and cp <= 0xFE1F)  -- 竖排标点
        or (cp >= 0xFE30 and cp <= 0xFE4F)  -- 兼容形式
        or (cp >= 0xFE50 and cp <= 0xFE6F)  -- 小写变体
        or (cp >= 0xFF01 and cp <= 0xFF0F)  -- ！＂＃…／
        or (cp >= 0xFF1A and cp <= 0xFF20)  -- ：；＜＝＞？＠
        or (cp >= 0xFF3B and cp <= 0xFF40)  -- ［＼］＾＿｀
        or (cp >= 0xFF5B and cp <= 0xFF65)  -- ｛｜｝～｟｠｡｢｣
        or cp == 0x00B7                     -- ·
end

--- 一次遍历同时累计**两种口径**：
---   state.count       = 只算文字（汉字/假名/谚文各 1，英文按词 1）
---   state.count_punct = 含标点（在上一行基础上，每个全角标点 +1）
--- 两种都留着，用户切「字数口径」时不必重扫。
function M.newState()
    return { count = 0, count_punct = 0, in_word = false }
end

-- Add one extracted page to the running count. `state.in_word` crosses page
-- boundaries so a word split between two pages is not counted twice.
-- @return count, delta, count_punct, punct_delta
function M.addPage(state, text)
    if type(state) ~= "table" then state = M.newState() end
    state.count = tonumber(state.count) or 0
    state.count_punct = tonumber(state.count_punct) or state.count
    if type(text) ~= "string" then return state.count, 0, state.count_punct, 0 end

    local before = state.count
    local before_punct = state.count_punct
    local i = 1
    while i <= #text do
        local cp
        cp, i = decodeAt(text, i)
        if isCjkUnit(cp) then
            state.count = state.count + 1
            state.count_punct = state.count_punct + 1
            state.in_word = false
        elseif isPunctUnit(cp) then
            state.count_punct = state.count_punct + 1
            state.in_word = false
        elseif isWordRune(cp) then
            if not state.in_word then
                state.count = state.count + 1
                state.count_punct = state.count_punct + 1
            end
            state.in_word = true
        else
            state.in_word = false
        end
    end
    return state.count, state.count - before,
        state.count_punct, state.count_punct - before_punct
end

function M.count(text)
    local state = M.newState()
    M.addPage(state, text)
    return state.count
end

return M
