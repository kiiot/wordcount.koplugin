local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local DocumentRegistry = require("document/documentregistry")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local DocSettings = require("docsettings")
local Geom = require("ui/geometry")
local Device = require("device")
local ButtonTable = require("ui/widget/buttontable")
local T = ffiUtil.template

-- 屏幕对象必须**显式取**，不能裸用 `Screen`。
-- ⇒ 教训：**不要依赖上游的隐式全局**，一律自己 require 后显式局部化。
local Screen = Device.screen

local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.*/)main%.lua$") or "./")
local Counter = dofile(plugin_dir .. "word_count.lua")
local PageText = dofile(plugin_dir .. "page_text.lua")
local ReadingStats = dofile(plugin_dir .. "reading_stats.lua")
local GlobalStats = dofile(plugin_dir .. "global_stats.lua")
local StatisticsPage = dofile(plugin_dir .. "statistics_page.lua")
local BookshelfIntegration = dofile(plugin_dir .. "bookshelf_integration.lua")
-- 内存探测（读 /proc）。扫描期间用它决定「块取多大」和「什么时候必须停手」。
-- 加载失败不影响统计，只是退回固定的保守块大小。
local ok_mem, Mem = pcall(dofile, plugin_dir .. "mem.lua")
if not ok_mem or type(Mem) ~= "table" then
    logger.warn("WordCount: mem 模块加载失败：" .. tostring(Mem))
    Mem = {
        availableMB = function() return nil end,
        rssMB = function() return nil end,
        peakMB = function() return nil end,
        critical = function() return false, nil end,
        tight = function() return false, nil end,
        describe = function() return "unavailable" end,
        beginScan = function() end,
        endScan = function() end,
        ABORT_AVAIL_MB = 28,
        TIGHT_AVAIL_MB = 70,
    }
end
-- 「来源 → 字数口径」规则表。只读书档里的 custom_props.platform，
-- 不依赖元数据插件是否安装（详见模块头注释）。
local SourcePolicy = dofile(plugin_dir .. "source_policy.lua")

-- 更新模块单独一个文件；加载失败也不该拖垮整个插件。
local ok_updater, Updater = pcall(dofile, plugin_dir .. "updater.lua")
if not ok_updater or type(Updater) ~= "table" then
    logger.warn("WordCount: updater 模块加载失败：" .. tostring(Updater))
    Updater = {
        check = function()
            UIManager:show(InfoMessage:new{
                text = _("更新模块不可用，请手动下载新版覆盖插件目录。"),
                timeout = 4,
            })
        end,
    }
end

