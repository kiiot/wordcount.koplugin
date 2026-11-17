-- Extract text through the APIs actually exposed by KOReader document types.
-- CRE (EPUB/HTML/FB2/TXT) uses XPointers and page coordinates, not openPage().
local M = {}

-- **一页文本的字节上限**。
M.MAX_PAGE_TEXT_BYTES = 60000

-- 块扫描的文本长度闸门。单块超过这个量，说明 crengine 没有理会终点
-- （直接把整段 DOM 倒了回来），这块必须作废并退回逐页 —— 否则「分块」
-- 就退化成了「一次性整书」，内存保护的初衷全部落空。
M.BLOCK_MAX_TEXT_BYTES = 3 * 1024 * 1024

-- 由「某个 XPointer」构造「它所在 DocFragment 的末尾」。
--
-- epub 的 XPointer 由多个 DocFragment 组成（每个 xhtml 文件一段），形如
--   /body/DocFragment[7]/body/div[2]/p[5].12
-- 旧实现用 `first_xp:match("^(.*%])")` 取「最后一个 ] 之前」再拼 .99999999，
-- 拿到的是 `.../div[2]/p[5].99999999` —— 只覆盖**第一页所在的那个段落**，
-- 后面整本书都不在范围内。表现就是字数严重偏少（一本 60 万字的书少十万）。
local function endPointerFor(xp)
    local frag = xp:match("/DocFragment%[(%d+)%]")
    if frag then
        -- 该片段内第「极大」个字符 ⇒ 覆盖到这个 html 文件的末尾
        return "/body/DocFragment[" .. frag .. "].99999999"
    end
    local head = xp:match("^(.*)%.[0-9]+$")
    if head then return head .. ".99999999" end
    return xp .. ".99999999"
end

-- 尝试一次性取回整本文本的函数（返回 text 或 nil, err）。
-- ⚠ 1.4.2 起主扫描路径已改用 extractRange 分块，这个函数只保留给
-- 覆盖率自检 / 少数需要全文的场合。在低内存设备上直接调它仍有 OOM 风险。
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
    local total = 1
    if type(doc.getPageCount) == "function" then
        local okc, n = pcall(doc.getPageCount, doc)
        if okc and tonumber(n) and tonumber(n) > 0 then total = tonumber(n) end
    end

    -- 终点必须落在**文档真正的末尾**（endPointerFor 已提到模块级，块扫描共用）。

    local function isForward(a, b)
        if type(doc.compareXPointers) ~= "function" then return true end
        local ok, cmp = pcall(doc.compareXPointers, doc, a, b)
        return ok and cmp == 1
    end

    -- 最后一页的指针：先问 total（真实存在的页），再试 total+1。
    local last_xp
    for _i, page_no in ipairs({ total, total + 1 }) do
        local okp, xp = pcall(doc.getPageXPointer, doc, page_no)
        if okp and type(xp) == "string" and xp ~= "" and xp ~= first_xp then
            last_xp = xp
            break
        end
    end

    local end_xp
    if last_xp then
        local candidate = endPointerFor(last_xp)
        if isForward(first_xp, candidate) then
            end_xp = candidate
        else
            -- 「片段末尾」这种构造万一不被接受，退回最后一页起点（只丢最后一页）
            end_xp = last_xp
        end
    end
    if not end_xp then end_xp = endPointerFor(first_xp) end

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

