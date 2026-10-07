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
end

function M.newState()
    return { count = 0, in_word = false }
end

-- Add one extracted page to the running count. `state.in_word` crosses page
-- boundaries so a word split between two pages is not counted twice.
--
-- ★ 31-huge-book-guard：返回值里补上「本页新增了几个单位」。
--   以前调用方为了拿「这一页有多少字」，会**把同一个 text 再遍历一遍**
--   （`Counter.count(text)`）—— 页大时就是白白两倍 CPU。现在一次遍历同时
--   得到「累计值」和「本页增量」，调用方不必再数第二遍。
function M.addPage(state, text)
    if type(state) ~= "table" then state = M.newState() end
    state.count = tonumber(state.count) or 0
    if type(text) ~= "string" then return state.count, 0 end

    local before = state.count
    local i = 1
    while i <= #text do
        local cp
        cp, i = decodeAt(text, i)
        if isCjkUnit(cp) then
            state.count = state.count + 1
            state.in_word = false
        elseif isWordRune(cp) then
            if not state.in_word then state.count = state.count + 1 end
            state.in_word = true
        else
            state.in_word = false
        end
    end
    return state.count, state.count - before
end

function M.count(text)
    local state = M.newState()
    M.addPage(state, text)
    return state.count
end

return M