--- 读 _meta.lua 里的版本号（菜单首行显示用）。
local function readMetaVersion()
    local ok, meta = pcall(dofile, plugin_dir .. "_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return "unknown"
end

local WordCount = WidgetContainer:extend{
    name = "wordcount",
    is_doc_only = false,
}

-- ProgressbarDialog only updates its bar; its subtitle is built once during
-- init and is never re-rendered by reportProgress(). We therefore keep our own
-- references to the title/subtitle TextWidgets and push text into them on every
-- tick.

-- 进度框标题里的书名**必须先自己截短**，不能指望 TextWidget 截。
-- ⚠ 为什么不能用 `string.sub` 直接切：它是**按字节**切的，中文一个字 3 字节，
-- 切在第 2 个字节上会产生非法 UTF-8，渲染时直接报错或画成方块。
local BOOK_NAME_MAX_CHARS = 22

local function shortBookName(name)
    if type(name) ~= "string" or name == "" then return nil end
    -- 去掉扩展名（书库里显示 "三体" 比 "三体.epub" 干净）
    local base = name:match("^(.+)%.[%a%d]+$") or name
    if base == "" then base = name end

    local count = 0
    local index = 1
    local length = #base
    while index <= length do
        local byte = base:byte(index)
        if not byte then break end
        -- 只数首字节：ASCII（<128）或 UTF-8 首字节（>=192）。
        -- 续字节（128..191）跳过，不计数。
        if byte < 128 or byte >= 192 then
            count = count + 1
            if count > BOOK_NAME_MAX_CHARS then
                return base:sub(1, index - 1) .. "…"
            end
        end
        index = index + 1
    end
    return base
end

local LiveProgressDialog = ProgressbarDialog:extend{}
function LiveProgressDialog:init()
    ProgressbarDialog.init(self)

    local function is_leaf(t)
        -- 文本叶子（TextWidget）或进度条（ProgressWidget）：能直接拿来做内容
        return type(t) == "table"
            and (type(t.setText) == "function" or type(t.setPercentage) == "function")
    end

    -- 1) 定位 VerticalGroup。
    -- ⚠ 不要用「有 getSize」判断容器：VerticalGroup 也继承 getSize。
    local root = self[1]
    local group = root
    if not is_leaf(root) and type(root[1]) == "table" and not is_leaf(root[1]) then
        group = root[1]
    end
    if type(group) ~= "table" then return end

    -- 2) 认领子控件
    self._text_widgets = {}
    for i = 1, #group do
        local child = group[i]
        if type(child) == "table" then
            if type(child.setPercentage) == "function" then
                self._progress_bar_widget = child
            elseif type(child.setText) == "function" and type(child.text) == "string" then
                self._text_widgets[#self._text_widgets + 1] = child
            end
        end
    end

    -- 3) 按初始文字认领 title / subtitle（比按下标猜稳）
    self._title_widget = nil
    self._subtitle_widget = nil
    local texts = self._text_widgets
    if type(self.title) == "string" then
        for i = 1, #texts do
            if texts[i].text == self.title then self._title_widget = texts[i] break end
        end
    end
    if type(self.subtitle) == "string" then
        for i = 1, #texts do
            if texts[i] ~= self._title_widget and texts[i].text == self.subtitle then
                self._subtitle_widget = texts[i]
                break
            end
        end
    end
    -- 兜底：按上游的构造顺序回填（title 先于 subtitle）
    if not self._title_widget and type(self.title) == "string" then
        self._title_widget = texts[1]
    end
    if not self._subtitle_widget and type(self.subtitle) == "string" then
        if texts[2] and texts[2] ~= self._title_widget then
            self._subtitle_widget = texts[2]
        elseif texts[1] and texts[1] ~= self._title_widget then
            self._subtitle_widget = texts[1]
        end
    end
    self._progress_group = group
    -- reportProgress 直接操作这个引用，别再依赖 self.progress_bar 一定存在
    if self._progress_bar_widget then self.progress_bar = self._progress_bar_widget end

    -- 刷屏控制的内部状态（20-flicker-fix）。见 _redraw / MIN_REDRAW_INTERVAL。
    self._last_redraw_at = nil       -- 上次真实重绘的 monotonic 时刻
    self._redraw_pending = false     -- 有没有被节流掉、欠着的重绘
    self._last_progress_text = nil   -- 上一句写进 subtitle 的进度文本（去重用）
    -- 上一帧真实重绘的区域。下次重绘要跟它取并集 ——
    -- 否则「长书名 → 短书名」时框变小，上一帧多出来的那截永远擦不掉。
    self._last_region = nil

    -- 在进度条下方挂一个「取消」按钮。
    -- ⚠ 布局注意：本对话框是 InputContainer，Point 事件按子控件递归派发。
    self._cancel_button = nil
    if self._progress_group and type(self.cancel_callback) == "function" then
        -- ⚠ 注意：`ButtonTable:new{...}` 是**方法调用语法**，不能直接当表达式
        -- 传给 pcall（Lua 语法不允许）。必须包一层 function 再 pcall。
        local ok_bt, btn_table = pcall(function()
            return ButtonTable:new{
                width = Screen:getWidth() - Screen:scaleBySize(80),
                buttons = {{
                    {
                        text = self.cancel_text or _("取消统计"),
                        callback = function()
                            if type(self.cancel_callback) == "function" then
                                self.cancel_callback()
                            end
                        end,
                    },
                }},
            }
        end)
        if ok_bt and btn_table then
            self._cancel_button = btn_table
            self._progress_group[#self._progress_group + 1] = btn_table
            -- **不要清外层 self.dimen！**
            local screen_size = Screen:getSize()
            if self.dimen == nil or self.dimen.w ~= screen_size.w
                    or self.dimen.h ~= screen_size.h then
                self.dimen = Geom:new{
                    x = 0, y = 0,
                    w = screen_size.w, h = screen_size.h,
                }
            end
            -- 内层 FrameContainer：**必须**清 dimen（命中区域要按新高度重算）。
            local frame = self[1]
            if type(frame) == "table" and frame.dimen ~= nil then
                frame.dimen = nil
            end
        else
            -- **把真实错误打出来**。
            logger.warn("WordCount: 取消按钮创建失败：" .. tostring(btn_table))
        end
    end
end

-- 文本变了必须**同时作废两层尺寸缓存**，否则框还是按旧尺寸画的。
-- ⚠ **不要清 `self.dimen`**（对话框自己的）。上游把 `self.dimen` 设成
-- 整屏尺寸，它同时承担「居中偏移的基准」和「事件命中区」两个职责；
-- 清掉会让框贴到屏幕最上方（1.5-bugP 踩过，见 init 里的长注释）。
function LiveProgressDialog:_invalidateLayout()
    local group = self._progress_group
    if type(group) == "table" and type(group.resetLayout) == "function" then
        pcall(group.resetLayout, group)
    end
    local frame = self[1]
    if type(frame) == "table" then
        frame.dimen = nil
    end
end

-- 把一个文本推给指定槽位。找不到控件时只更新内部字段，绝不抛错。
function LiveProgressDialog:_pushText(slot, text)
    text = tostring(text or "")
    local widget
    if slot == "title" then
        self.title = text
        widget = self._title_widget
    else
        self.subtitle = text
        widget = self._subtitle_widget
    end
    -- **不要**写成 `(slot == "title") and self._title_widget or self._subtitle_widget`。
    if widget and type(widget.setText) == "function" then
        local before = widget.text
        widget:setText(text)
        -- 只有内容真的变了才作废尺寸缓存（进度文本每 5% 变一次，
        -- 不做判断的话会白白触发一堆重算）。
        if before ~= text then
            self:_invalidateLayout()
        end
    end
end

-- 批量统计时，在**标题行**显示「第 X / N 本」。
function LiveProgressDialog:setBatchInfo(index, total, name)
    index = tonumber(index)
    total = tonumber(total)
    if not index or not total or total <= 0 then
        -- 以前这里直接 return，**什么都不写** ——
        -- 于是从「批量第 3 本」切回单本统计时，标题里还挂着上一本书的名字。
        self.batch_index = nil
        self.batch_total = nil
        self.batch_name = nil
        self:refreshBatchTitle()
        return
    end
    self.batch_index = index
    self.batch_total = total
    self.batch_name = shortBookName(name)
    self:refreshBatchTitle()
end

-- 把当前批次信息重新组合进标题。扫描过程中标题可能被 configureProgress
-- 改回「正在批量统计字数」，所以 configureProgress 里也要调一次。
function LiveProgressDialog:refreshBatchTitle()
    local index, total = self.batch_index, self.batch_total
    if not index or not total or total <= 0 then
        if not self._batch_title_written then
            -- 从来没写过批次标题 ⇒ 纯单本流程，什么都不动
            return
        end
        -- 之前写过 ⇒ 正在退出批量，把书名擦掉，退回基础标题
        self._batch_title_written = nil
        self:_pushText("title", self.batch_base_title or _("正在统计全书字数"))
        return
    end
    local base = self.batch_base_title or _("正在批量统计字数")
    self.batch_base_title = base
    self._batch_title_written = true
    local text = T(_("%1（第 %2 / %3 本）"), base, index, total)
    if self.batch_name and self.batch_name ~= "" then
        text = text .. "  " .. self.batch_name
    end
    self:_pushText("title", text)
end

-- e-ink 刷屏总控（20-flicker-fix）。
local MIN_REDRAW_INTERVAL = 0.5    -- 秒；两次真实重绘之间的最短间隔
local PERCENT_QUANTUM = 5          -- 百分比量化档位

-- 单调时钟，模块级只解析一次。
local _now
do
    local ok, t = pcall(require, "ui/time")
    if ok and type(t) == "table" and type(t.now) == "function" then
        _now = t.now
    end
end

-- 计算这个 modal 需要重绘的最小区域。
function LiveProgressDialog:_refreshRegion()
    -- 容器（= 整屏），内容在它里面居中
    local dx = tonumber(self.dimen and self.dimen.x) or 0
    local dy = tonumber(self.dimen and self.dimen.y) or 0
    local dw = tonumber(self.dimen and self.dimen.w) or 1072
    local dh = tonumber(self.dimen and self.dimen.h) or 1448

    local root = self[1]
    if root and type(root) == "table" and type(root.getSize) == "function" then
        local ok, size = pcall(root.getSize, root)
        if ok and type(size) == "table" and tonumber(size.w) and tonumber(size.h) then
            local w = math.floor(size.w)
            local h = math.floor(size.h)
            -- 居中偏移：与 InputContainer:paintTo 的算式保持一致
            local cx = dx + math.floor((dw - w) / 2)
            local cy = dy + math.floor((dh - h) / 2)
            -- 夹到屏幕内，别让浮点/尺寸异常把 region 甩到屏幕外（那样等于不刷新）
            if cx < dx then cx = dx end
            if cy < dy then cy = dy end
            if cx + w > dx + dw then w = dx + dw - cx end
            if cy + h > dy + dh then h = dy + dh - cy end
            if w > 0 and h > 0 then
                return Geom:new{ x = cx, y = cy, w = w, h = h }
            end
        end
    end

    -- 兜底：屏幕正中的一条横带（同样按居中算）。宁可刷多了，也别刷整屏。
    local band_h = math.min(360, dh)
    return Geom:new{
        x = dx, y = dy + math.floor((dh - band_h) / 2),
        w = math.floor(dw), h = band_h,
    }
end

-- 两次重绘区域的**并集**。
-- ⚠ 只并集，不并到整屏 —— 并集最多是两块对话框尺寸的矩形包络，
-- 仍然远小于 1072×1448，不会把「只刷对话框那一小块」的省电优化废掉。
local function unionRegion(a, b)
    if not a then return b end
    if not b then return a end
    local x1 = math.min(a.x, b.x)
    local y1 = math.min(a.y, b.y)
    local x2 = math.max(a.x + a.w, b.x + b.w)
    local y2 = math.max(a.y + a.h, b.y + b.h)
    return Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- 统一的重绘入口：显式 region + 时间节流。
-- @param force 布尔；true 时无视时间节流（收尾、状态变更用）
function LiveProgressDialog:_redraw(force)
    -- 改用模块级缓存的 _now。
    local now = _now and _now() or os.time()

    -- 时间节流：没到间隔就只更新内部字段，不碰屏幕。
    if not force and self._last_redraw_at
            and (now - self._last_redraw_at) < MIN_REDRAW_INTERVAL then
        self._redraw_pending = true
        return false
    end
    self._last_redraw_at = now
    self._redraw_pending = false

    -- 与上一帧的区域取并集，保证「框变小 / 文字变短」时旧内容被擦掉。
    local region = unionRegion(self._last_region, self:_refreshRegion())
    self._last_region = region
    pcall(UIManager.setDirty, UIManager, self, "ui", region)
    return true
end

-- @param total      本次扫描的上限页数（抽样模式下 = 样本页数）
-- @param title      标题行文字（nil = 不改）
-- @param full_pages 全书真实页数；只在抽样时传，用于把「样本 100 页」和
--                   「全书 N 页」区分开
function LiveProgressDialog:configureProgress(total, title, full_pages)
    self.progress_max = math.max(1, math.floor(tonumber(total) or 1))
    self.full_pages = tonumber(full_pages)
    -- 进度文本里带了全书页数 ⇒ 换书时必须让缓存作废，否则会沿用上一本的文案。
    self["_last_progress_text"] = nil
    -- 进度条要在 init 时就已经建好；这里不能靠改 progress_max 让 bar 出现，
    -- 所以如果先前没有 bar（progress_max 为 nil 的「正在打开…」对话框），
    -- 就把可见性关掉并只显示文字进度，避免出现半截布局。
    self.progress_bar_visible = self._progress_bar_widget ~= nil
    if title then
        self:_pushText("title", title)
        -- 记住这次传进来的「基础标题」，refreshBatchTitle
        -- 要拿它去拼「基础标题（第 X / N 本）」。
        if self.batch_total and self.batch_total > 0 then
            self.batch_base_title = title
        end
    end
    -- 批量时 title 又被写回「正在批量统计字数」了，
    -- 这里补一次，否则「第 X / N 本」会被每本书开头覆盖掉。
    self:refreshBatchTitle()
    self:_syncProgressBar(0)
    self:_pushProgressText(0)
    -- 刚切到正式进度：强制放行一次，让用户立刻看到新标题/0%。
    self:updateProgress(0, true)
end

-- 只写进度条内部百分比，不刷屏。
function LiveProgressDialog:_syncProgressBar(progress)
    local bar = self._progress_bar_widget or self.progress_bar
    if not self.progress_bar_visible or not bar or type(bar.setPercentage) ~= "function" then return end
    local total = math.max(1, tonumber(self.progress_max) or 1)
    pcall(bar.setPercentage, bar,
        math.max(0, math.min(1, (tonumber(progress) or 0) / total)))
end

-- 进度副标题的文本。
-- ⚠ 抽样时 total 只是**样本页数**（SAMPLE_PAGES = 100），不是全书页数；
-- 只写「已扫描 3 / 100 页」会让人以为这本书只有 100 页。所以抽样时
-- 额外把全书页数（self.full_pages）缀在后面，两个数一起给出来。
local function buildProgressText(done, total, shown, full_pages)
    local full = tonumber(full_pages)
    if full and full > total then
        return T(_("已扫描 %1 / %2 页（%3%）· 全书 %4 页"), done, total, shown, full)
    end
    return T(_("已扫描 %1 / %2 页（%3%）"), done, total, shown)
end

-- 写「已扫描 x / y 页（z%）」这行字，百分比量化以减少无谓的文本变化。
-- 返回 true 表示文本确实变了。
function LiveProgressDialog:_pushProgressText(done)
    done = math.max(0, math.floor(tonumber(done) or 0))
    local total = math.max(1, math.floor(tonumber(self.progress_max) or 1))
    if done > total then done = total end
    local percent = math.floor(done * 100 / total + 0.5)
    -- 量化：只有跨过 5% 档位（或到达 100%）才真的改文字
    local shown = percent
    if percent < 100 then
        shown = math.floor(percent / PERCENT_QUANTUM) * PERCENT_QUANTUM
    end
    local text = buildProgressText(done, total, shown, self.full_pages)
    if text == self._last_progress_text then return false end
    self._last_progress_text = text
    self:_pushText("subtitle", text)
    return true
end

-- @param done  已扫描页数
-- @param force 布尔；true 时无视时间节流立刻重绘（用于 0% 与 100% 这类
-- 用户一定会看到的节点）
function LiveProgressDialog:updateProgress(done, force)
    done = math.max(0, math.floor(tonumber(done) or 0))
    local total = math.max(1, math.floor(tonumber(self.progress_max) or 1))
    if done >= total then force = true end

    self:_syncProgressBar(done)
    local text_changed = self:_pushProgressText(done)
    -- 文本没变、也没被强制 —— 这一 tick 完全不需要动屏幕。
    if not force and not text_changed then return end
    self:_redraw(force)
end

-- 保留给上游/外部调用的兼容入口。上游 ProgressbarDialog:reportProgress 会调
-- redrawProgressbarIfNeeded() → redrawProgressbar() → forceRePaint()（全屏糊），
-- 我们覆写掉，改成只写内部状态 + 走自己的节流重绘。
function LiveProgressDialog:reportProgress(progress)
    self:_syncProgressBar(progress)
end

-- 上游的这两个都被我们摘掉，防止它偷偷 forceRePaint。
-- ⚠ 不要写成一行 `function LiveProgressDialog:redrawProgressbar() end`：
-- luaparser（check_plugin.py 用的解析器）对「函数体为空的单行定义」会报
-- no viable alternative —— 是真机的 Lua 能过、静态检查过不了。展开成多行。
function LiveProgressDialog:redrawProgressbarIfNeeded()
    -- 故意空实现：上游这里会 redrawProgressbar() → forceRePaint()（全屏刷）
end

function LiveProgressDialog:redrawProgressbar()
    -- 故意空实现：同上。真正的重绘由 _redraw() 以最小 region 完成。
end

function LiveProgressDialog:setStatus(status)
    -- ⚠ 用 self["_last_progress_text"] 而不是 self._last_progress_text：
    -- luaparser（check_plugin.py 用的解析器）不接受 `obj:field = value`
    -- 这种「冒号当索引、冒号后跟字段」的形式，会报 no viable alternative。
    self["_last_progress_text"] = nil   -- 状态文本与进度文本不同，强制写
    self:_pushText("subtitle", status)
    -- 状态变更必须让用户看见
    self:_redraw(true)
end

-- 关闭时把重绘状态清干净。
-- ⚠ 用 `self["_last_region"] = nil` 的方括号写法，理由同 setStatus 上方注释。
function LiveProgressDialog:onCloseWidget()
    self["_last_region"] = nil
    self["_last_redraw_at"] = nil
    self["_redraw_pending"] = false
    local parent = ProgressbarDialog.onCloseWidget
    if type(parent) == "function" then
        pcall(parent, self)
    end
end

local KEY_COUNT = "word_count_total_v1"
-- 同一本书的「含标点」口径字数。三种口径一起存，切口径不用重扫。
local KEY_COUNT_PUNCT = "word_count_total_punct_v1"
-- 「严格字符数」口径（每个非空白字符算 1，对齐晋江/番茄后台那个数）
local KEY_COUNT_CHAR = "word_count_total_char_v1"
local KEY_MTIME = "word_count_file_mtime_v1"
local KEY_SIZE = "word_count_file_size_v1"
-- 记录「这个字数是估算的还是精确的」。
-- 缓存命中时要据此提示用户「想看精确值请点重新统计」。
local KEY_ESTIMATED = "word_count_estimated_v1"
local KEY_SAMPLED_PAGES = "word_count_sampled_pages_v1"
-- 全局字数缓存表（24-cache-reuse）：{ [文件路径] = {count,mtime,size,at} }。
local KEY_CACHE = "word_count_cache_v1"
local KEY_READ_STATS = "word_count_read_stats_v1"
local KEY_GLOBAL_STATS = "word_count_global_stats_v1"
-- 扫描节流参数（22-progress-only：省电优先）。
-- ⇒ 32 次 wakeup，**唤醒次数直接砍半**，而总工作量完全不变。
local PAGES_PER_TICK = 32
local SCAN_TICK_DELAY = 0.25
-- 进度上报的最短时间间隔（秒）。
local PROGRESS_REPORT_INTERVAL = 1.5
-- 阅读状态/全局统计落盘频率（每 N 次累积写一次）。攒得越大越省电，
-- 但突然断电丢的也越多。3 → 8 是「每本书结束时本来还会有一次 force_flush」
local READ_FLUSH_EVERY = 8

-- 扫描过程中的 CPU 让渡间隔（秒）。
-- ⇒ SoC 有更多窗口降频/进 idle，机身更凉
-- · 休息更久（1.2 秒，原来 1 秒）
local CHUNK_TICKS = 10            -- 每 10 个 tick 休息一次（原来 20）
local CHUNK_REST_DELAY = 1.2      -- 休息 1.2 秒（此时不刷屏、不唤醒）

-- 抽页统计（26-sample-estimate）—— 「太耗电就只统计前一百，可以翻页查看」。
local SAMPLE_PAGES = 100          -- 抽页统计的样本页数
local MODE_FULL = "full"
local MODE_SAMPLE = "sample"

-- **「极端大书」的口头确认线**（不是限制！）。
local EXTREME_PAGES = 30000

-- （历史常量，已不再参与任何判断 —— 58 起用 EXTREME_PAGES + 用户上限取代）
-- 保留名字只为兼容旧注释里的引用，别再拿它做闸门。
local PER_PAGE_SCAN_MAX_PAGES = EXTREME_PAGES

-- **把「降级/拒绝」的触发点交给用户**。
-- ⚠ 内存保护并没有消失：1.4.2 起改成「按剩余内存决定块大小 + 跌破安全线自动停手」
--   （见 mem.lua 与 chooseBlockPages），不再靠页数/体积这类静态阈值去猜。
local DEFAULT_DOWNGRADE_PAGES = 0   -- 0 = 不限制（58 起）

-- 是否允许「自动降级」。（默认 false = 完整优先，不够就断）
local function downgradeEnabled()
    local v = G_reader_settings and G_reader_settings:readSetting("word_count_downgrade_enabled")
    return v == true   -- 只有显式设成 true 才允许
end

-- 用户自定义的「降级触发页数」。
-- @return number  0 = **不限制**（58 起默认值）；> 0 = 用户输入的上限
local function downgradePages()
    local v = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_pages"))
    -- 只认「>= 0」的整数输入。
    if v and v >= 0 then return math.floor(v) end
    return DEFAULT_DOWNGRADE_PAGES
end

-- 「页数上限」是否真的存在（用户输入了 > 0 的数）。
local function pageLimitActive()
    return downgradePages() > 0
end

-- 逐页字数表的**容量上限**。
local MAX_TRACKED_PAGES = 50000

-- **单页字数的合理上限**。
local PAGE_UNITS_MIN_CAP = 4000
local PAGE_UNITS_MAX_FACTOR = 3

-- 批量统计的自动降级阈值。
local DEFAULT_BATCH_SAMPLE_THRESHOLD = 5
-- 本批自动降级为抽样的「本数阈值」（用户可调）。
local function batchSampleThreshold()
    local v = G_reader_settings
        and tonumber(G_reader_settings:readSetting("word_count_batch_sample_threshold"))
    if v == nil then return DEFAULT_BATCH_SAMPLE_THRESHOLD end
    if v < 0 then return 0 end
    return math.floor(v)
end
-- 读取用户选择的统计模式（存在全局设置里）。
local function countMode()
    local mode = G_reader_settings and G_reader_settings:readSetting("word_count_scan_mode")
    if mode == MODE_SAMPLE or mode == MODE_FULL then return mode end
    return MODE_FULL
end

-- 模式的显示名（菜单 / 提示文案用）。
local function scanModeName(mode)
    if mode == MODE_SAMPLE then
        return T(_("抽页估算（前 %1 页，省电）"), SAMPLE_PAGES)
    end
    return _("完整扫描（精确）")
end

-- ================= 字数口径：三档 =================
--
--   "plain"  只算文字 —— 汉字/假名/谚文各 1，英文按词 1，标点不计
--   "punct"  含标点   —— 上面的基础上，每个**全角**标点 +1
--   "chars"  严格字符数 —— 每个非空白字符 +1（半角标点、英文字母逐个算）
--
-- ⚠ 前两档是「阅读单位」，不是平台后台那个数；第三档才是**对齐平台**的：
--   平台按字符算，`2019年` 是 5 个字符，前两档只会记 2 个字。
--
-- 三种值在同一次扫描里同时累计，切口径只是换一个字段读，不用重扫。
local COUNT_MODES = { plain = true, punct = true, chars = true }
local SET_COUNT_MODE = "word_count_count_mode"
local SET_COUNT_PUNCT_LEGACY = "word_count_count_punct"

local function normalizeMode(value)
    if value == true then return "punct" end
    if value == false then return "plain" end
    if type(value) == "string" and COUNT_MODES[value] then return value end
    return nil
end

-- 口径的显示名（和 SourcePolicy.modeLabel 保持一致）
local function modeLabel(mode)
    if mode == "punct" then return _("含标点") end
    if mode == "chars" then return _("严格字符数") end
    return _("只算文字")
end

-- 全局口径（**兜底**）：开了「按来源设定口径」之后，它只对来源规则
-- 覆盖不到的书起作用。旧版本存的是布尔值 → 这里继续认。
local function globalMode()
    if not G_reader_settings then return "plain" end
    local saved = normalizeMode(G_reader_settings:readSetting(SET_COUNT_MODE))
    if saved then return saved end
    if G_reader_settings:readSetting(SET_COUNT_PUNCT_LEGACY) == true then
        return "punct"
    end
    return "plain"
end

local function setGlobalMode(mode)
    mode = normalizeMode(mode) or "plain"
    if not G_reader_settings then return end
    G_reader_settings:saveSetting(SET_COUNT_MODE, mode)
    -- 旧键同步写，避免降级到老版本时口径突变
    G_reader_settings:saveSetting(SET_COUNT_PUNCT_LEGACY, mode == "punct")
    G_reader_settings:flush()
end

--- 这本书该用什么口径（来源规则优先，否则全局兜底）。
-- 返回模式字符串，**永远不是 nil** —— 调用方不用再判空。
local function countModeOf(path)
    local from_source = SourcePolicy.modeFor(path)   -- 总开关关闭时返回 nil
    if from_source then return from_source end
    return globalMode()
end

-- 某个口径要看哪个字段（缓存有效性检查用）
local function modeField(mode)
    if mode == "chars" then return "count_char" end
    if mode == "punct" then return "count_punct" end
    return "count"
end

--- 一次扫描的三个结果里，按口径取一个。
-- ⚠ 该口径**没有**这个数时返回 nil —— 宁可让调用方当「没统计过」，
-- 也绝不能拿另一种口径的数冒充，那正是「数字偏少」的根源。
-- `strict` 为 true 时不做任何回退（缓存读路径用）；false 时允许退到
-- 「更保守的那个」（收尾展示用，避免 0 字这种明显错误）。
local function valueFor(mode, plain, punct, chars, strict)
    if mode == "chars" then
        local v = tonumber(chars)
        if v and v > 0 then return v end
        if strict then return nil end
        return tonumber(punct) or tonumber(plain) or 0
    elseif mode == "punct" then
        local v = tonumber(punct)
        if v and v > 0 then return v end
        if strict then return nil end
        return tonumber(plain) or 0
    end
    return tonumber(plain) or 0
end

local function fileFingerprint(path)
    local attr = path and lfs.attributes(path)
    if type(attr) ~= "table" then return nil, nil end
    return tonumber(attr.modification), tonumber(attr.size)
end

-- 缓存查询（24-cache-reuse）—— 「统计完为什么要再统计一遍」的根因修复。
local function readCachedCount(path, prefer_settings)
    if type(path) ~= "string" or path == "" then return nil end
    local mtime, size = fileFingerprint(path)
    if not mtime or not size then return nil end   -- 拿不到指纹，宁可重扫

    -- ① 先查全局缓存表（最可靠：单文件、键就是 path）
    local gcache = nil
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local ok, t = pcall(G_reader_settings.readSetting, G_reader_settings, KEY_CACHE)
        if ok and type(t) == "table" then gcache = t end
    end
    if gcache then
        local e = gcache[path]
        if type(e) == "table"
                and tonumber(e.mtime) == mtime
                and tonumber(e.size) == size
                and tonumber(e.count) and tonumber(e.count) > 0 then
            -- 老缓存只有「只算文字」的 count；要别的口径却没有那个字段时
            -- 视为失效（重扫一次即可拿到），不能拿纯文字值冒充。
            local mode = countModeOf(path)
            if mode ~= "plain" and not tonumber(e[modeField(mode)]) then return nil end
            -- 第三个返回值告诉调用方这是不是估算值
            return valueFor(mode, e.count, e.count_punct, e.count_char, true),
                prefer_settings, e.estimated == true
        end
        -- 全局里有这个 path 但指纹不符 → 明确失效，不用再看 DocSettings
        if type(e) == "table" then return nil end
    end

    -- ② 回落：DocSettings sidecar（历史数据）
    local settings = prefer_settings
    if not (settings and type(settings.readSetting) == "function") then
        local ok, s = pcall(DocSettings.open, DocSettings, path)
        if ok and s and type(s.readSetting) == "function" then settings = s end
    end
    if not settings then return nil end

    local ok_m, saved_mtime = pcall(settings.readSetting, settings, KEY_MTIME)
    local ok_s, saved_size  = pcall(settings.readSetting, settings, KEY_SIZE)
    local ok_plain, saved_count = pcall(settings.readSetting, settings, KEY_COUNT)
    if not (ok_m and ok_s and ok_plain) then return nil end

    if tonumber(saved_mtime) ~= mtime then return nil end
    if tonumber(saved_size)  ~= size  then return nil end
    local count = tonumber(saved_count)
    if not count or count <= 0 then return nil end
    -- 当前口径在 sidecar 里没有对应字段 ⇒ valueFor 返回 nil ⇒ 当作没统计过
    -- （让用户重扫一次），绝不拿另一种口径的数冒充。
    local mode = countModeOf(path)
    local ok_p, saved_punct = pcall(settings.readSetting, settings, KEY_COUNT_PUNCT)
    local ok_ch, saved_char = pcall(settings.readSetting, settings, KEY_COUNT_CHAR)
    count = valueFor(mode, count,
        ok_p and tonumber(saved_punct) or nil,
        ok_ch and tonumber(saved_char) or nil, true)
    if count == nil then return nil end
    -- 旧数据没有 KEY_ESTIMATED 键 → readSetting 返回 nil → 当作精确值（向后兼容）
    local ok_e, saved_est = pcall(settings.readSetting, settings, KEY_ESTIMATED)
    return count, settings, (ok_e and saved_est == true) or false
end

-- 把统计结果写进**全局缓存**（键 = 文件路径，值 = 指纹 + 三种口径的字数）。
local function writeCachedCount(path, count, count_punct, count_char, mtime, size, estimated)
    if type(path) ~= "string" or path == "" then return false end
    count, mtime, size = tonumber(count), tonumber(mtime), tonumber(size)
    count_punct = tonumber(count_punct)
    count_char = tonumber(count_char)
    if not count or count <= 0 or not mtime or not size then return false end
    if not (G_reader_settings and type(G_reader_settings.saveSetting) == "function") then
        return false
    end
    local ok_read, t = pcall(G_reader_settings.readSetting, G_reader_settings, KEY_CACHE)
    if not ok_read or type(t) ~= "table" then t = {} end
    t[path] = {
        count = count, count_punct = count_punct, count_char = count_char,
        mtime = mtime, size = size, at = os.time(),
        -- 估算标记。false 时也显式写出来，便于排查「为什么标了约」
        estimated = (estimated == true) and true or false,
    }
    -- 防止无限膨胀：超过 CAP 条就把最旧的删掉（保留最近 CAP 条）
    local CAP = 500
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n > CAP then
        local arr = {}
        for k, v in pairs(t) do arr[#arr + 1] = { k = k, at = tonumber(v.at) or 0 } end
        table.sort(arr, function(a, b) return a.at < b.at end)
        for i = 1, n - CAP do t[arr[i].k] = nil end
    end
    local ok_save = pcall(G_reader_settings.saveSetting, G_reader_settings, KEY_CACHE, t)
    if ok_save then pcall(G_reader_settings.flush, G_reader_settings) end
    return ok_save
end

-- 删除某本书的**统计缓存**（全局缓存 KEY_CACHE 里那一条）。
local function removeCachedCount(path, prefer_settings)
    if type(path) ~= "string" or path == "" then return false end

    -- ① 全局缓存：删掉这个 path 的那一条，其余条目**原样保留**（不要整表清空！
    -- 那样会把其他已完成的书也一起清掉 —— 正是用户明确要求避免的）。
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local ok, t = pcall(G_reader_settings.readSetting, G_reader_settings, KEY_CACHE)
        if ok and type(t) == "table" and t[path] ~= nil then
            t[path] = nil
            local ok_save = pcall(G_reader_settings.saveSetting, G_reader_settings, KEY_CACHE, t)
            if ok_save then pcall(G_reader_settings.flush, G_reader_settings) end
        end
    end

    -- ② DocSettings sidecar：清掉四个键（count / mtime / size / estimated），保留其他设置。
    -- ⇒ 传进来的 settings 属于 A，而我们要清的是 C。
    local settings = prefer_settings
    if settings and type(settings.saveSetting) == "function" then
        local owner = nil
        if type(settings.file) == "string" then
            owner = settings.file
        elseif type(settings.getFilePath) == "function" then
            local ok_p, p = pcall(settings.getFilePath, settings)
            if ok_p and type(p) == "string" then owner = p end
        end
        -- owner 拿不到时**不冒险**：宁可多开一次 sidecar，也不误删别的书。
        if owner == nil or owner ~= path then
            settings = nil
        end
    else
        settings = nil
    end
    if not settings then
        local ok, s = pcall(DocSettings.open, DocSettings, path)
        if ok and s and type(s.saveSetting) == "function" then settings = s end
    end
    if settings then
        pcall(settings.delSetting, settings, KEY_COUNT)
        pcall(settings.delSetting, settings, KEY_COUNT_PUNCT)
        pcall(settings.delSetting, settings, KEY_COUNT_CHAR)
        pcall(settings.delSetting, settings, KEY_MTIME)
        pcall(settings.delSetting, settings, KEY_SIZE)
        pcall(settings.delSetting, settings, KEY_ESTIMATED)
        pcall(settings.flush, settings)
    end
    return true
end


-- `UIManager:show` 的安全版本（main.lua 侧）。
-- ⇒ `_repaint()` 的兜底补一次 **无 region 的 `"partial"`**（:1291-1294）⇒
-- ① region 填成整屏；② 每 `FULL_REFRESH_COUNT`（默认 6）次被提升成 `"full"`
-- —— 那就是整屏黑闪。
local function showNoFlash(widget)
    UIManager:show(widget, function()
        local region
        if widget then
            if widget.movable and widget.movable.dimen then
                region = widget.movable.dimen
            elseif widget.popup_frame and widget.popup_frame.dimen then
                region = widget.popup_frame.dimen
            end
        end
        return "[partial]", region
    end)
    return widget
end

-- 统一提示入口：显式构造 Notification 实例并 show。
local function notifyUser(arg, timeout)
    local text, opts
    if type(arg) == "table" then
        -- 兼容旧写法 Notification:notify{ text = ..., timeout = ... }
        text = arg.text
        timeout = arg.timeout or timeout
    else
        text = arg
    end
    pcall(function()
        showNoFlash(Notification:new{
            text = tostring(text or ""),
            timeout = timeout or 2,
        })
    end)
end

-- 千分位格式化：1234567 → "1,234,567"。
local function fmtCount(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local rev = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (rev:gsub("^,", ""))
end

-- 轻量提示：告知「用的是缓存」并给出数字，不弹对话框、不扫描。
local function notifyCached(path, count, settings, estimated)
    local read_units = 0
    local sampled_pages = nil
    if settings and type(settings.readSetting) == "function" then
        local ok, state = pcall(settings.readSetting, settings, KEY_READ_STATS)
        if ok and type(state) == "table" then
            read_units = tonumber(state.read_units) or 0
        end
        if estimated then
            local ok_p, sp = pcall(settings.readSetting, settings, KEY_SAMPLED_PAGES)
            if ok_p then sampled_pages = tonumber(sp) end
        end
    end
    if estimated then
        -- 抽页估算：一定要让用户看得出来「这个数是估的」，
        -- 否则他会以为跟精确统计一样准。
        local msg
        if sampled_pages and sampled_pages > 0 then
            msg = T(_("已使用缓存结果（估算）：全书约 %1\n依据：前 %2 页中有文本的页抽页推算。想精确请再点一次「统计本书字数」（会完整扫描）"),
                fmtCount(count), fmtCount(sampled_pages))
        else
            msg = T(_("已使用缓存结果（估算）：全书约 %1\n想精确请再点一次「统计本书字数」（会完整扫描）"),
                fmtCount(count))
        end
        notifyUser(msg, 4)
    else
        notifyUser(T(_("已使用缓存结果：全书约 %1（已读约 %2）\n想重算请再点一次「统计本书字数」"),
            fmtCount(count), fmtCount(read_units)), 3)
    end
end

local function pageCount(doc)
    if not doc or type(doc.getPageCount) ~= "function" then return 0 end
    local ok, n = pcall(doc.getPageCount, doc)
    return ok and math.max(0, math.floor(tonumber(n) or 0)) or 0
end


-- 打开一个「后台文档」并把它**准备好**，让 getPageCount() 能返回真实页数。
local HUGE_FILE_BYTES = 32 * 1024 * 1024        -- 一般格式：32MB
local HUGE_FILE_BYTES_EPUB = 20 * 1024 * 1024   -- epub（压缩）：20MB

-- 按扩展名取「超大文件」阈值。
local function hugeFileThreshold(path)
    local ext = tostring(path or ""):lower():match("%.([%w]+)$")
    if ext == "epub" then return HUGE_FILE_BYTES_EPUB end
    return HUGE_FILE_BYTES
end

-- 37j / 58：用户自定义的「降级触发文件大小」（字节）。
-- ⚠ 注意「不限制」只作用于**这一条判断**（要不要拒绝/降级）。
local function downgradeBytes(path)
    local v = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_mb"))
    -- 判据用 `v > 0`；★ 58：`v == 0` 是「显式不限制」，不是「未设置」。
    if v and v > 0 then return v * 1024 * 1024 end
    if v == 0 then return math.huge end
    -- 未设置 ⇒ 58 起同样不限制（以前回落到 hugeFileThreshold）。
    -- ⚠ 想恢复「按格式默认」的老行为：把下面这行换成
    -- `return hugeFileThreshold(path)` 即可（`path` 参数就是为此保留的）。
    return math.huge
end

-- 37o → 1.2：`prepareDocument` 里那条「探不到页数就拒绝 render」的**硬保护线**。
-- ⇒ 现在：**用户设多少就是多少**，不再封顶。
local function hardRenderGuardBytes(path)
    local v = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_mb"))
    if v and v > 0 then
        -- 用户设了值 ⇒ **完全以用户为准，不封顶**。
        return v * 1024 * 1024
    end
    return hugeFileThreshold(path)
end

-- 分块扫描的块大小：按**实测剩余内存**定，不看文件大小。
--
-- 为什么不看文件大小：epub 是压缩包，文件大小和实际文本量没有稳定关系
-- （图片多的书很小却极吃内存，纯文字书反过来），而且同样一本书在别的设备上
-- 可能刚好、换成 512MB 的机器就崩。剩余内存是唯一直接对应的量。
local function chooseBlockPages(job)
    local pages = math.max(1, tonumber(job.page_count) or 1)
    if pages <= 1 then return pages end

    local avail = Mem.availableMB()
    local base
    if avail == nil then
        -- 读不到 /proc（极少数设备）：取中间偏保守，不要指望探测。
        base = 80
    elseif avail < 45 then
        base = 16       -- 已经贴地：小块慢走，给 GC 喘气的机会
    elseif avail < 70 then
        base = 48
    elseif avail < 110 then
        base = 120
    else
        base = 200      -- 宽裕：块大一点，少几次 crengine 调用
    end

    if pages < base then return pages end
    return base
end

local function prepareDocument(doc)
    if not doc or type(doc) ~= "table" then return doc, nil end
    if type(doc.loadDocument) ~= "function" then
        -- 不是 CRE 文档（或老版本没有该 API）：无需准备。
        -- PDF 等的页数在 openDocument 时就已知（Document:_readMetadata）。
        return doc, nil
    end
    -- 页数已经有了就不用再折腾（重复 prepare 也无害，只是省点时间）
    if pageCount(doc) > 0 then return doc, nil end

    -- loadDocument 与 render 是两步，**先把文件加载进 DOM**。
    local function try_load()
        local ok = pcall(function()
            if type(doc.setupDefaultView) == "function" then
                doc:setupDefaultView()
            end
            doc:loadDocument()
        end)
        return ok
    end

    if not try_load() then
        logger.warn("WordCount: prepareDocument loadDocument failed")
        return doc, "loadDocument failed"
    end
    if pageCount(doc) > 0 then
        logger.info("WordCount: pages available after loadDocument without render, skipping render")
        return doc, nil
    end

    -- **超大书不再一律拒绝**。
    local _, fsize = fileFingerprint(doc.file)
    local limit = hardRenderGuardBytes(doc.file)
    local is_huge = fsize and fsize > limit

    if is_huge then
        logger.warn("WordCount: huge document (size=" .. tostring(fsize)
            .. " limit=" .. tostring(limit) .. "), retrying loadDocument (no render)")
        -- 重试几次：crengine 对超大 epub 的惰性分页偶发探不到页数，
        -- 多调一次 loadDocument 常常就能拿到（日志里见过 93551 页成功）。
        for attempt = 1, 3 do
            if pageCount(doc) > 0 then break end
            pcall(try_load)
            if pageCount(doc) > 0 then
                logger.info("WordCount: huge document pages available after retry #"
                    .. tostring(attempt) .. " pages=" .. tostring(pageCount(doc)))
                break
            end
        end
        if pageCount(doc) > 0 then
            -- 拿到页数 ⇒ 放行（startCount 会因 total_pages 超限强制抽样）。
            return doc, nil
        end
        -- 反复重试仍无页数 ⇒ 只能如实拒绝（绝不 render）。
        logger.warn("WordCount: huge document still has 0 pages after retries, refusing")
        return doc, "huge_document"
    end

    -- 31 §③ / ★ 1.2：走到这里 = 文件在**用户设定线以内**，正常 render。
    local ok, err = pcall(function()
        if type(doc.render) == "function" then
            doc:render()
        end
    end)
    if not ok then
        logger.warn("WordCount: prepareDocument render failed", err)
        return doc, tostring(err)
    end
    return doc, nil
end

-- 打开后台文档并准备到可取页数的状态。
local function openPreparedDocument(path)
    local ok, doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, path)
    if not ok or not doc then
        return nil, tostring(doc or "openDocument failed")
    end
    local _, prep_err = prepareDocument(doc)
    if prep_err == "huge_document" then
        if type(doc.close) == "function" then pcall(doc.close, doc) end
        return nil, "huge_document"
    end
    if prep_err then
        -- 准备失败不直接放弃：有些文档可能仍能拿到页数
        logger.warn("WordCount: openPreparedDocument prepare issue for "
            .. tostring(path) .. ": " .. tostring(prep_err))
    end
    return doc, nil
end

local function readLimits()
    local settings = G_reader_settings and G_reader_settings:readSetting("statistics") or nil
    local min_sec = settings and tonumber(settings.min_sec) or 5
    local max_sec = settings and tonumber(settings.max_sec) or 120
    if max_sec < min_sec then max_sec = min_sec end
    return min_sec, max_sec
end

local function countReadPages(state)
    local count = 0
    for _i, seconds in pairs(state and state.page_seconds or {}) do
        if (tonumber(seconds) or 0) > 0 then count = count + 1 end
    end
    return count
end

-- KOReader 把高亮 / 书签 / 笔记统一存在 sidecar 的 "annotations" 里，
-- 每条带 datetime 字段。这里只关心条数，用来算「记录笔记」。
local function countAnnotations(settings)
    if not settings or type(settings.readSetting) ~= "function" then return nil end
    local ok, annotations = pcall(settings.readSetting, settings, "annotations")
    if not ok then return nil end
    if type(annotations) ~= "table" then return 0 end
    return #annotations
end

function WordCount:init()
    -- 诊断打点：确认设备上加载的是哪一版、以及 Bookshelf 钩子装没装上。
    -- 用 logger.info（会落进 crash.log），便于出问题时直接对日志。
    logger.info("WordCount: plugin init start")
    -- 把「按来源口径」的解析函数交给书架占位符那边。
    -- ⇒ 不然书架上的 %word_count 永远是最早写进去的「只算文字」数，
    --   和阅读器里按来源算出来的数字对不上（用户一眼就发现）。
    -- 传过去的是**口径字符串**（plain/punct/chars），不是布尔值。
    BookshelfIntegration.setPunctResolver(function(path)
        return countModeOf(path)
    end)
    local ok, err = BookshelfIntegration.install()
    if not ok then logger.dbg("WordCount: Bookshelf token integration unavailable", err) end
    self.ui.menu:registerToMainMenu(self)
    self:_installFileManagerActions()
    self:_installBookshelfBulkAction()
    local tries = 0
    local function retryBookshelfHook()
        tries = tries + 1
        self:_installBookshelfBulkAction()
        local ok_widget, bw = pcall(require, "lib/bookshelf_widget")
        local hooked_single = ok_widget and bw and bw._wordcount_single_wrapped
        local hooked_menu   = ok_widget and bw and bw._wordcount_bulkmenu_wrapped
        -- 只要**两条腿里任意一条**装上了就算成功。
        local hooked = hooked_single or hooked_menu
        if tries == 1 then
            logger.info("WordCount: bookshelf_widget=" .. tostring(ok_widget)
                .. " hasFileDialogPluginRows=" .. tostring(ok_widget and bw
                    and type(bw._fileDialogPluginRows) == "function")
                .. " hookInstalled=" .. tostring(hooked_single)
                .. " bulkMenuHook=" .. tostring(hooked_menu)
                .. " bulkActionsWrapped=" .. tostring(
                    package.loaded["lib/bookshelf_bulk_actions"]
                    and package.loaded["lib/bookshelf_bulk_actions"]._wordcount_wrapped))
        end
        if tries < 20 and not hooked then
            UIManager:nextTick(retryBookshelfHook)
        elseif hooked then
            logger.info("WordCount: bookshelf hook ready after " .. tries .. " tries")
        else
            logger.warn("WordCount: bookshelf hook NOT installed after " .. tries .. " tries")
        end
    end
    UIManager:nextTick(retryBookshelfHook)
end

local function closeCurrentModal()
    -- FileManager's callback has file_dialog; Bookshelf's custom book/bulk
    -- dialogs do not. Close the current menu before showing progress, or the
    -- scan runs underneath it and looks like a no-op.
    local ok, top = pcall(UIManager.getTopmostVisibleWidget, UIManager)
    if ok and top then pcall(UIManager.close, UIManager, top) end
end

-- 判断某个 widget 当前是否还在 UIManager 的显示栈上。
local function is_widget_on_stack(widget)
    if not widget then return false end
    local ok, stack = pcall(function() return UIManager._window_stack end)
    if ok and type(stack) == "table" then
        for i = 1, #stack do
            local entry = stack[i]
            if type(entry) == "table" and entry.widget == widget then return true end
        end
        return false
    end
    -- 取不到内部栈结构时保守返回 true：宁可不动，也不要重复 show 造成叠加。
    return true
end

-- 正确的「弹一条提示」写法。**不要再直接用 `Notification:notify(...)`。**

-- 千分位格式化 fmtCount 同样已上移，这里不再重复定义。

local function runEntrySafely(fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        logger.err("WordCount: operation entry failed", err)
        -- 走 showNoFlash（否则 InfoMessage:onShow 自己排的 "ui" 在 PW4 上
        -- = AUTO ⇒ 含灰 ⇒ GC16 ⇒ 闪黑；我们的 "[partial]" 优先级更高会把它顶掉）。
        showNoFlash(InfoMessage:new{
            text = T(_("字数统计启动失败：%1"), tostring(err)),
        })
    end
end

function WordCount:_installFileManagerActions()
    local fm = self.ui
    if not fm then return end

    -- KOReader's long-press file dialog extension is also used by a number of
    -- Bookshelf frontends, so expose the action there without depending on a
    -- particular Bookshelf implementation.
    if type(fm.addFileDialogButtons) == "function" then
        fm:addFileDialogButtons("wordcount_scan", function(file, is_file)
            if not is_file or not DocumentRegistry:hasProvider(file) then return nil end
            return {
                {
                    text = _("统计本书字数"),
                    callback = function()
                        closeCurrentModal()
                        UIManager:nextTick(function()
                            -- 用户「点击统计本书的时候自动忽略缓存重新统计」。
                            runEntrySafely(function() self:startCountForPath(file, true) end)
                        end)
                    end,
                },
            }
        end)
    end

    -- Add one action to FileManager's standard multi-select operation sheet.
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and type(FileManager.getPlusDialogButtons) == "function"
            and not FileManager._wordcount_plus_wrapped then
        FileManager._wordcount_plus_wrapped = true
        local original = FileManager.getPlusDialogButtons
        FileManager.getPlusDialogButtons = function(file_manager, ...)
            local title, buttons = original(file_manager, ...)
            if file_manager.selected_files and type(buttons) == "table" then
                local selected = {}
                for path, selected_flag in pairs(file_manager.selected_files) do
                    if selected_flag and DocumentRegistry:hasProvider(path) then
                        selected[#selected + 1] = path
                    end
                end
                table.insert(buttons, 2, {
                    {
                        text = _("统计选中文件字数"),
                        enabled = #selected > 0,
                        callback = function()
                            closeCurrentModal()
                            UIManager:nextTick(function()
                                runEntrySafely(function() self:startBatchCount(selected) end)
                            end)
                        end,
                    },
                })
            end
            return title, buttons
        end
    end
end

-- 把 BulkActions 的接线从 `_installBookshelfBulkAction` 里**拆出来**，
-- 并做「两条腿走路」，因为 `require("lib/bookshelf_bulk_actions")` 在本插件里
-- **不是一定能成**：
-- 1) KOReader 的 PluginLoader 用 **dofile**（不是 require）加载各插件，
-- `lib/?.lua` 只在**所有插件 dofile 完之后**才追加进 package.path
local WORDCOUNT_BULK_MARK = "_wordcount_bulk_block"

-- 关掉批量对话框。
local function closeBulkDialog(dialog)
    if type(dialog) ~= "table" then
        local ok_top, top = pcall(UIManager.getTopmostVisibleWidget, UIManager)
        dialog = ok_top and top or nil
    end
    if type(dialog) ~= "table" then return end
    if type(dialog._dismiss) == "function" then
        pcall(dialog._dismiss, dialog)
    else
        pcall(UIManager.close, UIManager, dialog)
    end
end

-- 批量统计的共用动作：取选中路径 → 关框 → 退出多选 → 起后台任务。
local function startBulkCount(plugin, opts, dialog)
    local selection = opts and opts.selection
    if type(selection) ~= "table" or type(selection.paths) ~= "function" then return end
    local ok_paths, paths = pcall(selection.paths, selection)
    if not ok_paths or type(paths) ~= "table" or #paths == 0 then
        notifyUser(_("没有选中任何书"), 3)
        return
    end
    closeBulkDialog(dialog)
    local bw = opts and opts.bw
    if type(bw) == "table" then
        -- 退出多选态并重建书架（否则选中的高亮会留在屏幕上）。
        if type(bw._selection) == "table"
                and type(bw._selection.exitMode) == "function" then
            pcall(bw._selection.exitMode, bw._selection)
        end
        if type(bw._rebuild) == "function" then pcall(bw._rebuild, bw) end
        pcall(UIManager.setDirty, UIManager, bw, "ui")
    end
    UIManager:nextTick(function()
        runEntrySafely(function()
            plugin:startBatchCount(paths)
        end)
    end)
end

-- 往 6.x 的 page 模型里追加「字数统计」一栏（heading + chips）。
-- @param get_dialog 回调：返回当前对话框（show 返回后才拿得到，所以用闭包）
local function appendBulkCountBlock(plugin, model, opts, get_dialog)
    if type(model) ~= "table" then return model end
    local blocks = model.blocks
    if type(blocks) ~= "table" then
        blocks = {}
        model.blocks = blocks
    end
    -- 幂等：同一个模型被反复 render 时不要叠出两栏。
    for _i, b in ipairs(blocks) do
        if type(b) == "table" and b[WORDCOUNT_BULK_MARK] then return model end
    end
    blocks[#blocks + 1] = {
        type = "heading",
        text = _("字数统计"),
        [WORDCOUNT_BULK_MARK] = true,
    }
    blocks[#blocks + 1] = {
        type = "chips",
        items = {
            {
                text = _("统计选中字数"),
                callback = function()
                    startBulkCount(plugin, opts, get_dialog and get_dialog() or nil)
                end,
            },
        },
    }
    return model
end

local function wrapBulkActionsShow(BulkActions, plugin)
    if type(BulkActions) ~= "table" or type(BulkActions.show) ~= "function"
            or BulkActions._wordcount_wrapped then
        return false
    end
    -- Buttons/ButtonDialog 可能在 init() 时机还没就绪；用到时再取，避免
    -- 在模块顶层 require 一遍把自己也搭进去（和 bugN-1 同一个坑）。
    local original_show = BulkActions.show
    BulkActions._wordcount_wrapped = true
    BulkActions.show = function(opts)
        -- ── 腿 0（Bookshelf 6.x）：page 模型对话框 ───────────────────────────
        if type(opts) == "table" and type(opts.page) == "function" then
            local user_page = opts.page
            local dialog_ref
            local patched = {}
            for k, v in pairs(opts) do patched[k] = v end
            patched.page = function(...)
                local model = user_page(...)
                return appendBulkCountBlock(plugin, model, opts,
                    function() return dialog_ref end)
            end
            local ok_call, err = pcall(original_show, patched)
            -- 6.x 的 `BulkActions.show` **不返回**对话框对象
            -- （`local dialog = PageDialog.show{...}` 吞掉了返回值），
            -- 但 `PageDialog.show` 内部是**同步** `UIManager:show` ⇒
            -- 这里返回时栈顶就是它，抓下来给回调关窗用。
            local ok_top, top = pcall(UIManager.getTopmostVisibleWidget, UIManager)
            if ok_top and type(top) == "table"
                    and (top.page == patched.page or type(top._dismiss) == "function") then
                dialog_ref = top
            end
            if not ok_call then error(err) end
            return
        end

        -- 没有 page 模型（Bookshelf 5.x 及更早）→ 原样弹出，不做注入。
        -- 6.x 起批量菜单统一走 page 模型，这条分支已经用不到。
        local ok_call, err = pcall(original_show, opts)
        if not ok_call then error(err) end
    end
    return true
end

-- 兜底注入：挂 BookshelfWidget._openBulkMenu。
local function installBulkMenuButtonPatch(BookshelfWidget, plugin)
    if type(BookshelfWidget) ~= "table"
            or type(BookshelfWidget._openBulkMenu) ~= "function"
            or BookshelfWidget._wordcount_bulkmenu_wrapped then
        return false
    end
    BookshelfWidget._wordcount_bulkmenu_wrapped = true
    local original_open = BookshelfWidget._openBulkMenu
    BookshelfWidget._openBulkMenu = function(widget, ...)
        local ret = original_open(widget, ...)
        -- 原实现是同步 UIManager:show(dialog)，所以这里栈顶就是那个对话框。
        UIManager:nextTick(function()
            local ok_top, top = pcall(UIManager.getTopmostVisibleWidget, UIManager)
            if not ok_top or type(top) ~= "table" then return end
            local selection = widget and widget._selection
            if type(top.page) == "function" and type(top.refresh) == "function"
                    and type(selection) == "table" then
                local original_page = top.page
                top.page = function(...)
                    local model = original_page(...)
                    appendBulkCountBlock(plugin, model,
                        { selection = selection, bw = widget },
                        function() return top end)
                    return model
                end
                pcall(top.refresh, top)
            end
        end)
        return ret
    end
    return true
end

function WordCount:_installBookshelfBulkAction()
    -- Bookshelf has its own book-operation renderer. Replace the generic
    -- hook row with a direct row here, so the action works even when the
    -- Bookshelf screen has no live FileManager dialog instance.
    local ok_widget, BookshelfWidget = pcall(require, "lib/bookshelf_widget")
    if ok_widget and BookshelfWidget and type(BookshelfWidget._fileDialogPluginRows) == "function"
            and not BookshelfWidget._wordcount_single_wrapped then
        BookshelfWidget._wordcount_single_wrapped = true
        local original_rows = BookshelfWidget._fileDialogPluginRows
        local plugin = self
        BookshelfWidget._fileDialogPluginRows = function(widget, file)
            local rows = original_rows(widget, file) or {}
            -- Remove the old generic row; it is replaced by a callback that
            -- explicitly closes the Bookshelf menu before starting the job.
            for i = #rows, 1, -1 do
                local first = rows[i] and rows[i][1]
                if first and first.text == _("统计本书字数") then table.remove(rows, i) end
            end
            rows[#rows + 1] = {
                {
                    text = _("统计本书字数"),
                    callback = function()
                        closeCurrentModal()
                        UIManager:nextTick(function()
                            -- 显式点「统计本书字数」⇒ 忽略缓存重新统计。
                            runEntrySafely(function() plugin:startCountForPath(file, true) end)
                        end)
                    end,
                },
            }
            return rows
        end
    end

    -- 第二条腿先挂上 —— 它只依赖 BookshelfWidget（上面那条
    -- require 已经成功过），完全不碰 lib/bookshelf_bulk_actions，最稳。
    if ok_widget and BookshelfWidget then
        local ok_menu = installBulkMenuButtonPatch(BookshelfWidget, self)
        if ok_menu then
            logger.info("WordCount: bookshelf bulk-menu button patch installed")
        end
    end

    -- 第一条腿 —— 包裹 BulkActions.show。
    local BulkActions = package.loaded["lib/bookshelf_bulk_actions"]
    if type(BulkActions) ~= "table" then
        local ok, mod = pcall(require, "lib/bookshelf_bulk_actions")
        if ok then
            BulkActions = mod
        else
            logger.warn("WordCount: 批量对话框钩子未装上，"
                .. "require lib/bookshelf_bulk_actions 失败：" .. tostring(mod))
            return
        end
    end
    if wrapBulkActionsShow(BulkActions, self) then
        logger.info("WordCount: bookshelf BulkActions.show wrapped")
    end
    return
end

function WordCount:addToMainMenu(menu_items)
    -- 当前版本号（菜单首行显示，方便确认装的是哪一版）。
    local version_text = readMetaVersion()

    -- sorting_hint 必须按上下文选：本插件阅读器/文件管理器两侧都会加载，
    -- 而 "filemanager_settings" 分组只存在于文件管理器菜单里，
    -- 写死会让阅读器侧构建菜单时崩（menusorter 取到 nil）。
    local is_reader_context = (self.ui ~= nil and self.ui.document ~= nil)
    local word_count_sorting_hint =
        is_reader_context and "tools" or "filemanager_settings"

    menu_items.word_count = {
        text = _("字数与阅读速度"),
        -- 把入口挪进**文件管理器顶部菜单的「设置」标签**
        -- （`filemanager_settings`）——用户要求放到「书籍状态 / 排序依据」
        sorting_hint = word_count_sorting_hint,
        sub_item_table = {
            {
                -- 点一下显示当前版本（方便核对装的是哪一包）。
                text_func = function()
                    return T(_("版本：v%1"), tostring(version_text))
                end,
                callback = function()
                    notifyUser(T(_("字数与阅读速度\n当前版本：v%1"), tostring(version_text)), 5)
                end,
                keep_menu_open = true,
            },
            {
                text = _("检查更新"),
                callback = function() Updater.check() end,
                keep_menu_open = true,
            },
            {
                text = _("启用 Bookshelf 占位符"),
                callback = function() self:enableBookshelfIntegration() end,
            },
            {
                text = _("打开阅读统计页面"),
                callback = function() self:showStatisticsDashboard() end,
            },
            {
                -- 显式点「统计全书字数」= 用户明确要求**现在重新统计一次**。
                -- ⇒ 与 37h 的「统计本书字数」入口保持一致：传 true，跳过缓存重扫。
                text = _("统计全书字数"),
                callback = function() self:startCountFromMenu(true) end,
            },
            -- 用户「字数与统计中的重新统计可以删掉了」——
            -- 删除「忽略缓存重扫」那一项菜单。需要重算时直接在书/文件上
            -- 点「统计本书字数」（见 37h：该入口现在自带 force_rescan）。
            {
                text = _("查看字数与阅读速度"),
                callback = function() self:showSavedStats() end,
            },
            {
                -- 单位显示 —— 改成二级菜单选择（原来是点一下循环切换）。
                text_func = function() return self:unitFormatLabel() end,
                sub_item_table_func = function() return self:unitFormatSubMenu() end,
            },
            {
                -- 统计模式 —— 同样改成二级菜单选择。
                text_func = function() return self:scanModeLabel() end,
                sub_item_table_func = function() return self:scanModeSubMenu() end,
            },
            {
                -- 字数口径：只算文字 / 含标点（对齐晋江、起点等平台）
                text_func = function() return self:countScopeLabel() end,
                sub_item_table_func = function() return self:countScopeSubMenu() end,
            },
            {
                -- 按来源设定口径：晋江按含标点、起点按只算文字，各站各算
                text_func = function() return self:sourcePolicyLabel() end,
                sub_item_table_func = function() return self:sourcePolicySubMenu() end,
            },
            {
                -- 大书处理方式 —— 原来是「点一下开关」的 toggle，
                -- 用户要求「降级的选项能不能自己选」⇒ 改成二级菜单单选：
                -- · 超限直接取消（默认，最安全，绝不 OOM）
                text_func = function() return self:downgradeEnabledLabel() end,
                sub_item_table_func = function() return self:downgradeModeSubMenu() end,
            },
            -- 37j/37l：两个阈值（页数 / 大小）挪进「降级阈值」二级菜单里，
            -- 一级菜单只留一行，少占屏幕。
            {
                text_func = function() return self:downgradeThresholdLabel() end,
                sub_item_table_func = function() return self:downgradeThresholdSubMenu() end,
            },
            -- 多选「本数阈值」单独一行，
            -- 因为它管的是「多选时按本数降级」，与上面按单本规模的降级不同。
            {
                text_func = function() return self:batchThresholdLabel() end,
                callback = function() self:editBatchThreshold() end,
            },
            {
                text = _("取消全书字数统计"),
                callback = function() self:cancelCount() end,
            },
        },
    }
end

-- 大书降级 / 拒绝 —— 用户可调的三个设置

-- 「允许大书自动降级」的开关标签。
function WordCount:downgradeEnabledLabel()
    local base = downgradeEnabled() and _("大书处理：超限转抽样估算")
        or _("大书处理：超限直接取消（防重启）")
    -- 默认状态下**两条上限都不存在**，这时「超限怎么处理」其实不会发生。
    -- 如实标出来，否则用户会以为插件还在偷偷拦他。
    if not pageLimitActive() and downgradeBytes("") == math.huge then
        return T(_("%1（当前无上限）"), base)
    end
    return base
end

-- 大书处理方式的 radio 子菜单（替代原来的 toggle）。
function WordCount:downgradeModeSubMenu()
    local pages = downgradePages()
    local limit_desc = (pages > 0)
        and T(_("%1 页"), fmtCount(pages))
        or _("页数不限")
    return {
        {
            text = _("超限直接取消统计"),
            desc = _("最安全。超过你设的上限的书不统计，绝不会耗尽内存重启设备。"),
            checked_func = function() return downgradeEnabled() ~= true end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting("word_count_downgrade_enabled", false)
                G_reader_settings:flush()
            end,
        },
        {
            text = _("超限改用抽样估算"),
            desc = T(_("超过上限（%1 / %2）的书只扫前 %3 页再按比例外推，"
                .. "快且省电，但数字为「约」。"),
                limit_desc, self:downgradeMbLimitText(), SAMPLE_PAGES),
            checked_func = function() return downgradeEnabled() == true end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting("word_count_downgrade_enabled", true)
                G_reader_settings:flush()
            end,
        },
    }
end

-- 降级阈值的二级菜单（页数 / 大小两项，点进去弹输入框）。
-- 一级菜单不再平铺两行，省屏幕；父项 text_func 同时回显两个当前值。
function WordCount:downgradeThresholdSubMenu()
    return {
        {
            text_func = function() return self:downgradePagesLabel() end,
            callback = function() self:editDowngradePages() end,
        },
        {
            text_func = function() return self:downgradeMbLabel() end,
            callback = function() self:editDowngradeMb() end,
        },
    }
end

-- 降级阈值菜单的父项标签（两个值一起回显）。
function WordCount:downgradeThresholdLabel()
    local pages = downgradePages()
    local page_text = (pages > 0) and T(_("%1 页"), fmtCount(pages)) or _("不限")
    return T(_("页数 / 大小上限：%1 / %2"), page_text, self:downgradeMbLimitText())
end

-- `toggleDowngradeEnabled` 已删除 —— 大书处理方式改由
-- `downgradeModeSubMenu` 的 radio 子菜单直接写入 `word_count_downgrade_enabled`。

-- 当前生效的「降级触发大小」文字（含按格式默认时的实际值）。
function WordCount:downgradeMbLimitText()
    local mb = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_mb"))
    local epub_mb = math.floor(HUGE_FILE_BYTES_EPUB / 1024 / 1024)
    if mb and mb > 0 then
        if mb > epub_mb then
            -- 超过 epub 默认红线：如实提示「这是放宽后的值，极端情况可能变慢/重启」
            return T(_("%1 MB（自定义，已放宽；超过 epub 默认 %2 MB，"
                .. "极端大书可能需要更多时间或内存）"),
                tostring(mb), tostring(epub_mb))
        end
        return T(_("%1 MB（自定义）"), tostring(mb))
    end
    -- 未设 == 不限制。这里必须和 `downgradeBytes()` 的返回值对上，
    -- 否则会出现「菜单说不限制、实际按 20MB 拦」的老矛盾（1.2 踩过）。
    return _("不限")
end

-- 档位常量已删除 —— 两个阈值入口都只留 取消 / 默认 / 确定。
local DOWNGRADE_PAGES_MIN, DOWNGRADE_PAGES_MAX = 0, 10000000

function WordCount:downgradePagesLabel()
    local pages = downgradePages()
    if pages <= 0 then
        return _("页数上限：不限制（点此输入）")
    end
    return T(_("页数上限：%1 页"), fmtCount(pages))
end

-- 应用一个页数上限（带校验）。0 = 不限制。
-- @return boolean ok, string msg
local function applyDowngradePages(v)
    v = tonumber(v)
    if not v or v ~= math.floor(v) then
        return false, _("请输入整数页数")
    end
    if v < DOWNGRADE_PAGES_MIN or v > DOWNGRADE_PAGES_MAX then
        return false, T(_("页数需在 %1 ~ %2 之间（0 = 不限制）"),
            fmtCount(DOWNGRADE_PAGES_MIN), fmtCount(DOWNGRADE_PAGES_MAX))
    end
    G_reader_settings:saveSetting("word_count_downgrade_pages", v)
    G_reader_settings:flush()
    if v == 0 then
        return true, _("页数上限：不限制")
    end
    return true, T(_("页数上限：%1 页"), fmtCount(v))
end

-- 37n / 58：手动输入「页数上限」。
function WordCount:editDowngradePages()
    local InputDialog = require("ui/widget/inputdialog")
    local cur = downgradePages()

    local dialog
    dialog = InputDialog:new{
        title = _("页数上限"),
        -- 说明里把「0 = 不限制」写在第一行 —— 用户问的就是
        -- 「为什么给我放限制」，所以这个入口必须一眼看到怎么取消限制。
        description = T(_("超过这个页数的书，按「大书处理」那条设置处理；"
            .. "填 0 = 不限制（默认，插件不会替你设上限）。\n"
            .. "这里的页数是统计时那份排版排出来的：在阅读界面统计＝和状态栏一致，"
            .. "在书架统计＝按默认排版算，可能和翻书时看到的页数不同。\n"
            .. "当前：%1"),
            (cur > 0) and T(_("%1 页"), fmtCount(cur)) or _("不限制")),
        input = tostring(cur),
        input_type = "number",
        input_hint = T(_("%1 - %2（0 = 不限制）"),
            fmtCount(DOWNGRADE_PAGES_MIN), fmtCount(DOWNGRADE_PAGES_MAX)),
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("不限"),
                    callback = function()
                        local ok, msg = applyDowngradePages(0)
                        UIManager:close(dialog)
                        if ok then notifyUser(msg, 2) end
                    end,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local ok, msg = applyDowngradePages(dialog:getInputValue())
                        if not ok then
                            notifyUser(msg, 3)
                            return
                        end
                        UIManager:close(dialog)
                        notifyUser(msg, 2)
                    end,
                },
            },
        },
    }
    -- 走 showNoFlash，别退回裸的 `UIManager:show(dialog)`（见它的注释）。
    showNoFlash(dialog)
    dialog:onShowKeyboard()
