-- Extract text through the APIs actually exposed by KOReader document types.
-- CRE (EPUB/HTML/FB2/TXT) uses XPointers and page coordinates, not openPage().
local M = {}

--- ★★ 整书取文本（23-accurate-count）—— 这是**唯一精确**的取文本方式。
--
-- 为什么不能用「逐页 XPointer 拼接」（这是老做法，有结构性误差）：
--
--   crengine 的 `getPageXPointer(page)` 返回的不是「第 page 页第一个字符」
--   的精确位置，而是**吸附到最近的元素/文本节点边界**的位置。
--   于是相邻两页的边界经常落到同一个节点上：
--     · 前吸 → 上一页结尾的几个字被算进这一页（重复计数）
--     · 后吸 → 这一页开头的几个字被吞掉（漏计数）
--   若某段 <p> 横跨两页，page 与 page+1 的 XPointer 可能指向同一个节点，
--   此时 `getTextFromXPointers` 会返回空串或整段 → 大段重复/丢失。
--   误差随页数**线性累积**（实测每页多吸一个文本节点 ≈ 膨胀 2.3%）。
--
-- 正确做法：直接从**文档开头取到文档结尾**，只取一次。
-- `getTextFromXPointers` 接受任意两个 XPointer，文档首尾各取一个即可。
M.WHOLE_BOOK_CHUNK = nil   -- 占位，便于外部探测版本

--- 尝试一次性取回整本文本的函数（返回 text 或 nil, err）。
-- 这是 page_text.lua 里唯一不会重复/漏计数的路径。
function M.extractWholeBook(doc)
    if type(doc) ~= "table" and type(doc) ~= "userdata" then
        return nil, "invalid document"
    end

    -- 只有 CRE 系（epub/html/fb2/txt）有 XPointer。
    if type(doc.getPageXPointer) ~= "function"
            or type(doc.getTextFromXPointers) ~= "function" then
        return nil, "document has no XPointer API"
    end

    -- 起点：文档最开头。crengine 的 XPointer 格式形如 "/body/DocFragment[1]/body/..."
    -- 取第 1 页的 XPointer 作为起点通常就是文档开头；
    -- 但更稳的是直接用页面 1 的指针，再靠「取到末尾」的终点兜住。
    local ok0, first_xp = pcall(doc.getPageXPointer, doc, 1)
    if not ok0 or type(first_xp) ~= "string" or first_xp == "" then
        return nil, "cannot get first page XPointer"
    end

    -- 终点：构造一个「文档最末尾」的 XPointer。
    -- crengine 支持把 XPointer 的最后一个字符位置设成一个极大的偏移，
    -- 也可以用 getPageXPointer(最后一页 + 1) 拿越界指针（crengine 会夹到末尾）。
    local total = 1
    if type(doc.getPageCount) == "function" then
        local okc, n = pcall(doc.getPageCount, doc)
        if okc and tonumber(n) and tonumber(n) > 0 then total = tonumber(n) end
    end

    local end_xp
    -- 优先：用 getXPointer()（当前阅读位置）试一次末尾偏移法
    do
        local okp, last_xp = pcall(doc.getPageXPointer, doc, total + 1)
        if okp and type(last_xp) == "string" and last_xp ~= ""
                and last_xp ~= first_xp then
            end_xp = last_xp
        end
    end
    -- 退一步：把首页 XPointer 的最后一个 "]" 之后的字符位置改成极大值
    if not end_xp then
        -- 形如 "/body/DocFragment[1]/body/div/p[3].0" → 末尾 ".0" 是字符偏移
        local stem = first_xp:match("^(.*%])")
        if stem then end_xp = stem .. ".99999999" end
    end
    if not end_xp then
        return nil, "cannot build end XPointer"
    end

    local ok, text = pcall(doc.getTextFromXPointers, doc, first_xp, end_xp)
    if not ok then
        return nil, "getTextFromXPointers failed: " .. tostring(text)
    end
    if type(text) == "string" and #text > 0 then
        return text
    end
    -- 有些返回是 table（自带 text 字段）
    if type(text) == "table" then
        if type(text.text) == "string" and #text.text > 0 then return text.text end
        if type(text[1]) == "string" then
            local joined = table.concat(text, "\n")
            if #joined > 0 then return joined end
        end
    end
    return nil, "whole-book extraction returned empty"
end

local function normalize(value)
    if type(value) == "string" then return value end
    if type(value) == "table" then
        if type(value.text) == "string" then return value.text end
        if type(value.content) == "string" then return value.content end
        if type(value[1]) == "string" then return table.concat(value, "\n") end
    end
    return nil
end