-- 取 [p1, p2] 这个**闭区间**的页文本 —— 分块扫描的核心。
--
-- 和「一次性取全本」的区别只在切法：这里用第 p2+1 页的 XPointer 当右开边界
-- （最后一页才退到 DocFragment 末尾），所以块与块之间既不重叠也不留缝。
-- 内存占用只跟**块内页数**有关，跟整本书有多长无关 —— 这正是要的效果。
function M.extractRange(doc, p1, p2, page_count)
    if type(doc) ~= "table" and type(doc) ~= "userdata" then
        return nil, "invalid document"
    end
    if type(doc.getPageXPointer) ~= "function"
            or type(doc.getTextFromXPointers) ~= "function" then
        return nil, "document has no XPointer API"
    end
    p1 = math.max(1, math.floor(tonumber(p1) or 1))
    p2 = math.max(p1, math.floor(tonumber(p2) or p1))
    page_count = math.max(p2, math.floor(tonumber(page_count) or p2))

    local ok1, start_xp = pcall(doc.getPageXPointer, doc, p1)
    if not ok1 or type(start_xp) ~= "string" or start_xp == "" then
        return nil, "cannot get page " .. tostring(p1) .. " XPointer"
    end

    local end_xp
    if p2 < page_count then
        local ok2, next_xp = pcall(doc.getPageXPointer, doc, p2 + 1)
        if ok2 and type(next_xp) == "string" and next_xp ~= "" then
            end_xp = next_xp
        end
    end
    if not end_xp then
        -- 走到最后一块：没有「下一页起点」可用，推到文档真正的末尾。
        local last_xp = start_xp
        if p2 > p1 then
            local ok3, xp = pcall(doc.getPageXPointer, doc, p2)
            if ok3 and type(xp) == "string" and xp ~= "" then last_xp = xp end
        end
        end_xp = endPointerFor(last_xp)
        if type(doc.compareXPointers) == "function" then
            local okc, cmp = pcall(doc.compareXPointers, doc, start_xp, end_xp)
            -- 只在「构造出来的末尾 == 起点」时才退回最后一页起点（那说明这个
            -- fragment 末尾指针没被接受，继续用它会取到空文本）。
            -- ⚠ 不判断大小方向：不同 crengine 版本对 -1/1 的含义并不一致，
            -- 猜错方向会让最后一块少掉一整页。
            if okc and cmp == 0 then end_xp = last_xp end
        end
    end

    if type(doc.compareXPointers) == "function" then
        local okc, cmp = pcall(doc.compareXPointers, doc, start_xp, end_xp)
        -- 起点 == 终点 ⇒ 这一块没有文字（整页插图之类），记 0 字即可。
        -- 同上：不靠方向判断，交给后面的长度闸门兜底。
        if okc and cmp == 0 then return "" end
    end

    local ok, text = pcall(doc.getTextFromXPointers, doc, start_xp, end_xp)
    if not ok then
        return nil, "getTextFromXPointers failed: " .. tostring(text)
    end
    local normalized = normalize(text)
    if normalized == nil then return nil, "range text not a string" end
    if #normalized > M.BLOCK_MAX_TEXT_BYTES then
        -- crengine 没理终点，把远超一块的内容倒了回来。交给调用方降级。
        return nil, "block text too large: " .. #normalized
    end
    return normalized
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
            -- **页区间单调性闸门**。
            local ordered = nil
            if type(doc.compareXPointers) == "function" then
                local ok_cmp, cmp = pcall(doc.compareXPointers, doc, start_xp, end_xp)
                if ok_cmp then ordered = cmp end
            end
            if ordered == 0 then
                -- 起点 = 终点：这一页没有新的文字（整页插图之类），记 0 字即可，
                -- 不该当成错误 —— 旧代码在这里 return nil，等于把整页丢掉。
                return ""
            end
            if ordered ~= -1 then
                local ok_text, text = pcall(doc.getTextFromXPointers, doc, start_xp, end_xp)
                if ok_text then
                    local normalized = normalize(text)
                    if normalized ~= nil and #normalized <= M.MAX_PAGE_TEXT_BYTES then
                        return normalized
                    end
                end
            end
            -- ordered == -1（起点跑到终点后面）：不用整段取文本，往下走兜底。
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
                -- 矩形取文本理论上只覆盖一屏，但同样加长度闸门 ——
                -- 上游某些实现会忽略矩形直接返回整段。
                if normalized ~= nil and #normalized <= M.MAX_PAGE_TEXT_BYTES then
                    return normalized
                end
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
            -- 单指针版返回的是**整个包含它的文本节点**。
            if normalized ~= nil and #normalized <= M.MAX_PAGE_TEXT_BYTES then
                return normalized
            end
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