end

-- 大小上限的合法区间（MB）。**0 = 不限制**（58 起，默认值）。
local DOWNGRADE_MB_MIN, DOWNGRADE_MB_MAX = 0, 100000

function WordCount:downgradeMbLabel()
    return T(_("大小上限：%1"), self:downgradeMbLimitText())
end

-- 应用一个「大小上限」（MB，带校验）。0 = 不限制。
-- @return boolean ok, string msg
local function applyDowngradeMb(v)
    if v == nil then v = 0 end
    v = tonumber(v)
    if not v or v ~= math.floor(v) then
        return false, _("请输入整数 MB")
    end
    if v < DOWNGRADE_MB_MIN or v > DOWNGRADE_MB_MAX then
        return false, T(_("大小需在 %1 ~ %2 MB 之间（0 = 不限制）"),
            DOWNGRADE_MB_MIN, DOWNGRADE_MB_MAX)
    end
    if v == 0 then
        -- 0 = 不限制 ⇒ 直接清掉设置（`downgradeBytes` 未设即返回 math.huge）。
        G_reader_settings:delSetting("word_count_downgrade_mb")
        G_reader_settings:flush()
        return true, _("大小上限：不限制")
    end
    G_reader_settings:saveSetting("word_count_downgrade_mb", v)
    G_reader_settings:flush()
    return true, T(_("大小上限：%1 MB"), tostring(v))