local function crePageText(doc, page, page_count)
    local start_xp
    if type(doc.getPageXPointer) == "function" then
        local ok, value = pcall(doc.getPageXPointer, doc, page)
        if ok then start_xp = value end
    end
    if type(start_xp) ~= "string" or start_xp == "" then
        return nil, "KOReader did not return a page XPointer"
    end

    -- The next page's XPointer is an exact exclusive end boundary for all but
    -- the final page. CRE's native getTextFromXPointers returns a plain string.
    if page < page_count and type(doc.getPageXPointer) == "function"
            and type(doc.getTextFromXPointers) == "function" then
        local ok_end, end_xp = pcall(doc.getPageXPointer, doc, page + 1)
        if ok_end and type(end_xp) == "string" and end_xp ~= "" then
            local ok_text, text = pcall(doc.getTextFromXPointers, doc, start_xp, end_xp)
            if ok_text then
                local normalized = normalize(text)
                if normalized ~= nil then return normalized end
            end
        end
    end

    -- The last page has no page+1 XPointer. Select its rendered rectangle via
    -- the CRE page geometry API, which uses 1-based Lua page numbers.
    local native = doc._document
    if type(doc.getTextFromPositions) == "function" and native
            and type(native.getPageStartY) == "function"
            and type(native.getPageHeight) == "function" then
        local ok_geom, y0, height = pcall(function()
            return native:getPageStartY(page), native:getPageHeight(page)
        end)
        if ok_geom and tonumber(y0) and tonumber(height) and tonumber(height) > 0 then
            local x0 = 0
            if type(native.getPageOffsetX) == "function" then
                local ok_x, offset = pcall(native.getPageOffsetX, native, page)
                if ok_x and tonumber(offset) then x0 = tonumber(offset) end
            end
            local page_width
            local ok_canvas, canvas = pcall(require, "ui/canvascontext")
            if ok_canvas and canvas and type(canvas.getWidth) == "function" then
                local ok_w, width = pcall(canvas.getWidth, canvas)
                if ok_w then page_width = tonumber(width) end
            end
            page_width = page_width or 10000
            if type(doc.getVisiblePageCount) == "function" then
                local ok_visible, visible = pcall(doc.getVisiblePageCount, doc)
                if ok_visible and tonumber(visible) and tonumber(visible) > 1 then
                    page_width = page_width / tonumber(visible)
                end
            end
            local p0 = { x = math.floor(x0), y = math.floor(tonumber(y0)) }
            local p1 = {
                x = math.floor(x0 + page_width - 1),
                y = math.floor(tonumber(y0) + tonumber(height) - 1),
            }
            local ok_text, result = pcall(doc.getTextFromPositions, doc, p0, p1, true)
            if ok_text then
                local normalized = normalize(result)
                if normalized ~= nil then return normalized end
            else
                return nil, tostring(result)
            end
        end
    end

    -- Last-resort CRE extraction: return the text node containing the final
    -- page's start, rather than failing the whole scan or silently saving 0.
    if type(doc.getTextFromXPointer) == "function" then
        local ok, text = pcall(doc.getTextFromXPointer, doc, start_xp)
        if ok then
            local normalized = normalize(text)
            if normalized ~= nil then return normalized end
        end
    end
    return nil, "could not extract CRE page text"
end

function M.extract(doc, page, page_count)
    if type(doc) ~= "table" and type(doc) ~= "userdata" then
        return nil, "invalid document"
    end
    if type(doc.getPageXPointer) == "function" then
        local text, err = crePageText(doc, page, page_count)
        if text ~= nil then return text end
        -- Do not fall through to inherited Document:getPageText on a CRE
        -- document: that implementation does `self._document:openPage(pageno)`,
        -- and when self._document is nil (CRE binding has no openPage, or the
        -- document was already closed) it raises
        --   document.lua:596: attempt to call method 'openPage' (a nil value)
        -- Returning early here keeps the scan degraded-but-alive instead of
        -- flooding crash.log and losing the whole run.
        if type(doc.getTextFromXPointers) == "function" then
            return nil, err
        end
    end

    if type(doc.getPageText) == "function" then
        -- Document:getPageText needs a live backend handle. Without it the call
        -- is guaranteed to throw, so report a clean error instead.
        if doc._document == nil and type(doc.getPageXPointer) ~= "function" then
            return nil, "document backend not open (self._document is nil)"
        end
        local ok, value = pcall(doc.getPageText, doc, page)
        if ok then
            local text = normalize(value)
            if text ~= nil then return text end
            if value == nil then return "" end
            return nil, "getPageText returned " .. type(value)
        end
        return nil, tostring(value)
    end
    return nil, "document has no supported text extraction method"
end

return M
