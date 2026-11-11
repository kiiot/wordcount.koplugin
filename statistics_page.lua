--[[--
阅读统计页面：卡片网格 + 趋势图，日 / 周 / 月 / 年 / 总 分段切换。

改这个文件前先记住几条踩过的坑：
  * 目标环境是 LuaJIT(5.1)：不要用 //、位运算、goto、math.log(x, base)。
  * 像素换算走 Screen:scaleBySize，不要按固定系数硬折。
  * Blitbuffer:paintCircle 的 w 默认 = r ⇒ 实心；最小可用半径 2。
  * ScrollableContainer 需要 dimen + show_parent。
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
-- KeyValuePage 已不再使用（下钻改成同级的 DrillDownPopup 浮窗）。
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.*/)statistics_page%.lua$") or "./")
local GlobalStats = dofile(plugin_dir .. "global_stats.lua")

local M = {}

--==========================================================================
-- 数值格式化
--==========================================================================

local function trimZero(text)
    return (tostring(text):gsub("%.0$", ""))
end

local function groupDigits(n)
    local reversed = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (reversed:gsub("^,", ""))
end

local function unitFormatMode()
    local mode = G_reader_settings and G_reader_settings:readSetting("word_count_unit_format")
    if mode == "full" or mode == "wan" or mode == "auto"
            or mode == "k" or mode == "qian" then
        return mode
    end
    return "auto"
end

local function formatCount(value)
    local n = math.max(0, math.floor(tonumber(value) or 0))
    local mode = unitFormatMode()
    if mode == "full" then return groupDigits(n) end
    if mode == "k" and n >= 1000 then
        return trimZero(string.format("%.1f", n / 1000)) .. "k"
    end
    if mode == "qian" and n >= 1000 then
        return trimZero(string.format("%.1f", n / 1000)) .. _("千")
    end
    if mode == "wan" and n >= 10000 then
        return trimZero(string.format("%.1f", n / 10000)) .. _("万")
    elseif n >= 100000000 then
        return trimZero(string.format("%.1f", n / 100000000)) .. _("亿")
    elseif mode ~= "full" and n >= 10000 then
        return trimZero(string.format("%.1f", n / 10000)) .. _("万")
    end
    return groupDigits(n)
end

-- 大数字 + 小单位的拆分，供卡片排版用。
-- @return array of { text = string, big = boolean }
local function formatCountParts(value, unit)
    local n = math.max(0, math.floor(tonumber(value) or 0))
    unit = unit or ""
    local mode = unitFormatMode()
    if mode == "full" then
        return {{ text = groupDigits(n), big = true }, { text = unit, big = false }}
    elseif mode == "k" and n >= 1000 then
        return {
            { text = trimZero(string.format("%.1f", n / 1000)), big = true },
            { text = "k" .. unit, big = false },
        }
    elseif mode == "qian" and n >= 1000 then
        return {
            { text = trimZero(string.format("%.1f", n / 1000)), big = true },
            { text = _("千") .. unit, big = false },
        }
    elseif mode == "wan" and n >= 10000 then
        return {{ text = trimZero(string.format("%.1f", n / 10000)), big = true }, { text = _("万") .. unit, big = false }}
    elseif n >= 100000000 then
        return {
            { text = trimZero(string.format("%.1f", n / 100000000)), big = true },
            { text = _("亿") .. unit, big = false },
        }
    elseif n >= 10000 then
        return {
            { text = trimZero(string.format("%.1f", n / 10000)), big = true },
            { text = _("万") .. unit, big = false },
        }
    end
    return {
        { text = groupDigits(n), big = true },
        { text = unit, big = false },
    }
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if days > 0 then return T(_("%1天%2小时"), days, hours) end
    if hours > 0 then return T(_("%1小时%2分钟"), hours, minutes) end
    if minutes > 0 then return T(_("%1分钟"), minutes) end
    return T(_("%1秒"), seconds % 60)
end

-- "2 小时 1 分钟" 拆成 { "2"(大), "小时"(小), "1"(大), "分钟"(小) }
local function formatDurationParts(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if days > 0 then
        if hours > 0 then
            return {
                { text = tostring(days), big = true }, { text = _("天"), big = false },
                { text = tostring(hours), big = true }, { text = _("小时"), big = false },
            }
        end
        return { { text = tostring(days), big = true }, { text = _("天"), big = false } }
    end
    if hours > 0 then
        if minutes > 0 then
            return {
                { text = tostring(hours), big = true }, { text = _("小时"), big = false },
                { text = tostring(minutes), big = true }, { text = _("分钟"), big = false },
            }
        end
        return { { text = tostring(hours), big = true }, { text = _("小时"), big = false } }
    end
    if minutes > 0 then
        return { { text = tostring(minutes), big = true }, { text = _("分钟"), big = false } }
    end
    return { { text = tostring(seconds % 60), big = true }, { text = _("秒"), big = false } }
end

-- **删掉了 `compactDuration`**（原「图表 Y 轴刻度用的
-- 紧凑时长」）。它的唯一调用者是 `metricAxisText`，而 `metricAxisText`
-- 唯一的调用者是趋势图那行图例的「虚线＝本期平均 X」—— 41 把均值虚线
-- 连同图例那半句一起删了，这条调用链整条断掉，两个函数都成了死代码。

-- 环比用的纯文本
local function deltaText(kind, value)
    value = math.max(0, tonumber(value) or 0)
    if kind == "duration" then return formatDuration(value) end
    if kind == "units" then return formatCount(value) .. " " .. _("字") end
    if kind == "speed" then return formatCount(value) .. " " .. _("字/分钟") end
    if kind == "books" then return T(_("%1 本"), math.floor(value)) end
    if kind == "notes" then return T(_("%1 条"), math.floor(value)) end
    return T(_("%1 天"), math.floor(value))
end

local function deltaArrow(value)
    return (tonumber(value) or 0) >= 0 and "\u{2191} " or "\u{2193} "
end

-- Y 轴刻度的"好看"上限：把 max 向上取到 1 / 1.2 / 1.6 / 2 / 2.4 / 3 / 4 / 5 / 6 / 8 / 10 倍数量级。
-- 这样 4 等分后的刻度也都是整数（25% / 30% / 40% / 50% ...）。
local function niceMax(value)
    value = tonumber(value) or 0
    if value <= 0 then return 1 end
    local magnitude = 10 ^ math.floor(math.log(value) / math.log(10))
    local normalized = value / magnitude
    local steps = { 1, 1.2, 1.6, 2, 2.4, 3, 4, 5, 6, 8, 10 }
    for _i, step in ipairs(steps) do
        if normalized <= step + 1e-9 then return step * magnitude end
    end
    return 10 * magnitude
end

local function metricValueText(value, metric)
    value = tonumber(value) or 0
    if metric == "seconds" or metric == "average" then
        return formatDuration(value)
    elseif metric == "speed" then
        return formatCount(value) .. " " .. _("字/分钟")
    end
    return formatCount(value) .. " " .. _("字")
end

-- **删掉了 `metricAxisText`**（原「Y 轴刻度那种紧凑
-- 写法」）。它唯一的调用者是已删的均值虚线图例。列值文案现在只有两条路：
-- · `metricValueText` —— 列表视图那种**带单位**的完整写法；
-- · `chartBarLabel`   —— 柱顶那种**不带单位**的裸数字。

-- 整张图**统一一个单位**，柱顶标签只写数字。
-- ⚠ 旧方案是**逐值**挑单位的（那个函数 41 已删）：927 秒 →「15分」、
-- 83 秒 →「83秒」—— 同一张图里混着「分」和「秒」，那就不叫
-- 「单位统一」，也就没法省。所以这里改成**按整张图的量级选一次**：
-- scale_max 决定这张图用秒 / 分 / 小时。
local function chartUnit(metric, scale_max)
    if metric == "seconds" or metric == "average" then
        local top = tonumber(scale_max) or 0
        if top >= 3600 then
            return { suffix = _("小时"), div = 3600 }
        elseif top >= 120 then
            return { suffix = _("分"), div = 60 }
        end
        return { suffix = _("秒"), div = 1 }
    elseif metric == "speed" then
        return { suffix = _("字/分钟"), div = 1 }
    end
    return { suffix = _("字"), div = 1 }
end

-- 柱顶数值标签：**只写数字**，不带单位（单位由 chartUnit 决定、写在标题上）。
-- ⚠ 数值口径必须与卡片 / 列表完全一致（都走 formatCount），
-- 否则同一根柱子上的数字会和卡片对不上。
local function chartBarLabel(value, unit)
    value = math.max(0, tonumber(value) or 0)
    if unit and unit.div and unit.div > 1 then
        local v = value / unit.div
        if v < 10 then return trimZero(string.format("%.1f", v)) end
        return tostring(math.floor(v + 0.5))
    end
    return formatCount(value)
end

--==========================================================================
-- 字体
--==========================================================================

local FACES

local function faces()
    if FACES then return FACES end
    FACES = {
        -- 用户要求「字体放大一点」。整体上调 2~4 px。
        value_big = Font:getFace("cfont", 32),
        value_small = Font:getFace("cfont", 19),
        label = Font:getFace("smallinfofont", 19),
        delta = Font:getFace("smallinfofont", 18),
        tab = Font:getFace("cfont", 21),
        period = Font:getFace("cfont", 23),
        section = Font:getFace("cfont", 24),
        axis = Font:getFace("x_smallinfofont", 17),
        footer = Font:getFace("smallinfofont", 19),
        -- 柱顶数值标签专用字号。
        value = Font:getFace("x_smallinfofont", 13),
    }
    return FACES
end

--==========================================================================
-- 基础容器
--==========================================================================

-- 不画滚动条的滚动容器。
local NoBarScrollable = ScrollableContainer:extend{}

function NoBarScrollable:initState()
    ScrollableContainer.initState(self)
    -- 关键：crop 宽高已经在 initState 里按「有滚动条」减过一遍了，
    -- 这里把宽度补回来，否则右侧会空出一条无用的白边。
    if self._v_scroll_bar then
        self._crop_w = self.dimen.w
        self._v_scroll_bar = nil
    end
    if self._h_scroll_bar then
        self._crop_h = self.dimen.h
        self._h_scroll_bar = nil
    end
end

-- **禁止滑动**的固定面板。
local FixedPane = ScrollableContainer:extend{}

function FixedPane:init()
    -- ⚠ 上游 `ScrollableContainer:init()` 只认 `self.ignore_events`（字符串数组），
    -- 不认 `self.ignore` —— 所以必须写成数组形式。
    self.ignore_events = {
        "touch", "swipe", "hold", "hold_pan", "hold_release", "pan", "pan_release",
    }
    ScrollableContainer.init(self)
end

function FixedPane:initState()
    ScrollableContainer.initState(self)
    if self._v_scroll_bar then
        self._crop_w = self.dimen.w
        self._v_scroll_bar = nil
    end
    if self._h_scroll_bar then
        self._crop_h = self.dimen.h
        self._h_scroll_bar = nil
    end
end

-- 固定尺寸容器。
local FixedBox = WidgetContainer:extend{
    width = nil,
    height = nil,
    align = "left",          -- left | center | right
    vertical_align = "top",  -- top | center | bottom
}

function FixedBox:getSize()
    local child = self[1]
    local child_size = child and child:getSize()
    return Geom:new{
        x = 0, y = 0,
        w = self.width or (child_size and child_size.w) or 0,
        h = self.height or (child_size and child_size.h) or 0,
    }
end

function FixedBox:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    local child = self[1]
    if not child then return end
    local child_size = child:getSize()
    local cx, cy = x, y
    if self.align == "center" then
        cx = x + math.floor((size.w - child_size.w) / 2)
    elseif self.align == "right" then
        cx = x + size.w - child_size.w
    end
    if self.vertical_align == "center" then
        cy = y + math.floor((size.h - child_size.h) / 2)
    elseif self.vertical_align == "bottom" then
        cy = y + size.h - child_size.h
    end
    child:paintTo(bb, cx, cy)
end

-- 绝对定位容器：把若干子控件按 (x, y) 摆在固定尺寸的画布上。
-- 用于 Y 轴刻度列（垂直对齐网格线）和 X 轴刻度行（水平对齐柱子中心）。
local AbsoluteContainer = WidgetContainer:extend{
    width = nil,
    height = nil,
    items = nil, -- { { x = number, y = number, widget = Widget }, ... }
}

function AbsoluteContainer:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    -- 同时挂到数组部分，这样 WidgetContainer:free() 能正常回收
    for _i, item in ipairs(self.items or {}) do
        self[#self + 1] = item.widget
    end
end

function AbsoluteContainer:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    for _i, item in ipairs(self.items or {}) do
        item.widget:paintTo(bb, x + item.x, y + item.y)
    end
end

-- 可点击容器。
local TapBox = InputContainer:extend{
    on_tap = nil,
}

function TapBox:init()
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function TapBox:onTapSelect(arg, ges)
    if self.on_tap then
        local x, y
        if ges and ges.pos then x, y = ges.pos.x, ges.pos.y end
        return self.on_tap(x, y) and true or false
    end
    return false
end

--==========================================================================
-- 小组件工厂
--==========================================================================

local function text(str, face, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str,
        face = face,
        bold = opts.bold or false,
        fgcolor = opts.color or Blitbuffer.COLOR_BLACK,
        max_width = opts.max_width,
        truncate_with_ellipsis = opts.truncate ~= false,
        -- 可选的**垂直内边距覆盖**。
        -- ⇒ **每行文字凭空多 8px 高**（不是字号的 8px，是固定的 8px）。
        padding = opts.padding,
    }
end

-- 一个 face 在 `padding = 0` 时**单行占的像素高** —— 就是上游
-- `TextWidget:updateSize()`（ui/widget/textwidget.lua:113）算出来的 `_height`：
-- `_height = math.ceil(face.ftsize:getHeightAndAscender()) + 2*self.padding`
-- 这里要的是 `padding = 0` 的那部分，所以直接取 `ceil(ftsize:getHeightAndAscender())`。
local function faceLineH(face)
    if not face then return 0 end
    local ftsize = face.ftsize
    if ftsize then
        local ok, h = pcall(function() return ftsize:getHeightAndAscender() end)
        if ok and type(h) == "number" and h > 0 then
            return math.ceil(h)
        end
    end
    return math.ceil((face.size or 16) * 1.6)
end

-- 图标统一开 alpha：卡片/条带底色不是纯白时，IconWidget 默认会把图标压平到白色底上，
-- 那会在浅灰底上出现一圈白边。
local function icon(name, size, opts)
    opts = opts or {}
    return IconWidget:new{
        icon = name,
        width = size,
        height = size,
        alpha = true,
        dim = opts.dim or false,
        -- 同时接受 opts.invert 和旧名 opts.white（历史上用的是 white）。
        -- IconWidget 真正认的字段是 `invert`（把图标反色）。
        invert = opts.invert or opts.white or false,
    }
end

--==========================================================================
-- 趋势图
--==========================================================================

-- 网格线删掉之后，这个常量**只剩「图高 = 4 行」一个作用**
-- （唯一用途是 buildTrendSection 的 `chart_h = row_h * TREND_ROWS`）。
local TREND_ROWS = 4

-- **删掉了 `trendBucketLabels(period, count)`**。

-- 一根柱子在给定绘图高度下的像素高度。
local function barPixelHeight(value, scale_max, plot_h, min_bar_h)
    value = tonumber(value) or 0
    local bar_h = math.floor(plot_h * value / scale_max + 0.5)
    if value > 0 and bar_h < min_bar_h then bar_h = min_bar_h end
    return bar_h
end

-- **删掉了均值参考线**（`trendMean` + `meanLineY`）。
-- ⚠ 删除理由（用户给过两次信号）：39 那轮把这条线从纯黑降成深灰
-- （「不需要参照线加强」），41 直接说「去掉」。也就是说 ——
-- 用户并不需要「本期平均」这个参照：每根柱子顶上已经写着自己的数值
-- （40-unit-free），而「日均阅读时长」这个**口径完全相同**的数字

-- 把 buckets 画成位图。返回 ImageWidget。
local function buildChartImage(buckets, selected_index, width, height, scale_max)
    local bb_type = (Screen.bb and Screen.bb:getType()) or Blitbuffer.TYPE_BB8
    local bb = Blitbuffer.new(width, height, bb_type)
    bb:fill(Blitbuffer.COLOR_WHITE)

    if not scale_max then
        local maximum = 0
        for _i, bucket in ipairs(buckets) do
            maximum = math.max(maximum, tonumber(bucket.value) or 0)
        end
        scale_max = niceMax(maximum)
    end
    -- **横向网格线也删掉了**（原来这里有 3 条浅灰点线）。
    -- ⚠ 注意这里删的是**网格线**，不是基线：基线（最下面那条纯黑实线）

    local count = math.max(1, #buckets)
    local slot = width / count
    -- 柱子加粗（用户：「实心柱可以粗一点」）。0.6 → 0.8。
    -- ⚠ 下限 2px 是 e-ink 的安全线：300dpi 上约 0.17mm。再细相邻柱
    -- 在灰阶抖动下就糊成一片了 —— 所以不写 `floor(slot) - 1`。
    local bar_gap = math.max(2, math.floor(slot * 0.08))
    local bar_w = math.max(1, math.floor(slot) - bar_gap)
    local min_bar_h = math.max(2, Screen:scaleBySize(2))
    for i, bucket in ipairs(buckets) do
        local value = tonumber(bucket.value) or 0
        local bar_h = barPixelHeight(value, scale_max, height, min_bar_h)
        if bar_h > 0 then
            local x = math.floor((i - 1) * slot + (slot - bar_w) / 2)
            -- **所有柱子一律实心填充**（用户：「统计图都用实心的条条」）。
            -- ⚠ 本文件**不再有任何 paintBorder 调用**。32 的注释说的「不要灰色」
            if i == selected_index then
                bb:paintRect(x, height - bar_h, bar_w, bar_h, Blitbuffer.COLOR_BLACK)
            else
                bb:paintRect(x, height - bar_h, bar_w, bar_h, Blitbuffer.COLOR_LIGHT_GRAY)
            end
        end
    end

    -- **均值虚线也删掉了**（原来这里有一段
    -- 「12px 长划线 + 8px 间隔、COLOR_DARK_GRAY(0x88)」的绘制代码）。

    local base_h = math.max(1, Size.line.medium)

    bb:paintRect(0, height - base_h, width, base_h, Blitbuffer.COLOR_BLACK)

    return ImageWidget:new{ image = bb }
end

-- 标签宽高的缓存。
-- ⚠ 缓存键**只有字符串**（把 face 当成固定的）。若以后把 faces().value 的字号
-- 做成可配置的、或允许用户改字号，这里必须跟着清缓存，
-- 否则会拿旧字号量出来的宽度去排版，标签就会歪。
local LABEL_METRICS = {}
local LABEL_METRICS_LIMIT = 512

local function labelMetrics(s, face)
    -- 缓存键**带上 face**。
    local key = (face and (tostring(face) .. "\1") or "") .. s
    local m = LABEL_METRICS[key]
    if m then return m end
    -- 防御性上限：正常用不到（标签文案的取值集合很有限），
    -- 但万一某天有人把日期/书名拼进标签，这里兜住内存。
    local n = 0
    for _ in pairs(LABEL_METRICS) do n = n + 1 end
    if n >= LABEL_METRICS_LIMIT then LABEL_METRICS = {} end
    local probe = text(s, face, { color = Blitbuffer.COLOR_BLACK })
    local size = probe:getSize()
    m = { w = size.w, h = size.h }
    pcall(probe.free, probe)
    LABEL_METRICS[key] = m
    return m
end

-- 柱顶数值标签的绝对定位表。
-- ⇒ 前提是 `buildTrendSection` 在图的上面**显式留了一块** VerticalSpan
-- （40-no-y-axis 之后由它负责，之前是 Y 轴刻度列比图高一行白送的 62px）。
local function chartValueLabels(buckets, unit, selected_index, width, height, scale_max)
    local f = faces()
    local count = #buckets
    if count == 0 then return {} end
    local slot = width / count
    -- 标签之间的**最小缝**从 scaleBySize(6)=11px 收到 3px。
    local gap = Screen:scaleBySize(3)
    local min_bar_h = math.max(2, Screen:scaleBySize(2))

    local texts = {}
    for i, bucket in ipairs(buckets) do
        texts[i] = chartBarLabel(bucket.value, unit)
    end
    local label_h = labelMetrics(texts[1] or "0", f.value).h

    -- 第 i 个标签的水平位置（已按图宽夹紧）与宽度。
    local function label_x(i)
        local w = labelMetrics(texts[i], f.value).w
        local x = math.floor((i - 1) * slot + slot / 2 - w / 2)
        return math.max(0, math.min(x, width - w)), w
    end

    local items = {}
    local function place(i)
        local x, w = label_x(i)
        -- 标签外面套一层**白底**：图上每隔一段就有一条虚线网格，
        -- 文字直接压上去会从笔画缝里透出灰点，很难看。
        local widget = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            margin = 0,
            padding = 0,
            text(texts[i] or "", f.value, { color = Blitbuffer.COLOR_BLACK }),
        }
        local bar_h = barPixelHeight(buckets[i] and buckets[i].value,
            scale_max, height, min_bar_h)
        items[#items + 1] = {
            x = x,
            y = height - bar_h - label_h - gap,
            widget = widget,
        }
        return x, x + w
    end

    -- **值为 0 的桶不标数值**。
    local function has_value(i)
        local v = buckets[i] and tonumber(buckets[i].value) or 0
        return v > 0
    end

    -- 锚点 = 选中柱（越界/缺省都夹回合法范围）
    local anchor = tonumber(selected_index) or 1
    anchor = math.max(1, math.min(count, anchor))

    -- **最高柱必须标上数值**。
    -- ⚠ 代价说清楚：最高柱和它邻居的标签**可能真的二选一**（上面那个例子
    -- 里 700 就会被挤掉）。这是几何上的硬约束 —— 31 个桶、标签比 slot
    -- 还宽时怎么摆都会叠。用户的诉求是「最长的柱子要有数」，所以优先级
    -- 排在 700 前面。**宁可少标一根矮的，也不能让最高那根空着。**
    local placed = {}   -- { {x1, x2}, ... } 已放置标签的区间
    local function overlaps(x, w)
        local x1, x2 = x, x + w
        for _i, p in ipairs(placed) do
            if x1 < p[2] + gap and p[1] < x2 + gap then return true end
        end
        return false
    end
    local function try_place(i)
        if not has_value(i) then return false end
        local x, w = label_x(i)
        if overlaps(x, w) then return false end
        placed[#placed + 1] = { x, x + w }
        place(i)
        return true
    end

    -- ① 选中柱
    try_place(anchor)

    -- ② 最高柱（跳过 0 桶；与选中柱重合时 try_place 会被 overlaps 自动挡掉）
    local max_index, max_value = 0, 0
    for i, bucket in ipairs(buckets) do
        local v = tonumber(bucket.value) or 0
        if v > max_value then max_index, max_value = i, v end
    end
    if max_index > 0 and max_index ~= anchor then
        try_place(max_index)
    end

    -- ③ 其余：从选中柱向左右各扫一遍。
    -- ⚠ 跳过 0 桶时什么都不做 —— 被跳过的桶没有占位，不该影响别的判定。
    for i = anchor - 1, 1, -1 do
        try_place(i)
    end
    for i = anchor + 1, count do
        try_place(i)
    end
    return items
end

-- 图表 = 柱状位图 + 柱顶数值标签，叠在一个绝对定位容器里。
local function buildChartWidget(buckets, unit, selected_index, width, height, scale_max)
    local image = buildChartImage(buckets, selected_index, width, height, scale_max)
    local labels = chartValueLabels(buckets, unit, selected_index, width, height, scale_max)
    if #labels == 0 then return image end
    local items = { { x = 0, y = 0, widget = image } }
    for _i, item in ipairs(labels) do items[#items + 1] = item end
    return AbsoluteContainer:new{ width = width, height = height, items = items }
end

-- **Y 轴刻度列已删除**。
-- ⚠ 上面这段是 40 那轮写的。**41 已经把横向网格虚线也删了** ——
-- 当时以为「网格线不是轴、是辅助线，可以留」，用户随后明确说
-- 「y 轴的刻度怎么没去掉」，指的就是这几条线（见 buildChartImage 里的注释）。

-- X 轴刻度文字「**只写变化的部分**」。
-- ⚠ 三点刻意的取舍，都写在这里免得以后当成 bug 改掉：
-- · **第一格也不留年份**。用户说的是「只有12月和一月中间下方位置
-- 显示过渡的年份」——「只有」把第一格也排除了。
local function compactTickLabels(labels)
    local out = {}
    local prev_year
    for i, raw in ipairs(labels) do
        local s = tostring(raw)
        local yy, rest = s:match("^(%d%d)年(.+)$")
        if yy then
            if prev_year ~= nil and yy ~= prev_year then
                out[i] = s        -- 跨年那一格：保留「26年01月」
            else
                out[i] = rest     -- 其余各格：只留「11月」
            end
            prev_year = yy
        else
            out[i] = s            -- 没有年份前缀的（日期/时间/星期/月）原样
        end
    end
    return out
end

-- X 轴刻度行：按每个柱子的中心 x 绝对定位。
local function buildTickRow(buckets, chart_width, tick_height, color)
    local f = faces()
    local raw_labels = {}
    for i, bucket in ipairs(buckets) do
        raw_labels[i] = tostring((bucket and bucket.label) or i)
    end
    local labels = compactTickLabels(raw_labels)
    local bucket_count = math.max(1, #labels)
    local slot = chart_width / bucket_count

    -- **改成「按实际宽度贪心摆放」**，不再用固定 stride 隔格丢。
    -- ⇒ 压缩后的标签（「11月」约 35px）在 ≈70px 的 slot 里全都放得下，
    -- 12 个月一个不落。
    local min_gap = Screen:scaleBySize(4)
    local items = {}
    local placed_right = nil   -- 上一个已放下刻度的右边界（判重叠用）
    for i = 1, bucket_count do
        local widget = text(labels[i] or tostring(i), f.axis, { color = color })
        local w = widget:getSize().w
        local x = math.floor((i - 1) * slot + slot / 2 - w / 2)
        x = math.max(0, math.min(x, chart_width - w))
        local keep_year = labels[i] ~= nil and labels[i]:find("年", 1, true) ~= nil
        local forced = keep_year or (i == bucket_count)
        local fits = (placed_right == nil) or (x >= placed_right + min_gap)
        if forced or fits then
            if forced and not fits and #items > 0 then
                table.remove(items)   -- 撤掉挡住保底格的那一格
            end
            items[#items + 1] = { x = x, y = 0, widget = widget }
            placed_right = x + w
        end
    end
    local row = AbsoluteContainer:new{
        width = chart_width,
        height = tick_height,
        items = items,
    }
    -- 刻度文字在行内垂直居中
    for _i, item in ipairs(items) do
        item.y = math.floor((tick_height - item.widget:getSize().h) / 2)
    end
    return row
end

-- 前向声明：这两个控件在文件后半部分才定义，但**前面的函数体里已经用到**。
-- ⚠ 45f 修的真 bug：`buildHourlyActivityList` 行间用 `HRule`，而 `HRule` 的
-- local 定义在后面 ⇒ 打开**日视图**直接崩：
-- `plugins/wordcount.koplugin/statistics_page.lua:1251:
-- attempt to index global 'HRule' (a nil value)`
local SolidRect
local HRule
-- `anchorAtMonth` 定义在**文件后半**的选择器一节里
-- （原 :4329），而 `buildCalendarPage`（:3000 一带）比它早。
local anchorAtMonth

-- 趋势列表视图（图表视图的替代），每行「标签 …… 数值」。
-- ⚠ 这里必须说清楚是哪一种「点线」——两种长得像、含义完全不同：
-- · **导航线（leader dots）**：像目录那样，在**同一行内部**从左边标签
-- 一路点过去接到右边数值（`01 ......... 1,200`）。用户明确**不要**这个。
local function buildTrendList(buckets, metric, selected_index, width)
    local f = faces()
    local group = VerticalGroup:new{}
    local row_h = Screen:scaleBySize(34)
    for i, bucket in ipairs(buckets) do
        local is_selected = (i == selected_index)
        local color = Blitbuffer.COLOR_BLACK
        local left = text(tostring(bucket.label), f.axis, { color = color, bold = is_selected })
        local right = text(metricValueText(bucket.value, metric), f.footer, { color = color, bold = is_selected })
        local left_w = left:getSize().w
        local right_w = right:getSize().w
        local filler = math.max(0, width - left_w - right_w - Screen:scaleBySize(8))
        group[#group + 1] = FixedBox:new{
            width = width,
            height = row_h,
            align = "left",
            vertical_align = "center",
            HorizontalGroup:new{
                align = "center",
                left,
                HorizontalSpan:new{ width = filler },
                right,
            },
        }
        -- 行间水平点线（最后一行不加，见函数头注释）。
        if i < #buckets then
            group[#group + 1] = HRule:new{ width = width, dotted = true }
        end
    end
    return group
end

-- 日视图按小时展示实际发生过的阅读记录。
local function buildHourlyActivityList(buckets, width)
    local f = faces()
    local rows = {}
    local max_value = 0
    local total_seconds, total_units = 0, 0
    for i, bucket in ipairs(buckets) do
        local seconds = math.max(0, tonumber(bucket.seconds) or 0)
        local units = math.max(0, tonumber(bucket.units) or 0)
        total_seconds = total_seconds + seconds
        total_units = total_units + units
        if seconds > 0 or units > 0 then
            local value = seconds > 0 and seconds or units
            max_value = math.max(max_value, value)
            rows[#rows + 1] = {
                hour = i - 1,
                seconds = seconds,
                units = units,
                value = value,
            }
        end
    end

    local group = VerticalGroup:new{ align = "left" }
    if #rows == 0 then
        group[#group + 1] = FixedBox:new{
            width = width,
            height = Screen:scaleBySize(42),
            align = "center",
            vertical_align = "center",
            text(_("当天暂无阅读记录"), f.footer, { color = Blitbuffer.COLOR_BLACK }),
        }
        return group, total_seconds, total_units
    end

    -- **列宽与行高一律量出来**，不再写死像素。
    -- ⚠ 只有 `seconds > 0 or units > 0` 的小时才会进 rows（见上面的过滤），
    -- 所以实际行数通常是几个到十几个，不会真的排满 24 行。
    local time_texts, amount_texts = {}, {}
    local time_w, amount_w = 0, 0
    for i, row in ipairs(rows) do
        local next_hour = (row.hour + 1) % 24
        time_texts[i] = string.format("%02d:00–%02d:00", row.hour, next_hour)
        -- 数值并成**一行**（两行根本放不下，见上）：
        -- `1小时20分 · 1,234 字`
        amount_texts[i] = formatDuration(row.seconds) .. " · "
            .. formatCount(row.units) .. " " .. _("字")
        time_w = math.max(time_w, labelMetrics(time_texts[i], f.axis).w)
        amount_w = math.max(amount_w, labelMetrics(amount_texts[i], f.footer).w)
    end

    local gap = Screen:scaleBySize(8)
    local padding = Screen:scaleBySize(4)
    local bar_h = Screen:scaleBySize(12)
    local border = Screen:scaleBySize(1)
    -- 行高 = 两个字号里更高的那一行 + 上下留白（量出来的，不是拍脑袋的 40px）
    local row_h = math.max(
        labelMetrics("0", f.axis).h,
        labelMetrics("0", f.footer).h) + 2 * padding
    -- 两列各留 2px 气口：正好等于文字宽时，像素取整会把最后一个字符挤掉。
    local time_col = time_w + Screen:scaleBySize(2)
    local amount_col = amount_w + Screen:scaleBySize(2)
    local bar_w = math.max(Screen:scaleBySize(20),
        width - 2 * padding - time_col - amount_col - 2 * gap - 2 * border)

    for i, row in ipairs(rows) do
        local time_widget = text(time_texts[i], f.axis, { bold = true })
        local ratio = max_value > 0 and row.value / max_value or 0
        local fill_w = math.max(border, math.floor((bar_w - 2 * border) * ratio))
        -- 柱子加圆角（用户：「日的按小时记录列形式里的
        -- 柱子加一点圆角效果」）。
        local bar_r = Screen:scaleBySize(3)
        local bar = FixedBox:new{
            width = bar_w,
            height = bar_h,
            align = "left",
            vertical_align = "center",
            SolidRect:new{
                width = fill_w,
                height = math.max(1, bar_h - 2 * border),
                color = Blitbuffer.COLOR_BLACK,
                radius = bar_r,
            },
        }
        local content = HorizontalGroup:new{
            align = "center",
            FixedBox:new{
                width = time_col,
                height = row_h,
                align = "left",
                vertical_align = "center",
                time_widget,
            },
            HorizontalSpan:new{ width = gap },
            bar,
            HorizontalSpan:new{ width = gap },
            FixedBox:new{
                width = amount_col,
                height = row_h,
                align = "right",
                vertical_align = "center",
                text(amount_texts[i], f.footer, { bold = true }),
            },
        }
        group[#group + 1] = FixedBox:new{
            width = width,
            height = row_h,
            align = "left",
            vertical_align = "center",
            content,
        }
        if i < #rows then
            group[#group + 1] = HRule:new{
                width = width, height = border,
                color = Blitbuffer.COLOR_BLACK,
            }
        end
    end
    return group, total_seconds, total_units
end

--==========================================================================
-- 卡片
--==========================================================================

-- 卡片大数字的候选字号。宽度不够就整档降级，避免多列卡片互相压字。
-- 整体上调（用户要求字体更大）；同时因为改成多列，降级档位也保留。
local VALUE_SIZE_PAIRS = { { 32, 19 }, { 28, 17 }, { 23, 15 }, { 19, 13 }, { 16, 11 } }
local VALUE_FACES

local function valueFaces()
    if VALUE_FACES then return VALUE_FACES end
    VALUE_FACES = {}
    for i, pair in ipairs(VALUE_SIZE_PAIRS) do
        VALUE_FACES[i] = { Font:getFace("cfont", pair[1]), Font:getFace("cfont", pair[2]) }
    end
    return VALUE_FACES
end

-- 卡片**标签行 / 环比行**的字号梯子。
-- ⇒ 卡片宽度从 298px 掉到 221px（inner_w 280 → 203）。
local CARD_LABEL_SIZE_LADDER = { 19, 18, 17, 16, 15, 14, 13 }
local CARD_DELTA_SIZE_LADDER = { 18, 17, 16, 15, 14, 13 }

-- 在字号梯子里挑第一个「所有卡片都放得下」的字号。
local function pickCardFace(specs, field, avail, ladder, face_name)
    for _i, px in ipairs(ladder) do
        local face = Font:getFace(face_name, px)
        local ok = true
        for _j, spec in ipairs(specs) do
            local s = spec[field]
            if s and labelMetrics(s, face).w > avail then
                ok = false
                break
            end
        end
        if ok then return face end
    end
    -- 全都放不下：用最小那档，让 TextWidget 自己去折行（至少不崩）。
    return Font:getFace(face_name, ladder[#ladder])
end

local function buildValueRow(parts, inner_width, big_face, small_face)
    local row = HorizontalGroup:new{ align = "bottom" }
    for i, part in ipairs(parts) do
        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{
                width = Screen:scaleBySize(part.big and 5 or 2),
            }
        end
        row[#row + 1] = text(part.text, part.big and big_face or small_face, {
            bold = true,
            max_width = inner_width,
        })
    end
    return row
end

-- 给「大数字」也挑一个**所有卡片共用**的档位。
-- ⚠ 代价要说清楚：统一之后，原本能单独用 32 号的那几张（阅读字数 / 阅读天数
-- / 累计读过 / 读完书籍）会**跟着降**到共同档位。这是「一致」的必然代价，
-- 不是 bug。49 轮实测 4 列下共同档位是 `{23, 15}`（设备 42/27）。
local function pickValuePair(specs, inner_width)
    local sizes = valueFaces()
    for i = 1, #sizes do
        local pair = sizes[i]
        local ok = true
        for _j, spec in ipairs(specs) do
            local row = buildValueRow(spec.parts, inner_width, pair[1], pair[2])
            if row:getSize().w > inner_width then
                ok = false
                break
            end
        end
        if ok then return pair, i end
    end
    -- 连最小档都放不下：仍然用最小档（各片段自己有 max_width，会截断加省略号，
    -- 至少不会横向压出卡片外），保证「一致」这个前提不被打破。
    return sizes[#sizes], #sizes
end

-- 多三个可选参数 `label_face` / `delta_face` / `value_pair`
-- （由 buildCardGrid 按「所有卡片里最宽的那条」统一选出来，
-- 见 pickCardFace / pickValuePair）。
local function buildCardContent(spec, inner_width, label_face, delta_face, value_pair)
    local f = faces()
    label_face = label_face or f.label
    delta_face = delta_face or f.delta
    local group = VerticalGroup:new{}

    -- 第一行：大数字 + 小单位
    local value_row
    if value_pair then
        value_row = buildValueRow(spec.parts, inner_width, value_pair[1], value_pair[2])
    else
        local sizes = valueFaces()
        for i = 1, #sizes do
            value_row = buildValueRow(spec.parts, inner_width, sizes[i][1], sizes[i][2])
            if value_row:getSize().w <= inner_width then break end
        end
    end
    group[#group + 1] = value_row
    group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }

    -- 第二行：标签（+ 可下钻的 ">"）
    -- ⚠ 不要再给 label_row 加 `HorizontalSpan` 去「补」左边那块空位 ——
    -- 那等于把图标换成了空白，用户要的是**标签整体靠左**。
    local label_row = HorizontalGroup:new{ align = "center" }
    label_row[#label_row + 1] = text(spec.label, label_face, {
        color = Blitbuffer.COLOR_BLACK,
        max_width = inner_width - Screen:scaleBySize(20),
    })
    if spec.drill then
        label_row[#label_row + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(2) }
        label_row[#label_row + 1] = icon("chevron.right", Screen:scaleBySize(13))
    end
    group[#group + 1] = label_row
    group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }

    -- 第三行：环比。没有环比时也占位，保证卡片等高。
    local delta_row
    if spec.delta_text then
        delta_row = HorizontalGroup:new{
            align = "center",
            text(spec.delta_text, delta_face, {
                color = Blitbuffer.COLOR_BLACK,
                max_width = inner_width,
            }),
        }
    else
        delta_row = HorizontalGroup:new{ align = "center", text(" ", delta_face) }
    end
    group[#group + 1] = delta_row

    return group
end

-- 线条控件（★★★ 34：卡片/列表分隔线）
-- ⇒ **scaleBySize(px) = ceil(px * min(W, H) / 600)**
-- KPW4 是 1072×1448（crash.log 里 `initializing for device KindlePaperWhite4`
-- 紧跟着就是 w=1072 / h=1448），且 settings 里**没有** `screen_dpi`
-- ⇒ 系数 = 1072/600 = 1.78667，并且**向上取整**：
local SEP_DOT_R   = 2                       -- 圆点半径(px)：2 ⇒ 直径 5px
local SEP_DOT_GAP = Screen:scaleBySize(2)   -- 点间隔(px)：KPW4 上 = 4px

-- 注意：这里**不能**再写 `local`（会遮蔽掉 1126 行的前向声明，
-- 前面函数里拿到的就还是全局 nil）。同 SolidRect 的写法。
HRule = WidgetContainer:extend{
    width = nil,
    height = nil,
    color = Blitbuffer.COLOR_BLACK,
    dotted = false,
    dot_r = SEP_DOT_R,   -- ★ 42：圆点半径。>0 ⇒ 画实心圆点；置 0 ⇒ 回退成横条
    dot_gap = nil,       -- ★ 42：圆点间隔（nil ⇒ 用 SEP_DOT_GAP）
    dot_len = nil,       -- 旧「横条」参数，已无调用点，保留只为兼容
    gap_len = nil,       -- 同上
}

function HRule:getSize()
    local h = self.height or Screen:scaleBySize(1)
    return Geom:new{ x = 0, y = 0, w = self.width or 0, h = h }
end

function HRule:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    if not self.dotted then
        bb:paintRect(x, y, size.w, size.h, self.color)
        return
    end
    -- 圆点模式（参数见文件上方的 SEP_DOT_R / SEP_DOT_GAP）。
    -- ⚠ 圆点**故意画得比 size.h 高**：size.h 还是 2px（scaleBySize(1)），
    -- 而圆点直径是 5px。行高保持 2px 是**为了不动分页预算** ——
    -- buildUnitsPage 里 `rows_per_page = avail / (row_h + line_w)`。
    local r = math.floor(self.dot_r or 0)
    if r > 0 then
        local gap = math.max(0, self.dot_gap or SEP_DOT_GAP)
        local cy = y + math.floor((size.h - 1) / 2)   -- 在分隔带里垂直居中
        local step = 2 * r + 1 + gap                  -- 周期 = 直径 + 间隔
        local px = r
        -- 条件必须是 `px + r < size.w`（不是 `<=`）：paintCircle 点亮的列是
        -- `px-r .. px+r`，而本控件占的列是 `0 .. size.w-1`，所以最右点亮的列
        -- 必须 <= size.w-1。写成 `<= size.w` 会在 size.w ≡ 4 (mod 9) 时右溢 1px
        -- （950 / 821 这两个真实宽度不触发，但卡片样式那条 310px 的会）。
        while px + r < size.w do
            bb:paintCircle(x + px, cy, r, self.color)
            px = px + step
        end
        return
    end

    -- 旧的「横条」回退路径（当前无调用点；只有外部传 dot_r = 0 时才会走到）
    -- 和圆点分支一样夹一下 —— `gap_len` 传负值在这里同样是死循环。
    local dot = math.floor(self.dot_len or Screen:scaleBySize(2))
    local gap = math.max(0, self.gap_len or Screen:scaleBySize(4))
    local px = 0
    while px < size.w do
        local w = math.min(dot, size.w - px)
        if w > 0 then bb:paintRect(x + px, y, w, size.h, self.color) end
        px = px + dot + gap
    end
end

local VRule = WidgetContainer:extend{
    width = nil,
    height = nil,
    color = Blitbuffer.COLOR_BLACK,
}

function VRule:getSize()
    local w = self.width or Screen:scaleBySize(1)
    return Geom:new{ x = 0, y = 0, w = w, h = self.height or 0 }
end

function VRule:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    bb:paintRect(x, y, size.w, size.h, self.color)
end

-- 实心矩形（自带尺寸，不依赖子控件）。
-- ⚠ `paintRoundedRect` 的签名是 **(x, y, w, h, c, r)** —— 颜色在前、
-- 半径在后（ffi/blitbuffer.lua:2169），别按直觉写反。
SolidRect = WidgetContainer:extend{
    width = nil,
    height = nil,
    color = Blitbuffer.COLOR_BLACK,
    radius = 0,
}

function SolidRect:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width or 0, h = self.height or 0 }
end

function SolidRect:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    local r = math.floor(self.radius or 0)
    if r > 0 and size.w > 0 and size.h > 0 then
        bb:paintRoundedRect(x, y, size.w, size.h, self.color, r)
    else
        bb:paintRect(x, y, size.w, size.h, self.color)
    end
end

-- 卡片样式（★★★ 34：多套可切换样式）
local CARD_STYLES = {
    { value = "box",      label = _("方框") },
    { value = "grid",     label = _("连线") },
    { value = "hairline", label = _("点线") },
    { value = "plate",    label = _("标签") },
}

local function cardStyleValid(style)
    for _i, s in ipairs(CARD_STYLES) do
        if s.value == style then return true end
    end
    return false
end

local function wrapCard(content, card_width, card_height, style, on_tap)
    local border = Screen:scaleBySize(1)
    local pad = Size.padding.default
    local card

    if style == "grid" then
        -- 「连线」样式：卡片自己**不画外框**，靠网格层的 VRule/HRule 补线。
        -- 这里只负责内容留白与纯白底（外层网格负责画线）。
        card = FixedBox:new{
            width = card_width,
            height = card_height,
            FrameContainer:new{
                width = card_width, height = card_height,
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0, radius = 0,
                padding = 0, margin = 0,
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = pad },
                    VerticalGroup:new{
                        VerticalSpan:new{ width = pad },
                        content,
                    },
                },
            },
        }
    elseif style == "hairline" then
        -- 「点线」样式：无外框，仅每张卡下方一条点线做分隔。
        card = FixedBox:new{
            width = card_width,
            height = card_height + border,
            VerticalGroup:new{
                align = "left",
                FrameContainer:new{
                    width = card_width, height = card_height,
                    background = Blitbuffer.COLOR_WHITE,
                    bordersize = 0, radius = 0,
                    padding = pad, margin = 0,
                    content,
                },
                HRule:new{ width = card_width, height = border,
                    color = Blitbuffer.COLOR_BLACK, dotted = true },
            },
        }
    elseif style == "plate" then
        -- 「标签」样式：1px 外框 + 左侧粗竖条，便签/标签纸观感。
        local bar_w = Screen:scaleBySize(6)
        local inner_h = math.max(1, card_height - 2 * border)
        local inner_w = math.max(1, card_width - bar_w - 2 * border)
        card = FixedBox:new{
            width = card_width,
            height = card_height,
            FrameContainer:new{
                width = card_width, height = card_height,
                background = Blitbuffer.COLOR_WHITE,
                bordersize = border,
                color = Blitbuffer.COLOR_BLACK,
                radius = 0,
                padding = 0, margin = 0,
                HorizontalGroup:new{
                    align = "top",
                    SolidRect:new{
                        width = bar_w, height = inner_h,
                        color = Blitbuffer.COLOR_BLACK,
                    },
                    FixedBox:new{
                        width = inner_w,
                        height = inner_h,
                        align = "left", vertical_align = "top",
                        HorizontalGroup:new{
                            HorizontalSpan:new{ width = pad },
                            VerticalGroup:new{
                                VerticalSpan:new{ width = pad },
                                content,
                            },
                        },
                    },
                },
            },
        }
    else -- "box"（默认）
        card = FixedBox:new{
            width = card_width,
            height = card_height,
            FrameContainer:new{
                width = card_width,
                height = card_height,
                background = Blitbuffer.COLOR_WHITE,
                radius = Size.radius.window,
                -- 卡片原本 bordersize = 0（纯白贴在白底浮窗上，等于没有边界）。
                bordersize = border,
                color = Blitbuffer.COLOR_BLACK,
                padding = pad,
                margin = 0,
                content,
            },
        }
    end

    if on_tap then
        return TapBox:new{ card, on_tap = on_tap }
    end
    return card
end

--==========================================================================
-- 下钻列表
--==========================================================================

-- 尺寸策略：
-- · 宽 = min(屏宽 - 2*margin, 最大宽上限)。留出左右各 margin 的缝隙，
-- 既看得到背景，也避免 e-ink 上贴边难看。
local POPUP_MARGIN = Size.padding.large           -- 窗口与屏幕边缘的缝隙
local POPUP_SIDE_PADDING = Size.padding.large     -- 窗口内部左右内边距
-- 用户原话「整体的阅读统计能不能缩小一点」⇒ 92%/90% → 88%/80%。
-- ⇒ 高度少了 145px、宽度少了 43px，正文露出的部分明显变多。
local POPUP_MAX_WIDTH_RATIO = 0.88                -- 宽度不超过屏宽的 88%
local POPUP_MAX_HEIGHT_RATIO = 0.80               -- 高度不超过屏高的 80%

-- 下钻浮窗的尺寸比例 —— 必须**明显小于**主浮窗（0.88 / 0.80），
-- 这样点卡片进去时，能看到下钻框四周还露出主浮窗，一眼就是「叠在上面一层」。
local DRILL_MAX_WIDTH_RATIO = 0.78
local DRILL_MAX_HEIGHT_RATIO = 0.66

-- 两排标签的**统一高度**（视图排 + 周期排）。
-- ⚠ 先把 KPW4 的换算写清楚，免得后面对不上：
-- `fb:scaleBySize(px)`（ffi/framebuffer.lua:414）=
-- `ceil(px * (min(屏宽,屏高)/600 + dpi_scale) / 2)`；
-- KPW4 没有 dpi_override ⇒ 两个 scale 都是 1072/600 = 1.7867
local ROW_TAB_H_PX = 46

-- 候选 D ⑦ 的三个几何常量（都是「设计像素」，走 scaleBySize）。
local NAV_TRACK_RADIUS_PX = 11   -- 轨道（外框）圆角
local NAV_THUMB_RADIUS_PX = 9    -- 选中滑块圆角（四角同值）
local NAV_TRACK_PAD_PX    = 3    -- 轨道内边距（滑块四周留白）

-- 下钻浮窗（★★★ 34：从全屏 KeyValuePage 改成**悬浮在上层的浮窗**）
local DrillDownPopup = FocusManager:extend{
    modal = true,
    title = nil,
    rows = nil,
}

function DrillDownPopup:init()
    self.rows = self.rows or {}
    if #self.rows == 0 then
        self.rows = { { _("暂无数据"), "" } }
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self:build()
    if Device:isTouchDevice() then
        self.ges_events = self.ges_events or {}
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        }
    end
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.AnyKeyPressed = {
            { "Back", "Home", "RPgBack", "LPgBack", "RPgFwd", "LPgFwd" },
        }
    end
end

function DrillDownPopup:onClose()
    UIManager:close(self)
end

function DrillDownPopup:onTapClose(arg, ges)
    if self.popup_frame and self.popup_frame.dimen
            and ges and ges.pos and ges.pos:notIntersectWith(self.popup_frame.dimen) then
        self:onClose()
        return true
    end
    return false
end

function DrillDownPopup:onAnyKeyPressed()
    self:onClose()
    return true
end

function DrillDownPopup:onCloseWidget()
    -- `"ui"` → `"[partial]"`（与 49d 同源）。
    -- ⇒ 驱动按矩形内容挑波形：纯黑白 DU（不闪）/ 含灰 GC16（闪黑）。
    local region = (self.popup_frame and self.popup_frame.dimen) or self.dimen
    if region then
        pcall(UIManager.setDirty, UIManager, self, "[partial]", region)
    end
end

function DrillDownPopup:build()
    local frame_w = Screen:getWidth() * DRILL_MAX_WIDTH_RATIO
    frame_w = math.max(Screen:scaleBySize(200),
        math.min(frame_w, Screen:getWidth() - 2 * POPUP_MARGIN))
    local content_w = frame_w - 2 * POPUP_SIDE_PADDING

    local title_bar = TitleBar:new{
        title = tostring(self.title or _("详情")),
        width = content_w,
        align = "left",
        with_bottom_line = true,
        bottom_line_color = Blitbuffer.COLOR_DARK_GRAY,
        bottom_line_h_padding = Size.padding.large,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local body = VerticalGroup:new{ align = "left" }
    body[#body + 1] = title_bar
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }

    -- 行：左标题 / 右数值，行间一条点线分隔（用户要求「中间用虚线或点线分隔」）
    local line_w = Screen:scaleBySize(1)
    for _i, row in ipairs(self.rows) do
        local left = tostring(row[1] or "")
        local right = tostring(row[2] or "")
        local row_h = Screen:scaleBySize(42)
        local right_w = math.floor(content_w * 0.34)
        local left_w = content_w - right_w - Size.padding.small
        body[#body + 1] = FixedBox:new{
            width = content_w, height = row_h,
            align = "left", vertical_align = "center",
            HorizontalGroup:new{
                align = "center",
                FixedBox:new{ width = left_w, height = row_h,
                    align = "left", vertical_align = "center",
                    text(left, faces().label, { color = Blitbuffer.COLOR_BLACK,
                        max_width = left_w - Size.padding.small }) },
                HorizontalSpan:new{ width = Size.padding.small },
                FixedBox:new{ width = right_w, height = row_h,
                    align = "right", vertical_align = "center",
                    text(right, faces().footer, { color = Blitbuffer.COLOR_BLACK,
                        max_width = right_w }) },
            },
        }
        -- 行间点线（最后一行不画）
        if _i < #self.rows then
            body[#body + 1] = HRule:new{ width = content_w, height = line_w,
                color = Blitbuffer.COLOR_BLACK, dotted = true }
        end
    end

    local padded = HorizontalGroup:new{
        HorizontalSpan:new{ width = POPUP_SIDE_PADDING },
        body,
    }
    local max_h = math.floor(Screen:getHeight() * DRILL_MAX_HEIGHT_RATIO)
    local scroll = NoBarScrollable:new{
        dimen = Geom:new{ x = 0, y = 0, w = frame_w, h = max_h },
        show_parent = self,
        padded,
    }
    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Screen:scaleBySize(2),
        color = Blitbuffer.COLOR_BLACK,
        radius = Screen:scaleBySize(12),
        padding = 0, margin = 0,
        VerticalGroup:new{ align = "left", scroll },
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.popup_frame,
    }
    return self
end

-- 「不带刷新参数的 UIManager:show」一律不许用
local function widgetRegion(w)
    if not w then return nil end
    -- ButtonDialog 的外框是 movable
    if w.movable and w.movable.dimen then return w.movable.dimen end
    -- 本插件自己的浮窗（StatisticsPage / DrillDownPopup）
    if w.popup_frame and w.popup_frame.dimen then return w.popup_frame.dimen end
    return nil
end

-- `UIManager:show` 的安全版本：**一定**带一条 `"[partial]"` + 自身矩形。
-- 返回值就是传进来的 widget，方便 `local p = showNoFlash(X:new{...})`。
local function showNoFlash(widget)
    UIManager:show(widget, function()
        return "[partial]", widgetRegion(widget)
    end)
    return widget
end

local function showDrillDown(parent, plugin, title, rows)
    showNoFlash(DrillDownPopup:new{
        title = title,
        rows = rows,
    })
end

--==========================================================================
-- 页面
--==========================================================================

local TABS = {
    { value = "day", label = _("日") },
    { value = "week", label = _("周") },
    { value = "month", label = _("月") },
    { value = "year", label = _("年") },
    { value = "total", label = _("总") },
}

-- 新增「日历」视图 —— 用户原话：
-- 「你做的月历放到哪了，我没看到」→「月历放到总览那一行的轨道里」。
local VIEW_TABS = {
    { value = "overview", label = _("总览") },
    { value = "trend", label = _("趋势") },
    { value = "units", label = _("字数") },
    { value = "speed", label = _("速度") },
    { value = "calendar", label = _("日历") },
}

local METRICS = {
    { value = "seconds", label = _("阅读时间"), icon = "history" },
    { value = "units", label = _("阅读字数"), icon = "align.justify" },
    { value = "speed", label = _("阅读速度"), icon = "zoom.content" },
    { value = "average", label = _("日均阅读时长"), icon = "dogear.reading" },
}

-- 从「全屏页」改成「居中浮窗」。

local StatisticsPage = FocusManager:extend{
    modal = true,
    plugin = nil,
    period = "year",
    anchor = nil,
    metric = "units",
    trend_view = "chart",
    view = "overview",
    unit_sort = "units",
    -- 总览卡片样式（box / grid / hairline / plate，见 CARD_STYLES）
    card_style = "box",
    -- 阅读字数页的**分页**（用户要求左右键翻页，不再上下滑动）
    unit_page = 1,
    -- 日历视图自己的选择（与别的视图互不干扰）。
    -- ⚠ 这里的默认值就是「打开日历看到什么」，`reload()` 传的是
    -- `opts.cal_metric or self.cal_metric` ⇒ 从别的视图切进日历也吃这个默认值。
    cal_metric = "seconds",
    cal_format = "auto",
    cal_speed_unit = "min",
    -- 这两个现在表示**浮窗内容区**的尺寸，不再等于整屏
    width = nil,
    height = nil,
    popup_frame = nil,
}

-- 阅读字数页每页行数的**上限**（实际行数按可用高度自适应，见 buildUnitsPage）。
local UNIT_PAGE_SIZE_MAX = 12

-- 计算浮窗的最大可用尺寸（不含外层缝隙）。
-- 返回 w, h（都是像素，已按比例和 margin 收窄）。
local function popupBounds()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local max_w = math.floor(sw * POPUP_MAX_WIDTH_RATIO)
    local max_h = math.floor(sh * POPUP_MAX_HEIGHT_RATIO)
    -- 再减掉两层 margin，保证「卡片 + 缝隙」加起来不超过屏幕
    max_w = math.max(1, math.min(max_w, sw - 2 * POPUP_MARGIN))
    max_h = math.max(1, math.min(max_h, sh - 2 * POPUP_MARGIN))
    return max_w, max_h
end

function StatisticsPage:init()
    local max_w, max_h = popupBounds()
    -- self.width 表示**浮窗卡片的整体宽度**（含卡片左右内边距）。
    -- build() 里再扣 POPUP_SIDE_PADDING 得到内容区宽度去分栏/排卡片。
    self.width = self.width or max_w
    -- self.height 现在只作为「卡片最大高度」的参考值；真正的高度
    -- 由 CenterContainer 按内容自适应（内容高就走内容高，内容超高就走
    -- max_h 并内部滚动）。见 build() 里的 available_h。
    self.height = self.height or max_h
    self.anchor = tonumber(self.anchor) or os.time()
    -- dimen 仍取整屏：它是「这个浮窗控件的命中范围」，
    -- 点它内部但落在 popup_frame 之外的地方 = 点空白 = 关闭。
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self:build()

    -- 触摸设备：点空白处关闭
    if Device:isTouchDevice() then
        self.ges_events = self.ges_events or {}
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        }
    end
    -- 按键分工。
    -- ⚠ 重要事实：**KPW4（KindlePaperWhite4）是纯触摸设备，没有实体翻页键**
    -- （device.lua:1076 `KindlePaperWhite4 = Kindle:extend{ isTouchDevice = yes }`
    -- 且未设 `hasKeys`）。所以用户说的「按左右键翻页」实际是**点屏幕上的
    -- 左右箭头按钮**，不是物理键。本页因此以「屏上 ‹ › 按钮」为主，
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.AnyKeyPressed = {
            { "Back", "Home" },
        }
        -- KOReader 约定（readerrolling.lua:140-141）：
        -- 下一页 = RPgFwd/LPgFwd → GotoNextView
        -- 上一页 = RPgBack/LPgBack → GotoPrevView
        self.key_events.GotoNextView = { { { "RPgFwd", "LPgFwd" } } }
        self.key_events.GotoPrevView = { { { "RPgBack", "LPgBack" } } }
    end
end

function StatisticsPage:onClose()
    UIManager:close(self)
end

-- 翻到「阅读字数」列表的下一页（只在该视图有意义）。
-- 返回 true 表示已处理；非 units 视图返回 false，交给调用方决定。
function StatisticsPage:pageUnits(delta)
    if self.view ~= "units" then return false end
    local total = math.max(1, self._unit_total_pages or 1)
    local target = (self.unit_page or 1) + delta
    if target < 1 then target = total end     -- 到头往回绕
    if target > total then target = 1 end     -- 到尾往前绕
    self:reload{ view = "units", unit_page = target }
    return true
end

-- 物理键：下一页（GotoNextView）。
function StatisticsPage:onGotoNextView()
    if self:pageUnits(1) then return true end
    self:onClose()
    return true
end

-- 物理键：上一页（GotoPrevView）。
function StatisticsPage:onGotoPrevView()
    if self:pageUnits(-1) then return true end
    self:onClose()
    return true
end

-- 点空白关闭：命中区是整屏，但 popup_frame 之外的点击才算「点空白」。
function StatisticsPage:onTapClose(arg, ges)
    if self.popup_frame and self.popup_frame.dimen
            and ges and ges.pos and ges.pos:notIntersectWith(self.popup_frame.dimen) then
        self:onClose()
        return true
    end
    return false
end

function StatisticsPage:onAnyKeyPressed()
    self:onClose()
    return true
end

function StatisticsPage:onCloseWidget()
    -- reload（切视图/周期）时是「关掉自己、立刻开一个同尺寸的新浮窗」。
    if self._skip_close_repaint then
        self._skip_close_repaint = nil
        return
    end
    -- 正常关闭：只刷浮窗所在区域，把底下的书页还回去；不做全屏 flash。
    -- ⚠ **这句话在 PW4 上不成立**：Rex 平台的
    -- `waveform_ui = WAVEFORM_MODE_AUTO`（`framebuffer_mxcfb.lua:874`），
    -- 而 `refresh_rex` 在非 ZELDA_GLR16 波形下把
    -- `hist_gray_waveform_mode` 设成 `GC16`（:557-558）
    local region = (self.popup_frame and self.popup_frame.dimen) or self.dimen
    if region then
        pcall(UIManager.setDirty, UIManager, self, "[partial]", region)
    end
end

-- 换周期 / 换指标 / 换视图：整页重建再替换。
-- 重建比原地 update 简单可靠得多，代价是一次重绘。
function StatisticsPage:reload(opts)
    opts = opts or {}
    local next_period = opts.period or self.period
    local next_trend_view = opts.trend_view
    if next_trend_view == nil then
        if next_period ~= self.period and next_period == "day" then
            next_trend_view = "list"
        else
            next_trend_view = self.trend_view
        end
    end
    local ok, next_page = pcall(StatisticsPage.new, StatisticsPage, {
        plugin = self.plugin,
        period = next_period,
        anchor = opts.anchor or self.anchor,
        metric = opts.metric or self.metric,
        trend_view = next_trend_view,
        view = opts.view or self.view,
        unit_sort = opts.unit_sort or self.unit_sort,
        card_style = opts.card_style or self.card_style,
        -- 翻页：显式传了就按传的，没传就回到第 1 页
        -- （只有在「同一个 units 视图内翻页」时才显式传 unit_page）
        unit_page = opts.unit_page or 1,
        -- 日历视图的两个选择，同样「显式传了按传的，没传沿用自己」。
        cal_metric = opts.cal_metric or self.cal_metric,
        cal_format = opts.cal_format or self.cal_format,
        -- 速度单位（字/分钟 ↔ 字/小时）同理。
        cal_speed_unit = opts.cal_speed_unit or self.cal_speed_unit,
    })
    if not ok then
        logger.err("WordCount: statistics page build failed", next_page)
        -- 错误提示也要走 showNoFlash —— 裸的 `UIManager:show` 会触发
        -- `_repaint` 兜底排一条**整屏**无 region 的 "partial"（见 showNoFlash 注释）。
        showNoFlash(InfoMessage:new{ text = T(_("统计页面打开失败：%1"), tostring(next_page)) })
        return self
    end
    -- 重建时不要先 close 再 show —— 那会在 e-ink 上闪一下
    -- （先画回底层书页，再画新浮窗）。把「关闭时不要重绘」的标志挂上，
    -- 让 onCloseWidget 跳过这次刷新，由紧接着的 show(next_page) 一次画完。
    self._skip_close_repaint = true
    UIManager:close(self)

    -- **显式**给「浮窗矩形」一个 `"ui"` 刷新。
    -- ⇒ 两个后果：
    -- 1) region 为 nil ⇒ `_refresh` 把区域填成整屏（:1178），
    -- 所以刷的是整屏而不是浮窗那一块；
    -- 2) 更要命的是 :1163-1175 的**提升规则**：没有 region 的 "partial"
    local refresh_region = self.popup_frame and self.popup_frame.dimen or nil
    if refresh_region then
        UIManager:show(next_page, "[partial]", refresh_region)
    else
        -- 矩形拿不到时**也不能**退回裸 show（那会走 `_repaint` 兜底排
        -- 整屏无 region 的 "partial"，每 6 次提升成 full = 整屏黑闪）。
        showNoFlash(next_page)
    end
    return next_page
end

-- 当前周期里"正在看"的那个分桶下标（柱状图高亮 + 底部读数用）。
function StatisticsPage:selectedIndex(buckets)
    local period = self.period
    if period == "total" then return #buckets end
    local now = os.time()
    local first, last = GlobalStats.bounds(period, self.anchor)
    if not first or not last then return #buckets end
    local today = GlobalStats.dateKey(now)
    if today < first or today > last then return #buckets end
    if period == "day" then
        return math.min(#buckets, tonumber(os.date("%H", now)) + 1)
    elseif period == "week" then
        local weekday = tonumber(os.date("%w", now)) or 0 -- Sunday = 0
        return math.min(#buckets, ((weekday + 6) % 7) + 1)
    elseif period == "month" then
        return math.min(#buckets, tonumber(os.date("%d", now)) or 1)
    end
    return math.min(#buckets, tonumber(os.date("%m", now)) or 1)
end

-- 底部读数里的分桶全名，例如 "2026年1月"
-- 注意：这里不能用 `local _, _, label = ...` —— 会把 gettext 的 `_` 遮蔽掉，
-- 后面再调 `_(...)` 就是"attempt to call a string value"。
function StatisticsPage:selectedLabel(bucket, index)
    local period = self.period
    if period == "day" then
        local _first, _last, label = GlobalStats.bounds("day", self.anchor)
        return label .. T(_("%1时"), tostring(index - 1))
    elseif period == "week" then
        return T(_("周%1"), tostring(bucket.label))
    elseif period == "month" then
        local _first, _last, label = GlobalStats.bounds("month", self.anchor)
        return label .. T(_("%1日"), tostring(index))
    elseif period == "year" then
        local _first, _last, label = GlobalStats.bounds("year", self.anchor)
        return label .. T(_("%1月"), tostring(index))
    end
    return tostring(bucket.label)
end

local function statMemoKey(plugin, period, anchor, metric)
    local rev = (plugin and plugin._global_stats_rev) or 0
    return tostring(period) .. "|" .. tostring(anchor) .. "|"
        .. tostring(metric) .. "|" .. tostring(rev)
end

-- `kind` 里带了 period|anchor，用户每翻一次月/年就多一个 kind。
local MEMO_MAX_SLOTS = 48

local function memoBox(plugin)
    local box = plugin._stat_memo
    if not box then
        box = {}
        plugin._stat_memo = box
    end
    return box
end

local function memoTouchNewSlot(plugin, box)
    -- 仅在**新增** slot 时调用；到顶就清空重建。
    local n = (plugin._stat_memo_n or 0) + 1
    if n > MEMO_MAX_SLOTS then
        box = {}
        plugin._stat_memo = box
        n = 1
    end
    plugin._stat_memo_n = n
    return box
end

local function memoGet(plugin, kind, key)
    if not plugin then return nil end
    local box = memoBox(plugin)
    local slot = box[kind]
    if slot and slot.key == key then return slot.value end
    return nil
end

local function memoSet(plugin, kind, key, value)
    if not plugin then return value end
    local box = memoBox(plugin)
    if box[kind] == nil then
        box = memoTouchNewSlot(plugin, box)
    end
    box[kind] = { key = key, value = value }
    return value
end

function StatisticsPage:build()
    local f = faces()
    -- self.width 是**浮窗卡片的整体宽度**（已含卡片左右内边距）。
    -- 内容区还要再扣掉卡片自己那圈 padding，否则卡片最右会被裁掉一点。
    local frame_w = self.width
    local content_w = frame_w - 2 * POPUP_SIDE_PADDING
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local memo_key = statMemoKey(self.plugin, self.period, self.anchor, self.view)

    -- ── ★★★ 57-kpw4-perf：这四样**按视图按需算**，不要无条件算 ──
    local summary, previous
    if self.view == "overview" then
        summary = memoGet(self.plugin, "summary:" .. tostring(self.period)
            .. "|" .. tostring(self.anchor), memo_key)
            or memoSet(self.plugin, "summary:" .. tostring(self.period)
                .. "|" .. tostring(self.anchor), memo_key,
                GlobalStats.summarize(store, self.period, self.anchor))
        if self.period ~= "total" then
            local prev_anchor = GlobalStats.shiftAnchor(self.period, self.anchor, -1)
            local pkey = "prev:" .. tostring(self.period) .. "|" .. tostring(self.anchor)
            previous = memoGet(self.plugin, pkey, memo_key)
                or memoSet(self.plugin, pkey, memo_key,
                    GlobalStats.summarize(store, self.period, prev_anchor))
        end
    end
    local _first, _last, range_label = GlobalStats.bounds(self.period, self.anchor)
    local buckets, selected
    if self.view == "trend" or self.view == "speed" then
        local page_metric = self.view == "speed" and "speed" or self.metric
        local trend_key = "trend:" .. tostring(self.period) .. "|" .. tostring(self.anchor)
            .. "|" .. tostring(page_metric)
        buckets = memoGet(self.plugin, trend_key, memo_key)
            or memoSet(self.plugin, trend_key, memo_key,
                GlobalStats.trend(store, self.period, self.anchor, page_metric))
        selected = self:selectedIndex(buckets)
    end

    local title_bar = TitleBar:new{
        title = _("阅读统计"),
        width = content_w,
        align = "left",
        with_bottom_line = true,
        bottom_line_color = Blitbuffer.COLOR_DARK_GRAY,
        bottom_line_h_padding = Size.padding.large,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showPeriodDialog() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    -- 可用高度要在**建 body 之前**算出来 —— 因为各视图
    -- （尤其阅读字数页）要按它自适应「每页放几行」，保证内容放得下、
    -- 不依赖滚动（外层容器已是禁止滑动的 FixedPane）。
    local max_w_unused, max_h = popupBounds()
    local available_h = math.max(
        Screen:scaleBySize(80),  -- 极端小屏兜底，别算出负数高度
        max_h
    )
    self._available_h = available_h

    local body = VerticalGroup:new{ align = "left" }
    -- 标题栏作为**滚动内容的第一行**（不再是钉死的顶栏）。
    body[#body + 1] = title_bar
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
    -- 「阅读字数」+「阅读速度」要放在**其他同级卡片的最前面**，
    -- 不是整个页面的最开头。所以这里什么都不插，只改 buildCardGrid 里
    -- specs 的顺序（把这两张卡挪到数组头部）—— 它们是「卡片网格」里
    -- 的同级卡片，位置就该在网格内部体现，而不是在网格外面另起一块。
    body[#body + 1] = self:buildViewTabs(content_w)
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
    if self.view == "calendar" then
        -- 日历视图**不显示**「日/周/月/年/总」那条周期轨道 ——
        -- 日历自带月份导航（‹ 2026 年 10 月 ›），两条导航并存会让人不知道
        -- 该点哪个；而且「日历 + 周期 = 周」这种组合本身没有意义。
        local above_h = 0
        for _i = 1, #body do
            local sz = body[_i]:getSize()
            above_h = above_h + ((sz and sz.h) or 0)
        end
        local cal_avail = available_h - above_h - Size.span.vertical_large
        body[#body + 1] = self:buildCalendarPage(content_w, cal_avail)
    else
        body[#body + 1] = self:buildTabs(content_w)
        body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
        body[#body + 1] = self:buildPeriodNav(content_w, range_label)
        body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
        if self.view == "overview" then
            -- 卡片样式切换行（只在总览视图出现，换来换去才有意义）
            body[#body + 1] = self:buildCardStyleRow(content_w)
            body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
            body[#body + 1] = self:buildCardGrid(content_w, summary, previous)
        elseif self.view == "units" then
            body[#body + 1] = self:buildUnitsPage(content_w)
        else
            body[#body + 1] = self:buildTrendSection(content_w, buckets, selected,
                self.view == "speed" and "speed" or nil)
        end
    end
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
    -- **删掉「退出」按钮**。

    local padded = HorizontalGroup:new{
        HorizontalSpan:new{ width = POPUP_SIDE_PADDING },
        body,
    }

    -- 容器改成 `FixedPane` —— **禁止上下/左右滑动**。
    local scroll = FixedPane:new{
        dimen = Geom:new{ x = 0, y = 0, w = frame_w, h = available_h },
        show_parent = self,
        padded,
    }

    -- 白底圆角卡片 = 浮窗本体。
    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Screen:scaleBySize(2),
        bordercolor = Blitbuffer.COLOR_BLACK,
        radius = Screen:scaleBySize(12),
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "left",
            scroll,
        },
    }

    -- CenterContainer 把卡片摆正中央；dimen 取整屏，超出部分自然裁掉，
    -- 也顺便构成了「点卡片外面 = 点空白」的判定区域。
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.popup_frame,
    }
    return self
end

-- 总览 / 趋势 / 阅读字数 / 阅读速度。
-- ⇒ 未选中的格子之间没有分界，整排看着就是一块白，选中格孤零零的。
local SegFill = WidgetContainer:extend{
    width = nil,
    height = nil,
    radius = 0,          -- ★ 49：四角同圆角（>0 时优先于下面两个）
    radius_left = 0,
    radius_right = 0,
    color = Blitbuffer.COLOR_BLACK,
    -- 可选**描边**（默认 0 ⇒ 完全不画，行为与 49 版一致）。
    -- ⚠ 只在 `radius == 0` 的矩形分支生效；圆角分支（分段轨道滑块）
    border_size = 0,
    border_color = nil,
}

function SegFill:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width or 0, h = self.height or 0 }
end

function SegFill:paintTo(bb, x, y)
    local w, h = self.width or 0, self.height or 0
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }

    -- 四角同圆角这条路（见控件头的注释）。
    local four_r = math.floor(self.radius or 0)
    if four_r > 0 then
        -- `paintRoundedRect` 内部自己会把 r 夹到 h/2 / w/2，这里不用再夹。
        bb:paintRoundedRect(x, y, w, h, self.color, four_r)
        local child = self[1]
        if child then
            local cs = child:getSize()
            child:paintTo(bb, x + math.floor((w - cs.w) / 2),
                y + math.floor((h - cs.h) / 2))
        end
        return
    end
    local max_r = math.floor(math.min(w, h) / 2)
    local rl = math.max(0, math.min(self.radius_left or 0, max_r))
    local rr = math.max(0, math.min(self.radius_right or 0, max_r))
    local c = self.color

    -- 中间竖带：从左圆角区右缘到右圆角区左缘，通高
    local mid_w = w - rl - rr
    if mid_w > 0 then
        bb:paintRect(x + rl, y, mid_w, h, c)
    end
    if rl > 0 then
        local band_h = h - 2 * rl
        if band_h > 0 then
            bb:paintRect(x, y + rl, rl, band_h, c)
        end
        bb:paintCircle(x + rl, y + rl, rl, c)
        bb:paintCircle(x + rl, y + h - 1 - rl, rl, c)
    end
    if rr > 0 then
        local band_h = h - 2 * rr
        if band_h > 0 then
            bb:paintRect(x + w - rr, y + rr, rr, band_h, c)
        end
        bb:paintCircle(x + w - 1 - rr, y + rr, rr, c)
        bb:paintCircle(x + w - 1 - rr, y + h - 1 - rr, rr, c)
    end

    -- 可选描边（日历格子用它把边界画出来）。
    -- ⚠ 画在**填充之后、文字之前** —— 这样边框压在底色上，文字仍然清晰。
    local bsz = math.floor(self.border_size or 0)
    if bsz > 0 and self.border_color then
        local bc = self.border_color
        local t = math.min(bsz, math.floor(h / 2))
        local v = math.min(bsz, math.floor(w / 2))
        if t > 0 then
            bb:paintRect(x, y, w, t, bc)                        -- 上边
            bb:paintRect(x, y + h - t, w, t, bc)                -- 下边
        end
        if v > 0 then
            bb:paintRect(x, y, v, h, bc)                        -- 左边
            bb:paintRect(x + w - v, y, v, h, bc)                -- 右边
        end
    end

    -- 子控件（文字）居中
    local child = self[1]
    if child then
        local cs = child:getSize()
        child:paintTo(bb, x + math.floor((w - cs.w) / 2), y + math.floor((h - cs.h) / 2))
    end
end

local function buildSegmentedRow(opts)
    local width = opts.width
    local height = opts.height
    local radius = opts.radius or Screen:scaleBySize(NAV_TRACK_RADIUS_PX)
    local items = opts.items or {}
    local border = Screen:scaleBySize(1)              -- 2px
    -- 新增**轨道内边距**（用户选的候选 D ⑦）。
    local pad = Screen:scaleBySize(NAV_TRACK_PAD_PX)
    -- **行高自动长到放得下最高的那个标签**。
    -- ⇒ 自动 / k / 万 三个字上下各被切 3~4px。
    for _i, it in ipairs(items) do
        local need = faceLineH(it.face) + 2 * (border + pad)
        if need > height then height = need end
    end
    local inner_w = math.max(1, width - 2 * border - 2 * pad)
    local inner_h = math.max(1, height - 2 * border - 2 * pad)
    local n = math.max(1, #items)
    -- **去掉格与格之间的竖线分隔**（用户回执：「这个不要中间的
    -- 竖线分隔」）。改回「纯留白 + 选中填黑」—— 格子均分整个内宽，
    -- 不再为分隔线预留位置。45c 那条竖线（SolidRect）整段删掉。
    local cell_w = math.floor(inner_w / n)

    local row = HorizontalGroup:new{ align = "center" }
    for i, it in ipairs(items) do
        -- 取整的余数补给最后一格，保证整排严丝合缝贴住内边距的内缘
        -- （否则右边会留一条 1~4px 的白缝）。
        local cw = (i == n) and (inner_w - cell_w * (n - 1)) or cell_w
        local label = text(it.label, it.face, {
            color = it.active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            bold = it.active,
            max_width = math.max(1, cw - Screen:scaleBySize(6)),
            -- 同日历格子，去掉 TextWidget 白送的 2×4px。
            padding = 0,
        })
        local inner = FixedBox:new{
            width = cw, height = inner_h,
            align = "center", vertical_align = "center", label,
        }
        if it.active then
            -- 选中块 = **四角同圆角**的滑块，颜色
            -- `COLOR_BLACK`（用户：「选中的导航栏还是深色吧」）。
            inner = SegFill:new{
                width = cw, height = inner_h,
                radius = Screen:scaleBySize(NAV_THUMB_RADIUS_PX),
                color = Blitbuffer.COLOR_BLACK,
                label,
            }
        end
        if it.on_tap then
            inner = TapBox:new{ inner, on_tap = it.on_tap }
        end
        row[#row + 1] = FixedBox:new{ width = cw, height = inner_h, inner }
    end

    -- 外框 = 白底 + `COLOR_DARK_GRAY` 边框 + 圆角 + 内边距。
    -- ⚠ `FrameContainer:getSize()` **忽略**构造时传的 width/height，
    -- 只按「子控件 + 2*(margin + bordersize + padding)」反推 ——
    -- 所以 `padding` 必须在这里真的传下去，否则尺寸会算少 12px。
    return FixedBox:new{
        width = width, height = height,
        align = "center", vertical_align = "center",
        FrameContainer:new{
            width = width, height = height,
            bordersize = border,
            color = Blitbuffer.COLOR_DARK_GRAY,
            radius = radius,
            margin = 0, padding = pad,
            background = Blitbuffer.COLOR_WHITE,
            row,
        },
    }
end

-- 日历视图

-- 下面这些是**设计像素**，实际高度由 `Screen:scaleBySize` 算，
-- 而且**必须和字体的真实行高取 max** —— 见 faceLineH 的注释（52 轮算错的根因）。
local CAL_CELL_H_PX    = 34   -- 日期格的**设计**高度（下限；实际取 max(它, 内容高)）
local CAL_CELL_PAD_PX  = 2    -- 日期格内容上下的内边距（scaleBySize(2) = 4px）
local CAL_HEAD_H_PX    = 22   -- 星期头行 / 月份导航行的**设计**高度（下限）
local CAL_NAV_PAD_PX   = 2    -- 导航行 / 星期头内容上下的内边距（scaleBySize(2) = 4px）
local CAL_FMT_ROW_H_PX = 34   -- 「自动 / k / 万」「字/分钟 / 字/小时」那一行（比主轨道矮一档；不够会自动长）
local CAL_ARROW_W_PX   = 30   -- 月份导航左右箭头的宽度
-- 热力图描边宽度（只画在「今天」那一格上，不是网格线）。
local CAL_TODAY_BORDER_PX = 1

local CAL_METRICS = {
    { value = "units",   label = _("字数") },
    { value = "speed",   label = _("速度") },
    { value = "seconds", label = _("时间") },
}

-- 速度单位轨道（只在「速度」指标下出现）。
local CAL_SPEED_UNITS = {
    { value = "min",  label = _("字/分钟") },
    { value = "hour", label = _("字/小时") },
}

local CAL_FORMATS = {
    { value = "auto", label = _("自动") },
    { value = "k",    label = _("k") },
    { value = "wan",  label = _("万") },
}

-- 格子里的数值文案（**尽量短** —— 格子宽只有 content_w/7 ≈ 129px）。
-- ⚠ 旧写法是 `>= 3600 → "1.5h"` / 否则 `"23分"` —— 已整体替换，
-- `分` 这个汉字在 24px 字号下比 `m` 宽得多，5 个汉字就顶满格子了。
local function calendarCellText(value, metric, fmt)
    value = tonumber(value) or 0
    if value <= 0 then return "" end
    if metric == "seconds" then
        local hours = math.floor(value / 3600)
        local minutes = math.floor((value % 3600) / 60)
        if hours > 0 then
            if minutes > 0 then
                return tostring(hours) .. "h" .. tostring(minutes) .. "m"
            end
            return tostring(hours) .. "h"
        end
        if minutes > 0 then return tostring(minutes) .. "m" end
        return ""
    end
    if metric == "speed" then
        local v = math.floor(value + 0.5)
        if v <= 0 then return "" end
        return tostring(v)
    end
    local n = math.max(0, math.floor(value))
    if fmt == "k" then
        if n >= 1000 then return trimZero(string.format("%.1f", n / 1000)) .. "k" end
        return groupDigits(n)
    end
    if fmt == "wan" then
        if n >= 10000 then return trimZero(string.format("%.1f", n / 10000)) .. _("万") end
        return groupDigits(n)
    end
    return formatCount(n)
end

-- 把 bucket 的原始值换算成「日历格子里要显示的那个数」。
-- ⚠ 热力图用的也是这个换算后的值（`buildCalendarGrid` 里先算 max 再分档），
-- 所以「切单位」只会改格子里写的数字，**不会**改变各格深浅的相对分布 ——
-- 乘一个正常数不改变比例，这是刻意的。
local function calendarCellValue(bucket, metric, speed_unit)
    local value = bucket and tonumber(bucket.value) or 0
    if not value then return 0 end
    if metric == "speed" and speed_unit == "hour" then
        return value * 60
    end
    return value
end

-- 热力图分档。
-- ⚠ 代价说清楚：如果某个月有一天特别突出（比如读了 10 小时、其余都是
-- 20 分钟），其余天会全部落进第 1 档，看起来偏平。这是相对分档的固有
-- 取舍；要改成固定阈值（如时间按 15min/1h/3h 分档）随时可以，改这里即可。
local CAL_HEAT_FILL = {
    Blitbuffer.COLOR_WHITE,        -- 0：无数据
    Blitbuffer.COLOR_GRAY_E,       -- 1
    Blitbuffer.COLOR_LIGHT_GRAY,   -- 2
    Blitbuffer.COLOR_GRAY,         -- 3
    Blitbuffer.COLOR_DARK_GRAY,    -- 4
}

-- 每档对应的文字色。最深那档**反白**：0x88 底 + 黑字在 e-ink 上会糊成一片，
-- 白字对比度才够（这也是 KOReader 自己在「选中态」上的做法）。
local CAL_HEAT_TEXT = {
    Blitbuffer.COLOR_BLACK,
    Blitbuffer.COLOR_BLACK,
    Blitbuffer.COLOR_BLACK,
    Blitbuffer.COLOR_BLACK,
    Blitbuffer.COLOR_WHITE,        -- 4
}

-- 按「当天值 / 当月最大值」的比例返回 0~4 档。抽成纯函数是为了能直接喂输入断言输出。
local function heatLevel(value, max_value)
    value = tonumber(value) or 0
    max_value = tonumber(max_value) or 0
    if value <= 0 or max_value <= 0 then return 0 end
    local ratio = value / max_value
    if ratio <= 0.25 then return 1 end
    if ratio <= 0.50 then return 2 end
    if ratio <= 0.75 then return 3 end
    return 4
end

-- 日历里的一格：上面日期、下面数值（没数据时只有日期）。
-- ⚠ 描边只画在今天这一格上 —— 52b 那版「每格都描边」才会把整张日历
-- 切成一张网（用户明确否掉了），这里不会。
local function calendarCell(w, h, day, value_text, is_today, level, on_tap)
    local f = faces()
    level = math.max(0, math.min(4, math.floor(tonumber(level) or 0)))
    local fill = CAL_HEAT_FILL[level + 1]
    local fg = CAL_HEAT_TEXT[level + 1]
    local pad = Screen:scaleBySize(4)
    local col = VerticalGroup:new{ align = "center" }
    -- 两行文字都必须 `padding = 0`。
    col[#col + 1] = text(tostring(day), f.value_small, {
        color = fg, max_width = math.max(1, w - pad), padding = 0,
        bold = is_today,   -- ★ 56：今天 = 日期加粗
    })
    if value_text ~= "" then
        col[#col + 1] = text(value_text, f.value, {
            color = fg, max_width = math.max(1, w - pad), padding = 0,
        })
    end
    -- ⚠ 这里必须用 `SegFill` 而**不能**用 `FrameContainer`：
    -- `FrameContainer:getSize()`（framecontainer.lua:54-67）**忽略**构造时
    -- 传进来的 width/height，只按「子控件 + 2*(margin+bordersize+padding)」反推
    -- ⇒ 传 width 根本撑不出整格，今天那格的黑色底会只跟文字一样宽。
    local cell = SegFill:new{
        width = math.max(1, w),
        height = math.max(1, h),
        radius = 0,
        color = fill,
        border_size = is_today and Screen:scaleBySize(CAL_TODAY_BORDER_PX) or 0,
        border_color = is_today and Blitbuffer.COLOR_BLACK or nil,
        col,
    }
    local box = FixedBox:new{
        width = w, height = h,
        align = "center", vertical_align = "center",
        cell,
    }
    if on_tap then
        return TapBox:new{ box, on_tap = on_tap }
    end
    return box
end

-- 日历网格：星期头行 + 日期格子（周一起始，与日选择器一致）。
function StatisticsPage:buildCalendarGrid(width, avail_rows_h)
    local f = faces()
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local metric = self.cal_metric or "seconds"
    local fmt = self.cal_format or "auto"
    local speed_unit = self.cal_speed_unit or "min"
    local year = tonumber(os.date("%Y", self.anchor)) or 1970
    local month = tonumber(os.date("%m", self.anchor)) or 1
    local today_key = GlobalStats.dateKey(os.time())

    -- 逐日数据：buckets[1] 是 1 号，以此类推（global_stats.lua:694-702）。
    local key = "cal:" .. tostring(self.anchor) .. "|" .. tostring(metric)
    local memo_key = statMemoKey(self.plugin, "month", self.anchor, "calendar")
    local buckets = memoGet(self.plugin, key, memo_key)
        or memoSet(self.plugin, key, memo_key,
            GlobalStats.trend(store, "month", self.anchor, metric))

    local last_day = tonumber(os.date("%d", os.time{
        year = year, month = month + 1, day = 0, hour = 12, min = 0, sec = 0,
    })) or 30
    local first_ts = os.time{ year = year, month = month, day = 1, hour = 12, min = 0, sec = 0 }
    -- `%w`：0 = 周日 … 6 = 周六；表头是周一起始 ⇒ 前导空格 = (%w + 6) % 7
    local leading = ((tonumber(os.date("%w", first_ts)) or 0) + 6) % 7

    -- ── ★★★ 56-cal-time-heat：热力图的分母 = **当月最大的那一天** ──
    -- 必须先扫一遍再画格子（分档要知道 max）。这一步是纯 Lua 数组遍历，
    -- 月末 31 个元素，成本可以忽略；不要为了省这点而去缓存，
    -- 缓存反而会在「切指标 / 切速度单位」时忘记失效。
    local max_value = 0
    for day = 1, last_day do
        local v = calendarCellValue(buckets[day], metric, speed_unit)
        if v > max_value then max_value = v end
    end

    -- ── ★★★ 53-cal-fit：尺寸全部**按真实字体行高**算（见 faceLineH 的注释）──
    local cell_w = math.floor(width / 7)
    local nav_pad = Screen:scaleBySize(CAL_NAV_PAD_PX)
    local cell_pad = Screen:scaleBySize(CAL_CELL_PAD_PX)
    -- 星期头：`f.axis` 实际 31px ⇒ 行高 43，比设计值 scaleBySize(22)=40 高，
    -- 所以取 max（否则「一二三四五六日」上下各被切 1~2px）。
    local head_h = math.max(Screen:scaleBySize(CAL_HEAD_H_PX),
        faceLineH(f.axis) + 2 * nav_pad)
    -- 日期格：日期行 + 数值行 + 上下内边距。
    local day_line_h = faceLineH(f.value_small)   -- 47（34px NotoSans）
    local val_line_h = faceLineH(f.value)         -- 33（24px NotoSans）
    local need_cell_h = day_line_h + val_line_h + 2 * cell_pad
    local cell_h = math.max(Screen:scaleBySize(CAL_CELL_H_PX), need_cell_h)
    -- 预算：有就压到预算内，但**绝不小于 `need_cell_h`** ——
    -- 宁可不填满整页，也不能再切字。
    local rows = math.max(1, math.ceil((leading + last_day) / 7))
    if avail_rows_h and avail_rows_h > 0 then
        local budget = math.floor(avail_rows_h / rows)
        if budget > 0 and budget < cell_h then
            cell_h = math.max(need_cell_h, budget)
        end
    end
    local grid = VerticalGroup:new{ align = "left" }

    local weekdays = { "一", "二", "三", "四", "五", "六", "日" }
    local head = HorizontalGroup:new{ align = "center" }
    for i = 1, 7 do
        head[#head + 1] = FixedBox:new{
            width = cell_w, height = head_h,
            align = "center", vertical_align = "center",
            text(weekdays[i], f.axis, {
                color = Blitbuffer.COLOR_DARK_GRAY,
                max_width = math.max(1, cell_w - Screen:scaleBySize(4)),
                padding = 0,   -- ★ 52-cell-fit：同导航行，去掉 TextWidget 白送的 8px
            }),
        }
    end
    grid[#grid + 1] = head
    grid[#grid + 1] = VerticalSpan:new{ width = Size.span.vertical_default }

    local row = HorizontalGroup:new{ align = "center" }
    local filled = 0
    local function flush()
        while filled % 7 ~= 0 do
            row[#row + 1] = FixedBox:new{ width = cell_w, height = cell_h }
            filled = filled + 1
        end
        grid[#grid + 1] = row
        row = HorizontalGroup:new{ align = "center" }
    end

    for _i = 1, leading do
        row[#row + 1] = FixedBox:new{ width = cell_w, height = cell_h }
        filled = filled + 1
    end
    for day = 1, last_day do
        -- 取值走 `calendarCellValue`（速度在这里做「字/分钟 → 字/小时」换算），
        -- 文案走 `calendarCellText`，深浅走 `heatLevel(value, max_value)`。
        local value = calendarCellValue(buckets[day], metric, speed_unit)
        local value_text = calendarCellText(value, metric, fmt)
        local level = heatLevel(value, max_value)
        local day_ts = os.time{ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 }
        local is_today = (GlobalStats.dateKey(day_ts) == today_key)
        row[#row + 1] = calendarCell(cell_w, cell_h, day, value_text, is_today, level, function()
            self:reload{ period = "day", anchor = day_ts }
            return true
        end)
        filled = filled + 1
        if filled % 7 == 0 then flush() end
    end
    if filled % 7 ~= 0 then flush() end
    return grid
end

-- 日历视图的整页内容：指标轨道 + 写法轨道 + 月份导航 + 网格。
function StatisticsPage:buildCalendarPage(width, avail_h)
    local f = faces()
    local body = VerticalGroup:new{ align = "left" }
    local metric = self.cal_metric or "seconds"
    -- 本页「网格以上」已经占掉的高度，用来给网格留预算。
    local used = 0
    local function add(w)
        body[#body + 1] = w
        local sz = w:getSize()
        used = used + ((sz and sz.h) or 0)
        return w
    end

    -- ── 指标轨道：字数 / 速度 / 时间 ──
    local metric_items = {}
    for _i, m in ipairs(CAL_METRICS) do
        local value = m.value
        metric_items[#metric_items + 1] = {
            label = m.label,
            face = f.tab,
            active = (value == metric),
            on_tap = function()
                if value ~= self.cal_metric then
                    self:reload{ view = "calendar", cal_metric = value }
                end
                return true
            end,
        }
    end
    add(buildSegmentedRow{
        width = width,
        height = Screen:scaleBySize(ROW_TAB_H_PX),
        radius = Screen:scaleBySize(NAV_TRACK_RADIUS_PX),
        items = metric_items,
    })

    -- ── 单位轨道（**按指标二选一出现**）────────────────────────────────
    -- · 字数 → 「自动 / k / 万」
    local function unitRow(defs, active_value, field)
        add(VerticalSpan:new{ width = Size.span.vertical_default })
        local items = {}
        for _i, d in ipairs(defs) do
            local value = d.value
            items[#items + 1] = {
                label = d.label,
                face = f.tab,
                active = (value == active_value),
                on_tap = function()
                    if value ~= self[field] then
                        local opts = { view = "calendar" }
                        opts[field] = value
                        self:reload(opts)
                    end
                    return true
                end,
            }
        end
        add(buildSegmentedRow{
            width = width,
            height = Screen:scaleBySize(CAL_FMT_ROW_H_PX),
            radius = Screen:scaleBySize(NAV_TRACK_RADIUS_PX),
            items = items,
        })
    end

    if metric == "units" then
        unitRow(CAL_FORMATS, self.cal_format, "cal_format")
    elseif metric == "speed" then
        unitRow(CAL_SPEED_UNITS, self.cal_speed_unit, "cal_speed_unit")
    end

    add(VerticalSpan:new{ width = Size.span.vertical_default })

    local year = tonumber(os.date("%Y", self.anchor)) or 1970
    local month = tonumber(os.date("%m", self.anchor)) or 1
    local nav = VerticalGroup:new{ align = "left" }
    local arrow_w = Screen:scaleBySize(CAL_ARROW_W_PX)
    -- 导航行高按**真实字高**算。
    -- ⇒ 设计值 40 差了 27px，「2026 年 / 10 月」和两个 ‹ › 上下各被切十几像素。
    local nav_pad = Screen:scaleBySize(CAL_NAV_PAD_PX)
    local head_h = math.max(Screen:scaleBySize(CAL_HEAD_H_PX),
        faceLineH(f.section) + 2 * nav_pad)
    -- 箭头改用 KOReader 原生 chevron（与 buildPeriodNav 统一），
    -- 年份/月份文字点击弹出对应的选择器。
    local arrow_icon = Screen:scaleBySize(18)
    local function arrow(icon_name, on_click)
        return TapBox:new{
            FixedBox:new{
                width = arrow_w, height = head_h,
                align = "center", vertical_align = "center",
                icon(icon_name, arrow_icon),
            },
            on_tap = on_click,
        }
    end
    local title_w = math.max(1, width - 2 * arrow_w)
    -- kind = "year" 只改年，kind = "month" 只改月。
    local function navRow(label_text, kind)
        local function go(delta)
            return function()
                local y, m = year, month
                if kind == "year" then y = y + delta else m = m + delta end
                self:reload{
                    view = "calendar",
                    anchor = anchorAtMonth(self.anchor, y, m),
                }
                return true
            end
        end
        local row = HorizontalGroup:new{ align = "center" }
        row[#row + 1] = arrow("chevron.left", go(-1))
        -- 中间文字：点击弹出年份/月份选择器
        local title_widget = FixedBox:new{
            width = title_w, height = head_h,
            align = "center", vertical_align = "center",
            text(label_text, f.section, {
                color = Blitbuffer.COLOR_BLACK, bold = true,
                max_width = math.max(1, title_w - Screen:scaleBySize(6)),
                padding = 0,   -- ★ 52-cell-fit：同上
            }),
        }
        row[#row + 1] = TapBox:new{
            title_widget,
            on_tap = function()
                if kind == "year" then
                    self:showYearPicker()
                else
                    self:showMonthPicker("month")
                end
                return true
            end,
        }
        row[#row + 1] = arrow("chevron.right", go(1))
        return row
    end
    nav[#nav + 1] = navRow(T(_("%1 年"), year), "year")
    nav[#nav + 1] = navRow(T(_("%1 月"), month), "month")
    add(nav)
    add(VerticalSpan:new{ width = Size.span.vertical_default })

    -- ── 网格：把「本页剩余可用高」传下去，让它自己决定每格多高 ──
    local avail_rows_h = nil
    if avail_h and avail_h > 0 then
        avail_rows_h = avail_h - used
    end
    add(self:buildCalendarGrid(width, avail_rows_h))
    return body
end

-- 总览 / 趋势 / 阅读字数 / 阅读速度。
-- ⇒ 未选中 = 白底黑框；选中 = 黑底白字。
function StatisticsPage:buildViewTabs(width)
    local face = Font:getFace("cfont", 17)
    local items = {}
    for j = 1, #VIEW_TABS do
        local tab = VIEW_TABS[j]
        local active = tab.value == self.view
        local target = tab.value
        items[#items + 1] = {
            label = tab.label,
            face = face,
            active = active,
            on_tap = function()
                if target ~= self.view then self:reload{ view = target } end
                return true
            end,
        }
    end
    return buildSegmentedRow{
        width = width,
        height = Screen:scaleBySize(ROW_TAB_H_PX),
        radius = Screen:scaleBySize(NAV_TRACK_RADIUS_PX),
        items = items,
    }
end

-- 日 / 周 / 月 / 年 / 总
-- 同「不选中描边、选中反白」的规则。
function StatisticsPage:buildTabs(width)
    local f = faces()
    local items = {}
    for _i, tab in ipairs(TABS) do
        local active = (tab.value == self.period)
        local target = tab.value
        items[#items + 1] = {
            label = tab.label,
            face = f.tab,
            active = active,
            -- **点已选中的周期标签 = 弹出该粒度的选择器**。
            -- ⇒ 两级语义：
            -- · 点**未选中**的标签 → 只切粒度（不打断，不弹窗）
            on_tap = function()
                if active then
                    self:showPeriodPicker(target)
                else
                    self:reload{ period = target, anchor = self.anchor }
                end
                return true
            end,
        }
    end
    return buildSegmentedRow{
        width = width,
        height = Screen:scaleBySize(ROW_TAB_H_PX),
        radius = Screen:scaleBySize(NAV_TRACK_RADIUS_PX),
        items = items,
    }
end

-- 周期导航条（★★★ 37f 布局：双行 + **六个箭头**，37i 恢复此形状）
-- ⇒ 明确布局：
-- · 第一行「2026年」左右**最远端**各一个箭头 → 按**年**翻   （2 个）
function StatisticsPage:buildPeriodNav(width, range_label)
    local f = faces()
    local line_h = Screen:scaleBySize(34)
    -- 37f/37i：**两行**（年 / 月日）—— nav_h 相应改成 2 行高。
    -- ⚠ 改这里必须同步改 buildUnitsPage 的 PERIODNAV_H 预算，见那里的注释。
    local nav_h = line_h * 2 + Size.padding.tiny

    -- 年月日两段文字
    local year_label, month_day_label = GlobalStats.navLabels(self.period, self.anchor)
    if not year_label then year_label = range_label or "" end
    if self.period == "total" then
        year_label, month_day_label = _("累计"), nil
    end

    -- 第二行**只说「比第一行更细」的那部分**。
    -- ⚠ 只改**文字**，控件结构与热区一律不动：第二行里「内=日 / 外=月」
    if self.period == "year" then
        month_day_label = _("全年")
    elseif self.period == "month" then
        local mm = tonumber(os.date("%m", self.anchor))
        if mm then month_day_label = string.format("%d月", mm) end
    end

    -- 37f/37i：用户要的方案（两行 + 六箭头，由外到内对称）。
    local arrow_icon = Screen:scaleBySize(18)     -- 适当放大（原来 13px 太小）
    local arrow_w = Screen:scaleBySize(30)        -- 触摸热区（透明，不画任何东西）
    local disabled = (self.period == "total")

    -- 固定粒度的翻格箭头：每个箭头翻什么粒度**写死**，位置固定 ⇒ 行为可预期。
    -- 裸箭头：只有 glyph + 透明热区。
    local function stepArrow(icon_name, fixed_period, delta)
        -- 关键坑：`icon()` 出来的 IconWidget **没有 color 字段**，
        -- 置灰只能 `dim = true`（沿用 37c 结论）。
        local glyph = icon(icon_name, arrow_icon, { dim = disabled })
        local hit = FixedBox:new{
            width = arrow_w, height = line_h,
            align = "center", vertical_align = "center", glyph,
        }
        if disabled then return hit end
        return TapBox:new{
            hit,
            on_tap = function()
                self:reload{
                    period = fixed_period,
                    anchor = GlobalStats.shiftAnchor(fixed_period, self.anchor, delta),
                }
                return true
            end,
        }
    end

    -- 第 1 行：年 —— 左右**最远端**各一个箭头（翻年），中间是年文字。
    -- ⚠ 边框色字段是 **`color`**，不是 `bordercolor`
    -- （upstream framecontainer.lua:29 声明 `color`、:139 `paintBorder(..., self.color, ...)`）。
    local year_center_widget
    if disabled then
        -- 「累计」没有年份可选：只把文字居中，**不画胶囊**。
        -- 画了会让人以为能点，点了却什么都不发生。
        year_center_widget = FixedBox:new{
            width = math.max(1, width - 2 * arrow_w), height = line_h,
            align = "center", vertical_align = "center",
            text(year_label or "", f.period, { bold = true }),
        }
    else
        -- **年份去掉边框**（用户原话：「年份不要有边框」）。
        -- ⇒ 整个 FrameContainer 撤掉（边框、圆角、左右 padding 一并没了），
        -- 只留一行加粗文字 —— 与下面「月日」那行的文字样式同一套语言。
        year_center_widget = TapBox:new{
            FixedBox:new{
                width = math.max(1, width - 2 * arrow_w), height = line_h,
                align = "center", vertical_align = "center",
                text(year_label or "", f.period, { bold = true }),
            },
            on_tap = function()
                self:showYearPicker()
                return true
            end,
        }
    end
    local year_row = HorizontalGroup:new{
        align = "center",
        stepArrow("chevron.left", "year", -1),
        year_center_widget,
        stepArrow("chevron.right", "year", 1),
    }

    local rows = VerticalGroup:new{ align = "center" }
    rows[#rows + 1] = year_row

    -- 第 2 行：月日 —— **三层**（外：月箭头；内：日箭头；中：月日文字）。
    if not disabled and month_day_label then
        local md_text = text(month_day_label, f.footer, { bold = true })
        -- 中间簇：日‹ + [tiny] + 月日 + [tiny] + 日›
        -- 点文字下钻到「日」（保留 37c 手感）。
        local md_text_widget = md_text
        if not disabled then
            -- 点第 2 行文字 = 弹**当前粒度**的选择器。
            -- ⇒ 一句话：「点这行文字，就是选这一行代表的那个格子」。
            md_text_widget = TapBox:new{ md_text, on_tap = function()
                self:showPeriodPicker(self.period)
                return true
            end }
        end
        local mid_cluster = HorizontalGroup:new{
            align = "center",
            stepArrow("chevron.left", "day", -1),         -- 日箭头（贴月日，左）
            HorizontalSpan:new{ width = Size.padding.tiny },
            md_text_widget,
            HorizontalSpan:new{ width = Size.padding.tiny },
            stepArrow("chevron.right", "day", 1),         -- 日箭头（贴月日，右）
        }
        -- 外层：月箭头(最外左) + [弹性留白] + 中间簇 + [弹性留白] + 月箭头(最外右)
        -- ⚠ 弹性留白用 HorizontalSpan{width=1} 不够 —— 需要"填满剩余"。
        local mid_box_w = math.max(1, width - 2 * arrow_w)
        rows[#rows + 1] = HorizontalGroup:new{
            align = "center",
            stepArrow("chevron.left", "month", -1),       -- 月箭头（最外左）
            FixedBox:new{
                width = mid_box_w, height = line_h,
                align = "center", vertical_align = "center", mid_cluster,
            },
            stepArrow("chevron.right", "month", 1),       -- 月箭头（最外右）
        }
    end

    return FixedBox:new{
        width = width, height = nav_h,
        align = "left", vertical_align = "center", rows,
    }
end

-- 标题点击：在同一天（anchor）上循环切换粒度
-- 年 → 月 → 日 → 周 → 总 → 年 …
---
function StatisticsPage:cyclePeriodGranularity()
    local ORDER = { "year", "month", "day", "week", "total" }
    -- 找当前粒度在顺序里的位置，取下一个
    local idx = 1
    for i, p in ipairs(ORDER) do
        if p == self.period then idx = i break end
    end
    local next_period = ORDER[(idx % #ORDER) + 1]
    -- anchor 保持不变（还在同一天），只是换「看这一天的年/这一天的月/这一天…」
    self:reload{ period = next_period, anchor = self.anchor }
end

-- 直接切到**指定粒度**（不循环）。
function StatisticsPage:cycleToGranularity(target)
    if not target then return end
    if target == self.period then
        -- 已经是这个粒度：什么都不做（不重建、不闪屏）
        return
    end
    self:reload{ period = target, anchor = self.anchor }
end

-- 卡片网格。
-- ⚠ 少一行是**省高度**，不是费高度 —— 这才是解决「放不下」的正路。
local CARD_MIN_W = Screen:scaleBySize(118)
local CARD_DEFAULT_COLS = 4     -- 49-cards：用户要求的每行卡片数
local CARD_MAX_COLS = 4         -- 硬上限（宽屏也别超过，否则字太小）

-- 决定列数：优先 3 列；宽度不够才退。纯函数，便于行为测试。
local function decideCardCols(width, gap, min_w, want_cols, max_cols)
    min_w = min_w or CARD_MIN_W
    want_cols = want_cols or CARD_DEFAULT_COLS
    max_cols = max_cols or CARD_MAX_COLS
    local fit = math.floor((width + gap) / (min_w + gap))
    local cols = math.min(want_cols, fit)
    cols = math.max(1, math.min(max_cols, cols))
    return cols
end

-- 卡片样式切换行。
function StatisticsPage:buildCardStyleRow(width)
    local f = faces()
    local row = HorizontalGroup:new{ align = "center" }

    -- 左侧小标题「卡片样式」，右侧四个样式按钮
    local label_w = Screen:scaleBySize(76)
    row[#row + 1] = FixedBox:new{
        width = label_w, height = Screen:scaleBySize(32),
        align = "left", vertical_align = "center",
        text(_("卡片样式"), f.footer, { color = Blitbuffer.COLOR_DARK_GRAY }),
    }
    row[#row + 1] = HorizontalSpan:new{ width = Size.padding.small }

    local n = #CARD_STYLES
    local btn_w = math.floor((width - label_w - Size.padding.small * (n - 1)) / n)
    if btn_w < Screen:scaleBySize(40) then
        btn_w = math.max(Screen:scaleBySize(28), math.floor(width / n))
    end
    local btn_h = Screen:scaleBySize(32)
    local current = cardStyleValid(self.card_style) and self.card_style or "box"

    for i, style in ipairs(CARD_STYLES) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = Size.padding.small } end
        local active = (style.value == current)
        local target = style.value
        row[#row + 1] = FrameContainer:new{
            width = btn_w, height = btn_h,
            bordersize = Screen:scaleBySize(1), bordercolor = Blitbuffer.COLOR_BLACK,
            radius = Size.radius.button,
            background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            padding = 0,
            TapBox:new{
                FixedBox:new{ width = btn_w, height = btn_h,
                    align = "center", vertical_align = "center",
                    text(style.label, Font:getFace("cfont", 15), {
                        color = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                        bold = active,
                    }) },
                on_tap = function()
                    if target ~= self.card_style then
                        self:reload{ card_style = target, view = "overview" }
                    end
                    return true
                end,
            },
        }
    end

    return row
end

function StatisticsPage:buildCardGrid(width, summary, previous)
    local gap = Size.padding.default
    local style = cardStyleValid(self.card_style) and self.card_style or "box"
    -- 「连线」样式不用间隙，卡片紧贴、由线分隔 ⇒ gap 记 0。
    local cell_gap = (style == "grid") and 0 or gap
    local cols = decideCardCols(width, cell_gap)
    local card_w = math.floor((width - cell_gap * (cols - 1)) / cols)
    local inner_w = card_w - 2 * Size.padding.default
    if inner_w < Screen:scaleBySize(30) then
        inner_w = math.max(Screen:scaleBySize(20), card_w - 2 * Size.padding.small)
    end

    local function diff(current, old)
        if old == nil then return nil end
        return (tonumber(current) or 0) - (tonumber(old) or 0)
    end

    -- 「阅读字数」与「阅读速度」放在**所有同级卡片的最前面**。
    local specs = {
        {
            id = "units", icon = "align.justify", label = _("阅读字数"),
            parts = formatCountParts(summary.units, _("字")),
            kind = "units", delta = diff(summary.units, previous and previous.units), drill = "units",
        },
        {
            id = "speed", icon = "zoom.content", label = _("阅读速度"),
            parts = summary.seconds > 0 and formatCountParts(summary.speed, _("字/分钟"))
                or { { text = "0", big = true }, { text = _("字/分钟"), big = false } },
            kind = "speed", delta = summary.seconds > 0
                and diff(summary.speed, previous and previous.speed) or nil,
            drill = "speed",
        },
        {
            id = "seconds", icon = "history", label = _("阅读时间"),
            parts = formatDurationParts(summary.seconds),
            kind = "duration", delta = diff(summary.seconds, previous and previous.seconds),
        },
        {
            id = "days", icon = "bookmark", label = _("阅读天数"),
            parts = formatCountParts(summary.days, _("天")),
            kind = "days", delta = diff(summary.days, previous and previous.days),
        },
        {
            id = "average", icon = "dogear.reading", label = _("日均阅读时长"),
            parts = formatDurationParts(summary.average_day_seconds),
            kind = "duration", delta = diff(summary.average_day_seconds, previous and previous.average_day_seconds),
        },
        {
            id = "longest", icon = "move.up", label = _("单日阅读最久"),
            parts = formatDurationParts(summary.longest_day),
            kind = "duration", delta = diff(summary.longest_day, previous and previous.longest_day),
            drill = "days",
        },
        {
            id = "books_read", icon = "book.opened", label = _("累计读过"),
            parts = formatCountParts(summary.books_read, _("本")),
            kind = "books", delta = diff(summary.books_read, previous and previous.books_read),
            drill = "books_read",
        },
        {
            id = "books_completed", icon = "dogear.complete", label = _("读完书籍"),
            parts = formatCountParts(summary.books_completed, _("本")),
            kind = "books", delta = diff(summary.books_completed, previous and previous.books_completed),
            drill = "books_completed",
        },
    }

    -- 先量出最高的卡片，再统一套用，保证每行严格等高
    for _i, spec in ipairs(specs) do
        if spec.delta and spec.delta ~= 0 then
            spec.delta_text = deltaArrow(spec.delta) .. deltaText(spec.kind, math.abs(spec.delta))
        end
    end
    -- ⚠ 标签行要给行尾的 `>`（scaleBySize(13)=23px）留位，所以可用宽要减
    -- scaleBySize(20)=36px —— 这个数必须和 buildCardContent 里的
    -- `max_width` 算法**保持一致**，否则「量出来放得下、画出来折行」。
    local label_avail = inner_w - Screen:scaleBySize(20)
    local label_face = pickCardFace(specs, "label", label_avail,
        CARD_LABEL_SIZE_LADDER, "smallinfofont")
    local delta_face = pickCardFace(specs, "delta_text", inner_w,
        CARD_DELTA_SIZE_LADDER, "smallinfofont")
    -- 大数字也要统一档位（用户：「卡片字体一致一点啊」）。
    local value_pair = pickValuePair(specs, inner_w)

    local contents = {}
    local card_h = 0
    for i, spec in ipairs(specs) do
        contents[i] = buildCardContent(spec, inner_w, label_face, delta_face, value_pair)
        card_h = math.max(card_h, contents[i]:getSize().h)
    end
    card_h = card_h + 2 * Size.padding.default

    local grid = VerticalGroup:new{ align = "left" }

    -- 34「连线」样式：相邻卡片之间靠一条竖线（VRule）连接，
    -- 行与行之间一条横线（HRule）。卡片自身不带框（wrapCard 已处理），
    -- 这里在每张卡**右侧**插一条竖线即可 —— 下一个格子的卡紧贴它，
    -- 视觉上就是「两个卡片中间只用一条线连接」。
    local line_w = Screen:scaleBySize(1)
    local n_rows = math.ceil(#specs / cols)

    local row
    for i, spec in ipairs(specs) do
        local col = (i - 1) % cols
        local is_last_col = (col == cols - 1)
        local is_last_spec = (i == #specs)
        if col == 0 then
            if row then
                grid[#grid + 1] = row
                if style == "grid" then
                    grid[#grid + 1] = HRule:new{ width = width, height = line_w,
                        color = Blitbuffer.COLOR_BLACK }
                else
                    grid[#grid + 1] = VerticalSpan:new{ width = cell_gap }
                end
            end
            row = HorizontalGroup:new{ align = "top" }
        end

        local drill = spec.drill
        local tap = drill and function()
            if drill == "units" or drill == "speed" then
                self:reload{ view = drill }
            else
                showDrillDown(self, self.plugin, spec.label, self:drillRows(drill))
            end
            return true
        end or nil

        local cell = wrapCard(contents[i], card_w, card_h, style, tap)
        if style == "grid" then
            -- 每个格子 = 卡 + 右侧竖线（最后一列不画右线，避免右边界多一条）
            if is_last_col or is_last_spec then
                row[#row + 1] = cell
            else
                row[#row + 1] = FixedBox:new{
                    width = card_w + line_w,
                    height = card_h,
                    HorizontalGroup:new{
                        align = "top",
                        cell,
                        VRule:new{ width = line_w, height = card_h,
                            color = Blitbuffer.COLOR_BLACK },
                    },
                }
            end
        else
            if col > 0 then
                row[#row + 1] = HorizontalSpan:new{ width = cell_gap }
            end
            row[#row + 1] = cell
        end
    end

    -- 最后一行不足 cols 张时，用空占位补齐宽度，
    -- 否则该行整体靠左、右端留白，和上面几行的右边界对不齐。
    if row then
        local placed = #specs % cols
        if placed > 0 then
            for _k = placed + 1, cols do
                if style == "grid" then
                    -- 先把上一格与这一格之间的竖线补上
                    row[#row + 1] = FixedBox:new{
                        width = line_w, height = card_h,
                        VerticalGroup:new{ align = "left",
                            VRule:new{ width = line_w, height = card_h,
                                color = Blitbuffer.COLOR_BLACK } },
                    }
                    row[#row + 1] = FixedBox:new{ width = card_w, height = card_h }
                else
                    row[#row + 1] = HorizontalSpan:new{ width = cell_gap }
                    row[#row + 1] = FixedBox:new{ width = card_w, height = card_h }
                end
            end
        end
        grid[#grid + 1] = row
        if style == "grid" then
            grid[#grid + 1] = HRule:new{ width = width, height = line_w,
                color = Blitbuffer.COLOR_BLACK }
        end
    end

    return FixedBox:new{ width = width, align = "left", grid }
end

-- 下钻数据
-- 注意：循环变量不能叫 `_`，否则后面 T(_(...)) 会拿到下标数字。
function StatisticsPage:drillRows(kind)
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local rows = {}
    if kind == "days" then
        for _i, item in ipairs(GlobalStats.details(store, self.period, self.anchor, "days")) do
            rows[#rows + 1] = { item.date, formatDuration(item.seconds) }
        end
    else
        for _i, item in ipairs(GlobalStats.details(store, self.period, self.anchor, kind)) do
            local suffix
            if item.total_units and item.total_units > 0 then
                suffix = T(_("%1 / %2"), formatCount(item.read_units), formatCount(item.total_units))
            else
                suffix = formatCount(item.read_units)
            end
            rows[#rows + 1] = { item.title or item.path, suffix }
        end
    end
    return rows
end

-- 「阅读字数」视图（★★★ 35 重做）
function StatisticsPage:buildUnitsPage(width)
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local memo_key = statMemoKey(self.plugin, self.period, self.anchor, "units")
    local dkey = "units_details:" .. tostring(self.period) .. "|" .. tostring(self.anchor)
    local details = memoGet(self.plugin, dkey, memo_key)
        or memoSet(self.plugin, dkey, memo_key,
            GlobalStats.details(store, self.period, self.anchor, "books_read"))
    local sort = self.unit_sort or "units"
    table.sort(details, function(a, b)
        if sort == "title" then return tostring(a.title) < tostring(b.title) end
        if sort == "date" then return (a.last_read_date or "") > (b.last_read_date or "") end
        return (a.read_units or 0) > (b.read_units or 0)
    end)

    -- 本页每屏能放几行（自适应）。
    local row_h = Screen:scaleBySize(40)
    local line_w = Screen:scaleBySize(1)
    local v_def = Size.span.vertical_default     -- = scaleBySize(2)
    local v_large = Size.span.vertical_large     -- = scaleBySize(5)
    local SCROLL_SAFETY = Screen:scaleBySize(8)  -- 底部安全边（防浮窗边框吃掉最后一行）

    -- ── 列表**上方**的固定占高 ──────────────────────────────────────────
    -- 逐项对应 build() 里的 body 与 buildUnitsPage 开头：
    -- 浮窗边框(2×border) + title_bar + span.v_def + viewTabs(38)
    local TITLEBAR_H = Screen:scaleBySize(34)    -- TitleBar 标题文字行高（含下划线内边距的保守值）
    -- 视图排 / 周期排都改引用统一的 `ROW_TAB_H_PX`。
    local VIEWTAB_H  = Screen:scaleBySize(ROW_TAB_H_PX)
    local TABS_H     = Screen:scaleBySize(ROW_TAB_H_PX)
    -- buildPeriodNav 现在是「**两**行 × line_h(34)」= scaleBySize(68)，
    -- 这里必须跟着改，否则预算又对不上（这正是翻页栏被顶掉的老病根）。
    local PERIODNAV_H = Screen:scaleBySize(34)   -- ← 与 buildPeriodNav 的 line_h 一致
                      * 2                        -- ← 37f/37i 两行（年一行 + 月日一行）
                      + Size.padding.tiny
    local SORTROW_H  = Screen:scaleBySize(36)
    local STATUS_H   = Screen:scaleBySize(30)
    local POPUP_BORDER_H = 2 * Screen:scaleBySize(2)
    local chrome_top = POPUP_BORDER_H + TITLEBAR_H
        + v_def + VIEWTAB_H + v_large + TABS_H + v_def + PERIODNAV_H
        + v_large + SORTROW_H + v_def + STATUS_H + Size.padding.small
    -- ── 列表**下方**的固定占高（点线 + span + 翻页栏 + 底部大间距）─────
    local NAVBAR_H = Screen:scaleBySize(44)      -- ← 与 buildUnitsPage 翻页栏 nav_h 一致
    local chrome_bottom = line_w + Size.padding.small + NAVBAR_H + v_large

    local chrome_h = chrome_top + chrome_bottom + SCROLL_SAFETY
    local avail_h = self._available_h or (Screen:getHeight() * 0.9)
    local avail = avail_h - chrome_h
    local rows_per_page = math.floor(avail / (row_h + line_w))
    rows_per_page = math.max(3, math.min(UNIT_PAGE_SIZE_MAX, rows_per_page))
    self._unit_page_size = rows_per_page

    local group = VerticalGroup:new{ align = "left" }

    -- 排序行：字数 / 最近阅读 / 书名（沿用 32 的黑底反白选中样式）
    local sort_row = HorizontalGroup:new{ align = "center" }
    local sorts = {
        { value = "units", label = _("字数") },
        { value = "date", label = _("最近阅读") },
        { value = "title", label = _("书名") },
    }
    local sort_cell_w = math.floor((width - Size.padding.small * 2) / 3)
    for i, item in ipairs(sorts) do
        if i > 1 then sort_row[#sort_row + 1] = HorizontalSpan:new{ width = Size.padding.small } end
        local active = sort == item.value
        local target = item.value
        sort_row[#sort_row + 1] = FrameContainer:new{
            width = sort_cell_w,
            height = Screen:scaleBySize(36),
            bordersize = Screen:scaleBySize(1), bordercolor = Blitbuffer.COLOR_BLACK,
            radius = Size.radius.button,
            background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            padding = 0,
            TapBox:new{
                FixedBox:new{ width = sort_cell_w, height = Screen:scaleBySize(36),
                    align = "center", vertical_align = "center",
                    text(item.label, Font:getFace("cfont", 17), {
                        color = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                        bold = active,
                    }) },
                -- 换排序时**回到第 1 页**（排序变了，页码不再有意义）
                on_tap = function()
                    if target ~= self.unit_sort then
                        self:reload{ unit_sort = target, view = "units", unit_page = 1 }
                    end
                    return true
                end,
            },
        }
    end
    group[#group + 1] = sort_row
    group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }

    -- 分页计算：把 details 切成每页 rows_per_page（行数自适应，见上）
    local per = rows_per_page
    local total_rows = #details
    local total_pages = math.max(1, math.ceil(total_rows / per))
    -- 供 pageUnits() 绕页用（它读 self._unit_total_pages）
    self._unit_total_pages = total_pages
    local page = tonumber(self.unit_page) or 1
    if page < 1 then page = 1 end
    if page > total_pages then page = total_pages end
    self.unit_page = page
    local first_idx = (page - 1) * per + 1
    local last_idx = math.min(total_rows, first_idx + per - 1)

    -- 页码状态行：左「第 X / Y 页」右「本页合计」（空列表时不显示）
    if total_rows > 0 then
        local page_units = 0
        for _i = first_idx, last_idx do
            page_units = page_units + (tonumber(details[_i].read_units) or 0)
        end
        local status = FixedBox:new{
            width = width, height = Screen:scaleBySize(30),
            align = "left", vertical_align = "center",
            HorizontalGroup:new{
                align = "center",
                text(T(_("第 %1 / %2 页"), page, total_pages),
                    faces().footer, { color = Blitbuffer.COLOR_BLACK }),
                HorizontalSpan:new{ width = Size.padding.small },
                FixedBox:new{ width = math.max(0, width - Screen:scaleBySize(120)),
                    height = Screen:scaleBySize(30), align = "right", vertical_align = "center",
                    text(T(_("本页合计 %1 字"), formatCount(page_units)),
                        faces().footer, { color = Blitbuffer.COLOR_DARK_GRAY }) },
            },
        }
        group[#group + 1] = status
        group[#group + 1] = VerticalSpan:new{ width = Size.padding.small }
    end

    -- 行列表：书名 + 已读字数，**行间点线分隔**（不是外框、不是灰底）
    if total_rows == 0 then
        group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
        group[#group + 1] = text(_("当前周期没有阅读字数记录"),
            faces().footer, { color = Blitbuffer.COLOR_BLACK })
        return group
    end

    local right_w = math.floor(width * 0.36)
    local left_w = width - right_w - Size.padding.small
    -- ⚠ 绝不能写 `for _, item`：本文件顶部有 `local _ = require("gettext")`，
    -- Lua 里 `_` 是普通变量名，`for _, item` 会把它覆盖成数字下标，
    -- 循环体里任何 _("...") 都会报 attempt to call local '_' (a number value)。
    for _i = first_idx, last_idx do
        local item = details[_i]
        local title = tostring(item.title or item.path or _("未知书籍"))
        local value = formatCount(item.read_units or 0)
        group[#group + 1] = FixedBox:new{
            width = width, height = row_h,
            align = "left", vertical_align = "center",
            HorizontalGroup:new{
                align = "center",
                FixedBox:new{ width = left_w, height = row_h,
                    align = "left", vertical_align = "center",
                    text(title, faces().label, { color = Blitbuffer.COLOR_BLACK,
                        max_width = left_w - Size.padding.small }) },
                HorizontalSpan:new{ width = Size.padding.small },
                FixedBox:new{ width = right_w, height = row_h,
                    align = "right", vertical_align = "center",
                    text(value, faces().footer, { color = Blitbuffer.COLOR_BLACK,
                        max_width = right_w }) },
            },
        }
        -- 行间点线（本页最后一行不画，交给翻页栏上方的收口线）
        if _i < last_idx then
            group[#group + 1] = HRule:new{ width = width, height = line_w,
                color = Blitbuffer.COLOR_BLACK, dotted = true }
        end
    end

    -- 翻页栏：‹ | 第 X / Y 页 | ›（纯图标按钮 —— 用户 36 要求「只显示图标」）
    -- ⚠ 边框不是我们画的 —— 是上游 `IconButton` 自带 `FrameContainer`
    -- （bordersize=Size.border.button、白底 + 圆角），所以**用 IconButton
    -- 就必然有框**。改法：不再用 IconButton，改用「极简图标 + TapBox」——
    -- 只有箭头本身可点，不画任何边框/底色。
    group[#group + 1] = HRule:new{ width = width, height = line_w,
        color = Blitbuffer.COLOR_BLACK }
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.small }

    -- 用户「箭头都不需要底色和边框，可以适当的大一点」。
    -- ⇒ 退掉 37g 的灰药丸，回到 37b 的「纯箭头裸放」思路。

    -- 37h/37i：翻页栏与 buildPeriodNav 一样，用**裸箭头**
    -- （无底色、无边框，细尖角 chevron）。
    local nav_h = Screen:scaleBySize(44)
    -- 热区：透明，只负责命中面积（不画任何东西）。
    local arrow_w = Screen:scaleBySize(44)
    -- 箭头与页码之间的**固定留白**（让它们「近一点」但不相撞）
    local gap = Size.padding.small
    -- ── 翻页按钮：裸 chevron（无底色、无边框）+ TapBox 热区 ──
    -- ⚠ IconWidget **没有 color 字段**（见 icon() 的注释）——
    -- 想置灰只能走 `dim = true`，不能传 color。
    local arrow_icon = Screen:scaleBySize(18)    -- 37i：放大（原 13px）
    local function navButton(icon_name, enabled, on_tap)
        local glyph = icon(icon_name, arrow_icon, { dim = not enabled })
        local hit = FixedBox:new{ width = arrow_w, height = nav_h,
            align = "center", vertical_align = "center",
            glyph }
        if enabled then
            return TapBox:new{ hit, on_tap = on_tap }
        end
        return hit
    end

    -- 只有一页时两个箭头都置灰（点了也没意义），但仍占位保证布局稳定。
    local can_prev = total_pages > 1
    local can_next = total_pages > 1
    -- 页码用**自然宽度**（不撑满），这样才能跟箭头贴在一起。
    local page_label = text(T(_("第 %1 / %2 页"), page, total_pages), faces().footer,
        { color = Blitbuffer.COLOR_BLACK, bold = true })
    -- 内层「紧凑簇」：‹  [gap]  第X/Y页  [gap]  ›
    local cluster = HorizontalGroup:new{
        align = "center",
        navButton("chevron.left", can_prev, function()
            self:pageUnits(-1)
            return true
        end),
        VerticalSpan:new{ width = gap },
        page_label,
        VerticalSpan:new{ width = gap },
        navButton("chevron.right", can_next, function()
            self:pageUnits(1)
            return true
        end),
    }
    -- 外层 FixedBox 只负责「把这一簇整体居中」，不再把箭头推到两端。
    group[#group + 1] = FixedBox:new{
        width = width, height = nav_h,
        align = "center", vertical_align = "center",
        cluster,
    }

    return group
end

-- 「阅读字数趋势」卡片
function StatisticsPage:buildTrendSection(width, buckets, selected, metric_override)
    local f = faces()
    local pad = Size.padding.large
    local inner_w = width - 2 * pad
    local metric = metric_override or self.metric
    local metric_label = metric == "speed" and _("阅读速度") or self:metricLabel()
    local row_h = Screen:scaleBySize(34)
    local chart_h = row_h * TREND_ROWS
    local is_chart = self.trend_view ~= "list"
    local is_daily_list = self.period == "day" and not is_chart

    -- 上限和「这张图用哪个单位」都**提前**算 ——
    -- 因为下面的**标题**要拿单位（「阅读时长趋势（分）」）。
    local maximum = 0
    for _i, bucket in ipairs(buckets) do
        maximum = math.max(maximum, tonumber(bucket.value) or 0)
    end
    local scale_max = niceMax(maximum)
    local unit = chartUnit(metric, scale_max)

    -- 标题 + 单位。只在**图表视图**里把单位拼进标题：
    -- · 图表视图的柱顶标签是**不带单位**的裸数字（chartBarLabel），
    -- 单位总得有个地方说一次 —— 标题最省地方、而且永远看得见；
    -- · 列表视图每行都写着「14分钟」，标题上再重复一遍纯属啰嗦；
    -- · 指标名里已经含这个单位时不重复（「阅读字数」里已经有「字」）。
    local title_text = is_daily_list and _("按小时阅读记录") or metric_label .. _("趋势")
    if is_chart and not string.find(title_text, unit.suffix, 1, true) then
        title_text = title_text .. "（" .. unit.suffix .. "）"
    end

    -- 标题行 + 图表/列表切换
    local icon_size = Screen:scaleBySize(22)
    local toggle_size = Screen:scaleBySize(42)
    local header = HorizontalGroup:new{ align = "center" }
    header[#header + 1] = text(title_text, f.section, {
        bold = true,
        max_width = inner_w - 2 * toggle_size - Size.padding.large,
    })
    local spacer_w = math.max(0, inner_w - 2 * toggle_size
        - Size.padding.large - header[1]:getSize().w)
    header[#header + 1] = HorizontalSpan:new{ width = spacer_w }
    local function trendToggle(icon_name, target_view)
        local active = self.trend_view == target_view
        local indicator_h = Screen:scaleBySize(2)
        local indicator = active and SolidRect:new{
            width = icon_size,
            height = indicator_h,
            color = Blitbuffer.COLOR_BLACK,
        } or VerticalSpan:new{ width = indicator_h }
        return TapBox:new{
            FixedBox:new{
                width = toggle_size,
                height = toggle_size,
                align = "center",
                vertical_align = "center",
                VerticalGroup:new{
                    align = "center",
                    icon(icon_name, icon_size),
                    VerticalSpan:new{ width = Screen:scaleBySize(2) },
                    indicator,
                },
            },
            on_tap = function()
                if not active then self:reload{ trend_view = target_view } end
                return true
            end,
        }
    end
    header[#header + 1] = trendToggle("column.three", "chart")
    header[#header + 1] = trendToggle("align.justify", "list")

    local section = VerticalGroup:new{ align = "left" }
    section[#section + 1] = header
    section[#section + 1] = VerticalSpan:new{ width = Size.span.vertical_large }

    -- 这里原来有个 `local mean = nil`（本周期均值），
    -- 因为「图表画虚线」和「图例写『虚线＝本期平均 X』」两处都要用它。

    if is_chart then
        -- **没有 Y 轴刻度列了**。
        -- ⇒ 柱子变粗（月视图 slot 22.7 → 29.5px）、整张图**往左移**
        -- （用户要的「适当往左一点」）—— 一个改动同时满足两条要求。
        local chart_w = inner_w

        -- 40-no-y-axis（连带修的坑）：**必须显式给柱顶标签留出上方空间**。
        -- ⚠ 别图省事写死像素：字号一改就不够了（labelMetrics 量的就是真字号）。
        local label_h = labelMetrics("0", f.value).h
        section[#section + 1] = VerticalSpan:new{
            width = label_h + Screen:scaleBySize(14),
        }

        local chart = buildChartWidget(buckets, unit, selected, chart_w, chart_h, scale_max)
        section[#section + 1] = chart

        local tick_h = Screen:scaleBySize(24)
        -- 刻度走**真实 bucket.label**（详见 buildTickRow 的注释）。
        -- 不再需要给 Y 轴列让位，刻度行直接铺满。
        local tick_row = buildTickRow(buckets, chart_w, tick_h, Blitbuffer.COLOR_BLACK)
        section[#section + 1] = tick_row
    elseif is_daily_list then
        local hourly_rows, total_seconds, total_units = buildHourlyActivityList(buckets, inner_w)
        if total_seconds > 0 or total_units > 0 then
            section[#section + 1] = VerticalSpan:new{ width = Screen:scaleBySize(6) }
            section[#section + 1] = text(
                T(_("当天共阅读 %1 字，阅读 %2"), formatCount(total_units), formatDuration(total_seconds)),
                f.footer,
                { bold = true, max_width = inner_w }
            )
            section[#section + 1] = VerticalSpan:new{ width = Screen:scaleBySize(6) }
        end
        section[#section + 1] = hourly_rows
    else
        section[#section + 1] = buildTrendList(buckets, metric, selected, inner_w)
    end

    section[#section + 1] = VerticalSpan:new{ width = Size.span.vertical_large }

    -- **删掉**底部的指标切换行（阅读时间/阅读字数/阅读速度/日均阅读时长）。

    section[#section + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
    section[#section + 1] = HorizontalGroup:new{
        align = "center",
            text(self:footerText(buckets, selected, metric), f.footer, {
            color = Blitbuffer.COLOR_BLACK,
            max_width = inner_w,
        }),
    }

    -- 图表视图下补一行**图例**。
    if is_chart then
        local hint = _("点柱子看具体数值")
        section[#section + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        section[#section + 1] = HorizontalGroup:new{
            align = "center",
            text(hint, f.axis, {
                color = Blitbuffer.COLOR_BLACK,
                max_width = inner_w,
            }),
        }
    end

    return FixedBox:new{
        width = width,
        FrameContainer:new{
            width = width,
            background = Blitbuffer.COLOR_WHITE,
            radius = Size.radius.window,
            bordersize = 0,
            padding = pad,
            margin = 0,
            section,
        },
    }
end

function StatisticsPage:metricLabel()
    for _i, metric in ipairs(METRICS) do
        if metric.value == self.metric then return metric.label end
    end
    return METRICS[2].label
end

function StatisticsPage:footerText(buckets, selected, metric_override)
    local bucket = buckets[selected]
    if not bucket then return "" end
    local metric = metric_override or self.metric
    local label = metric == "speed" and _("阅读速度") or self:metricLabel()
    return T(_("%1 %2 %3"), self:selectedLabel(bucket, selected), label,
        metricValueText(bucket.value, metric))
end

-- 指标切换：两列，选中项打勾
-- 未选中白底描边、选中黑底反白；不再有灰底。
function StatisticsPage:buildMetricLegend(width)
    local f = faces()
    local gap = Size.padding.default
    local cell_w = math.floor((width - gap) / 2)
    local cell_h = Screen:scaleBySize(42)
    local icon_size = Screen:scaleBySize(18)
    local check_size = Screen:scaleBySize(18)

    local function cell(metric)
        local active = (metric.value == self.metric)
        local color = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local row = HorizontalGroup:new{ align = "center" }
        row[#row + 1] = icon(metric.icon, icon_size, { white = active })
        row[#row + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(5) }
        row[#row + 1] = text(metric.label, f.label, {
            color = color,
            bold = active,
            max_width = cell_w - icon_size - check_size - Screen:scaleBySize(16),
        })
        if active then
            row[#row + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(5) }
            row[#row + 1] = icon("check", check_size, { white = true })
        end
        local value = metric.value
        return FixedBox:new{
            width = cell_w,
            height = cell_h,
            align = "left",
            vertical_align = "center",
            TapBox:new{
                FrameContainer:new{
                    width = cell_w - Size.padding.small, height = cell_h,
                    align = "left", vertical_align = "center",
                    bordersize = Screen:scaleBySize(1),
                    bordercolor = Blitbuffer.COLOR_BLACK,
                    radius = Size.radius.button,
                    background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    padding = 0,
                    row,
                },
                on_tap = function()
                    if not active then self:reload{ metric = value } end
                    return true
                end,
            },
        }
    end

    local group = VerticalGroup:new{ align = "left" }
    for i = 1, #METRICS, 2 do
        local row = HorizontalGroup:new{ align = "center", cell(METRICS[i]) }
        if METRICS[i + 1] then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
            row[#row + 1] = cell(METRICS[i + 1])
        end
        group[#group + 1] = row
    end
    return group
end

-- 顶部左图标：快速切换统计周期
function StatisticsPage:showPeriodDialog()
    local current = self.period
    local buttons = { {} }
    for _index, tab in ipairs(TABS) do
        local value = tab.value
        local label = tab.label
        buttons[1][#buttons[1] + 1] = {
            text = value == current and T(_("%1 ✓"), label) or label,
            callback = function()
                UIManager:close(self.dialog)
                if value ~= current then
                    self:reload{ period = value, anchor = os.time() }
                end
            end,
        }
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    self.dialog = ButtonDialog:new{
        title = _("选择统计周期"),
        buttons = buttons,
    }
    -- 不能写成裸的 `UIManager:show(self.dialog)` —— 见 showNoFlash 的注释。
    showNoFlash(self.dialog)
end

function StatisticsPage:showYearPicker()
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local years = GlobalStats.availableYears(store, self.anchor)
    local anchor = tonumber(self.anchor) or os.time()
    local current_year = tonumber(os.date("%Y", anchor)) or 1970

    -- 一条一行：`buttons` 的每一项都是「一行」，里面只放一个按钮。
    local buttons = {}
    for _i, item in ipairs(years) do
        local label = tostring(item.year)
        if item.year == current_year then label = label .. " ✓" end
        -- 每个按钮各自捕获自己的年份（别用循环变量闭包，否则都指向最后一年）
        local year = item.year
        buttons[#buttons + 1] = {
            {
                text = label,
                callback = function()
                    if self.dialog then
                        UIManager:close(self.dialog)
                        self.dialog = nil
                    end
                    if year == current_year then return end
                    -- 用 shiftAnchor 平移：**保留 anchor 的月日**，
                    -- 只把年份挪过去。这样「2026年10月3日 → 看 2021年」之后
                    -- 再切回日视图，落点还是 10月3日，不会莫名其妙变成 1月1日。
                    self:reload{
                        period = "year",
                        anchor = GlobalStats.shiftAnchor("year", anchor, year - current_year),
                    }
                end,
            },
        }
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    self.dialog = ButtonDialog:new{
        title = _("选择年份"),
        -- 这两项照抄补丁：宽度收到「刚好放下最宽的那行」，
        -- 并置 modal 让它盖住统计浮窗（否则点击会穿透到底下的页面）。
        shrink_unneeded_width = true,
        modal = true,
        buttons = buttons,
    }
    -- 不能写成裸的 `UIManager:show(self.dialog)` —— 见 showNoFlash 的注释。
    showNoFlash(self.dialog)
end

-- 周期选择器（年 / 月 / 周）

-- 把 anchor 挪到「目标年月的同一天」，**保留日**。
-- ⚠ 不能直接用 `GlobalStats.shiftAnchor("month", anchor, delta)`：
-- 那个函数是 `dayTimestamp(year, month + delta, 1)` —— 日被写死成 1。
anchorAtMonth = function(anchor, year, month)
    local _y, _m, day = tonumber(os.date("%Y", anchor)), tonumber(os.date("%m", anchor)),
        tonumber(os.date("%d", anchor))
    day = day or 1
    -- 目标月的天数：下个月 1 号往前一天
    local last_day = tonumber(os.date("%d", os.time{
        year = year, month = month + 1, day = 0, hour = 12, min = 0, sec = 0,
    })) or day
    if day > last_day then day = last_day end
    return os.time{ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 }
end

-- 统一的入口：按粒度弹对应的选择器。
function StatisticsPage:showPeriodPicker(granularity)
    granularity = granularity or self.period
    if granularity == "year" then
        self:showYearPicker()
    elseif granularity == "month" then
        self:showMonthPicker(granularity)
    elseif granularity == "day" then
        self:showDayPicker()
    elseif granularity == "week" then
        self:showWeekPicker()
    end
end

-- 月份列表（点「月」/「日」标签或第 2 行文字时弹出）。
function StatisticsPage:showMonthPicker(target_period)
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local months = GlobalStats.availableMonths(store, self.anchor)
    local anchor = tonumber(self.anchor) or os.time()
    local current_year = tonumber(os.date("%Y", anchor)) or 1970
    local current_month = tonumber(os.date("%m", anchor)) or 1

    local buttons = {}
    for _i, item in ipairs(months) do
        local label = item.label
        local is_current = (item.year == current_year and item.month == current_month)
        if is_current then label = label .. " ✓" end
        -- 每个按钮各自捕获自己的年月（别用循环变量闭包）
        local year, month = item.year, item.month
        buttons[#buttons + 1] = {
            {
                text = label,
                callback = function()
                    if self.dialog then
                        UIManager:close(self.dialog)
                        self.dialog = nil
                    end
                    if is_current then return end
                    self:reload{
                        period = target_period or self.period,
                        anchor = anchorAtMonth(anchor, year, month),
                    }
                end,
            },
        }
    end

    -- 行文字现在只有「10月」（用户要的「只显示月份」），
    -- 所以**跨年时**在标题里补一句范围，免得两行「1月」看着一模一样。
    local title = _("选择月份")
    local y_min, y_max
    for _i, item in ipairs(months) do
        y_min = (not y_min or item.year < y_min) and item.year or y_min
        y_max = (not y_max or item.year > y_max) and item.year or y_max
    end
    if y_min and y_max and y_min ~= y_max then
        title = T(_("选择月份（跨 %1–%2 年）"), y_min, y_max)
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    self.dialog = ButtonDialog:new{
        title = title,
        shrink_unneeded_width = true,
        modal = true,
        buttons = buttons,
    }
    -- 不能写成裸的 `UIManager:show(self.dialog)` —— 见 showNoFlash 的注释。
    showNoFlash(self.dialog)
end

-- 日期日历选择器。月箭头切换月份，选择日期后回到对应的日趋势。
local function newFlatButtonDialog(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local ButtonTable = require("ui/widget/buttontable")
    local saved = ButtonTable.sep_width
    ButtonTable.sep_width = 0
    local ok, dlg = pcall(ButtonDialog.new, ButtonDialog, opts)
    ButtonTable.sep_width = saved
    if not ok then error(dlg) end
    return dlg
end

-- 把「当前项」按钮做成**黑底白字**（真正能生效的做法）。
-- ⇒ `btn.color = COLOR_WHITE` 完全无效 ⇒ 黑底 + 黑字 = **一整块黑**，
-- 这就是用户报的「选中的周直接全变黑了」。
local function invertButtons(dlg, ids)
    local bt = dlg and dlg.buttontable
    if not (bt and bt.button_by_id) then return end
    for _, id in ipairs(ids) do
        local b = bt.button_by_id[id]
        if b and b.frame then b.frame.invert = true end
    end
end

function StatisticsPage:showDayPicker(anchor_override)
    local anchor = tonumber(anchor_override or self.anchor) or os.time()
    local year = tonumber(os.date("%Y", anchor)) or 1970
    local month = tonumber(os.date("%m", anchor)) or 1
    local cur_day = tonumber(os.date("%d", anchor)) or 1
    local first_of_month = os.time{
        year = year, month = month, day = 1, hour = 12, min = 0, sec = 0,
    }
    local last_day = tonumber(os.date("%d", os.time{
        year = year, month = month + 1, day = 0, hour = 12, min = 0, sec = 0,
    })) or 31
    local buttons = {}

    -- 头行从**一行**拆成**两行**（年一行、月一行）。
    -- ⚠ 月份行的箭头**保持原来的跨年行为**（12 月的 › 走到次年 1 月），
    -- 这是 anchorAtMonth 的既有语义（os.time 会自动规整越界的 month，
    -- 见它的实现），没有改动。
    local function gotoAnchor(target)
        return function()
            UIManager:close(self.dialog)
            self.dialog = nil
            self:showDayPicker(target)
            return true
        end
    end
    local function noop() return true end

    -- 第 1 行：年（箭头跨 1 年，保留当前月/日）
    buttons[#buttons + 1] = {
        { text = "‹", callback = gotoAnchor(anchorAtMonth(anchor, year - 1, month)) },
        { text = string.format("%04d 年", year), callback = noop },
        { text = "›", callback = gotoAnchor(anchorAtMonth(anchor, year + 1, month)) },
    }
    -- 第 2 行：月（箭头跨 1 月，跨年自动进位 —— 见函数头注释）
    buttons[#buttons + 1] = {
        { text = "‹", callback = gotoAnchor(anchorAtMonth(anchor, year, month - 1)) },
        { text = string.format("%d 月", month), callback = noop },
        { text = "›", callback = gotoAnchor(anchorAtMonth(anchor, year, month + 1)) },
    }

    local weekdays = { "一", "二", "三", "四", "五", "六", "日" }
    local weekday_row = {}
    for i = 1, #weekdays do
        weekday_row[i] = { text = weekdays[i], callback = function() return true end }
    end
    buttons[#buttons + 1] = weekday_row

    local row = {}
    local weekday = tonumber(os.date("%w", first_of_month)) or 0
    local leading_blanks = (weekday + 6) % 7
    local function blankCell()
        return { text = " ", callback = function() return true end, bordersize = 0 }
    end
    for _i = 1, leading_blanks do row[#row + 1] = blankCell() end
    for day = 1, last_day do
        local selected_day = day
        local is_today = (selected_day == cur_day)
        local btn = {
            text = tostring(day),
            callback = function()
                UIManager:close(self.dialog)
                self.dialog = nil
                self:reload{
                    period = "day",
                    anchor = os.time{
                        year = year, month = month, day = selected_day,
                        hour = 12, min = 0, sec = 0,
                    },
                }
                return true
            end,
            bordersize = 0,
        }
        if is_today then
            -- 见 invertButtons 的注释 —— Button 的文字颜色是硬编码黑的，
            -- `background = BLACK` + `color = WHITE` 只会得到「黑底黑字」。
            btn.id = "wc_today"
        end
        row[#row + 1] = btn
        if #row == 7 then
            buttons[#buttons + 1] = row
            row = {}
        end
    end
    if #row > 0 then
        while #row < 7 do row[#row + 1] = blankCell() end
        buttons[#buttons + 1] = row
    end
    while #buttons < 8 do
        local blank_row = {}
        for _i = 1, 7 do blank_row[#blank_row + 1] = blankCell() end
        buttons[#buttons + 1] = blank_row
    end

    -- 走「无分隔线」版本 —— 日历要的是**留白分隔**，
    -- 不是 ButtonTable 默认那套灰线（见 newFlatButtonDialog 的注释）。
    self.dialog = newFlatButtonDialog{
        title = _("选择日期"),
        width_factor = 0.74,   -- ★★★ 53-daypicker-narrow：0.80 → 0.74（见上）
        modal = true,
        buttons = buttons,
    }
    -- 今天的那个格子反色成黑底白字（见 invertButtons 的注释）。
    invertButtons(self.dialog, { "wc_today" })
    -- 不能写成裸的 `UIManager:show(self.dialog)` —— 见 showNoFlash 的注释。
    showNoFlash(self.dialog)
end

-- 周列表改成**图标翻页**，不再靠滚动。
-- ⚠ 45 轮用户反馈：「周选择器还是太长了」。
local WEEK_PAGE_SIZE = 8

function StatisticsPage:showWeekPicker(page)
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local anchor = tonumber(self.anchor) or os.time()
    local anchor_year = tonumber(os.date("%Y", anchor)) or 1970
    local weeks = GlobalStats.availableWeeks(store, anchor)
    local current_monday = GlobalStats.weekStart(anchor)

    local total = #weeks
    local page_count = math.max(1, math.ceil(total / WEEK_PAGE_SIZE))

    -- 默认落在**当前正在看的那一周**所在的页，省得每次都从第 1 页翻起。
    if not tonumber(page) then
        page = 1
        for i, item in ipairs(weeks) do
            if item.monday == current_monday then
                page = math.ceil(i / WEEK_PAGE_SIZE)
                break
            end
        end
    end
    page = math.max(1, math.min(tonumber(page) or 1, page_count))

    local first = (page - 1) * WEEK_PAGE_SIZE + 1
    local last = math.min(total, first + WEEK_PAGE_SIZE - 1)

    local function gotoPage(target)
        return function()
            if self.dialog then
                UIManager:close(self.dialog)
                self.dialog = nil
            end
            self:showWeekPicker(target)
        end
    end
    local function noop() return true end

    local buttons = {}
    -- 翻页行：‹  第 N/M 页  ›（到底时对应的箭头变成空白，不可点）
    buttons[#buttons + 1] = {
        {
            text = page > 1 and "‹" or " ",
            callback = page > 1 and gotoPage(page - 1) or noop,
        },
        {
            -- ⚠ 这里**不能**写「第 N / M 页」：ButtonTable 把一行三等分，
            -- 每格只有 table_width/3 ≈ 137px，而「第 1 / 7 页」在 40px 字号下
            -- 约 174px ⇒ 会被压到缩字号（Button 的 avoid_text_truncation）。
            text = string.format("%d / %d", page, page_count),
            callback = noop,
        },
        {
            text = page < page_count and "›" or " ",
            callback = page < page_count and gotoPage(page + 1) or noop,
        },
    }

    for _i = first, last do
        local item = weeks[_i]
        local label = item.label .. "  " .. item.range
        local is_current = (item.monday == current_monday)
        local monday = item.monday
        local btn = {
            text = label,
            callback = function()
                if self.dialog then
                    UIManager:close(self.dialog)
                    self.dialog = nil
                end
                if is_current then return end
                local delta = math.floor((monday - current_monday) / (7 * 86400) + 0.5)
                self:reload{
                    period = "week",
                    anchor = GlobalStats.shiftAnchor("week", anchor, delta),
                }
            end,
            bordersize = 0,
        }
        if is_current then
            -- 当前周：黑底反白就够了 —— 44 轮那个尾随的「 ✓」不再需要，
            -- 去掉之后整行窄了约 20px（用户一直嫌它宽）。
            btn.id = "wc_current_week"
        end
        buttons[#buttons + 1] = { btn }
    end

    self.dialog = newFlatButtonDialog{
        title = T(_("选择周（%1年）"), anchor_year),
        shrink_unneeded_width = true,
        modal = true,
        buttons = buttons,
    }
    -- 当前周那一行反色成黑底白字（见 invertButtons 的注释）。
    invertButtons(self.dialog, { "wc_current_week" })
    -- 不能写成裸的 `UIManager:show(self.dialog)` —— 见 showNoFlash 的注释。
    showNoFlash(self.dialog)
end

--==========================================================================
-- 入口
--==========================================================================

function M.show(plugin, period, anchor, metric)
    period = period or "year"
    local ok, page = pcall(StatisticsPage.new, StatisticsPage, {
        plugin = plugin,
        period = period,
        anchor = anchor,
        metric = metric or "units",
        trend_view = period == "day" and "list" or "chart",
    })
    if not ok then
        logger.err("WordCount: statistics page initial build failed", page)
        -- 同上，走 showNoFlash，避免整屏无 region 的 "partial" 兜底刷新。
        showNoFlash(InfoMessage:new{ text = T(_("统计页面打开失败：%1"), tostring(page)) })
        return nil
    end
    -- 见 `showNoFlash` 的注释 —— 裸的 `UIManager:show(page)` 会让
    -- `_repaint` 兜底排一次**整屏**无 region 的 "partial"（每 6 次还提升成
    -- "full" = 整屏黑闪）。这是「打开统计页闪一下」的来源。
    showNoFlash(page)
    return page
end

return M