end

-- 37n / 58：手动输入「大小上限」（MB）。
-- ⇒ 去掉那一排档位快捷按钮（8/12/20/.../500），只留三个按钮：
-- 取消 = 不保存；不限 = 不限制（58 起的默认）；确定 = 保存输入值。
function WordCount:editDowngradeMb()
    local InputDialog = require("ui/widget/inputdialog")
    local cur = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_mb"))

    local dialog
    dialog = InputDialog:new{
        title = _("大小上限"),
        description = T(_("超过这个大小的书，按「大书处理」那条设置处理；"
            .. "填 0 = 不限制（默认）。\n当前：%1"),
            (cur and cur > 0) and (tostring(cur) .. " MB") or _("不限制")),
        input = (cur and cur > 0) and tostring(cur) or "0",
        input_type = "number",
        input_hint = T(_("%1 - %2 MB，0 = 不限制"), DOWNGRADE_MB_MIN, DOWNGRADE_MB_MAX),
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("不限"),
                    callback = function()
                        local ok, msg = applyDowngradeMb(0)
                        UIManager:close(dialog)
                        if ok then notifyUser(msg, 2) end
                    end,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local ok, msg = applyDowngradeMb(dialog:getInputValue())
                        if not ok then
                            notifyUser(msg, 3)
                            return
                        end
                        UIManager:close(dialog)
                        notifyUser(msg, 2)
                    end,
                },
            },
        },
    }
    -- 走 showNoFlash，别退回裸的 `UIManager:show(dialog)`（见它的注释）。
    showNoFlash(dialog)
    dialog:onShowKeyboard()
end

-- 多选「本数阈值」用户可调

-- 多选本数阈值的合法区间（本）。0 是特殊值 = 关闭。
local BATCH_THRESHOLD_MIN, BATCH_THRESHOLD_MAX = 0, 10000

-- 菜单标签（一行回显当前值 + 语义）。
function WordCount:batchThresholdLabel()
    local v = batchSampleThreshold()
    if v == 0 then
        return _("多选本数阈值：已关闭（多选也精确）")
    end
    return T(_("多选本数阈值：%1 本起改用估算"), v)
end

-- 应用一个本数阈值（带校验）。0 = 关闭。
-- @return boolean ok, string msg
local function applyBatchThreshold(v)
    v = tonumber(v)
    if not v or v ~= math.floor(v) then
        return false, _("请输入整数本数")
    end
    if v < BATCH_THRESHOLD_MIN or v > BATCH_THRESHOLD_MAX then
        return false, T(_("本数需在 %1 ~ %2 之间（填 0 关闭）"),
            BATCH_THRESHOLD_MIN, BATCH_THRESHOLD_MAX)
    end
    if v == 0 then
        G_reader_settings:saveSetting("word_count_batch_sample_threshold", 0)
        G_reader_settings:flush()
        return true, _("多选本数阈值：已关闭（多选也精确统计）")
    end
    G_reader_settings:saveSetting("word_count_batch_sample_threshold", v)
    G_reader_settings:flush()
    return true, T(_("多选本数阈值：%1 本起改用估算"), v)
end

-- 手动输入「多选本数阈值」。
function WordCount:editBatchThreshold()
    local InputDialog = require("ui/widget/inputdialog")
    local cur = batchSampleThreshold()

    local dialog
    dialog = InputDialog:new{
        title = _("多选本数阈值"),
        description = T(_("一次多选统计，本数达到此值时整批改用「抽样估算」省电。\n"
            .. "填 0 = 关闭此规则，多选也精确统计（较慢、较费电）。\n"
            .. "当前：%1（默认 %2）"),
            self:batchThresholdLabel(), DEFAULT_BATCH_SAMPLE_THRESHOLD),
        input = tostring(cur),
        input_type = "number",
        input_hint = T(_("%1 - %2，0=关闭"), BATCH_THRESHOLD_MIN, BATCH_THRESHOLD_MAX),
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("默认"),
                    callback = function()
                        local ok, msg = applyBatchThreshold(DEFAULT_BATCH_SAMPLE_THRESHOLD)
                        UIManager:close(dialog)
                        if ok then notifyUser(msg, 2) end
                    end,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local ok, msg = applyBatchThreshold(dialog:getInputValue())
                        if not ok then
                            notifyUser(msg, 3)
                            return
                        end
                        UIManager:close(dialog)
                        notifyUser(msg, 2)
                    end,
                },
            },
        },
    }
    -- 走 showNoFlash，别退回裸的 `UIManager:show(dialog)`（见它的注释）。
    showNoFlash(dialog)
    dialog:onShowKeyboard()
end

function WordCount:enableBookshelfIntegration()
    local ok, err = BookshelfIntegration.install()
    if ok then
        BookshelfIntegration.clearCache()
        notifyUser(_("Bookshelf 占位符已启用；可在模板中选择字数和速度 token"))
    else
        notifyUser(T(_("无法启用 Bookshelf 占位符：%1"), tostring(err)))
    end
end

-- 单位显示 / 统计模式改成**二级菜单选择**。
-- ⚠ 每加/改一项，三处口径都要跟着改：
-- 本文件 UNIT_FORMAT_OPTIONS / unitFormatMode / setUnitFormat
-- formatUnits
-- unitFormatMode / formatCount / formatCountParts
local UNIT_FORMAT_OPTIONS = {
    { key = "auto", label = _("自动（万/亿）"),
      desc = _("按数量级自动选：不足 1 万显示完整数字，1 万以上用「万」，1 亿以上用「亿」。") },
    { key = "full", label = _("完整数字"),
      desc = _("始终显示完整数字并加千分位，例如 358,000。") },
    { key = "k",    label = _("k"),
      desc = _("每 1000 记为 1k，例如 358k；不足 1000 时仍显示完整数字。") },
    { key = "qian", label = _("千"),
      desc = _("每 1000 记为 1千，例如 358千；不足 1000 时仍显示完整数字。") },
    { key = "wan",  label = _("万"),
      desc = _("始终用「万」，例如 35.8万；不足 1 万时仍显示完整数字。") },
}

-- 当前单位显示模式（带兜底，非法值一律当 auto）。
function WordCount:unitFormatMode()
    local mode = G_reader_settings and G_reader_settings:readSetting("word_count_unit_format")
    if mode == "full" or mode == "wan" or mode == "auto"
            or mode == "k" or mode == "qian" then
        return mode
    end
    return "auto"
end

-- 写入单位显示模式。原来还有个 `cycleUnitFormat` 已随二级菜单一起删除。
function WordCount:setUnitFormat(mode)
    if mode ~= "auto" and mode ~= "full" and mode ~= "wan"
            and mode ~= "k" and mode ~= "qian" then
        return
    end
    G_reader_settings:saveSetting("word_count_unit_format", mode)
    G_reader_settings:flush()
    -- Bookshelf 占位符那边有一层 5 秒 memo（bookshelf_integration.lua），
    -- 换了显示单位必须让它立刻失效，否则占位符还是旧格式。
    BookshelfIntegration.clearCache()
end

function WordCount:unitFormatLabel()
    local mode = self:unitFormatMode()
    local labels = {
        auto = _("自动（万/亿）"), full = _("完整数字"),
        k = _("k"), qian = _("千"), wan = _("万"),
    }
    return T(_("单位显示：%1"), labels[mode] or labels.auto)
end

-- 构造「单位显示」的 radio 子菜单。
function WordCount:unitFormatSubMenu()
    local items = {}
    for _i, opt in ipairs(UNIT_FORMAT_OPTIONS) do
        local key, label, desc = opt.key, opt.label, opt.desc
        items[#items + 1] = {
            text = label,
            -- desc 会在选项下方以灰色小字显示 —— 用户选之前就能看到
            -- 「这个模式长什么样」，不用来回试。
            desc = desc,
            -- 每个子项各自捕获自己的 key（不要用循环变量闭包，否则都指向最后一个）
            checked_func = function() return self:unitFormatMode() == key end,
            radio = true,
            callback = function() self:setUnitFormat(key) end,
        }
    end
    return items
end

-- 写入统计模式（原 `cycleScanMode` 已随二级菜单删除）。
-- ⚠ 注意这里与「单位显示」不同：**不弹通知**。
function WordCount:setScanMode(mode)
    if mode ~= MODE_FULL and mode ~= MODE_SAMPLE then return end
    G_reader_settings:saveSetting("word_count_scan_mode", mode)
    G_reader_settings:flush()
end

function WordCount:scanModeLabel()
    return T(_("统计模式：%1"), scanModeName(countMode()))
end

-- 构造「统计模式」的 radio 子菜单。
function WordCount:scanModeSubMenu()
    return {
        {
            text = scanModeName(MODE_FULL),
            -- desc 会在选项下方以灰色小字显示 —— 把「代价/收益」写在
            -- 这里，用户选之前就看得见，比选完再弹通知更有用。
            desc = _("逐页精确统计全本。大书慢、耗电，但数字准确。"),
            checked_func = function() return countMode() == MODE_FULL end,
            radio = true,
            callback = function() self:setScanMode(MODE_FULL) end,
        },
        {
            text = T(_("抽页估算（前 %1 页，省电）"), SAMPLE_PAGES),
            desc = _("只扫前若干页再按比例外推，快且省电，数字为「约」。"),
            checked_func = function() return countMode() == MODE_SAMPLE end,
            radio = true,
            callback = function() self:setScanMode(MODE_SAMPLE) end,
        },
    }
end

-- 字数口径的显示名。
-- ⚠ 这里说的是**全局兜底**口径：开了「按来源设定口径」之后，
-- 它只对「来源规则没覆盖到」的书起作用，所以标签要如实标出来。
function WordCount:countScopeLabel()
    local base = T(_("字数口径：%1"), modeLabel(globalMode()))
    if SourcePolicy.enabled() then
        return base .. _("（兜底）")
    end
    return base
end

-- 构造「字数口径」的 radio 子菜单。
-- 三种口径在一次扫描里同时算好并存下来，所以**切换不需要重扫**。
function WordCount:countScopeSubMenu()
    return {
        {
            text = _("只算文字"),
            desc = _("汉字/假名/谚文各算 1 字，英文按词算，标点不计。"
                .. "这是「阅读单位」，不是平台后台那个数。"),
            checked_func = function() return globalMode() == "plain" end,
            radio = true,
            callback = function() setGlobalMode("plain") end,
        },
        {
            text = _("含标点"),
            desc = _("在只算文字的基础上，每个全角标点再加 1 字。"
                .. "半角标点仍然不计，英文仍按词算。"),
            checked_func = function() return globalMode() == "punct" end,
            radio = true,
            callback = function() setGlobalMode("punct") end,
        },
        {
            text = _("严格字符数（对齐平台）"),
            desc = _("每个非空白字符各算 1：英文字母逐个算、数字逐个算、"
                .. "半角标点也算。这一档才是和平台后台对齐的，"
                .. "相当于 Word 的「字符数（不计空格）」。"),
            checked_func = function() return globalMode() == "chars" end,
            radio = true,
            callback = function() setGlobalMode("chars") end,
        },
        {
            text = _("说明"),
            desc = _("开了「按来源设定口径」后，来源能匹配上的书按来源规则算，"
                .. "匹配不上的按「未标注来源」那条算；这一项只作兜底。"),
            callback = function()
                notifyUser(_("这一项是全局兜底口径。\n"
                    .. "想让晋江、起点各用各的口径，去开「按来源设定口径」。\n\n"
                    .. "三档的区别（以「2019年3月5日」为例）：\n"
                    .. "· 只算文字 = 6（数字按词）\n"
                    .. "· 含标点 = 6（没有全角标点）\n"
                    .. "· 严格字符数 = 9（逐字符，和平台一致）"), 9)
            end,
            keep_menu_open = true,
        },
    }
end

-- ================= 「按来源设定口径」 =================
--
-- 每个网文站对「字数含不含标点」的算法不一样（晋江含、起点不含），
-- 所以口径不能是一个全局开关，得按**书的来源**分别设。
-- 来源读的是书档里的 custom_props.platform —— 元数据插件写进去的那个值，
-- 也就是书架 %platform 显示的东西。本插件只读不写，两个插件互不依赖。

-- 当前这本书的路径（菜单里回显用；文件管理器里没打开书 → nil）
function WordCount:currentBookPath()
    local doc = self.ui and self.ui.document
    if doc and doc.file then return doc.file end
    return self._read_doc_path or self._scan_path
end

function WordCount:sourcePolicyLabel()
    if SourcePolicy.enabled() then
        return _("按来源设定口径：开")
    end
    return _("按来源设定口径：关")
end

-- 「当前这本书用的哪个口径」——让用户能就地验证规则有没有生效
function WordCount:sourceInfoLabel()
    if not SourcePolicy.enabled() then
        return _("当前这本书：按全局「字数口径」统计（来源规则未启用）")
    end
    local path = self:currentBookPath()
    if not path then
        return _("当前这本书：未打开书籍")
    end
    local info = SourcePolicy.describe(path)
    local scope_label = modeLabel(info.mode or "plain")
    if info.name then
        return T(_("当前这本书：%1 · %2"), info.name, scope_label)
    end
    -- ⚠ 书档里没有 platform 是**最常见的状态**：元数据插件那边
    -- 「写入来源平台」默认是关的。不提示的话，用户会以为开关坏了。
    return T(_("当前这本书：未标注来源 · %1（书档里没有来源平台）"), scope_label)
end

-- 一个来源的四种状态：跟随未标注 / 只算文字 / 含标点 / 严格字符数
function WordCount:sourceRuleSubMenu(key)
    local function apply(value, msg)
        return function()
            SourcePolicy.setRule(key, value)
            -- 书架的 %word_count 有 5 秒 memo，改了口径要立刻失效
            BookshelfIntegration.clearCache()
            notifyUser(msg, 2)
        end
    end
    return {
        {
            text = _("跟随「未标注来源」"),
            desc = T(_("不单独设，跟着这一条走：%1"),
                modeLabel(SourcePolicy.unlabeledMode())),
            checked_func = function() return SourcePolicy.ruleMode(key) == nil end,
            radio = true,
            callback = apply(nil, _("已改为跟随「未标注来源」")),
            keep_menu_open = true,
        },
        {
            text = _("只算文字"),
            desc = _("汉字/假名/谚文各算 1 字，英文按词算，标点不计。"),
            checked_func = function() return SourcePolicy.ruleMode(key) == "plain" end,
            radio = true,
            callback = apply("plain", _("已设为只算文字")),
            keep_menu_open = true,
        },
        {
            text = _("含标点"),
            desc = _("在全角标点上也各算 1 字。"),
            checked_func = function() return SourcePolicy.ruleMode(key) == "punct" end,
            radio = true,
            callback = apply("punct", _("已设为含标点")),
            keep_menu_open = true,
        },
        {
            text = _("严格字符数（对齐平台）"),
            desc = _("每个非空白字符各算 1，和平台后台那个数一致。"),
            checked_func = function() return SourcePolicy.ruleMode(key) == "chars" end,
            radio = true,
            callback = apply("chars", _("已设为严格字符数")),
            keep_menu_open = true,
        },
    }
end

-- 「未标注来源」的口径（单独设置，与全局「字数口径」互不影响）
function WordCount:sourceUnlabeledSubMenu()
    local function apply(value, msg)
        return function()
            SourcePolicy.setUnlabeledMode(value)
            BookshelfIntegration.clearCache()
            notifyUser(msg, 2)
        end
    end
    return {
        {
            text = _("只算文字"),
            desc = _("没有来源标注的书（自己转的、来源不明的）按这个算。"),
            checked_func = function() return SourcePolicy.unlabeledMode() == "plain" end,
            radio = true,
            callback = apply("plain", _("未标注来源：只算文字")),
            keep_menu_open = true,
        },
        {
            text = _("含标点"),
            desc = _("在全角标点上也各算 1 字。"),
            checked_func = function() return SourcePolicy.unlabeledMode() == "punct" end,
            radio = true,
            callback = apply("punct", _("未标注来源：含标点")),
            keep_menu_open = true,
        },
        {
            text = _("严格字符数（对齐平台）"),
            desc = _("每个非空白字符各算 1。自己转的书想和平台对账，选这个。"),
            checked_func = function() return SourcePolicy.unlabeledMode() == "chars" end,
            radio = true,
            callback = apply("chars", _("未标注来源：严格字符数")),
            keep_menu_open = true,
        },
    }
end

function WordCount:addCustomSource()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("添加自定义来源"),
        description = _("填来源平台名（和书档里「来源平台」显示的一致即可，"
            .. "大小写和首尾空格不敏感）。\n加完回上一级菜单点它，就能设口径。"),
        input = "",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("添加"),
                    is_enter_default = true,
                    callback = function()
                        local name = dialog:getInputValue()
                        local ok, key = SourcePolicy.addCustomSource(name)
                        UIManager:close(dialog)
                        if ok then
                            notifyUser(T(_("已添加来源：%1"), key:sub(2)), 2)
                        else
                            notifyUser(key or _("来源名不能为空"), 3)
                        end
                    end,
                },
            },
        },
    }
    showNoFlash(dialog)
    dialog:onShowKeyboard()
end

function WordCount:sourcePolicySubMenu()
    local items = {
        {
            text = _("启用（按来源自动选口径）"),
            desc = _("默认关闭：关着时全部走全局「字数口径」，一个字都不读。"
                .. "开启后每本书按书档里的「来源平台」决定口径，"
                .. "没有来源标注的书走下面「未标注来源」这一条。"),
            checked_func = function() return SourcePolicy.enabled() end,
            callback = function()
                local on = SourcePolicy.setEnabled(not SourcePolicy.enabled())
                BookshelfIntegration.clearCache()
                notifyUser(on and _("已启用：按来源自动选口径")
                    or _("已关闭：全部走全局「字数口径」"), 3)
            end,
            keep_menu_open = true,
        },
        {
            text_func = function() return self:sourceInfoLabel() end,
            callback = function() notifyUser(self:sourceInfoLabel(), 4) end,
            keep_menu_open = true,
        },
        {
            text = _("来源平台从哪来？"),
            desc = _("元数据插件 → 配置 → 「写入来源平台」默认是关的，"
                .. "开启后对每本书应用一次元数据，才会写进书档。"),
            callback = function()
                notifyUser(_("本功能读的是书档里的「来源平台」。\n\n"
                    .. "元数据插件的「写入来源平台」默认关闭，"
                    .. "要在那边打开、并对书应用一次元数据，"
                    .. "书档里才会出现来源。\n\n"
                    .. "没写来源的书一律按上面「未标注来源」算，"
                    .. "不影响统计本身。"), 8)
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                return T(_("未标注来源：%1"), modeLabel(SourcePolicy.unlabeledMode()))
            end,
            sub_item_table_func = function() return self:sourceUnlabeledSubMenu() end,
        },
    }
    -- 预置来源（顺序固定，方便肌肉记忆）
    for _i, src in ipairs(SourcePolicy.SOURCES) do
        items[#items + 1] = {
            text_func = function()
                return T(_("%1：%2"), src.name, SourcePolicy.ruleLabel(src.key))
            end,
            sub_item_table_func = function() return self:sourceRuleSubMenu(src.key) end,
        }
    end
    -- 用户自己加的来源（键以 @ 开头）
    local custom = {}
    for key in pairs(SourcePolicy.rules()) do
        if key:sub(1, 1) == "@" then custom[#custom + 1] = key end
    end
    table.sort(custom)
    for _i, key in ipairs(custom) do
        items[#items + 1] = {
            text_func = function()
                return T(_("%1：%2"), key:sub(2), SourcePolicy.ruleLabel(key))
            end,
            sub_item_table_func = function() return self:sourceRuleSubMenu(key) end,
        }
    end
    items[#items + 1] = {
        text = _("添加自定义来源…"),
        desc = _("来源平台名不在内置列表里时，自己加一条。"),
        callback = function() self:addCustomSource() end,
        keep_menu_open = true,
    }
    items[#items + 1] = {
        text = _("恢复预设"),
        desc = _("晋江＝严格字符数，起点＝只算文字，番茄＝严格字符数，"
            .. "其余来源跟随未标注。"),
        callback = function()
            SourcePolicy.resetPresets()
            BookshelfIntegration.clearCache()
            notifyUser(_("已恢复预设规则"), 2)
        end,
        keep_menu_open = true,
    }
    return items
end

function WordCount:_globalStore()
    if self._global_stats then return self._global_stats end
    local saved = G_reader_settings and G_reader_settings:readSetting(KEY_GLOBAL_STATS)
    self._global_stats = GlobalStats.normalize(saved)
    -- 数据版本号 —— 统计页的结果缓存（见 statistics_page 的 statMemoKey）
    -- 用它做失效判据：只要 store 有新写入就 +1，缓存自动作废。
    self._global_stats_rev = self._global_stats_rev or 0
    return self._global_stats
end

function WordCount:_saveGlobalStats(force_flush)
    if not G_reader_settings or not self._global_stats then return end
    self._global_stats_flush_count = (self._global_stats_flush_count or 0) + 1
    if force_flush or self._global_stats_flush_count >= READ_FLUSH_EVERY then
        -- 全局统计同样可能包含大量按天/按书明细；避免每次翻页都重序列化。
        G_reader_settings:saveSetting(KEY_GLOBAL_STATS, self._global_stats)
        G_reader_settings:flush()
        -- 写完就让统计结果缓存失效（统计页下次打开/重建会重算一次）。
        self._global_stats_rev = (self._global_stats_rev or 0) + 1
        self._global_stats_flush_count = 0
    end
end

-- `_bookInfo` 加了**实例缓存**。
local function cachedDocSettings(self, path)
    if type(path) ~= "string" or path == "" then return nil end
    -- ① 阅读中的这本书：直接复用 ui.doc_settings（上游已经维护好，零成本）
    if self.ui and self.ui.document and self.ui.document.file == path
            and self.ui.doc_settings then
        return self.ui.doc_settings
    end
    -- ② 其它书：按 path 记忆一次 DocSettings:open 的结果
    self._bookinfo_settings_cache = self._bookinfo_settings_cache or {}
    local key = path
    local cached = self._bookinfo_settings_cache[key]
    if cached ~= nil then return cached or nil end
    local ok, settings = pcall(DocSettings.open, DocSettings, path)
    if not ok then settings = nil end
    -- 这份缓存是**按 path 累加**的（批量统计会依次碰很多本书）。
    local cache = self._bookinfo_settings_cache
    local n = self._bookinfo_settings_cache_n or 0
    if n >= 64 then
        cache = {}
        self._bookinfo_settings_cache = cache
        n = 0
    end
    if cache[key] == nil then       -- 只有真新增才 +1（覆盖同 key 不涨）
        n = n + 1
    end
    self._bookinfo_settings_cache_n = n
    -- 存 false 表示「查过了，没有」——避免每次都重试打开
    cache[key] = settings or false
    return settings
end

function WordCount:_bookInfo(doc, total_units_override)
    doc = doc or (self.ui and self.ui.document)
    local path = doc and doc.file or self._scan_path or self._read_doc_path
    local settings = cachedDocSettings(self, path)
    local summary = settings and settings:readSetting("summary") or {}
    if type(summary) ~= "table" then summary = {} end
    local title = summary.title or (doc and doc.title)
    if not title or title == "" then
        title = tostring(path or ""):match("([^/]+)$") or _("未知书籍")
        title = title:gsub("%.[^%.]+$", "")
    end
    local mtime, size = fileFingerprint(path)
    local total_units
    if settings and tonumber(settings:readSetting(KEY_MTIME)) == mtime
            and tonumber(settings:readSetting(KEY_SIZE)) == size then
        local mode = countModeOf(path)
        total_units = valueFor(mode,
            settings:readSetting(KEY_COUNT),
            settings:readSetting(KEY_COUNT_PUNCT),
            settings:readSetting(KEY_COUNT_CHAR), true)
        -- valueFor 在当前口径缺字段时返回 nil → 这本还没按该口径统计过
    end
    -- 调用方明确给了全书字数（例如来自全局缓存）就用它 ——
    -- 「重置设置」后 DocSettings 里的 KEY_COUNT 可能已被清掉，
    -- 但全局缓存 KEY_CACHE 里还有，这时必须以缓存值为准。
    total_units = tonumber(total_units_override) or total_units
    return { path = path, title = tostring(title), status = summary.status or "reading",
        total_units = total_units, date = GlobalStats.dateKey(os.time()) }
end

-- `force_flush` 参数化。
function WordCount:_syncGlobalBook(state, new_page, book_path, total_units_override, force_flush)
    if not state then return end
    local info = self:_bookInfo(book_path and { file = book_path } or nil, total_units_override)
    if type(info.path) ~= "string" or info.path == "" then return end
    -- 顺手把最新的全书字数同步进阅读状态，
    -- 并重算一次 —— 让「已读 ≤ 全书」的钳制在**写进全局统计之前**生效，
    -- 否则虚高的 read_units 会先被 upsert 进 KEY_GLOBAL_STATS 固化下来。
    if tonumber(info.total_units) and tonumber(info.total_units) > 0 then
        state.total_units = tonumber(info.total_units)
        ReadingStats.recompute(state)
    end
    GlobalStats.upsertBook(self:_globalStore(), {
        path = info.path, title = info.title, status = info.status,
        total_units = info.total_units,
        read_units = tonumber(state.read_units) or 0,
        read_seconds = tonumber(state.read_seconds) or 0,
        read_pages = countReadPages(state), date = info.date, new_page = new_page == true,
    })
    self:_saveGlobalStats(force_flush == true)
end

-- 缓存命中时**补写全局聚合**。
-- ⇒ 表现就是：字数明明在（所以显示「读取缓存」），
-- 但阅读统计总览里这本书依旧是 0（聚合里没有这条）。
function WordCount:_resyncBookFromCache(path, cached_count)
    if type(path) ~= "string" or path == "" then return false end
    local settings = cachedDocSettings(self, path)
    local state = nil
    if settings and type(settings.readSetting) == "function" then
        local ok, st = pcall(settings.readSetting, settings, KEY_READ_STATS)
        if ok and type(st) == "table" then state = st end
    end
    -- 没有阅读状态：构造一个最小 state（只有字数，时长/已读为 0），
    -- 这样至少「全书字数」这一项能回到总览里。
    if not state then state = { read_units = 0, read_seconds = 0 } end
    -- 主动把**缓存里的全书字数**传进去：重置后 DocSettings 的 KEY_COUNT
    -- 可能已被清掉，不能指望 _bookInfo 自己从 DocSettings 读到。
    local ok2, err = pcall(self._syncGlobalBook, self, state, false, path,
        tonumber(cached_count), true)
    if not ok2 then
        logger.warn("WordCount: resync global book from cache failed: " .. tostring(err))
        return false
    end
    return true
end

-- 「记录笔记」的采集：KOReader 的标注是每本书一个数组，我们只记增量。
function WordCount:_syncNotes(force_flush)
    local doc = self.ui and self.ui.document
    local settings = self.ui and self.ui.doc_settings
    if not doc or not settings then return end
    local path = doc.file
    if type(path) ~= "string" or path == "" then return end
    local count = countAnnotations(settings)
    if count == nil then return end

    self._notes_seen = self._notes_seen or {}
    local previous = self._notes_seen[path]
    if previous == count then return end
    self._notes_seen[path] = count

    local info = self:_bookInfo(doc)
    local store = self:_globalStore()
    if previous == nil or count < previous then
        -- 首次见到这本书（写存量），或用户删掉了标注（只回写存量）
        GlobalStats.setBookNotes(store, {
            path = info.path, title = info.title, status = info.status,
            total_units = info.total_units, notes = count, date = info.date,
        })
    else
        GlobalStats.recordNotes(store, {
            path = info.path, title = info.title, status = info.status,
            total_units = info.total_units,
            timestamp = os.time(), date = GlobalStats.dateKey(os.time()),
            notes = count - previous, total_notes = count,
        })
    end
    self:_saveGlobalStats(force_flush)
end

-- 页 key 的**廉价版**。
-- ⇒ 手感发涩、翻页掉帧。
function WordCount:_pageKeyFast(_doc, page)
    return "p:" .. tostring(page)
end

function WordCount:_pageKey(doc, page)
    if doc and type(doc.getPageXPointer) == "function" then
        local ok, xp = pcall(doc.getPageXPointer, doc, page)
        if ok and xp ~= nil and tostring(xp) ~= "" then
            return "x:" .. tostring(xp)
        end
    end
    return "p:" .. tostring(page)
end

-- 扫描循环专用的页 key。
function WordCount:_pageKeyForScan(job, doc, page)
    if job and job._key_stem == nil and not job._key_stem_tried then
        job._key_stem_tried = true
        job._key_stem = self:_pageKeyTemplate(doc)
    end
    local stem = job and job._key_stem
    if stem then
        local ok, formatted = pcall(string.format, stem, page)
        if ok and type(formatted) == "string" then return formatted end
    end
    return "p:" .. tostring(page)
end

-- 把「本页字数」记进 job 的逐页表，**带容量闸门**。
function WordCount:_recordPageUnits(job, doc, page, units)
    if not job then return end
    -- 闸门：超出容量上限就只记一次提示，之后静默跳过（不再分配 key 字符串）
    if (tonumber(job.page_count) or 0) > MAX_TRACKED_PAGES then
        if not job.page_units_capped then
            job.page_units_capped = true
            logger.info("WordCount: page_units tracking capped at "
                .. tostring(MAX_TRACKED_PAGES) .. " pages (memory guard); "
                .. "total count remains exact")
        end
        return
    end
    job.page_units[self:_pageKeyForScan(job, doc, page)] = units
end

-- 取「页号模板」：把首页 xpointer 里的页号替换成 `%d`。
function WordCount:_pageKeyTemplate(doc)
    if not doc or type(doc.getPageXPointer) ~= "function" then return nil end
    local ok, k1 = pcall(self._pageKey, self, doc, 1)
    if not ok or type(k1) ~= "string" then return nil end
    local s, n = k1:gsub("([Pp]%[)(%d+)(%])", "%1%%d%3", 1)
    if n <= 0 then return nil end
    return s
end

function WordCount:_ensureReadState(doc, path, known_page_count)
    -- 走 `cachedDocSettings`，避免热路径上重复 I/O。
    local settings = cachedDocSettings(self, path)
    if not settings or type(settings.readSetting) ~= "function" then return nil end
    local pages = tonumber(known_page_count) or pageCount(doc)
    local mtime, size = fileFingerprint(path)
    local state = settings:readSetting(KEY_READ_STATS)
    if not ReadingStats.isValidForFile(state, pages, mtime, size) then
        state = ReadingStats.newState(pages, mtime, size)
        self._read_save_count = 0
        self._read_dirty = true
    end
    -- 把**全书字数**记进阅读状态。
    if not tonumber(state.total_units) then
        local info = self:_bookInfo(doc)
        local total = info and tonumber(info.total_units)
        if total and total > 0 then state.total_units = total end
    end
    ReadingStats.recompute(state)
    self._read_state = state
    self._read_settings = settings
    self._read_doc_path = path
    self._read_page_count = pages
    return state
end

function WordCount:_saveReadState(force_flush)
    local settings = self._read_settings
        or (self.ui and self.ui.document and self.ui.doc_settings)
    if not self._read_state or not settings or type(settings.saveSetting) ~= "function" then return end
    ReadingStats.recompute(self._read_state)
    self._read_state.updated_at = os.time()
    self._read_dirty = true
    self._read_save_count = (self._read_save_count or 0) + 1
    -- saveSetting 也会序列化整张逐页表；此前虽然 flush 每 8 次才做，
    -- 但每次翻页仍会完整写入内存中的设置树，老设备上会造成明显 CPU/GC 抖动。
    if force_flush or self._read_save_count >= READ_FLUSH_EVERY then
        settings:saveSetting(KEY_READ_STATS, self._read_state)
        settings:flush()
        self._read_dirty = false
        self._read_save_count = 0
    end
end

-- `key` 参数现在允许是**廉价 key**（"p:<n>"）。
function WordCount:_pageUnitsBounds(doc)
    local state = self._read_state
    local total = state and tonumber(state.total_units) or nil
    if (not total or total <= 0) and doc then
        local info = self:_bookInfo(doc)
        total = info and tonumber(info.total_units) or nil
        if total and total > 0 and state then state.total_units = total end
    end
    local pages = state and tonumber(state.page_count) or nil
    if not pages or pages <= 0 then
        pages = doc and pageCount(doc) or nil
    end
    pages = math.max(1, tonumber(pages) or 1)
    local avg = nil
    if total and total > 0 then avg = total / pages end
    local cap = PAGE_UNITS_MIN_CAP
    if avg then
        cap = math.max(cap, math.floor(avg * PAGE_UNITS_MAX_FACTOR))
    end
    return cap, avg
end

function WordCount:_getPageUnits(doc, page, key, precise_key)
    local state = self._read_state
    -- 精确 key 按需计算：这里只算一次，下面读/写都用它。
    if precise_key == nil then
        precise_key = self:_pageKey(doc, page)
    end
    -- 传进来的 key 若和精确 key 不同（廉价 key），只用于内存里的临时判重，
    -- 真正读 page_units 一律用 precise_key。
    local lookup_key = precise_key

    -- 这里以前是「只要 page_units[key] 有值就直接返回」。
    if state and state.page_units[lookup_key] ~= nil
            and not ReadingStats.isEstimatedPageUnit(state, lookup_key) then
        return tonumber(state.page_units[lookup_key]) or 0
    end
    if not doc then return 0 end

    -- 先算出这一页的「合理区间」。
    local cap, avg = self:_pageUnitsBounds(doc)
    -- 日志闸门：同一本书只抱怨一次，避免整本退化书把 crash.log 刷爆。
    local function warnOnce(msg, a, b, c)
        if self._units_warn_path == doc.file then return end
        self._units_warn_path = doc.file
        logger.warn(msg, a, b, c)
    end

    local units, from_extract = nil, false
    local ok, text, err = pcall(PageText.extract, doc, page, pageCount(doc))
    if ok and type(text) == "string" and #text > 0 then
        -- 计数**之前**先按字节粗筛：UTF-8 里一个汉字 3 字节，取 4 字节上界
        -- ⇒ `cap * 4` 字节已经覆盖 cap 个汉字。超过就直接判为不可信。
        if #text > cap * 4 then
            warnOnce("WordCount: page text implausibly large, ignoring; bytes/page/cap:",
                #text, page, cap)
        else
            local n = Counter.count(text)
            if n > 0 and n <= cap then
                units, from_extract = n, true
            else
                warnOnce("WordCount: page unit count implausible, ignoring; units/page/cap:",
                    n, page, cap)
            end
        end
    elseif not ok then
        warnOnce("WordCount: could not extract text for page", page, tostring(text))
    end

    -- 抽取失败或明显不可信 ⇒ **退回「全书页均值」**，
    -- 并打上「估算」标记。三个取舍理由：
    -- · 不记 0 —— 一记 0，「已读字数」会明显偏低，用户照样觉得不对；
    -- · 不用抽到的那个大值 —— 那正是虚高的来源；
    -- · 打估算标记 —— `_getPageUnits` 遇估算值**不短路**，后续能抽到真实
    if not from_extract and avg and avg > 0 then
        units = math.floor(avg + 0.5)
    end

    if state and units then
        if from_extract then
            ReadingStats.setPageUnits(state, lookup_key, units)
        else
            ReadingStats.setEstimatedPageUnits(state, lookup_key, units)
        end
        self._read_dirty = true
    end
    return units or 0
end

function WordCount:_startPageTimer(doc, page)
    if self._reading_paused or not doc or not page then return end
    -- 页映射失效后**不再起新的计时**。
    if self._pagemap_invalid then return end
    local path = doc.file
    local pages = pageCount(doc)
    local state = self._read_state
    if not state or self._read_doc_path ~= path or self._read_page_count ~= pages then
        state = self:_ensureReadState(doc, path, pages)
    end
    if not state then return end
    -- 判重只用**廉价 key**（页号），
    -- 绝不为「是不是同一页」去付 `getPageXPointer` 的跨 FFI 代价。
    local key = self:_pageKeyFast(doc, page)
    if self._active_page and self._active_page.key == key then return end
    self._active_page = {
        doc = doc,
        path = path,
        page = page,
        key = key,
        started = os.time(),
    }
end

-- `skip_extract`（39-jump-overcount 新增）：**只记时间，不抽本页文本**。
function WordCount:_finishPageTimer(force_flush, skip_extract)
    local active = self._active_page
    if not active then
        if force_flush then self:_saveReadState(true) end
        return
    end
    self._active_page = nil
    local elapsed = math.max(0, os.time() - active.started)
    local min_sec, max_sec = readLimits()
    if elapsed >= min_sec and self._read_state then
        -- **结算时才计算精确 key，只算这一次**。
        local precise_key = self:_pageKey(active.doc, active.page)
        -- `units = nil` 时 `addPageVisit` 不写 page_units，
        -- `recompute` 会退回该页**已缓存**的字数（通常 0）—— 只记时间。
        local units
        if not skip_extract then
            units = self:_getPageUnits(active.doc, active.page, precise_key, precise_key)
        end
        local accepted, new_page, added_seconds = ReadingStats.addPageVisit(
            self._read_state, precise_key, units, elapsed, min_sec, max_sec)
        self:_saveReadState(force_flush)
        if accepted then
            local timestamp = os.time()
            local info = self:_bookInfo(active.doc)
            GlobalStats.recordVisit(self:_globalStore(), {
                path = info.path, title = info.title, status = info.status,
                total_units = info.total_units,
                read_units = tonumber(self._read_state.read_units) or 0,
                read_seconds = tonumber(self._read_state.read_seconds) or 0,
                read_pages = countReadPages(self._read_state),
                timestamp = timestamp, date = GlobalStats.dateKey(timestamp),
                hour = tonumber(os.date("%H", timestamp)), seconds = added_seconds,
                new_page = new_page, new_units = new_page and units or 0,
            })
            self:_saveGlobalStats(force_flush)
            self:_syncNotes(force_flush)
        end
    elseif force_flush and self._read_state then
        -- 这里补上 `_saveGlobalStats(true)`。
        self:_saveReadState(true)
        self:_syncNotes(true)
        self:_saveGlobalStats(true)
    end
end

function WordCount:_trackPageUpdate(page)
    local doc = self.ui.document
    if page == false or page == nil then
        self:_finishPageTimer(true)
        return
    end
    -- 页映射已失效（部分重排之后）⇒ **不再按页码记账**。
    if self._pagemap_invalid then return end
    if self._reading_paused then return end
    if not doc then return end
    local path = doc.file
    local state = self._read_state
    local current_count = pageCount(doc)
    if not state or self._read_doc_path ~= path
            or self._read_page_count ~= current_count then
        self:_ensureReadState(doc, path, current_count)
        self._active_page = nil
    end
    -- 这里同样只比较**廉价 key**。
    local key = self:_pageKeyFast(doc, page)
    if self._active_page and self._active_page.key == key then return end
    self:_finishPageTimer(false)
    self:_startPageTimer(doc, page)
end

function WordCount:_currentPage()
    if self.ui and type(self.ui.getCurrentPage) == "function" then
        local ok, page = pcall(self.ui.getCurrentPage, self.ui)
        if ok then return page end
    end
    return nil
end

-- `onReaderReady` 是**开书流程的同步尾巴**。
function WordCount:onReaderReady(_config)
    local doc = self.ui.document
    if not doc then return end
    self._reading_paused = false
    -- 换书 / 重新打开 ⇒ **重置「页映射失效」闸门**。
    self._pagemap_invalid = false
    self._units_warn_path = nil
    -- 先做**最廉价**的一件事：启动当前页计时（只有 os.time 和字符串拼接）。
    self._active_page = nil
    self:_startPageTimer(doc, self:_currentPage())

    -- 剩下的磁盘 I/O 全部推迟一拍。
    -- 闭包捕获 doc/path，避免 nextTick 执行时 ui.document 已经变了。
    local path = doc.file
    UIManager:nextTick(function()
        -- 这一拍里文档可能已经关了/换了书，必须重新校验身份。
        if not self.ui or not self.ui.document then return end
        if self.ui.document.file ~= path then return end
        local state = self:_ensureReadState(self.ui.document, path, pageCount(self.ui.document))
        self:_syncGlobalBook(state, false)
        self:_syncNotes(false)
    end)
end

function WordCount:onPageUpdate(page)
    self:_trackPageUpdate(page)
end

function WordCount:onPosUpdate(_pos, page)
    if page ~= nil then self:_trackPageUpdate(page) end
end

function WordCount:onReadingPaused()
    self:_finishPageTimer(true)
    self._reading_paused = true
end

function WordCount:onReadingResumed()
    self._reading_paused = false
    self:_startPageTimer(self.ui.document, self:_currentPage())
end

function WordCount:onSuspend()
    self:onReadingPaused()
end

function WordCount:onResume()
    self:onReadingResumed()
end

-- **页映射失效时停止按页记账**。
function WordCount:onDocumentPartiallyRerendered(first_partial_rerender)
    if not first_partial_rerender then return end
    local doc = self.ui and self.ui.document
    if not doc then return end
    if self._pagemap_invalid then return end
    -- 只记时间、不抽文本；force_flush = false（后面还有正常的落盘时机）
    self:_finishPageTimer(false, true)
    self._active_page = nil
    self._pagemap_invalid = true
    logger.info("WordCount: page map invalid after partial rerender; "
        .. "page accounting stopped for this document")
end

-- 打开阅读统计页面。
function WordCount:showStatisticsDashboard(period, anchor, metric)
    local doc = self.ui and self.ui.document
    if doc and doc.file and not self._stat_open_pending then
        local count = readCachedCount(doc.file,
            self.ui and self.ui.doc_settings)
        if not count then
            -- 当前书从没统计过：先扫一次（带进度条），扫完自动开统计页。
            logger.info("WordCount: statistics opened but current book has no count → scan first")
            self._stat_open_pending = { period = period, anchor = anchor, metric = metric }
            local started = self:startCountFromMenu(false)
            if started then
                -- 扫描是异步的；收尾处会调 _maybeOpenStatisticsAfterScan()。
                return nil
            end
            -- 起不来（例如已有任务在跑）就别卡住，直接开页
            self._stat_open_pending = nil
        else
            -- 字数在缓存里（所以不会起扫描）——
            -- 但「重置设置」可能把**聚合统计**清掉了，导致总览里这本书是 0。
            self:_resyncBookFromCache(doc.file, count)
        end
    end
    return StatisticsPage.show(self, period, anchor, metric)
end

-- 扫描收尾后，如果这次扫描是为了「打开统计页」而起的，就把页打开。
-- 由 startCount 的收尾分支调用（见 step 里 result 之后）。
function WordCount:_maybeOpenStatisticsAfterScan()
    local pending = self._stat_open_pending
    if not pending then return end
    self._stat_open_pending = nil
    UIManager:scheduleIn(0.4, function()
        StatisticsPage.show(self, pending.period, pending.anchor, pending.metric)
    end)
end

function WordCount:showSavedStats()
    local settings = self.ui.doc_settings
    local doc_path = self.ui.document and self.ui.document.file
    local mode = countModeOf(doc_path)
    local total
    if settings and self.ui.document then
        local mtime, size = fileFingerprint(doc_path)
        if tonumber(settings:readSetting(KEY_MTIME)) == mtime
                and tonumber(settings:readSetting(KEY_SIZE)) == size then
            total = valueFor(mode,
                settings:readSetting(KEY_COUNT),
                settings:readSetting(KEY_COUNT_PUNCT),
                settings:readSetting(KEY_COUNT_CHAR), true)
        end
    end
    local state = self._read_state
    if type(state) == "table" then ReadingStats.recompute(state) end
    if total == nil then
        -- 当前口径下这本书还没算过（老数据 / 刚切口径）—— 别拿 0 或
        -- 另一种口径的数糊过去，直接告诉用户重算一次。
        if mode ~= "plain" then
            notifyUser(T(_("这本书还没按「%1」口径统计过。\n"
                .. "点「统计全书字数」重算一次即可。"), modeLabel(mode)), 5)
        else
            notifyUser(_("本书还没有可显示的字数统计"))
        end
        return
    end
    total = tonumber(total) or 0
    local read_units = state and tonumber(state.read_units) or 0
    local speed = state and tonumber(state.speed_units_per_minute)
    if speed then
        -- **术语统一**。这里原来写的是「平均 %3 单位/分钟」，
        -- 而统计页的卡片/坐标轴/页脚一律是「字/分钟」—— 同一个量两种叫法，
        -- 用户直接反馈「术语和单位混乱」。本插件数出来的东西就是**字**，
        -- 没有第二个单位；「单位」这个词在整个插件里不再对用户出现。
        notifyUser(T(_("全书约 %1；已读约 %2；平均 %3 字/分钟"),
            fmtCount(total), fmtCount(read_units), fmtCount(speed)))
    else
        notifyUser(T(_("全书约 %1；已读约 %2；阅读速度尚未形成"),
            fmtCount(total), fmtCount(read_units)))
    end
end

function WordCount:cancelCount()
    if not self._job and not self._batch and not self._batch_preparing
            and not self._preparing_single then
        notifyUser(_("当前没有正在进行的全书统计"))
        return
    end
    -- 递增请求序号：让所有在途的 nextTick / scheduleIn 回调（其中包括
    -- startCountForPath 里「打开文档后延迟 0.25 秒再启动扫描」那一个）立刻
    -- 失效。仅把 _job/_batch 置 nil 是不够的 —— 它们本来就是 nil，回调会误判
    -- 成「可以开始」，于是取消后扫描仍会启动。
    self._request_seq = (self._request_seq or 0) + 1
    if self._job then self._job.cancelled = true end

    -- 清理**未完成**的缓存。
    local removed = {}
    local function wipe(path)
        if type(path) == "string" and path ~= "" and not removed[path] then
            removed[path] = true
            -- 只在「当前打开的正是这本书」时才把 doc_settings
            -- 传下去当 prefer_settings。否则它属于**另一本书**，
            -- 传进去会让 removeCachedCount 删错书的 sidecar
            -- （批量扫 C 时取消 ⇒ 正在读的 A 被清掉）。
            local prefer
            local ui = self.ui
            if ui and ui.doc_settings and ui.document and ui.document.file == path then
                prefer = ui.doc_settings
            end
            local ok_rm = pcall(removeCachedCount, path, prefer)
            if ok_rm then
                logger.info("WordCount: cancel — dropped incomplete cache for " .. tostring(path))
            end
        end
    end
    if self._job and self._job.path then
        wipe(self._job.path)
    end
    if self._preparing_single and self._preparing_single._wordcount_path then
        wipe(self._preparing_single._wordcount_path)
    end
    if self._batch then
        -- **不要再用 batch.paths[1] 当「当前正在处理的那本」**。
        if self._batch.dialog and self._batch.dialog._wordcount_path then
            wipe(self._batch.dialog._wordcount_path)
        end
        -- 「正在准备」的那本也算未完成（批处理第一本：此时 dialog 还没建）。
        if self._batch_preparing and self._batch_preparing._wordcount_path then
            wipe(self._batch_preparing._wordcount_path)
        end
        -- 兜底：批处理刚起步、上面两个来源都还是 nil 时，才用 paths[1]。
        local has_known = (self._batch.dialog and self._batch.dialog._wordcount_path)
            or (self._batch_preparing and self._batch_preparing._wordcount_path)
        if not has_known then
            local cur = self._batch.paths and self._batch.paths[1]
            if type(cur) == "string" then wipe(cur) end
        end
    end

    -- 批量的对话框挂在 _batch.dialog 上（整批共用一个）；它和
    -- _job.progress_dialog 可能是同一个对象，用 pcall + 去重避免关两次。
    local closed = {}
    local function close_dialog(dlg)
        if type(dlg) == "table" and type(dlg.close) == "function" and not closed[dlg] then
            closed[dlg] = true
            pcall(dlg.close, dlg)
        end
    end
    if self._job and self._job.progress_dialog then
        close_dialog(self._job.progress_dialog)
        self._job.progress_dialog = nil
    end
    if self._batch and self._batch.dialog then
        close_dialog(self._batch.dialog)
        self._batch.dialog = nil
    end
    if self._job and self._job.background_doc and type(self._job.background_doc.close) == "function" then
        pcall(self._job.background_doc.close, self._job.background_doc)
        self._job.background_doc = nil
    end
    if self._batch_preparing then
        close_dialog(self._batch_preparing)
        self._batch_preparing = nil
    end
    if self._preparing_single then
        close_dialog(self._preparing_single)
        self._preparing_single = nil
    end
    self._job = nil
    self._batch = nil
    -- 取消也要把 GC 恢复默认（扫描期间被调成了激进模式）
    Mem.endScan()
    -- 用户取消扫描时，也把「扫完自动开统计页」的挂起请求清掉，
    -- 否则取消后统计页还会突然弹出来。
    self._stat_open_pending = nil
    notifyUser(_("全书字数统计已取消"))
end

function WordCount:startCountFromMenu(force_rescan)
    if self._batch then
        notifyUser(_("批量字数统计正在进行中"))
        return false
    end
    -- 先查缓存。除非用户明确要求「重新统计」，
    -- 否则文件没变就直接用缓存结果，绝不重复扫描。
    if not force_rescan then
        local doc = self.ui and self.ui.document
        local path = doc and doc.file
        local count, cached_settings, cached_estimated = path and readCachedCount(path,
            self.ui and self.ui.doc_settings)
        if count then
            logger.info("WordCount: cache HIT for " .. tostring(path)
                .. " count=" .. tostring(count) .. " → skip scan")
            -- 命中缓存也要把这本书补进**聚合统计**，
            -- 否则「重置设置」后总览里这本书一直是 0（用户报的 bug）。
            self:_resyncBookFromCache(path, count)
            notifyCached(path, count, cached_settings, cached_estimated)
            return false       -- ★ 36：没起扫描 → false（调用方据此决定要不要等）
        end
        logger.info("WordCount: cache MISS for " .. tostring(path) .. " → will scan")
    else
        logger.info("WordCount: force rescan requested by user")
    end
    local ok, err = xpcall(function() self:startCount() end, debug.traceback)
    if ok then return true end       -- ★ 36：起了扫描 → true
    logger.err("WordCount: synchronous startCount failure", err)
    local message = T(_("无法启动字数统计：%1"), tostring(err))
    local shown = pcall(function()
        showNoFlash(InfoMessage:new{ text = message })
    end)
    if not shown then
        -- 这里以前写的是 `pcall(Notification.notify, Notification, message)` ——
        -- 在**类表**上点调用，`notify_source` 为 nil ⇒ 静默返回 false，什么也不显示。
        pcall(function()
            showNoFlash(Notification:new{ text = message, timeout = 4 })
        end)
    end
    return false
end

-- 统一的「有没有任务在跑」判据。
-- ⇒ **判定「没有任务」，照常起批**；
-- ④ 单本那个还在途的 nextTick 回调也只看 `_job/_batch`，同样判定「空的」，
-- 于是它**也**继续跑，把 doc 交给 startCount；
-- ⑤ 两边同时抢 UIManager 的对话框栈 + 同一批文档对象 ⇒ 界面错乱、
local function isBusy(self)
    return (self._job ~= nil)
        or (self._batch ~= nil)
        or (self._batch_preparing ~= nil)
        or (self._preparing_single ~= nil)
end

function WordCount:startCountForPath(path, force_rescan)
    logger.info("WordCount: startCountForPath path=" .. tostring(path)
        .. " force_rescan=" .. tostring(force_rescan))
    -- 统一忙判据（含 _preparing_single / _batch_preparing）。
    if isBusy(self) then
        notifyUser(_("已有字数统计任务正在进行中"))
        return
    end
    -- 先查缓存 —— 这本书统计过、文件也没变，就别再扫一遍。
    -- ⇒ 显式重算就该**先删后扫**，语义干净：点了重算 = 旧结果作废。
    if force_rescan then
        local removed = removeCachedCount(path)
        logger.info("WordCount: force rescan → cleared old cache for "
            .. tostring(path) .. " removed=" .. tostring(removed))
    end
    if not force_rescan then
        local count, cached_settings, cached_estimated = readCachedCount(path)
        if count then
            logger.info("WordCount: cache HIT for " .. tostring(path)
                .. " count=" .. tostring(count) .. " → skip scan")
            -- 同上 —— Bookshelf 点单本命中缓存时也补写聚合。
            self:_resyncBookFromCache(path, count)
            notifyCached(path, count, cached_settings, cached_estimated)
            return
        end
        logger.info("WordCount: cache MISS for " .. tostring(path) .. " → will scan")
    end
    local current = self.ui and self.ui.document
    if current and current.file == path then
        logger.info("WordCount: path is already the open document, direct startCount")
        self:startCount(current, path, false)
        return
    end
    -- Opening a background document can take long enough that the user would
    -- otherwise see no feedback before DocumentRegistry returns. Show a real
    -- progress dialog immediately; it is replaced by the page-aware dialog
    -- once the document is ready.
    local preparing = LiveProgressDialog:new{
        title = _("正在准备字数统计"),
        subtitle = T(_("正在打开：%1"), tostring(path)),
        progress_max = 1,
        dismissable = false,
        -- 准备阶段也能取消（会中断并清掉这本未完成的缓存）
        cancel_callback = function() self:cancelCount() end,
    }
    preparing:show()
    logger.info("WordCount: preparing dialog shown (正在准备字数统计)")
    -- 把 path 挂在对话框上，供 cancelCount() 定位「未完成的那本」并清缓存。
    preparing._wordcount_path = path
    self._preparing_single = preparing
    -- 取消安全：cancelCount() 只是把 _job/_batch/_preparing_single 置 nil，
    -- 单看这两个字段无法区分「用户取消」与「还没有任务」。以前 scheduleIn
    -- 的回调写的是 `if self._job or self._batch then return end`，取消之后
    -- 两者都是 nil，判定成「可以开始」，于是取消后 0.25 秒扫描仍会偷偷启动
    -- （用户在 0.25 秒的空窗期里点了取消，扫描照跑，看起来像取消无效）。
    self._request_seq = (self._request_seq or 0) + 1
    local seq = self._request_seq
    -- 只有序号才代表「这次请求还有效」。不要再用
    -- `self._preparing_single == preparing` 当令牌：preparing 在下面会被
    -- 主动置 nil（正常流程），那样 scheduleIn 回调会被误判成「已取消」。
    local function still_wanted()
        return self._request_seq == seq
    end
    UIManager:nextTick(function()
        -- 整段包 pcall：这个回调跑在 UIManager 的任务队列里（_checkTasks 里是
        -- 直接 `task.action(...)`，**没有 pcall**），一旦抛错就只剩顶层兜底，
        -- 而用户看到的是「对话框停在『正在打开』、之后再无任何反应」。
        local ok_cb, err_cb = pcall(function()
        if not still_wanted() then return end
        -- 这里**必须**用「除了我自己之外还有别人在忙」的判据。
        local other_preparing = self._preparing_single
            and self._preparing_single ~= preparing
        if self._job or self._batch or self._batch_preparing or other_preparing then
            preparing:close()
            if self._preparing_single == preparing then self._preparing_single = nil end
            return
        end
        logger.info("WordCount: opening document " .. tostring(path))
        -- 用 openPreparedDocument：openDocument 只创建对象，CRE 文档还要
        -- setupDefaultView + loadDocument + render 之后 getPageCount 才非 0。
        local ok, doc, open_err = pcall(openPreparedDocument, path)
        if not still_wanted() then
            -- 打开文档耗时期间用户取消了：把这个刚打开的文档还回去。
            if ok and doc and type(doc.close) == "function" then pcall(doc.close, doc) end
            return
        end
        if not ok or not doc then
            preparing:close()
            self._preparing_single = nil
            -- 区分「文件太大、拒绝排版」与一般打开失败。
            -- 直接说清楚原因 + 给可行的出路，别让用户以为是插件坏了。
            local err = open_err
            if not err and not ok then err = tostring(doc) end
            if err == "huge_document" then
                -- 报的必须是**实际生效**的那条线（跟随用户设置），
                -- 否则用户会看到「我明明设了 N，提示还说 M」的错乱。
                local mb = math.floor(hardRenderGuardBytes(path) / 1024 / 1024)
                notifyUser(T(_("这本书太大（超过 %1 MB），全文排版会耗尽内存并重启设备。\n"
                    .. "已跳过，以免影响你正在读的书。"), mb), 8)
                return
            end
            notifyUser(T(_("无法打开文件：%1"), tostring(err or path)))
            return
        end
        logger.info("WordCount: document opened, counting pages")
        local pages = pageCount(doc)
        if pages < 1 then
            -- 再给一次机会：万一 prepareDocument 里的 render 因为
            -- 「文档已在别处打开」被跳过，这里补一次并重查页数。
            logger.info("WordCount: pages==0, retrying prepareDocument")
            local _, prep_err2 = prepareDocument(doc)
            pages = pageCount(doc)
            logger.info("WordCount: after retry pages=" .. tostring(pages)
                .. " err=" .. tostring(prep_err2))
        end
        if pages < 1 then
            if type(doc.close) == "function" then pcall(doc.close, doc) end
            preparing:close()
            self._preparing_single = nil
            notifyUser(_("这本书没有可用的页数信息，无法统计"))
            return
        end
        -- 不再 close 掉 preparing 再新建对话框 —— 那样从 close 到新对话框
        -- show() 之间会有一段完全空白的窗口（0.25s 延时 + 一次 startCount），
        -- 在 e-ink 上就是用户看到的「进度条和文字都消失了」。
        UIManager:scheduleIn(0.25, function()
            if not still_wanted() then
                logger.info("WordCount: cancelled before startCount")
                if type(doc.close) == "function" then pcall(doc.close, doc) end
                return
            end
            -- 这条早退以前是「什么都不做就 return」——
            -- 两个泄漏：
            -- ① `preparing` 对话框没关 ⇒ 在 UIManager 栈上永久残留，
            -- 覆盖住后起的那个（批量）对话框；
            -- ② 刚打开的那本 `doc` 没还回去 ⇒ KPW4 上几十 MB 的
            if self._job or self._batch or self._batch_preparing then
                logger.info("WordCount: another job active, aborting this one")
                if preparing and type(preparing.close) == "function" then
                    pcall(preparing.close, preparing)
                end
                if self._preparing_single == preparing then
                    self._preparing_single = nil
                end
                if type(doc.close) == "function" then pcall(doc.close, doc) end
                return
            end
            logger.info("WordCount: handing off to startCount (reuse preparing dialog)")
            self:startCount(doc, path, true, preparing)
        end)
        end)
        if not ok_cb then
            logger.err("WordCount: openDocument callback failed", err_cb)
            pcall(function() preparing:close() end)
            self._preparing_single = nil
            self._request_seq = (self._request_seq or 0) + 1
            notifyUser(T(_("字数统计出错：%1"), tostring(err_cb)), 6)
        end
    end)
end

-- 判断「某个 job 所属的那一批」是否仍是当前活跃批次。
function WordCount:_batchAlive(job)
    local b = job and job.batch
    return b ~= nil and self._batch == b
end

function WordCount:_startNextBatch()
    local batch = self._batch
    if not batch then return end
    if #batch.paths == 0 then
        -- 整批结束：关掉那个长期存活的批次对话框（如果还开着）
        local dlg = batch.dialog or self._batch_preparing
        if self._batch_preparing then self._batch_preparing = nil end
        if dlg and type(dlg.close) == "function" then pcall(dlg.close, dlg) end
        self._batch = nil
        -- 「跳过 N 本」必须**说清跳的是哪几本、为什么**。
        local msg = T(_("批量统计完成：成功 %1 本，跳过 %2 本"),
            batch.completed, batch.skipped)
        local reasons = batch.skip_reasons
        if reasons and #reasons > 0 then
            -- 最多列 5 条，超过就折叠（KPW4 上提示框太长会盖满屏）。
            local shown = math.min(#reasons, 5)
            local lines = {}
            for i = 1, shown do lines[#lines + 1] = reasons[i] end
            local extra = ""
            if #reasons > shown then
                extra = T(_("\n…另有 %1 本"), #reasons - shown)
            end
            msg = msg .. "\n\n" .. T(_("跳过明细：")) .. "\n"
                .. table.concat(lines, "\n") .. extra
        end
        notifyUser(msg, reasons and #reasons > 0 and 8 or 4)
        return
    end

    local path = table.remove(batch.paths, 1)
    -- 进到这一本就把「第几本」推一格。计数在**取 path 之后**
    -- 自增，无论这本书最后是成功、跳过还是打开失败，序号都已经占掉，
    -- 保证「第 X / N 本」严格单调、不会因为跳过而回退或跳号。
    batch.index = (batch.index or 0) + 1
    local book_name = path and path:match("([^/\\]+)$") or nil
    -- 批量里这本书若已有有效缓存，直接跳过 ——
    -- 连文档都不用打开（打开 epub 才是批量里最慢的一步）。
    if not batch.force_rescan then
        local cached, _cs, cached_estimated = readCachedCount(path)
        if cached then
            logger.info("WordCount(batch): cache HIT for " .. tostring(path)
                .. " count=" .. tostring(cached)
                .. " estimated=" .. tostring(cached_estimated) .. " → skip")
            batch.completed = batch.completed + 1
            if batch.dialog and type(batch.dialog.setStatus) == "function" then
                batch.dialog:setBatchInfo(batch.index, batch.total, book_name)
                batch.dialog:setStatus(T(_("已跳过（有缓存）：%1"), tostring(path)))
            end
            return self:_startNextBatch()
        end
    end
    UIManager:nextTick(function()
        if self._batch ~= batch then return end
        -- 同样要用 prepare 版：否则每一本 epub 的页数都是 0，全被当「跳过」。
        local ok, doc, open_err = pcall(openPreparedDocument, path)
        if self._batch ~= batch then
            -- 取消（或又开了新批量）发生在 openDocument 期间：把刚打开的文档还回去。
            if ok and doc and type(doc.close) == "function" then pcall(doc.close, doc) end
            return
        end
        if not ok or not doc then
            -- 批量里遇到超大书（拒绝排版）→ 直接跳过，
            -- 计 skipped 并推进下一本。批量场景**不要**弹窗打断，
            -- 否则一次批量可能弹出一串「书太大」提示，很吵。
            local err = open_err
            if not err and not ok then err = tostring(doc) end
            if err == "huge_document" then
                logger.info("WordCount(batch): skip huge document " .. tostring(path))
                batch.skip_reasons = batch.skip_reasons or {}
                batch.skip_reasons[#batch.skip_reasons + 1] =
                    T(_("文件过大：%1"), tostring(path))
                if batch.dialog and type(batch.dialog.setStatus) == "function" then
                    batch.dialog:setStatus(T(_("已跳过（文件过大）：%1"), tostring(path)))
                end
            else
                -- **打开失败也必须给出可见原因**。
                logger.warn("WordCount(batch): open failed for " .. tostring(path)
                    .. " err=" .. tostring(err))
                batch.skip_reasons = batch.skip_reasons or {}
                batch.skip_reasons[#batch.skip_reasons + 1] =
                    T(_("打开失败：%1"), tostring(path))
                if batch.dialog and type(batch.dialog.setStatus) == "function" then
                    batch.dialog:setStatus(T(_("已跳过（无法打开）：%1"), tostring(path)))
                end
            end
            batch.skipped = batch.skipped + 1
            return self:_startNextBatch()
        end
        local pages = pageCount(doc)
        -- **批量路径必须和单本路径一样"补一刀"重试！**
        if pages < 1 then
            logger.info("WordCount(batch): pages==0, retrying prepareDocument for "
                .. tostring(path))
            local _, prep_err2 = prepareDocument(doc)
            pages = pageCount(doc)
            logger.info("WordCount(batch): after retry pages=" .. tostring(pages)
                .. " err=" .. tostring(prep_err2))
            if pages < 1 then
                -- 再给一次：有些书 render 之后才出页数（prepareDocument 已含 render）
                logger.info("WordCount(batch): still 0 pages, second retry")
                prepareDocument(doc)
                pages = pageCount(doc)
                logger.info("WordCount(batch): after 2nd retry pages=" .. tostring(pages))
            end
        end
        local supports_cre_text = type(doc.getPageXPointer) == "function"
            and (type(doc.getTextFromXPointers) == "function" or type(doc.getTextFromPositions) == "function")
        if pages < 1 or (type(doc.getPageText) ~= "function" and not supports_cre_text) then
            -- 这一条也是**静默**的（老代码直接 skipped+1）。
            local reason
            if pages < 1 then
                reason = "pages_zero"
            else
                reason = "no_text_layer"
            end
            logger.warn("WordCount(batch): skip " .. tostring(path)
                .. " reason=" .. reason
                .. " pages=" .. tostring(pages)
                .. " (retried twice)"
                .. " getPageText=" .. tostring(type(doc.getPageText) == "function")
                .. " cre_text=" .. tostring(supports_cre_text))
            if type(doc.close) == "function" then pcall(doc.close, doc) end
            batch.skip_reasons = batch.skip_reasons or {}
            if reason == "pages_zero" then
                batch.skip_reasons[#batch.skip_reasons + 1] =
                    T(_("无法分页：%1"), tostring(path))
                if batch.dialog and type(batch.dialog.setStatus) == "function" then
                    batch.dialog:setStatus(T(_("已跳过（无法分页）：%1"), tostring(path)))
                end
            else
                batch.skip_reasons[#batch.skip_reasons + 1] =
                    T(_("无文本层：%1"), tostring(path))
                if batch.dialog and type(batch.dialog.setStatus) == "function" then
                    batch.dialog:setStatus(T(_("已跳过（无可提取文字）：%1"), tostring(path)))
                end
            end
            batch.skipped = batch.skipped + 1
            return self:_startNextBatch()
        end
        -- 关键：整个批次**只保留一个对话框**，不要每本书 close 再 new。
        local preparing = batch.dialog
        if not preparing then
            preparing = self._batch_preparing
            self._batch_preparing = nil
            batch.dialog = preparing
        end
        -- 把「当前正在处理的这本」挂在对话框上，供 cancelCount()
        -- 定位未完成的缓存并清除（已完成的书不在这个字段里，自然保留）。
        if preparing then preparing._wordcount_path = path end
        -- 防御：万一准备对话框已经不存在（正常流程不会），兜一个新建的，
        -- 保证本批次后续每一本都有对话框可复用。
        if not preparing then
            preparing = LiveProgressDialog:new{
                title = _("正在批量统计字数"),
                subtitle = _("准备中…"),
                progress_max = 1,
                dismissable = false,
                -- 取消整批（已完成的书保留缓存，未完成的清掉）
                cancel_callback = function() self:cancelCount() end,
            }
            preparing:show()
            batch.dialog = preparing
        end
        -- 把「第 X / N 本」+ 当前书名推给标题行。
        if type(preparing.setBatchInfo) == "function" then
            preparing:setBatchInfo(batch.index, batch.total, book_name)
        end
        -- 与 DocumentRegistry 无关的 UI 安全：openDocument 只做 registry /
        -- refcount / GC，不碰 UI 栈（已对照 documentregistry.lua 全文确认），
        -- 所以保留的对话框不会因为打开文档而消失。
        UIManager:scheduleIn(0.25, function()
            -- 这里以前是 `if self._job then return end`。
            -- ⇒ 整个批量任务就此停摆（不报错、不结束，用户看着进度条不动）。
            local MAX_BUSY_RETRY = 20
            local function try_start(attempt)
                if self._batch ~= batch then
                    if type(doc.close) == "function" then pcall(doc.close, doc) end
                    return
                end
                if not self._job then
                    batch._busy_retry = 0
                    self:startCount(doc, path, true, preparing)
                    return
                end
                if attempt < MAX_BUSY_RETRY then
                    batch._busy_retry = attempt + 1
                    UIManager:scheduleIn(0.25, function() try_start(attempt + 1) end)
                    return
                end
                -- **等不及了也不能静默丢弃**。
                logger.warn("WordCount(batch): give up waiting for busy _job, skip "
                    .. tostring(path) .. " after " .. tostring(MAX_BUSY_RETRY) .. " retries")
                batch._busy_retry = 0
                batch.skip_reasons = batch.skip_reasons or {}
                batch.skip_reasons[#batch.skip_reasons + 1] =
                    T(_("等待上一本收尾超时：%1"), tostring(path))
                if batch.dialog and type(batch.dialog.setStatus) == "function" then
                    batch.dialog:setStatus(T(_("已跳过（等待超时）：%1"), tostring(path)))
                end
                batch.skipped = batch.skipped + 1
                if type(doc.close) == "function" then pcall(doc.close, doc) end
                self:_startNextBatch()
            end
            try_start(0)
        end)
    end)
end


function WordCount:startBatchCount(paths, force_rescan)
    if isBusy(self) then
        -- 区分文案：卡在「正在打开文档」时，明确告诉用户等的是哪一本，
        -- 否则他会以为插件坏了（旧文案「已有字数统计任务正在进行中」太含糊）。
        if not self._job and not self._batch and self._preparing_single then
            local p = self._preparing_single._wordcount_path
            notifyUser(T(_("正在打开上一本书，请稍候再统计（%1）"),
                tostring(p or _("准备中"))), 4)
        else
            notifyUser(_("已有字数统计任务正在进行中"))
        end
        return
    end
    local unique, list = {}, {}
    for _i, path in ipairs(paths or {}) do
        if type(path) == "string" and not unique[path] then
            unique[path] = true
            list[#list + 1] = path
        end
    end
    if #list == 0 then
        notifyUser(_("没有可统计的文件"))
        return
    end
    table.sort(list)
    -- 用户显式点「统计选中字数」⇒ **清掉这些书的旧缓存并全部重算**。
    -- ⇒ 批量与单本统一：**显式统计 = 先清缓存、再全部重扫**。
    local cleared = 0
    for _i, p in ipairs(list) do
        local ok_rm, rm = pcall(removeCachedCount, p)
        if ok_rm and rm then cleared = cleared + 1 end
    end
    logger.info("WordCount(batch): force batch rescan — cleared caches for "
        .. tostring(cleared) .. "/" .. tostring(#list) .. " book(s)")
    -- 让任何在途的单本 startCountForPath 回调失效（取消令牌语义一致）。
    self._request_seq = (self._request_seq or 0) + 1
    -- batch.index 是**当前正在处理第几本**（1 起），
    -- batch.total 是这批的总本数。注意 paths 表在 _startNextBatch 里会被
    -- table.remove 逐个吃掉，所以「已完成数」不能由 #paths 反推，
    -- 必须自己用一个只增不减的计数器。
    self._batch = {
        paths = list,
        completed = 0,
        skipped = 0,
        index = 0,          -- 已开始处理的（含跳过的）本数
        total = #list,
        -- 显式统计入口 ⇒ 缓存已在上方清掉，本批每本都要真扫，
        -- _startNextBatch 里据此**不做 cache HIT 跳过**（双保险）。
        force_rescan = true,
    }
    self._batch_preparing = LiveProgressDialog:new{
        title = _("正在准备批量统计"),
        subtitle = T(_("正在准备 %1 本书"), #list),
        progress_max = 1,
        dismissable = false,
        -- 批量准备阶段也能取消
        cancel_callback = function() self:cancelCount() end,
    }
    self._batch_preparing:setBatchInfo(0, #list, nil)
    self._batch_preparing:show()
    -- 批量本数多时自动降级抽页 —— **必须告诉用户**，
    -- 否则他拿到一堆「约」的数字会以为精确统计坏了。
    do
        local cur_mode = countMode()
        local thr = batchSampleThreshold()
        if cur_mode == MODE_FULL and thr > 0 and #list >= thr then
            notifyUser(T(_("共 %1 本，数量较多，本批将用「%2」省电模式统计（结果标「约」）。\n想要精确数字请单独点某一本重新统计。"),
                #list, scanModeName(MODE_SAMPLE)), 5)
        else
            notifyUser(T(_("开始批量统计：共 %1 本"), #list))
        end
    end
    self:_startNextBatch()
end

function WordCount:startCount(doc_override, path_override, batch_mode, preparing_dialog)
    logger.info("WordCount: startCount enter batch_mode=" .. tostring(batch_mode)
        .. " has_preparing_dialog=" .. tostring(preparing_dialog ~= nil))
    local function close_preparing()
        if preparing_dialog then
            preparing_dialog:close()
            if self._preparing_single == preparing_dialog then self._preparing_single = nil end
            if self._batch_preparing == preparing_dialog then self._batch_preparing = nil end
        end
    end
    -- 早退时必须把**调用方传进来的那个文档**还回去。
    local function close_override_doc()
        if doc_override and type(doc_override) == "table"
                and doc_override ~= (self.ui and self.ui.document)
                and type(doc_override.close) == "function" then
            pcall(doc_override.close, doc_override)
        end
    end
    -- 「已触发…正在检查文档…」这句弹窗去掉了。
    if self._job or (self._batch and not batch_mode) then
        logger.info("WordCount: EARLY-RETURN another job active")
        close_preparing()
        close_override_doc()
        notifyUser(_("全书字数统计正在进行中"))
        return
    end

    local doc = doc_override or (self.ui and self.ui.document)
    local path = path_override or (doc and doc.file)
    if type(path) ~= "string" or path == "" then
        logger.info("WordCount: EARLY-RETURN no path")
        close_preparing()
        close_override_doc()
        notifyUser(_("无法识别当前书籍文件"))
        return
    end
    local supports_cre_text = type(doc.getPageXPointer) == "function"
        and (type(doc.getTextFromXPointers) == "function" or type(doc.getTextFromPositions) == "function")
    if (type(doc.getPageText) ~= "function" and not supports_cre_text)
            or type(doc.getPageCount) ~= "function" then
        logger.info("WordCount: EARLY-RETURN unsupported document"
            .. " getPageText=" .. tostring(type(doc.getPageText) == "function")
            .. " cre_text=" .. tostring(supports_cre_text)
            .. " getPageCount=" .. tostring(type(doc.getPageCount) == "function"))
        close_preparing()
        close_override_doc()
        notifyUser(_("当前文档不支持文本提取"))
        return
    end

    local pages = pageCount(doc)
    -- 扫描期间把 GC 调激进。LuaJIT 默认 pause=200 的含义是「等内存涨到上轮的
    -- 两倍再回收」，在一台只剩几十 MB 可用的机器上等于放任它顶到 OOM。
    Mem.beginScan()
    -- 页数来自**哪一份文档**，直接决定它和用户翻书时看到的页数是否一致：
    -- · reader     = 正在读的那份 doc，和状态栏「页面 x / y」的 y 同源，必然相同
    -- · background = 书架/批量时后台重新打开的 doc，只走 setupDefaultView()，
    --                没有页眉页脚占位、也没套本书已保存的排版 ⇒ 页数可能不同
    -- 日志里把两个数都打出来，用户说「对不上」时能立刻判断是哪一种。
    do
        local live_doc = self.ui and self.ui.document
        local is_reader_doc = (live_doc ~= nil and live_doc == doc)
        local parts = {
            "WordCount: pageCount=" .. tostring(pages),
            "source=" .. (is_reader_doc and "reader" or "background"),
        }
        if is_reader_doc then
            -- 同一个 doc，两个数必然相同，写出来只是让日志自证
            parts[#parts + 1] = "reader_pages=" .. tostring(pages)
        elseif live_doc then
            -- 书架统计时若阅读界面恰好还开着另一本书，这里能拿到对照值
            parts[#parts + 1] = "other_reader_pages=" .. tostring(pageCount(live_doc))
        else
            -- 从书架统计时阅读界面根本没开书 —— 没有对照值可打。
            -- ⚠ 以前这里写 `reader_pages = live_pages or pages`，nil 时兜底成
            -- pages 自己，日志看起来像「两个数一样」，纯属误导。
            parts[#parts + 1] = "reader_doc=none"
        end
        logger.info(table.concat(parts, " "))
    end
    if pages < 1 then
        logger.info("WordCount: EARLY-RETURN pages<1")
        close_preparing()
        close_override_doc()
        notifyUser(_("无法获取文档页数"))
        return
    end

    local mtime, size = fileFingerprint(path)
    -- 决定这次是「全量扫」还是「抽页估算」。
    -- ⇒ 本批临时改成 sample。用户主动选 sample 时不重复判断（本来就省电）。
    local scan_mode = countMode()
    -- 确认框里点了「改用抽样估算」⇒ **只这一次**用抽样，
    -- 不改用户全局的「统计模式」偏好（标记随用随清）。
    if self._force_sample_once == path then
        scan_mode = MODE_SAMPLE
        self._force_sample_once = nil
    end
    local batch_forced_sample = false
    if scan_mode == MODE_FULL and self._batch then
        local bthr = batchSampleThreshold()
        if bthr > 0 and (tonumber(self._batch.total) or 0) >= bthr then
            scan_mode = MODE_SAMPLE
            batch_forced_sample = true
        end
    end
    local total_pages = pages
    local scan_pages = total_pages
    local sampled = false
    -- 降级行为完全由用户设置决定。
    local huge_book_forced_sample = false
    local refuse_reason = nil
    if scan_mode == MODE_FULL then
        local page_limit = downgradePages()
        local byte_limit = downgradeBytes(path)
        local too_many_pages = page_limit > 0 and total_pages > page_limit
        local too_big = byte_limit ~= math.huge and size and size > byte_limit
        if too_many_pages or too_big then
            if downgradeEnabled() then
                -- 用户允许降级 ⇒ 退到抽样估算（只扫前 SAMPLE_PAGES 页）。
                huge_book_forced_sample = true
                scan_pages = SAMPLE_PAGES
                sampled = true
                logger.warn("WordCount: user-allowed downgrade — pages=" .. tostring(total_pages)
                    .. " size=" .. tostring(size)
                    .. " (limits pages=" .. tostring(page_limit)
                    .. " bytes=" .. tostring(byte_limit) .. ") → sample mode")
            else
                -- 用户**禁止降级** ⇒ 直接拒绝，不硬跑（避免 OOM 重启）。
                refuse_reason = too_many_pages and "pages" or "size"
                logger.warn("WordCount: refusing huge scan (no-downgrade mode) — pages="
                    .. tostring(total_pages) .. " size=" .. tostring(size)
                    .. " limits pages=" .. tostring(page_limit)
                    .. " bytes=" .. tostring(byte_limit))
            end
        end
    elseif scan_mode == MODE_SAMPLE and total_pages > SAMPLE_PAGES then
        scan_pages = SAMPLE_PAGES
        sampled = true
    end

    -- 完整模式下规模超线且用户禁止降级 ⇒ 中止本次扫描（避免重启）。
    if refuse_reason then
        close_preparing()
        -- 既然处理不了，就把为它占用的资源**全部还回去**，
        -- 避免「打不开的书」残留一份文档对象 / 内存，越积越多。
        do
            -- 复用统一的 close_override_doc()（判据一致，避免两处漂移）。
            close_override_doc()
            self._refused_doc = nil
            collectgarbage("collect")
        end
        local limit_desc
        if refuse_reason == "pages" then
            limit_desc = T(_("%1 页（你设的上限 %2 页）"),
                fmtCount(total_pages), fmtCount(downgradePages()))
        else
            local mb = tostring(math.floor((tonumber(size) or 0) / 1024 / 1024))
            local bytes = downgradeBytes(path)
            local lim_mb = (bytes == math.huge) and "∞"
                or tostring(math.floor(bytes / 1024 / 1024))
            limit_desc = T(_("%1 MB（你设的上限 %2 MB）"), mb, lim_mb)
        end
        -- 文案改成「你设的上限」—— 现在上限只来自用户输入，
        -- 所以拒绝时该让用户知道「是我自己划的线」，而不是「插件不让统计」。
        notifyUser(T(_("这本书超过了你设的上限：%1，已按设置取消统计。\n"
            .. "想统计它：到「字数与阅读速度 → 页数 / 大小上限」把上限调大"
            .. "（或输入 0 = 不限制）。\n"
            .. "也可以把「大书处理」改成「超限改用抽样估算」，先拿一个约数。\n"
            .. "注：页数按统计时的排版计算（书架统计走默认排版），"
            .. "和你翻书时看到的页数可能不同。"),
            limit_desc), 10)
        Mem.endScan()
        return
    end

    -- **一点上限都没设 + 极端大的书** ⇒ 先问一句。
    if not refuse_reason and not sampled and scan_mode == MODE_FULL
            and not batch_mode
            and not pageLimitActive()
            and downgradeBytes(path) == math.huge
            and total_pages > EXTREME_PAGES
            and self._extreme_confirmed ~= path then
        logger.warn("WordCount: extreme book, asking before full scan — pages="
            .. tostring(total_pages) .. " size=" .. tostring(size))
        close_preparing()
        local plugin_self = self
        UIManager:show(ConfirmBox:new{
            text = T(_("这本书有 %1 页（%2 MB）。\n"
                .. "完整统计会逐页扫描，可能要很久，极少数情况下"
                .. "会因为内存不足导致设备重启。\n\n要怎么做？"),
                fmtCount(total_pages),
                tostring(math.floor((tonumber(size) or 0) / 1024 / 1024))),
            -- 左：取消（最安全，默认焦点）
            cancel_text = _("取消"),
            cancel_callback = function()
                close_override_doc()
                collectgarbage("collect")
            end,
            -- 中：改用抽样估算（只扫前 SAMPLE_PAGES 页 → 外推，结果标「约」）
            other_text = _("改用抽样估算"),
            other_callback = function()
                -- 只影响**这一次**（一次性标记），不改用户的全局「统计模式」偏好。
                plugin_self._force_sample_once = path
                UIManager:nextTick(function()
                    runEntrySafely(function()
                        plugin_self:startCount(doc, path, batch_mode, nil)
                    end)
                end)
            end,
            -- 右：仍然完整统计
            ok_text = _("仍然完整统计"),
            ok_callback = function()
                plugin_self._extreme_confirmed = path
                UIManager:nextTick(function()
                    runEntrySafely(function()
                        plugin_self:startCount(doc, path, batch_mode, nil)
                    end)
                end)
            end,
        })
        -- 三个分支都要退出本函数：恢复 GC 参数（重新开始扫描的那两个分支
        -- 会再次调用 beginScan，重复设置无害）。
        Mem.endScan()
        return
    end
    -- 一次性标记：用完即清，否则下次同一本书会跳过确认。
    if self._extreme_confirmed == path then self._extreme_confirmed = nil end

    local job = {
        doc = doc,
        background_doc = (doc_override and (not self.ui or self.ui.document ~= doc_override)) and doc_override or nil,
        path = path,
        -- page_count 是**本次扫描的上限**（抽页模式下就是样本页数），
        -- 全书真实页数放在 total_pages，收尾外推时用。
        page_count = scan_pages,
        total_pages = total_pages,
        scan_mode = scan_mode,
        -- 标记「这次是被批量规则降级的」，
        -- 收尾文案 / 完成提示据此说明「因为批量所以用了估算」。
        batch_forced_sample = batch_forced_sample,
        -- 标记「这次是因为书太大被强制降级的」，
        -- 收尾文案据此说明「书太大，为防卡死改用估算」。
        huge_book_forced_sample = huge_book_forced_sample,
        sampled = sampled,
        page = 1,
        state = Counter.newState(),
        -- ★ 口径**只解析一次**并存进 job。
        -- 旧写法在每页循环里调 punctIncluded(path)，一次扫描要问
        -- 设置/来源表几千次；更重要的是「扫到一半用户改了口径」会让
        -- 已读字数的累加基准前后不一致。
        count_mode = countModeOf(path),
        page_units = {},
        mtime = mtime,
        size = size,
        failed_pages = 0,
        pages_with_text = 0,
        first_error = nil,
        next_notice = math.max(1, math.floor(scan_pages / 4)),
        last_progress_page = 0,
        last_progress_time = 0,
        -- 用于「每 CHUNK_TICKS 个 tick 让 CPU 休息一次」的计数
        -- （28-kpw4-tuning：CHUNK_TICKS 已是 10，别在这里写死数字）
        tick_count = 0,
        -- 记住本 job 属于哪一批。
        batch = self._batch,
    }
    self._job = job
    -- 全书页数只在**抽样时**才和进度条分母不同，此时把它一并交给对话框，
    -- 副标题会写成「已扫描 3 / 100 页（3%）· 全书 1200 页」。
    local full_pages_hint = sampled and total_pages or nil
    -- 标题里带上全书页数：这样「进度条上的页码」和「翻书时状态栏的页码」
    -- 即使不一致，用户也能一眼看出进度条用的是哪个数。
    local scan_title = batch_mode and _("正在批量统计字数")
        or T(_("正在统计全书字数（%1 页）"), fmtCount(total_pages))
    if preparing_dialog then
        job.progress_dialog = preparing_dialog
        local on_stack = is_widget_on_stack(preparing_dialog)
        logger.info("WordCount: reusing preparing dialog, on_stack=" .. tostring(on_stack)
            .. " has_configureProgress=" .. tostring(type(preparing_dialog.configureProgress) == "function"))
        job.progress_dialog:configureProgress(scan_pages, scan_title, full_pages_hint)
        -- 保险：确保复用的对话框真的在屏幕上。preparing 是在上一个 tick 里
        -- show() 的，中间只隔了一次 openDocument（它不碰 UI 栈），所以正常
        -- 情况下它还在；万一被别的流程摘掉，这里补 show 一次，避免出现
        -- 「进度条和文字都消失」的空档。
        if type(preparing_dialog.show) == "function" and not on_stack then
            logger.warn("WordCount: preparing dialog was NOT on stack, re-showing")
            preparing_dialog:show()
        end
        self._preparing_single = nil
        self._batch_preparing = nil
    else
        job.progress_dialog = LiveProgressDialog:new{
            title = scan_title,
            subtitle = buildProgressText(0, scan_pages, 0, full_pages_hint),
            progress_max = scan_pages,
            full_pages = full_pages_hint,
            dismissable = false,
            refresh_time_seconds = 1.5,
            -- 页面扫描进度条上的「取消统计」按钮。
            cancel_callback = function() self:cancelCount() end,
        }
        job.progress_dialog:show()
        job.progress_dialog:updateProgress(0, true)
    end
    -- 不再用弹窗宣告「正在统计全书：0 / N 页」——
    -- 这个信息已经写在对话框的副标题里了。弹窗只会盖住它、白耗一次全屏刷新。

    local function releaseBackgroundDocument()
        if job.background_doc and type(job.background_doc.close) == "function" then
            pcall(job.background_doc.close, job.background_doc)
            job.background_doc = nil
        end
    end

    local function ensureScanDocument()
        if self.ui and self.ui.document == job.doc and job.doc and job.doc.file == path then
            return job.doc
        end
        -- Once the reader is closed (or another book is opened), use a separate
        -- document reference. This keeps the scan alive on the Bookshelf page.
        if not job.background_doc then
            -- prepare 版：这里重开的文档如果没 load+render，getPageXPointer
            -- 等取文本的 API 都会失败（页数 0 / XPointer 为空）。
            local ok, background_doc, bg_err = pcall(openPreparedDocument, path)
            if not ok or not background_doc then
                -- 把「文件太大」和一般失败区分开
                -- 接住第二个返回值（否则判断永不成立）。
                local err = bg_err
                if not err and not ok then err = tostring(background_doc) end
                if err == "huge_document" then
                    return nil, "HUGE_DOCUMENT"
                end
                return nil, tostring(err or "无法重新打开文档")
            end
            job.background_doc = background_doc
        end
        job.doc = job.background_doc
        return job.doc
    end

    local function step()
        if job.cancelled or self._job ~= job then return end
        local scan_doc, open_error = ensureScanDocument()
        if not scan_doc then
            self._job = nil
            releaseBackgroundDocument()
            Mem.endScan()
            -- 文件过大导致无法重开时，给出明确说明，
            -- 不要显示成含糊的「无法打开文档」。
            local message
            if open_error == "HUGE_DOCUMENT" then
                message = T(_("这本书太大，无法在不耗尽内存的前提下继续统计，已中止。"))
            else
                message = T(_("扫描无法继续：%1"), open_error or _("无法打开文档"))
            end
            if job.progress_dialog and type(job.progress_dialog.setStatus) == "function" then
                job.progress_dialog:setStatus(message)
            end
            notifyUser(message)
            if self:_batchAlive(job) then
                -- 批量：这一本算跳过，继续下一本（对话框留着复用）。
                job.batch.skipped = job.batch.skipped + 1
                job.progress_dialog = nil
                self:_startNextBatch()
            elseif job.progress_dialog then
                -- 单本：停留 5 秒让用户看清原因，然后关掉。
                local dlg = job.progress_dialog
                job.progress_dialog = nil
                UIManager:scheduleIn(5, function() pcall(dlg.close, dlg) end)
            end
            return
        end

        local stop_at = math.min(job.page + PAGES_PER_TICK - 1, job.page_count)

        -- ★ 1.4.2：不再「一次性取回全本文本」。
        --
        -- 旧做法要为整本书分配一个 Lua 字符串，crengine 内部还会再复制一份临时
        -- 缓冲；分配量取决于「书有多大」，而书有多大在取之前是不知道的。
        -- 在 512MB 内存的机器上这一步会把进程顶穿：日志里只剩下一个
        -- 「Killed」，没有任何 Lua 报错，KOReader 直接重启，用户看到的就是闪退。
        --
        -- 现在改成按块取：每次只 hold 住 block_pages 页的文本，数完立刻丢掉。
        -- 块大小由「实测剩余内存」决定（不看文件大小），内存越紧块越小。
        if job.page == 1 and not job.whole_book_tried and not job.sampled then
            job.whole_book_tried = true
            job.block_pages = chooseBlockPages(job)
            job.block_scan = true
            logger.info("WordCount: block scan start pages=" .. tostring(job.page_count)
                .. " block=" .. tostring(job.block_pages) .. " " .. Mem.describe())
            if job.progress_dialog then
                job.progress_dialog:setStatus(_("正在统计全书字数…"))
            end
        end

        while job.page <= stop_at do
            if job.block_scan then
                -- 块模式：一次取 block_pages 页，数完立刻丢掉这段文本。
                local finish = math.min(job.page + job.block_pages - 1, job.page_count)
                local text, range_err = PageText.extractRange(scan_doc, job.page,
                    finish, job.page_count)
                if text == nil then
                    -- 取不到就**永久**退回逐页，不要每个 tick 都再撞一次。
                    logger.warn("WordCount: block extract failed (" .. tostring(range_err)
                        .. ") pages=" .. tostring(job.page) .. "-" .. tostring(finish)
                        .. " → per-page scan")
                    job.block_scan = false
                else
                    local n = finish - job.page + 1
                    if text ~= "" then
                        job.pages_with_text = job.pages_with_text + n
                        local _t, plain_u, _tp, punct_u, _tc, char_u
                            = Counter.addPage(job.state, text)
                        -- 按 job 上记下的口径取本块的字数（三选一）
                        local units_total = valueFor(job.count_mode,
                            plain_u, punct_u, char_u, false)
                        -- 块内拿不到逐页字数，按块总量平均分给每一页（「已读字数」用）。
                        local per = math.floor((units_total or 0) / n)
                        for p = job.page, finish do
                            self:_recordPageUnits(job, scan_doc, p, per)
                        end
                        text = nil      -- 断开引用，让 GC 能立刻回收这一块
                    else
                        for p = job.page, finish do
                            self:_recordPageUnits(job, scan_doc, p, 0)
                        end
                    end
                    job.page = finish + 1
                    collectgarbage("step")
                end
            end
            if not job.block_scan then
            local ok, text, extract_error = pcall(PageText.extract, scan_doc, job.page, job.page_count)
            if not ok or text == nil then
                job.failed_pages = job.failed_pages + 1
                local reason = ok and extract_error or text
                job.first_error = job.first_error or tostring(reason or "unknown extraction error")
                logger.warn("WordCount: failed to extract page", job.page, reason)
            else
                if text ~= "" then
                    job.pages_with_text = job.pages_with_text + 1
                    -- 一次遍历同时得到「三种口径的累计」与「本页增量」。
                    local _t, plain_u, _tp, punct_u, _tc, char_u
                        = Counter.addPage(job.state, text)
                    -- 已读字数按当前口径累计，否则「已读 / 全书」的比例会算错
                    local page_units = valueFor(job.count_mode,
                        plain_u, punct_u, char_u, false)
                    -- **逐页路径也不能每页问一次
                    -- `getPageXPointer`**！
                    self:_recordPageUnits(job, scan_doc, job.page, page_units)
                else
                    self:_recordPageUnits(job, scan_doc, job.page, 0)
                end
            end
            job.page = job.page + 1
            end
        end

        -- 内存闸门：每个 tick 检查一次剩余内存。
        -- 跌破安全线就**立刻停手**，按已扫页数的比例估算剩下部分 ——
        -- 扫到一半被内核 SIGKILL，用户连结果都拿不到，还不如早点给个约数。
        if job.page <= job.page_count then
            local critical, avail = Mem.critical()
            if critical then
                logger.warn("WordCount: memory critical (" .. Mem.describe()
                    .. ", abort line=" .. tostring(Mem.ABORT_AVAIL_MB) .. "MB), stop at page "
                    .. tostring(job.page - 1) .. "/" .. tostring(job.page_count) .. " → estimate")
                job.memory_stopped = true
                job.memory_stop_page = job.page - 1
                job.sampled = true
                job.whole_book = false
                job.page = job.page_count + 1
            end
        end

        if job.page <= job.page_count then
            local done = job.page - 1
            local percent = math.floor(done * 100 / job.page_count + 0.5)
            -- 进度上报频率（20-flicker-fix 重写）。
            local progress_step = math.max(1, math.min(PAGES_PER_TICK,
                math.ceil(job.page_count / 20)))
            -- 时间源只 require 一次，缓存在模块级。
            local now_t = 0
            if _now then
                now_t = _now()
            else
                now_t = os.time()
            end
            local time_ok = (not job.last_progress_time)
                or (now_t - job.last_progress_time) >= PROGRESS_REPORT_INTERVAL
            if job.progress_dialog
                    and (done - job.last_progress_page >= progress_step)
                    and time_ok then
                job.progress_dialog:updateProgress(done)
                job.last_progress_page = done
                job.last_progress_time = now_t
            end
            -- 扫描期间**不发任何通知弹窗**（22-progress-only）。
            if not job.progress_dialog and done >= job.next_notice then
                notifyUser(T(_("正在统计全书：%1 / %2 页（%3%）"),
                    done, job.page_count, percent))
                job.next_notice = job.next_notice
                    + math.max(1, math.floor(job.page_count / 4))
            end
            -- 省电（22-progress-only）：每 CHUNK_TICKS 个 tick 让 CPU 休息一下。
            job.tick_count = (job.tick_count or 0) + 1
            -- **主动 GC**，压住内存峰值。
            if job.tick_count % 8 == 0 then
                collectgarbage("step")
            end
            local rest = (job.tick_count % CHUNK_TICKS == 0)
            -- 休息点顺带做一次**全量** GC：此刻本来就要空转 CHUNK_REST_DELAY 秒，
            -- 停顿被藏在空闲里，用户完全感知不到，但内存能被彻底收回。
            if rest then
                collectgarbage("collect")
            end
            UIManager:scheduleIn(rest and CHUNK_REST_DELAY or SCAN_TICK_DELAY, step)
            return
        end

        self._job = nil
        Mem.endScan()
        -- 块模式一路扫到最后一页 = 覆盖了全书，语义等同原来的「整书一次取完」，
        -- 下游据此禁止外推（数完就是数完了，不是估算）。
        if job.block_scan and not job.memory_stopped then
            job.whole_book = true
        end
        if job.progress_dialog then job.progress_dialog:updateProgress(job.page_count, true) end
        releaseBackgroundDocument()
        -- 关掉后台文档后立刻全量回收一次。
        -- 批量连跑几十本时，上一本的 native 内存不一定会还给系统，下一本再叠上来
        -- 就可能触顶；此刻正在写结果/准备提示，停顿被藏在里面，用户感知不到。
        collectgarbage("collect")
        if job.failed_pages > 0 then
            if job.progress_dialog and type(job.progress_dialog.setStatus) == "function" then
                job.progress_dialog:setStatus(T(_("扫描完成，但有 %1 页失败：%2"),
                    job.failed_pages, job.first_error or _("未知错误")))
            end
            if self:_batchAlive(job) then job.batch.skipped = job.batch.skipped + 1 end
            notifyUser(T(_("有 %1 页提取失败，未保存统计结果。首个错误：%2"),
                job.failed_pages, job.first_error or _("未知错误")))
            if self:_batchAlive(job) then
                job.progress_dialog = nil      -- 交给下一本复用，不关
                self:_startNextBatch()
            elseif job.progress_dialog then
                local dlg = job.progress_dialog
                job.progress_dialog = nil
                UIManager:scheduleIn(5, function() pcall(dlg.close, dlg) end)
            end
            return
        end
        if job.pages_with_text == 0 then
            if job.progress_dialog and type(job.progress_dialog.setStatus) == "function" then
                job.progress_dialog:setStatus(_("扫描完成，但没有提取到可读文本（可能需要 OCR）"))
            end
            if self:_batchAlive(job) then job.batch.skipped = job.batch.skipped + 1 end
            notifyUser(_("没有提取到可读文本；扫描版 PDF 需要先进行 OCR。本次未保存字数。"))
            if self:_batchAlive(job) then
                job.progress_dialog = nil
                self:_startNextBatch()
            elseif job.progress_dialog then
                local dlg = job.progress_dialog
                job.progress_dialog = nil
                UIManager:scheduleIn(5, function() pcall(dlg.close, dlg) end)
            end
            return
        end

        local settings = self.ui and self.ui.document and self.ui.document.file == path
            and self.ui.doc_settings or DocSettings:open(path)
        if not settings or type(settings.saveSetting) ~= "function" then
            settings = DocSettings:open(path)
        end
        -- 抽页模式的结果要从「样本页字数」外推到「全书字数」。
        -- 三种口径同时外推，存起来后切换口径不用重扫。
        local sample_plain = tonumber(job.state.count) or 0
        local sample_punct = tonumber(job.state.count_punct) or sample_plain
        local sample_char = tonumber(job.state.count_char) or sample_punct
        local total_plain, total_punct = sample_plain, sample_punct
        local total_char = sample_char
        local mode = job.count_mode or countModeOf(path)
        local total
        local sampled = job.sampled == true
        if job.whole_book == true then
            -- 整书一次数完 → 本身即全书口径，禁止外推。
            sampled = false
        end
        if sampled then
            local eff = tonumber(job.pages_with_text) or 0
            if eff <= 0 then eff = tonumber(job.page_count) or 1 end
            if eff > 0 then
                local full_pages = tonumber(job.total_pages) or job.page_count
                total_plain = math.floor(sample_plain / eff * full_pages + 0.5)
                total_punct = math.floor(sample_punct / eff * full_pages + 0.5)
                total_char = math.floor(sample_char / eff * full_pages + 0.5)
            end
        end
        total = valueFor(mode, total_plain, total_punct, total_char, false)
        logger.info("WordCount: result plain=" .. tostring(total_plain)
            .. " punct=" .. tostring(total_punct)
            .. " chars=" .. tostring(total_char)
            .. " scan_pages=" .. tostring(job.page_count)
            .. " total_pages=" .. tostring(job.total_pages)
            .. " sampled=" .. tostring(sampled)
            .. " mode=" .. tostring(mode)
            .. " final_total=" .. tostring(total))

        -- 把外推后的总量回写到 state，让下游（读状态、全局统计、
        -- 提示文案）拿到的是**全书**口径，而不是样本口径。
        job.state.count = total_plain
        job.state.count_punct = total_punct
        job.state.count_char = total_char

        settings:saveSetting(KEY_COUNT, total_plain)
        settings:saveSetting(KEY_COUNT_PUNCT, total_punct)
        settings:saveSetting(KEY_COUNT_CHAR, total_char)
        settings:saveSetting(KEY_MTIME, job.mtime)
        settings:saveSetting(KEY_SIZE, job.size)
        -- 记录「这个数字是怎么来的」：下次读缓存时能告诉用户「这是估算值，
        -- 想看精确的就点重新统计」。旧版本没有这个键 → 当作精确值（向后兼容）。
        if sampled then
            settings:saveSetting(KEY_ESTIMATED, true)
            -- 这里以前存的是 job.page_count，那只是
            -- **扫描上限**（前 100 页），而外推的分母其实是**有文本的页数**
            -- （job.pages_with_text，例如只有 80 页有字）。拿 100 去展示
            -- 「依据：前 100 页推算」会**夸大样本量、让用户低估误差**。
            local eff_pages = tonumber(job.pages_with_text) or 0
            if eff_pages <= 0 then eff_pages = tonumber(job.page_count) or 0 end
            settings:saveSetting(KEY_SAMPLED_PAGES, eff_pages)
        else
            settings:saveSetting(KEY_ESTIMATED, nil)
            settings:saveSetting(KEY_SAMPLED_PAGES, nil)
        end
        settings:flush()
        -- 同时写全局缓存 —— 下次点「统计全书字数」
        do
            local cur_mtime, cur_size = fileFingerprint(path)
            writeCachedCount(path, total_plain, total_punct, total_char,
                cur_mtime or job.mtime, cur_size or job.size, sampled)
        end

        -- 26-sample-estimate 修的一个真 bug：
        -- 这两处以前传的是 job.page_count。抽页模式下 job.page_count 已经
        -- 变成「扫描上限」（100），不是全书页数 —— 若照旧传下去：
        -- 1) read_state.page_count = 100（这本 1000 页的书）
        local sampled_run = job.sampled == true
        local function applySampledPageUnits(state)
            if not state or type(state.page_units) ~= "table" then return end
            local has_units = next(state.page_units) ~= nil
            local has_seconds = type(state.page_seconds) == "table"
                and next(state.page_seconds) ~= nil
            if sampled_run and (has_units or has_seconds) then
                -- 已有真实数据（逐页字数或阅读时长）：保留，不覆盖
                return
            end
            for key, units in pairs(job.page_units) do
                ReadingStats.setEstimatedPageUnits(state, key, units)
            end
        end
        local read_state
        if self.ui and self.ui.document and self.ui.document.file == path then
            read_state = self:_ensureReadState(scan_doc, path, job.total_pages)
            applySampledPageUnits(read_state)
            self:_saveReadState(true)
        else
            read_state = settings:readSetting(KEY_READ_STATS)
            if not ReadingStats.isValidForFile(read_state, job.total_pages, job.mtime, job.size) then
                read_state = ReadingStats.newState(job.total_pages, job.mtime, job.size)
            end
            applySampledPageUnits(read_state)
            ReadingStats.recompute(read_state)
            read_state.updated_at = os.time()
            settings:saveSetting(KEY_READ_STATS, read_state)
            settings:flush()
        end
        self._scan_path = path
        -- 扫描收尾立刻落盘（force_flush=true）——用户扫完就等着看
        -- 总览数字，不能让它卡在「第 8 次才写」的批次里。
        self:_syncGlobalBook(read_state, false, path, nil, true)
        self._scan_path = nil
        if self:_batchAlive(job) then job.batch.completed = job.batch.completed + 1 end
        -- 是否处于「一个批次里」要看 self._batch，而不是 batch_mode 参数：
        -- startCountForPath（从书菜单点单本）也会传 batch_mode=true，但它
        -- 根本不是批量任务（self._batch 为 nil），对话框必须照常关闭。
        local in_batch = self:_batchAlive(job)
        -- 结果文案：主数字按当前口径，后面附带另一个参照值。
        -- 用户拿它和晋江/起点的书页字数一比就知道该用哪种口径。
        local count_label = modeLabel(mode)
        local other_total, other_label
        if mode == "plain" then
            other_total, other_label = total_punct, _("含标点")
        else
            -- 含标点 / 严格字符数：都附带「只算文字」这个基准值，
            -- 它是最不容易混淆的那个数（标点、字母都不另算）。
            other_total, other_label = total_plain, _("只算文字")
        end
        -- 开了「按来源设定口径」就把来源一起标出来，
        -- 用户一眼能确认「这次用的是哪条规则」，不用去菜单里翻。
        if SourcePolicy.enabled() then
            local src_name = SourcePolicy.displayName(SourcePolicy.platformOf(path))
            if src_name then count_label = count_label .. " · " .. src_name end
        end
        local function resultLine()
            if job.memory_stopped then
                -- 内存不足提前停手：必须说清这是「前 N 页推算出来的约数」，
                -- 否则用户会拿这个数去和平台对账，越对越糊涂。
                return T(_("内存不足：只统计了前 %1 / %2 页，全书约 %3 字"),
                    fmtCount(job.memory_stop_page or 0), fmtCount(job.page_count),
                    fmtCount(total))
            end
            local line = T(_("统计完成：%1 字（%2）"), fmtCount(total), count_label)
            if tonumber(other_total) and other_total > 0 and other_total ~= total then
                line = line .. T(_("；%1 %2"), other_label, fmtCount(other_total))
            end
            return line
        end
        -- 完成结果也走对话框，不走弹窗。
        if job.progress_dialog then
            if type(job.progress_dialog.setStatus) == "function" then
                -- 如果是「书太大被强制降级」，明说是估算、并说明原因，
                -- 否则用户会以为我们把他要的精确值做错了。
                if job.huge_book_forced_sample then
                    job.progress_dialog:setStatus(
                        T(_("书太大（%1 页），为防卡死改用估算：全书约 %2 字"),
                            fmtCount(total_pages), fmtCount(total)))
                else
                    job.progress_dialog:setStatus(resultLine())
                end
            end
            job.progress_dialog:updateProgress(job.page_count, true)
            if not in_batch then
                local dlg = job.progress_dialog
                job.progress_dialog = nil
                UIManager:scheduleIn(3, function() pcall(dlg.close, dlg) end)
            else
                job.progress_dialog = nil
            end
        else
            -- 只在「压根没有对话框」时才退回弹窗（兜底，正常不会走到）
            if job.huge_book_forced_sample then
                notifyUser(T(_("书太大（%1 页），为防卡死改用估算：全书约 %2 字"),
                    fmtCount(total_pages), fmtCount(total)))
            else
                notifyUser(resultLine())
            end
        end
        if batch_mode and in_batch then self:_startNextBatch() end
        -- 如果这次扫描是「打开阅读统计」时顺带起的（当前书没数据），
        -- 扫完就把统计页打开 —— 这就是用户要的「打开时有扫描 → 显示进度条 →
        -- 扫完看到数字」。
        self:_maybeOpenStatisticsAfterScan()
    end

    UIManager:scheduleIn(SCAN_TICK_DELAY, step)
end

function WordCount:onCloseDocument()
    -- Do not cancel a full-book scan here. The next scheduled step reopens a
    -- private document reference, so the job can continue on the Bookshelf.
    if self._job and self._job.doc == self.ui.document then
        self._job.doc = nil
    end
    self:_finishPageTimer(true)
    if self._read_dirty then self:_saveReadState(true) end
    self:_syncNotes(true)
    self:_saveGlobalStats(true)
    self._read_state = nil
    self._read_settings = nil
    self._read_doc_path = nil
    self._read_page_count = nil
    self._notes_seen = nil
end

return WordCount
