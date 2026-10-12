--[[--
阅读统计页面：卡片网格 + 趋势图。

版面（对齐用户提供的手机端截图）：

    ┌ 阅读统计 ──────────────────────────┐
    │   日   周   月   年   总            │  分段切换
    │   ‹    [ 2026年 ]    ›            │  周期导航（★ 年文字=胶囊，点它弹年份列表）
    │  ┌───────────┐ ┌───────────┐       │
    │  │ 2 小时 1 分钟 │ │ 2 天       │       │  大数字 + 小单位
    │  │ 阅读时间     │ │ 阅读天数    │       │  灰标签
    │  │ ↑ 2 小时 1 分钟│ │ ↑ 2 天      │       │  环比
    │  └───────────┘ └───────────┘       │
    │           ... 共 10 张卡片 ...       │
    │  ┌───────────────────────────────┐  │
    │  │ 阅读字数趋势          ▥   ≡    │  │  趋势指标 + 图表/列表
    │  │ 30万字 ┤          █            │  │
    │  │ 20万字 ┤          █            │  │
    │  │ 10万字 ┤          █            │  │
    │  │   0字 ┤▁▁▁▁▁▁▁▁▁▁▁▁▁           │  │
    │  │        1 2 3 4 ... 12          │  │
    │  │ ⏱阅读时间  ≡阅读字数 ✓          │  │
    │  │ ⏱阅读速度  ⏱日均阅读时长         │  │
    │  │ 2026年1月 阅读字数 0 字         │  │
    │  └───────────────────────────────┘  │
    └────────────────────────────────────┘

KOReader 侧实现约束（逐条对着 koreader 源码核过，改动前请先复核）：

  * `FrameContainer:getSize()` 不读 `self.width`（只影响 paintTo 的背景尺寸），
    所以固定尺寸只能靠外层容器；而 `WidgetContainer:getSize()` 在有 `dimen` 时
    直接返回它 —— 本文件的 `FixedBox` / `AbsoluteContainer` 就是吃这个语义。
  * `TextWidget:getSize()` 的高度取自 `forced_height`（textwidget.lua:298）。
  * `HorizontalGroup.align` 只有 `"center"` / `"top"` / `"bottom"` 三种取值。
  * `CenterContainer` / `RightContainer` / `BottomContainer` 都要调用方自己给 `dimen`。
  * `GestureRange.range` 允许传函数，用来延迟取 `self.dimen`（gesturerange.lua:29）。
  * `Blitbuffer:paintRect` 收的是 `Color8`，内部按 bb 实际类型转换，
    所以 `Blitbuffer.COLOR_*` 在 8bpp 和 RGB32 设备上都安全。
  * ★ `Screen:scaleBySize(px)` = `ceil(px * min(屏宽,屏高) / 600)`
    （`ffi/framebuffer.lua:414`），**不是** `floor(px * dpi/160)`，
    也不是 `floor(px * 1.875)`。KPW4(1072×1448，无 `screen_dpi` 覆盖) 上：
    `(1)=2  (2)=4  (3)=6  (4)=8  (5)=9  (10)=18`。
    凡是要「算成几个像素」的地方，先按这个公式过一遍 —— 之前几轮
    就是按 1.875 折算，把 4px 宽的点当成 3px，结论全偏了。
  * `Blitbuffer:paintCircle(center_x, center_y, r, c, w)`（`ffi/blitbuffer.lua:1948`）
    `w` 默认 = `r` ⇒ 实心。半径 1 的光栅是**十字**不是圆，最小可用半径 2。
  * `ScrollableContainer` 需要 `dimen` + `show_parent`。
  * 目标运行环境是 LuaJIT(5.1)：不要用 `//`、位运算、`goto`、`math.log(x, base)`。

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
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
-- ★★★ 34：KeyValuePage 已不再使用（下钻改成同级的 DrillDownPopup 浮窗）。
--   原来这里 require 的是它 —— 它是个全屏页，show 出来会被 modal 主浮窗压住，
--   表现为用户说的「点进去在页面下一层，都看不到」。改浮窗后这个依赖可以删了。
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

--- ★★★ 37r：新增 k / qian 两种「千」进制（用户要求
---   「单位切换可以有完整数字，k，千，以及万」）。
---     · k    → 358k
---     · qian → 358千
---   两者都只在 n >= 1000 时启用，不足 1000 回退完整数字
---   （0.4k / 0.4千 这种读数没有意义）。
--- ⚠ 判定顺序必须与 bookshelf_integration.lua:formatUnits 完全一致 ——
---   否则同一本书的字数会在统计页与书架占位符上显示成两种写法。
---
--- Display mode: full = 1,234,567; k = 358k; qian = 358千;
---               wan = 123.5万 / 1.2亿; auto = threshold-based.
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

--- 大数字 + 小单位的拆分，供卡片排版用。
--- @return array of { text = string, big = boolean }
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

--- "2 小时 1 分钟" 拆成 { "2"(大), "小时"(小), "1"(大), "分钟"(小) }
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

--- ★★★ 41-plain-chart：**删掉了 `compactDuration`**（原「图表 Y 轴刻度用的
---   紧凑时长」）。它的唯一调用者是 `metricAxisText`，而 `metricAxisText`
---   唯一的调用者是趋势图那行图例的「虚线＝本期平均 X」—— 41 把均值虚线
---   连同图例那半句一起删了，这条调用链整条断掉，两个函数都成了死代码。
---   柱顶标签的时长写法现在归 `chartUnit` + `chartBarLabel` 管（整张图
---   统一一个单位，见下）。留这段注释是为了让后来者知道这里曾经有什么。

--- 环比用的纯文本
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

--- Y 轴刻度的"好看"上限：把 max 向上取到 1 / 1.2 / 1.6 / 2 / 2.4 / 3 / 4 / 5 / 6 / 8 / 10 倍数量级。
--- 这样 4 等分后的刻度也都是整数（25% / 30% / 40% / 50% ...）。
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

--- ★★★ 41-plain-chart：**删掉了 `metricAxisText`**（原「Y 轴刻度那种紧凑
---   写法」）。它唯一的调用者是已删的均值虚线图例。列值文案现在只有两条路：
---     · `metricValueText` —— 列表视图那种**带单位**的完整写法；
---     · `chartBarLabel`   —— 柱顶那种**不带单位**的裸数字。
---   不再需要第三种「给刻度用、能省字」的写法（Y 轴都没了）。

--- ★★★ 40-unit-free：整张图**统一一个单位**，柱顶标签只写数字。
---
---   用户原话：「每个柱体上方都加上数值注释，单位统一的可以不带单位」。
---   这两句其实是同一件事的两面 —— **标签越窄，能标上的柱子就越多**。
---   每根柱子后面都重复一遍单位，纯粹是在跟横向空间过不去，而横向空间
---   正是「能不能每根都标上」的**唯一**瓶颈。
---
---   做法：先给整张图定**一个**单位（本函数），标签只写数字
---   （chartBarLabel），单位在**标题**里出现一次（「阅读时长趋势（分）」）。
---
---   ⚠ 旧方案是**逐值**挑单位的（那个函数 41 已删）：927 秒 →「15分」、
---     83 秒 →「83秒」—— 同一张图里混着「分」和「秒」，那就不叫
---     「单位统一」，也就没法省。所以这里改成**按整张图的量级选一次**：
---     scale_max 决定这张图用秒 / 分 / 小时。
---
---   ⚠ 阈值 120 / 3600 的理由：scale_max < 120 秒时用「分」会把最高那根
---     压成「1」「2」，刻度全挤在个位数、完全分不出高低；≥ 3600 秒
---     （一小时）之后用「分」又会变成 60、90、120 这种三位数，
---     不如直接换成小时。中间那一段（2 分钟 ~ 1 小时）用「分」最顺眼。
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

--- 柱顶数值标签：**只写数字**，不带单位（单位由 chartUnit 决定、写在标题上）。
---
---   · 时长按 chartUnit 选定的单位折算；折算后 < 10 保留一位小数（「1.4」），
---     否则取整（「15」）—— 这样最短的那根也不会被压成「1」而失真，
---     最长的那根又不会写成「15.4」白占两个字符的位置。
---   · 其余指标直接走 formatCount，它自带「万 / 亿 / k / 千」的**量级**后缀
---     —— 那是数字写法的一部分，不是单位，不能剥掉。
---
---   ⚠ 数值口径必须与卡片 / 列表完全一致（都走 formatCount），
---     否则同一根柱子上的数字会和卡片对不上。
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
        -- ★★★ 32：用户要求「字体放大一点」。整体上调 2~4 px。
        value_big = Font:getFace("cfont", 29),
        value_small = Font:getFace("cfont", 18),
        label = Font:getFace("smallinfofont", 17),
        delta = Font:getFace("smallinfofont", 16),
        tab = Font:getFace("cfont", 18),
        period = Font:getFace("cfont", 20),
        section = Font:getFace("cfont", 24),
        axis = Font:getFace("x_smallinfofont", 17),
        footer = Font:getFace("smallinfofont", 19),
        -- ★★★ 37s：柱顶数值标签专用字号。
        --   比 Y 轴刻度(17)小一档 —— 它是「辅助读数」，不该抢柱子的视觉重心；
        --   同时字号越小标签越窄，越有可能做到「每根柱子都标得上」
        --   （横向放不下时会自动抽稀，见 chartValueLabels）。
        value = Font:getFace("x_smallinfofont", 13),
    }
    return FACES
end

--==========================================================================
-- 基础容器
--==========================================================================

--- ★★★ 32：不画滚动条的滚动容器。
---
--- 用户要求：「怎么还是有进度条啊，不能固定框吗」。
--- 这里的「进度条」不是统计进度，是 `ScrollableContainer` 右侧那根
--- **竖直滚动条**（`VerticalScrollBar`）—— 只要内容装不下，它就会出现。
---
--- 上游 `ScrollableContainer:paintTo()` 在最后无条件把
--- `self._v_scroll_bar:paintTo(...)` 画出来（没有任何开关），
--- 所以「想保留滚动、但不要滚动条」唯一可靠的办法是：
--- **继承它，把 `_v_scroll_bar` / `_h_scroll_bar` 在 initState 之后抹掉。**
--- 抹掉之后：
---   · 滚动本身照常（`_is_scrollable` / `_crop_w` / `_crop_h` 都已经算好）；
---   · `paintTo` 里那两个 `if self._v_scroll_bar then` 分支直接跳过；
---   · 右侧那 3*scroll_bar_width 的宽度还给了内容区，内容更宽、不会被裁。
local NoBarScrollable = ScrollableContainer:extend{}

function NoBarScrollable:initState()
    ScrollableContainer.initState(self)
    -- ★ 关键：crop 宽高已经在 initState 里按「有滚动条」减过一遍了，
    --   这里把宽度补回来，否则右侧会空出一条无用的白边。
    if self._v_scroll_bar then
        self._crop_w = self.dimen.w
        self._v_scroll_bar = nil
    end
    if self._h_scroll_bar then
        self._crop_h = self.dimen.h
        self._h_scroll_bar = nil
    end
end

--- ★★★ 36：**禁止滑动**的固定面板。
--
-- 用户原话：「阅读统计总览页面为什么还是可以左右上下滑动」「切换下一页上一页
--   也是通过图标不是滑动」。
--
-- 所以整块浮窗内容区不再允许手指拖动。做法不是换掉 ScrollableContainer
-- （那会丢掉它的裁剪/自适应），而是继承它、把**所有滚动手势全 ignore** ——
-- 上游 `ScrollableContainer:init()` 里 `ignore = {touch,swipe,hold,hold_pan,
-- hold_release,pan,pan_release}` 为 true 时，对应的 `ges_events` 直接不注册，
-- 手指拖动就不会再被它消费（会继续往下传给父控件，也就是「点空白关闭」）。
--
-- 内容比面板高时：会被裁掉下面（因为我们也没开滚动条），所以**各视图自己
-- 得保证内容放得下** —— 阅读字数页已改成图标翻页（每页 10 条），
-- 总览页卡片按屏高收敛，趋势页图表固定行数。
local FixedPane = ScrollableContainer:extend{}

function FixedPane:init()
    -- ⚠ 上游 `ScrollableContainer:init()` 只认 `self.ignore_events`（字符串数组），
    --   不认 `self.ignore` —— 所以必须写成数组形式。
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

--- 固定尺寸容器。
--- 存在的理由：`FrameContainer:getSize()` 不认 `self.width`，而 `WidgetContainer:getSize()`
--- 在有 `dimen` 时直接返回它 —— 但 `FrameContainer` 覆写了 `getSize`，所以拿不到这个语义。
--- 把 FrameContainer 塞进 FixedBox 就能得到"等宽卡片"。
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

--- 绝对定位容器：把若干子控件按 (x, y) 摆在固定尺寸的画布上。
--- 用于 Y 轴刻度列（垂直对齐网格线）和 X 轴刻度行（水平对齐柱子中心）。
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

--- 可点击容器。
--- `range` 用函数形式延迟取 `self.dimen`（dimen 要 paintTo 时才有值）。
---
--- ★★★ 37b：`on_tap` 现在会收到**点击位置** (x, y)（屏幕坐标，可为 nil）。
---   用途：周期导航第二行「10月03日」是一整块文字，需要按**点击的横向位置**
---   区分「外侧=切月 / 内侧=切日」——没有坐标就做不到。
---   老调用点忽略多余参数即可，行为不变。
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
    }
end

--- 图标统一开 alpha：卡片/条带底色不是纯白时，IconWidget 默认会把图标压平到白色底上，
--- 那会在浅灰底上出现一圈白边。
---
--- ★★ 32：加 `white` 开关 —— 选中态（黑底）上的图标必须**反白**，
---   否则默认的黑图标压在黑底上完全看不见。
---
---   实现方式沿用上游 `Button:_doFeedbackHighlight()` 的做法
---   （`button.lua:406`）：`ImageWidget` / `IconWidget` **没有 `color` 字段**，
---   想换色只能走 `invert` 标志，它在 paintTo 的最后一步做 `invertRect`。
---   `alpha = true` 时图标走 alphablit 分支，invert 在之后执行，两者不冲突。
local function icon(name, size, opts)
    opts = opts or {}
    return IconWidget:new{
        icon = name,
        width = size,
        height = size,
        alpha = true,
        dim = opts.dim or false,
        -- ★ 37h：同时接受 opts.invert 和旧名 opts.white（历史上用的是 white）。
        --   IconWidget 真正认的字段是 `invert`（把图标反色）。
        invert = opts.invert or opts.white or false,
    }
end

--==========================================================================
-- 趋势图
--==========================================================================

--- ★★★ 41-plain-chart：网格线删掉之后，这个常量**只剩「图高 = 4 行」一个作用**
---   （唯一用途是 buildTrendSection 的 `chart_h = row_h * TREND_ROWS`）。
---   名字保留是因为改它仍然等比改图高；但它**不再代表任何刻度**了 ——
---   以前它是「4 条网格线 + 1 条基线 = 5 个 Y 轴刻度」，那是 Y 轴还在时的算法。
local TREND_ROWS = 4

--- ★★★ 39-trend-axis：**删掉了 `trendBucketLabels(period, count)`**。
---
---   它原来是「按 period 现造一套 X 轴刻度」，而 `GlobalStats.trend` 生成的
---   `bucket.label` 是**另一套** —— 两边根本对不上（见 `buildTickRow` 的注释）。
---   现在 X 轴一律走 `bucket.label`，这个函数没有存在意义了。
---   （留这段注释是为了让后来者知道「这里曾经有一份会造错刻度的代码」，
---     别再照着写回来。）

--- ★★★ 37s：一根柱子在给定绘图高度下的像素高度。
---
--- 为什么必须抽成函数：「画柱子」（buildChartImage）和「把数值标签摆到柱顶」
--- （chartValueLabels）是两处代码，但它们必须用**完全同一套**取整 / 最小高度口径。
--- 各写一份的话，标签迟早会跟柱顶错开一两个像素 —— 白底黑柱上看得出来。
local function barPixelHeight(value, scale_max, plot_h, min_bar_h)
    value = tonumber(value) or 0
    local bar_h = math.floor(plot_h * value / scale_max + 0.5)
    if value > 0 and bar_h < min_bar_h then bar_h = min_bar_h end
    return bar_h
end

--- ★★★ 41-plain-chart：**删掉了均值参考线**（`trendMean` + `meanLineY`）。
---
---   用户原话：「虚线去掉」。被删掉的是两样东西：
---     · `trendMean(buckets)` —— 只平均「有数据」的桶（value > 0），
---       口径刻意与 summarize 的「日均阅读时长」一致（除以**有阅读的天数**，
---       不是除以全周期天数）；
---     · `meanLineY(mean, scale_max, height)` —— 把它换算成绘图区里的 y。
---   连带删掉的还有趋势图下方那行图例的后半句「· 虚线＝本期平均 X」
---   （图例只剩「点柱子看具体数值」）。
---
---   ⚠ 删除理由（用户给过两次信号）：39 那轮把这条线从纯黑降成深灰
---     （「不需要参照线加强」），41 直接说「去掉」。也就是说 ——
---     用户并不需要「本期平均」这个参照：每根柱子顶上已经写着自己的数值
---     （40-unit-free），而「日均阅读时长」这个**口径完全相同**的数字
---     在总览页有专门的卡片。图里再来一条线，纯属重复表达。
---   ⚠ 如果哪天想加回来：口径必须与 summarize 的 average_day_seconds 一致，
---     否则同一页上卡片和线会给出两个「平均」，那比没有更糟。

--- 把 buckets 画成位图。返回 ImageWidget。
--- 用真实像素而不是字符网格：字符画依赖等宽字体，KOReader 默认字体不是等宽的，
--- 一旦列宽漂移整张图就废了。
---
--- ★★★ 37s：`scale_max` 改成**由调用方传入**（buildTrendSection 为了排 Y 轴刻度
---   已经算过一次 niceMax 了）。传进来是为了让「柱顶数值标签」和柱子共用同一个
---   上限 —— 两边各算一次不只是白算，更危险的是以后改口径只改一处。
---   不传则退回「自己算」的老行为（保持本函数可单独调用/测试）。
--- ★★★ 40-unit-free：**去掉了从未被使用的 `metric` 参数**。
---   柱子只关心「多高」，不关心「什么指标」—— 单位是柱顶标签的事，
---   而标签在 chartValueLabels 里单独算。留一个没人读的参数只会让人
---   以为改单位要动这里。
--- ★★★ 41-plain-chart：再**去掉 `mean` 参数**（均值虚线已删）。
---   本函数现在只画两样东西：柱子 + 底部基线。
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
    -- ★★★ 41-plain-chart：**横向网格线也删掉了**（原来这里有 3 条浅灰点线）。
    --
    --   用户原话：「另外，y 轴的刻度怎么没去掉」——
    --   他说的「刻度」就是这几条横线：它们的**唯一**含义是「Y 轴刻度值所在的
    --   高度」（1 行 / 2 行 / 3 行处），而 40 那轮已经把 Y 轴那一列数字
    --   （0秒 / 4分 / 8分 / 13分 / 17分）整列删掉了 ——
    --   刻度值都没了，画着刻度线的位置也就成了纯粹的干扰线。
    --
    --   ⚠ 注意这里删的是**网格线**，不是基线：基线（最下面那条纯黑实线）
    --     是「柱子的地面」，删了柱子会像浮在半空。见函数末尾的 paintRect。
    --   ⚠ 顺带：`row_h = height / TREND_ROWS` 也因此没人用了，一起删掉
    --     （TREND_ROWS 现在只被 buildTrendSection 用来算 chart_h）。
    --   ⚠ 别再照着「网格线＝用密度区分主次」的老注释写回来：用户要的是
    --     **干净**，不是「更淡的网格」。真要参照高度，看柱顶的数字标签。

    local count = math.max(1, #buckets)
    local slot = width / count
    -- ★★★ 37s：柱子加粗（用户：「实心柱可以粗一点」）。0.6 → 0.8。
    --   ★★★ 39-bar-thicker：再 0.8 → **0.9**（用户看预览图后又说「柱子变粗」）。
    --   ★★★ 40-bar-thickest：用户第三次要求「柱体尽量粗」。
    --     这次不再「按比例留缝」，改成**至少留 2px 缝、其余全给柱子**：
    --         旧：bar_w = floor(slot * 0.9)          —— 缝固定占 10%
    --         新：bar_gap = max(2, floor(slot*0.08))
    --             bar_w  = floor(slot) - bar_gap
    --     两者在「桶多」时结果几乎一样（月视图 31 桶：slot≈29.5 ⇒ 都是 27px），
    --     但在「桶少」时新写法明显更粗（年/累计 12 桶：70 → 74px；
    --     周视图 7 桶：120 → 120px）。
    --     ★ 真正让柱子变粗的其实是**另一件事**：40-no-y-axis 之后绘图区
    --       从 704px 涨到 914px（整条 inner_w），月视图 slot 从 22.7 → 29.5，
    --       柱宽从 20px → 27px（+35%）。光调比例拿不到这个量级。
    --     ⚠ 下限 2px 是 e-ink 的安全线：300dpi 上约 0.17mm。再细相邻柱
    --       在灰阶抖动下就糊成一片了 —— 所以不写 `floor(slot) - 1`。
    --     ⚠ 这个宽度同时影响柱顶数值标签的观感（柱子越宽，标签越不显得飘），
    --       但**不影响**标签抽稀的计算 —— 那边只看 slot，不看 bar_w。
    local bar_gap = math.max(2, math.floor(slot * 0.08))
    local bar_w = math.max(1, math.floor(slot) - bar_gap)
    local min_bar_h = math.max(2, Screen:scaleBySize(2))
    for i, bucket in ipairs(buckets) do
        local value = tonumber(bucket.value) or 0
        local bar_h = barPixelHeight(value, scale_max, height, min_bar_h)
        if bar_h > 0 then
            local x = math.floor((i - 1) * slot + (slot - bar_w) / 2)
            -- ★★★ 37r：**所有柱子一律实心填充**（用户：「统计图都用实心的条条」）。
            --
            --   32 那版把非选中柱画成「空心描边」（paintBorder），本意是躲开灰色，
            --   但细描边柱在 e-ink 上看着像「没画完 / 像个边框」，用户明确要求改回实心。
            --
            --   选中态仍然保留区分（用户确认要「有选中效果」）：
            --     · 选中柱 = **纯黑实心**
            --     · 其余柱 = **浅灰实心**
            --   两者都是实心填充，只是深浅不同 —— 既满足「全实心」，
            --   又不至于让用户找不到当前选中的是哪一格。
            --
            --   ⚠ 本文件**不再有任何 paintBorder 调用**。32 的注释说的「不要灰色」
            --     用户原话是「尽量不要有灰色**字**」；灰**柱**是柱状图的常规画法，
            --     在白底上比描边清楚得多。若日后又有人想改回描边，请先确认
            --     用户要的是「实心」还是「不要灰」——这两个诉求在柱子上是冲突的。
            if i == selected_index then
                bb:paintRect(x, height - bar_h, bar_w, bar_h, Blitbuffer.COLOR_BLACK)
            else
                bb:paintRect(x, height - bar_h, bar_w, bar_h, Blitbuffer.COLOR_LIGHT_GRAY)
            end
        end
    end

    -- ★★★ 41-plain-chart：**均值虚线也删掉了**（原来这里有一段
    --   「12px 长划线 + 8px 间隔、COLOR_DARK_GRAY(0x88)」的绘制代码）。
    --
    --   历史：39 先把它从纯黑降成深灰（39-mean-subtle，用户「不需要参照线加强」），
    --   41 用户直接说「虚线去掉」。
    --   删除后本函数的绘制层次只剩两层，非常干净：
    --         选中柱 0x00  <  未选中柱 0xCC
    --   ⚠ 顺带说明：`COLOR_DARK_GRAY(0x88)` 在本文件里**还有别的使用者**
    --     （标题栏下划线、卡片样式说明文字、下钻浮窗的次要文字等 4 处），
    --     所以只是本函数不再用它，别顺手把这个常量当成死代码。
    --   ⚠ 想知道「哪几格高于平均」怎么办：柱顶现在每根都写着数值
    --     （40-unit-free），而「日均阅读时长」在总览页有专门卡片，
    --     口径与原来那条线完全一致 —— 用户已经明确表示不需要图内再画一条。

    local base_h = math.max(1, Size.line.medium)

    bb:paintRect(0, height - base_h, width, base_h, Blitbuffer.COLOR_BLACK)

    return ImageWidget:new{ image = bb }
end

--- 标签宽高的缓存。
---
--- 为什么需要：贪心铺排（见 chartValueLabels）必须**逐个**知道每个标签有多宽 ——
--- 「宽度不齐」正是贪心能比固定步长多标一截的前提。31 根就是 31 次文本整形，
--- 而这个页面每点一次柱子、每切一次指标都会整个重建一次。KPW4 是单核 1GHz，
--- 白做 31 次整形纯属浪费电。同一份数据下标签文案是稳定的，缓存后重建几乎零成本。
---
--- ⚠ 缓存键**只有字符串**（把 face 当成固定的）。若以后把 faces().value 的字号
---   做成可配置的、或允许用户改字号，这里必须跟着清缓存，
---   否则会拿旧字号量出来的宽度去排版，标签就会歪。
local LABEL_METRICS = {}
local LABEL_METRICS_LIMIT = 512

local function labelMetrics(s, face)
    local m = LABEL_METRICS[s]
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
    LABEL_METRICS[s] = m
    return m
end

--- ★★★ 37s：柱顶数值标签的绝对定位表。
---
--- 返回 `{ { x = , y = , widget = ... }, ... }`，坐标相对**图表位图**左上角。
---
--- y **允许为负**，而且这不是 bug：
---   图本身只有 4*row_h 高，最高的柱子顶到图顶时，它的标签
---   y ≈ -(标签高+间距)，也就是画到**图上方**去。
---   ⇒ 前提是 `buildTrendSection` 在图的上面**显式留了一块** VerticalSpan
---     （40-no-y-axis 之后由它负责，之前是 Y 轴刻度列比图高一行白送的 62px）。
---     那块留白不够高，最高的那根柱子的数字就会压到标题上。
---   （y 的公式本身是自限的：bar_h ≤ height ⇒ y ≥ -(标签高+间距)，不会更远。）
---
--- ⚠ 由此带来一条**必须守住的约束**：
---   `标签高 + 间距 ≤ buildTrendSection 里那个 VerticalSpan 的高度`。
---   40 之后那个 span 是**按 `labelMetrics("0", f.value).h` 现算的**，
---   所以只要字号是通过 faces() 改的，这条约束自动成立；
---   但**别再手写死像素** —— 一改字号就会顶到标题上。
---
--- ★★★ 40-unit-free：现在的目标是**每根有数据的柱子都标上**。
---
---   用户原话：「每个柱体上方都加上数值注释，单位统一的可以不带单位」。
---   上一轮（37s）只做到「尽量多标」，因为当时的标签是**带单位**的
---   （「15分」「83秒」「153.1万」），横向空间根本不够。这一轮把三处
---   一起改了，才真正接近「每根都标上」：
---     ① 标签**不带单位**（chartBarLabel）—— 单这一项就窄掉 30~40%；
---     ② 绘图区从 704px 涨到 914px（删掉 Y 轴列）—— slot +30%；
---     ③ 标签最小缝 11px → 3px。
---   实测（`_verify/zerolabel.lua`，标签宽度按 cfont 13px 建模：ASCII 7.2px、
---   CJK 13px；月视图 31 桶、只有 01~04 四天有数据）：
---     · 39 的**带单位**标签（「1.4分」→ 实际是「1分23秒」那种） + 旧宽度 704px
---       ⇒ 4 根里只标得上 **2** 个（01、03）；
---     · 40 的**无单位**标签 + 旧宽度 704px ⇒ 真实那 4 天的数据已经能 **4/4**；
---     · 40 的无单位标签 + 新宽度 914px ⇒ 4/4，而且**余量明显更大**：
---       换一组 3 位数字的标签做对照，704px 只有 2/4、914px 是 4/4。
---   ⇒ 结论：真正把「标不满」解决掉的是**去掉单位**；把绘图区加宽是
---     给更长的标签留余量（阅读字数那种「153.1万」就靠它）。
---   ⚠ 但「每根都标上」在几何上**不是永远成立**的：当标签本身比一根柱子
---     还宽时（典型：阅读字数月视图出现「153.1万」这种 5~6 字符标签、
---     而一个月有 31 根柱子，slot 只有 29px），怎么摆都会叠。
---     那种情况下仍然退回贪心抽稀 —— **宁可少标几根，也不让两个数字
---     糊成一团**（那是不可读，比少标更糟）。
---
--- 铺排策略：**贪心**，不是「隔 n 根标一个」。
---   从**当前选中那根**出发，向左右各扫一遍，只要跟上一个已放置的标签不重叠
---   （留 gap）就放。两个理由：
---     1) 标签宽度并不齐 ——「0」只有一位，「29.5万」要宽一倍多。固定步长只能按
---        **最宽**的那个留空，白白丢掉一堆本来放得下的位置。
---        实测（KPW4 度量）：日视图（24 根）8 → 13 个、月视图（31 根）7 → 8 个、
---        年视图（12 根）6 → 7 个。
---     2) 从选中柱出发（而不是从左端）是为了保证**当前选中那根一定有数值** ——
---        否则会出现「刚点了某根柱子，却在图上找不到它的数」的尴尬。
---   桶少时（周视图 7 根）贪心自然全部放得下，那就是用户要的「每根都有」。
local function chartValueLabels(buckets, unit, selected_index, width, height, scale_max)
    local f = faces()
    local count = #buckets
    if count == 0 then return {} end
    local slot = width / count
    -- ★★★ 40-unit-free：标签之间的**最小缝**从 scaleBySize(6)=11px 收到 3px。
    --   标签自己带白底（下面 place() 里那个 FrameContainer），两个数字之间
    --   只要有 3px 白就分得开 —— 这 11px 以前白白吃掉了近半根柱子的宽度，
    --   正是「明明放得下却标不上」的直接原因。
    local gap = Screen:scaleBySize(3)
    local min_bar_h = math.max(2, Screen:scaleBySize(2))

    local texts = {}
    for i, bucket in ipairs(buckets) do
        texts[i] = chartBarLabel(bucket.value, unit)
    end
    local label_h = labelMetrics(texts[1] or "0", f.value).h

    --- 第 i 个标签的水平位置（已按图宽夹紧）与宽度。
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
        -- 白底 = 把那一小块网格先擦掉（页面本身就是白的，看不出框）。
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

    -- ★★★ 39-zero-label：**值为 0 的桶不标数值**。
    --
    --   用户反馈「趋势图看不懂」的**第三个**原因（前两个是 X 轴刻度造错、
    --   图里没有参照）。这一条是「噪音太多」：
    --
    --     月视图 = 31 个桶，但通常只有几天真的读过书；
    --     日视图 = 24 个桶，通常只有两三个小时在读书。
    --     而这里**原先对 value == 0 的桶也照样摆标签** ——
    --     于是底部会糊上一整排「0秒」/「0」，把真正有数的三四根柱子
    --     彻底淹掉。这跟本函数注释里写的初衷（「绝不让两个数字叠在一起
    --     糊成一团 —— 那是不可读」）是同一个毛病，只是换成了「重复」。
    --
    --   ★ 为什么是「跳过 0」而不是「全都不标」：37s 那条用户要求是
    --     「每根柱子都标上」。**值为 0 的桶根本没有柱子**（barPixelHeight
    --     返回 0，不画），给它标个 0 不在那条要求的范围内。
    --     有柱子的桶（哪怕只有 1 秒）依旧照标，行为不变。
    --
    --   ★ 选中柱若是 0，也不再强标 —— 它的数值底部读数行里已经有了。
    --     这是对 37s「选中柱一定有标签」那条的**有意放宽**，因为那个
    --     保证的价值（「刚点了某根柱子却在图上找不到它的数」）在 0 柱上
    --     并不成立：柱子本身就不存在，读者不会去找它的数。
    local function has_value(i)
        local v = buckets[i] and tonumber(buckets[i].value) or 0
        return v > 0
    end

    -- 锚点 = 选中柱（越界/缺省都夹回合法范围）
    local anchor = tonumber(selected_index) or 1
    anchor = math.max(1, math.min(count, anchor))

    -- ★ 锚点的左右边沿**无论标不标都要先算出来** —— 左右两遍扫描
    --   都是以「选中柱的位置」为起点向外走的，跳过 0 桶不能改变这个起点。
    local anchor_x, anchor_w = label_x(anchor)
    local left_edge, right_edge = anchor_x, anchor_x + anchor_w
    if has_value(anchor) then place(anchor) end

    -- 向左：只要不压到已放置标签的左边沿就放
    --   ⚠ 跳过 0 桶时**不要动 left_edge** —— left_edge 记的是「最左那个
    --     已放置标签的左沿」，被跳过的桶什么都没放，不能拿它的位置去
    --     收紧后面（更靠左）的判定，否则会把本来放得下的标签误判为重叠。
    for i = anchor - 1, 1, -1 do
        if has_value(i) then
            local x, w = label_x(i)
            if x + w + gap <= left_edge then
                left_edge = place(i)
            end
        end
    end
    -- 向右：同理
    for i = anchor + 1, count do
        if has_value(i) then
            local x = label_x(i)
            if x >= right_edge + gap then
                local _unused, nr = place(i)
                right_edge = nr
            end
        end
    end
    return items
end

--- ★★★ 37s：图表 = 柱状位图 + 柱顶数值标签，叠在一个绝对定位容器里。
---
--- 抽稀（桶太密时少标几根）由 chartValueLabels 自己决定，这里不关心。
--- 没有任何标签时直接返回裸位图，保持与改动前完全一致的对象结构。
---
--- ★★★ 40-unit-free：第二个参数从 `metric` 改成 `unit`（chartUnit 的产物）。
---   柱子本身不需要单位，只有**柱顶标签**需要 —— 所以单位一直传到
---   chartValueLabels 那一层就够了。
--- ★★★ 41-plain-chart：**去掉了 `mean` 参数**（它唯一的用途是透传给
---   buildChartImage 画均值虚线，那条线已删）。参数表因此从 7 个缩到 6 个。
local function buildChartWidget(buckets, unit, selected_index, width, height, scale_max)
    local image = buildChartImage(buckets, selected_index, width, height, scale_max)
    local labels = chartValueLabels(buckets, unit, selected_index, width, height, scale_max)
    if #labels == 0 then return image end
    local items = { { x = 0, y = 0, widget = image } }
    for _i, item in ipairs(labels) do items[#items + 1] = item end
    return AbsoluteContainer:new{ width = width, height = height, items = items }
end

--- ★★★ 40-no-y-axis：**Y 轴刻度列已删除**。
---
---   用户原话：「统计图可以只要底部，不要 y 轴」。
---   原来的 `buildAxisColumn(labels, label_width, row_h, color)` 把 5 个刻度
---   （0秒 / 4分 / 8分 / 13分 / 17分）竖着排在图的左边，吃掉 `inner_w * 0.22`
---   —— KPW4 上是 201px，比 31 根柱子里任何一根都宽。
---   删掉之后：
---     · 那 201px + 9px 间距**全部还给绘图区**（704 → 914px），
---       月视图 slot 22.7 → 29.5px，柱宽 20 → 27px；
---     · 整张图自然**往左移**（用户要的「适当往左一点」），
---       左边界从「卡片内边距 + 210px」变成「卡片内边距」；
---     · 代价是**没有刻度参照**了 —— 但用户同时要求「每个柱体上方都加上
---       数值注释」，每根柱子自己带数，参照由标签承担（见 chartUnit）。
---   ⚠ 上面这段是 40 那轮写的。**41 已经把横向网格虚线也删了** ——
---     当时以为「网格线不是轴、是辅助线，可以留」，用户随后明确说
---     「y 轴的刻度怎么没去掉」，指的就是这几条线（见 buildChartImage 里的注释）。
---     所以现在图里只剩：柱子 + 柱顶数值 + 最底下那条纯黑基线。
---     这里保留 40 的原文，是为了让后来者看到「当时的判断是什么、
---     为什么后来被推翻」—— 别再照着它把网格线写回来。
---
---   （留这段注释是为了让后来者知道「这里曾经有一列 Y 轴刻度」，
---     别再照着写回来 —— 需要它的人是没读懂上面那段。）

--- ★★★ 41-tick-compact：X 轴刻度文字「**只写变化的部分**」。
---
---   用户原话：「只有12月和一月中间下方位置显示过渡的年份，日期和时间也是」。
---
---   问题出在**累计视图**：它的桶标签是 `os.date("%y年%m月", ts)`，12 格长这样 ——
---       25年11月 25年12月 26年01月 26年02月 … 26年10月
---   年份被重复了 12 次，而 12 格里真正有信息量的只有**跨年那一次**
---   （12月 → 01月）。一排「25年」「26年」白白吃掉近一半横向空间，
---   把真正要读的月份挤没了。
---
---   规则：去掉「%y年」前缀，**只在年份发生变化的那一格**保留。
---       改前：25年11月 25年12月 26年01月 26年02月 …
---       改后：11月      12月      26年01月 02月      …
---
---   ⚠ 三点刻意的取舍，都写在这里免得以后当成 bug 改掉：
---     · **第一格也不留年份**。用户说的是「只有12月和一月中间下方位置
---       显示过渡的年份」——「只有」把第一格也排除了。
---       代价是累计视图看不出起点是哪一年；好在上一行周期导航写着当前
---       年份（"2026年"），能倒推。若哪天想「第一格也带上年份」，
---       把下面 `prev_year ~= nil` 这个条件去掉即可（就一行）。
---     · 只认 `^%d%d年` 这种前缀，认不出的一律**原样返回**。
---       月视图的 "01".."31"（日期）、日视图的 "00".."23"（时间）、
---       周视图的 "一".."日"、年视图的 "01月".."12月" 都没有年份前缀，
---       ⇒ 结果**就是不变**。这正是用户那句「日期和时间也是」的含义：
---         同一套规则套到「日期」和「时间」刻度上，结论是它们本来就没在
---         重复什么 —— 要的是**规则统一**，而不是给每种粒度各写一份特例。
---     · 压缩后长度**只减不增**，所以绝不会把原来放得下的刻度挤掉；
---       反而让累计视图从「12 格只标 6 格」变成「12 格全标」。
---
---   ⚠ 必须在**抽稀之前**调用：抽稀量的是刻度文本宽度，量压缩后的才对。
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

--- X 轴刻度行：按每个柱子的中心 x 绝对定位。
---
--- ★★★ 39-trend-axis：**刻度必须用 `bucket.label`，绝不能按 period 现造**。
---
---   用户反馈「趋势图看不懂」。查下来这是**最直接的原因**：
---   旧实现这里调 `trendBucketLabels(period, count)` 自己生成刻度，
---   而 `GlobalStats.trend` 给每个 bucket 的 `label` 是另一套 —— 两边对不上：
---
---     | 粒度 | 真实 bucket.label        | 旧刻度（现造） | 后果 |
---     |------|--------------------------|----------------|------|
---     | 日   | "00".."23"（**每小时一根**）| 0..23 裸数字   | 看着像「日期」，其实是小时 |
---     | 周   | 一..日                    | 一..日         | ✓ |
---     | 月   | "01".."31"                | 1..31          | 丢前导零，勉强 |
---     | 年   | "01月".."12月"            | 1..12          | **丢了「月」** |
---     | 累计 | "25年10月" 这种            | 1..12          | **完全看不出是哪年哪月** |
---
---   更糟的是**列表视图用的是 `bucket.label`（正确）** ⇒ 同一份数据在
---   「图表」和「列表」两个视图里 X 轴含义不一致，来回切一下就对不上了。
---
---   现在两个视图统一走 `bucket.label`，口径一致。
---   抽稀逻辑不变，只是量的是**真实刻度文本**的宽度。
---   ★ 41-tick-compact 之后累计视图的刻度变短了（"25年10月" → "10月"），
---     所以它不再「自动少标几个」，12 个月能全标上 —— 这是顺带的好处。
---
--- ★★★ 41-tick-compact：刻度文字先过一遍 `compactTickLabels`，见上。
local function buildTickRow(buckets, chart_width, tick_height, color)
    local f = faces()
    local raw_labels = {}
    for i, bucket in ipairs(buckets) do
        raw_labels[i] = tostring((bucket and bucket.label) or i)
    end
    local labels = compactTickLabels(raw_labels)
    local bucket_count = math.max(1, #labels)
    local slot = chart_width / bucket_count

    -- ★★★ 43-tick-greedy：**改成「按实际宽度贪心摆放」**，不再用固定 stride 隔格丢。
    --
    --   用户报：「x 轴只显示 11月 26年1月，不显示 12月」。
    --   老写法是 `stride = ceil((某格文本宽 + 15px) / slot)`，然后
    --   `(i-1) % stride == 0` 的格子才显示。两个问题：
    --     1) 量的是 `labels[#labels]`（**最后一格**）的宽度，而它未必是最宽的
    --        （累计视图最后一格是「10月」，最宽的却是「26年01月」）；
    --     2) 隔格丢是**机械的**：哪怕两格之间明明塞得下，只要序号不对就被丢掉。
    --        累计视图 12 格 / 842px ⇒ slot≈70px；41-tick-compact 之前标签是
    --        「25年11月」约 70px ⇒ stride=2 ⇒ 第 2 格（12月）**必被丢**，
    --        而第 3 格（26年01月）靠「带年」后门被保住 —— 正好就是用户看到的样子。
    --
    --   现在：从左到右逐格试放，**只有当这一格真的会和上一格叠在一起才跳过**，
    --   且 `min_gap` 用 scaleBySize(4)=8px（老写法的 8 折算出来是 15px，偏保守）。
    --   ⇒ 压缩后的标签（「11月」约 35px）在 ≈70px 的 slot 里全都放得下，
    --     12 个月一个不落。
    --
    --   ★ 两道**保底**（信息量最大的两格绝不允许被丢）：
    --     · 带「年」的那一格 —— 跨年分界，丢了整张图看不出是哪年哪月；
    --       ⚠ 判据用**压缩后**的 labels（压缩前累计视图每格都含「年」，
    --         拿压缩前的判就等于强制全显，抽稀直接失效）。
    --     · **最后一格** —— 也就是「最近的月份」，最常被看；
    --       用户这次报的正是它前面那格被丢。
    --   保底格如果和上一格撞了，就把**上一格**撤掉：宁可少标一个，
    --   也不能让这两格消失。
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

--- 趋势列表视图（图表视图的替代），每行「标签 …… 数值」。
local function buildTrendList(buckets, metric, selected_index, width)
    local f = faces()
    local group = VerticalGroup:new{}
    local row_h = Screen:scaleBySize(34)
    for i, bucket in ipairs(buckets) do
        local is_selected = (i == selected_index)
        local color = is_selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local left = text(tostring(bucket.label), f.axis, { color = color, bold = is_selected })
        local right = text(metricValueText(bucket.value, metric), f.footer, { color = color, bold = is_selected })
        local left_w = left:getSize().w
        local right_w = right:getSize().w
        local filler = math.max(0, width - left_w - right_w - Screen:scaleBySize(8))
        local row = FixedBox:new{
            width = width, height = row_h,
            align = "left", vertical_align = "center",
            HorizontalGroup:new{
                align = "center", left,
                HorizontalSpan:new{ width = filler },
                right,
            },
        }
        if is_selected then
            row = FrameContainer:new{
                width = width, height = row_h,
                bordersize = 0, padding = 0, margin = 0,
                background = Blitbuffer.COLOR_BLACK,
                row,
            }
        end
        group[#group + 1] = row
    end
    return group
end

--==========================================================================
-- 卡片
--==========================================================================

--- 卡片大数字的候选字号。宽度不够就整档降级，避免多列卡片互相压字。
--- ★ 32：整体上调（用户要求字体更大）；同时因为改成多列，降级档位也保留。
local VALUE_SIZE_PAIRS = { { 29, 18 }, { 26, 16 }, { 22, 14 }, { 18, 12 }, { 15, 10 } }
local VALUE_FACES

local function valueFaces()
    if VALUE_FACES then return VALUE_FACES end
    VALUE_FACES = {}
    for i, pair in ipairs(VALUE_SIZE_PAIRS) do
        VALUE_FACES[i] = { Font:getFace("cfont", pair[1]), Font:getFace("cfont", pair[2]) }
    end
    return VALUE_FACES
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

local function buildCardContent(spec, inner_width)
    local f = faces()
    local group = VerticalGroup:new{}

    -- 第一行：大数字 + 小单位
    local sizes = valueFaces()
    local value_row
    for i = 1, #sizes do
        value_row = buildValueRow(spec.parts, inner_width, sizes[i][1], sizes[i][2])
        if value_row:getSize().w <= inner_width then break end
    end
    group[#group + 1] = value_row
    group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }

    -- 第二行：标签（+ 可下钻的 ">"）
    --
    -- ★★★ 41-no-card-icon：**卡片左侧的小图标删掉了**（用户：「总览页的卡片
    --   不要图标」）。
    --   · 删的是行首那个 `icon(spec.icon, ...)`。行尾那个 `chevron.right`
    --     **保留** —— 它明确提示「这张卡能点进去下钻」；浅灰描边只划分卡片边界，
    --     不表达点击动作。它和行首那个纯装饰性图标不是一回事。
    --   · 顺带把 `icon_size` 和它参与的 max_width 算术一起收掉：标签文字
    --     现在直接从卡片内边距起排，可用宽度多了 icon_size + 5px
    --     （KPW4 上 15+5 经 scaleBySize 后约 33px）——
    --     最长的两个标签「日均阅读时长」「单日阅读最久」因此少折一行。
    --   · 卡片 spec 里的 `icon = "..."` 字段**留着没删**：删它要动 9 处数据
    --     定义、风险不成比例；而且万一哪天想加回来，恢复上面这一行就够。
    --     留一个没人读的字段，比留一段被注释掉的代码干净。
    --   ⚠ 不要再给 label_row 加 `HorizontalSpan` 去「补」左边那块空位 ——
    --     那等于把图标换成了空白，用户要的是**标签整体靠左**。
    local label_row = HorizontalGroup:new{ align = "center" }
    label_row[#label_row + 1] = text(spec.label, f.label, {
        color = Blitbuffer.COLOR_DARK_GRAY,
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
            text(spec.delta_text, f.delta, {
                color = Blitbuffer.COLOR_DARK_GRAY,
                max_width = inner_width,
            }),
        }
    else
        delta_row = HorizontalGroup:new{ align = "center", text(" ", f.delta) }
    end
    group[#group + 1] = delta_row

    return group
end

--==========================================================================
-- 线条控件（★★★ 34：卡片/列表分隔线）
--==========================================================================
--
-- 上游 `LineWidget` 是有的，但它要求调用方**自己先设好 `dimen`**（否则
-- paintTo 里 `self.dimen.w` 直接 nil 崩），在竖排布局里很别扭。
-- 这里自造两个「天生带尺寸」的横线控件，宽度由构造参数给定，
-- paintTo 只负责按 dimen 画 —— 和本文件其它自造控件（FixedBox 等）同一套思路。
--
--   HRule —— 实线 / 点线，用于卡片下方、列表行之间的分隔
--   VRule —— 竖线，用于「一条线连接两张卡」的网格样式
--   SolidRect —— 实心矩形（任意宽高），用于「标签」样式左侧那条粗竖条。
--                ★★★ 36 新增：原来这里图省事用了**没有子控件的 FrameContainer**
--                当色块，但上游 `FrameContainer:getSize()` 第一行就是
--                `self[1]:getSize()` —— 没有子控件 ⇒ `self[1]` 为 nil ⇒
--                「attempt to index a nil value」**直接崩**。用户报的
--                「卡片样式标签 koreader 闪退」就是它。
--                自造控件只按给定的 width/height 画矩形，不依赖子控件。
-- ★★★ 42-round-dot：分隔线的圆点参数（**只改这两个常量就能调密度**）
--
--   用户原话：「分隔线密集一点，不是圆点吗，怎么都是方的」。
--
--   先说清楚**真实像素** —— 前面几轮一直算错了：
--     KOReader 的换算在 `ffi/framebuffer.lua:414`：
--         scaleBySize(px) = ceil(px * (size_scale + dpi_scale) / 2)
--         size_scale = min(屏宽, 屏高) / 600
--         dpi_scale = size_scale   -- 没设 `screen_dpi` 覆盖时两者相等
--     ⇒ **scaleBySize(px) = ceil(px * min(W, H) / 600)**
--     KPW4 是 1072×1448（crash.log 里 `initializing for device KindlePaperWhite4`
--     紧跟着就是 w=1072 / h=1448），且 settings 里**没有** `screen_dpi`
--     ⇒ 系数 = 1072/600 = 1.78667，并且**向上取整**：
--         scaleBySize(1)=2   (2)=4   (3)=6   (4)=8   (5)=9
--     （不是 `floor(n * 1.875)` —— 那是按 300dpi 直接折算，KOReader 不这么算。）
--
--   所以「现状」那条线的真实尺寸是：
--     **4px 宽 × 2px 高的小方块，间隔 8px，周期 12px**
--   宽高比 2:1 ⇒ 在 300dpi 上就是一排小方块 —— 这就是「怎么都是方的」。
--
--   改法：圆点改用 `bb:paintCircle`（`ffi/blitbuffer.lua:1948`，
--   `w` 默认 = `r` ⇒ 实心）。半径 2 ⇒ 直径 5px 的实心圆
--   （光栅 3/5/5/5/3 的圆角方块；1× 下就是个圆点）。
--   ⚠ 半径 1（3px）的光栅是**十字**（1/3/1），不是圆 ⇒ 最小可用半径就是 2。
--   ⚠ 半径 3（7px）最圆，但直径 7px 的点在 300dpi 上已经偏重，
--     而且横屏（`avail=376`）每页行数会从 5 掉到 4 ⇒ 不用。
--
--   密度：点 5px + 隔 4px ⇒ **周期 9px**，比原来的 12px 密 25%。
--   ⚠ 间隔别调到 3px 以下（点会粘连成「串珠」）；想更疏就往 5~6px 调。
local SEP_DOT_R   = 2                       -- 圆点半径(px)：2 ⇒ 直径 5px
local SEP_DOT_GAP = Screen:scaleBySize(2)   -- 点间隔(px)：KPW4 上 = 4px

local HRule = WidgetContainer:extend{
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
    -- ★★★ 42-round-dot：圆点模式（参数见文件上方的 SEP_DOT_R / SEP_DOT_GAP）。
    --
    --   ⚠ 圆点**故意画得比 size.h 高**：size.h 还是 2px（scaleBySize(1)），
    --     而圆点直径是 5px。行高保持 2px 是**为了不动分页预算** ——
    --     buildUnitsPage 里 `rows_per_page = avail / (row_h + line_w)`。
    --     ★ 42b 更正：这里原来写「把 line_w 从 2 抬到 5 会让 KPW4 上每页
    --       从 9 行掉到 8 行」，**算错了**。按本文件常量复算：
    --         竖屏 avail=715 / row_h=72 ⇒ 分隔带 2px: 715/74=9.66 → 9 行
    --                                     分隔带 5px: 715/77=9.29 → **还是 9 行**
    --         横屏 avail=376 / row_h=72 ⇒ 分隔带 2px: 376/74=5.08 → 5 行
    --                                     分隔带 5px: 376/77=4.88 → **掉到 4 行**
    --       所以「不抬行高」的真正理由是**横屏**会掉一行，竖屏其实无所谓。
    --     多出来的 ±2px 溢到相邻行的**空白**里，三处调用点都安全：
    --       · 阅读字数列表行 / 下钻浮窗行 = 透明 FixedBox（文字在 row_h 里
    --         垂直居中，上下各留 ~20px 空白）；
    --       · 「点线」卡片样式那处，行间距是 9px 的透明 VerticalSpan（cell_gap）。
    --     而且**没有任何东西会擦掉它**（42b 已核）：
    --       · 全 KOReader 树里 `setClipRect` 出现 **0 次** —— 不存在裁剪矩形；
    --       · 唯一的「裁剪」是 ScrollableContainer 把子控件画到白画布再 blit
    --         一块，而分隔线在容器 dimen 之内（列表页更是不用滚动容器）；
    --       · 列表行都是透明 FixedBox，不画底色 ⇒ 后画的行不会盖住上一条点。
    --
    --   ⚠ 42b：`r` 取整、`gap` 夹到 >= 0。两者都是**防呆**：
    --     `paintCircle` 内部按像素步进，`r` 传小数会在 FFI 索引处报
    --     「number has no integer representation」；而 `dot_gap` 是公开字段，
    --     传负值会让 `step <= 0` ⇒ 下面这个 while **死循环**（当前无调用点传，
    --     但一个公开字段不该留这种地雷）。
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
    -- 42b：和圆点分支一样夹一下 —— `gap_len` 传负值在这里同样是死循环。
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

--- 实心矩形（自带尺寸，不依赖子控件）。
-- 用于「标签」卡片左侧的粗竖条 —— 不能用无子控件的 FrameContainer（会崩）。
local SolidRect = WidgetContainer:extend{
    width = nil,
    height = nil,
    color = Blitbuffer.COLOR_BLACK,
}

function SolidRect:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width or 0, h = self.height or 0 }
end

function SolidRect:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    bb:paintRect(x, y, size.w, size.h, self.color)
end

--==========================================================================
-- 卡片样式（★★★ 34：多套可切换样式）
--==========================================================================
--
-- 用户要求：「总览页面的卡片每行三个卡片（阅读字数那种，多设计几种样式
--   可以切换，中间只用一条线连接两个卡片的还有其他的样式）」。
--
-- 设计：把「画一张卡片」抽成 `wrapCard(content, w, h, style, on_tap)`，
--   按 style 分派。所有样式**一致性前提**：
--     · 一律纯白底（不填充任何灰色 —— 32 轮已确立）；
--     · 点按区域、固定尺寸、等高对齐都不变（只换皮肤，不改布局）。
--   新增样式只需往 `CARD_STYLES` 里加一条，不动网格代码。
--
-- 注意：上游 `FrameContainer` **不支持分边边框**（没有 border_right_size
--   之类），所以「网格线」不能靠给 FrameContainer 设右边框实现，
--   必须在网格层用 VRule / HRule 自己补线。见 buildCardGrid。
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
    local pad = Size.padding.small
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
                    color = Blitbuffer.COLOR_GRAY_E, dotted = true },
            },
        }
    elseif style == "plate" then
        -- 「标签」样式：1px 外框 + 左侧粗竖条，便签/标签纸观感。
        --
        -- ★★★ 36 修的闪退 bug：左侧竖条原先是
        --     `FixedBox:new{ FrameContainer:new{ background=黑, 无子控件 } }`。
        --   上游 FrameContainer 的 getSize() 直接取 `self[1]:getSize()`，
        --   空子控件 ⇒ nil ⇒ `attempt to index a nil value` **必崩**。
        --   换成自造的 SolidRect（只按 width/height 画实心矩形）。
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
                -- ★★ 32：卡片原本 bordersize = 0（纯白贴在白底浮窗上，等于没有边界）。
                --   用户要求「不选中有边框，不要填充颜色」，这里统一给卡片描边，
                --   底色一律纯白（不再用任何灰底）。
                bordersize = border,
                color = Blitbuffer.COLOR_GRAY_E,
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
--   · 宽 = min(屏宽 - 2*margin, 最大宽上限)。留出左右各 margin 的缝隙，
--     既看得到背景，也避免 e-ink 上贴边难看。
--   · 高 = min(内容高, 屏高 - 2*margin)。内容超过就**内部滚动**
--     （ScrollableContainer），而不是撑破屏幕。
--   · 竖屏/横屏都用 min/max 取，不写死。
local POPUP_MARGIN = Size.padding.large           -- 窗口与屏幕边缘的缝隙
local POPUP_SIDE_PADDING = Size.padding.large     -- 窗口内部左右内边距
-- ★★★ 44-shrink：用户原话「整体的阅读统计能不能缩小一点」⇒ 88%/80% → 84%/76%。
--   KPW4（1072×1448）上的实际结果：
--     卡片宽 = floor(1072 * 0.84) = 900（原 943）
--     内容宽 = 900 - 2*18 = 864（原 907）
--     趋势图宽 = 864 - 2*18 = 828（原 871）
--     可用高 = floor(1448 * 0.76) = 1100（原 1158）
--   ⇒ 窗口四周留白增加，内容区仍保留适合阅读的尺寸。
local POPUP_MAX_WIDTH_RATIO = 0.84                -- 宽度不超过屏宽的 84%
local POPUP_MAX_HEIGHT_RATIO = 0.76               -- 高度不超过屏高的 76%

-- ★★★ 36：下钻浮窗的尺寸比例 —— 必须**明显小于**主浮窗（0.88 / 0.80），
--   这样点卡片进去时，能看到下钻框四周还露出主浮窗，一眼就是「叠在上面一层」。
local DRILL_MAX_WIDTH_RATIO = 0.78
local DRILL_MAX_HEIGHT_RATIO = 0.66

-- ★★★ 44-compact：两排标签的**统一高度**（视图排 + 周期排）。
--   以前是两处硬编码：`buildViewTabs` 里 `scaleBySize(38)`、`buildTabs` 里
--   `scaleBySize(36)`，而 `buildUnitsPage` 的高度预算里又各抄了一份
--   （VIEWTAB_H / TABS_H）—— 改一处就会算错可用高、把内容挤出去。
--   现在统一成一个常量，三处都引用它。
--   KPW4：scaleBySize(23) = 42（原 47 / 65）。
local ROW_TAB_H_PX = 23

--==========================================================================
-- 下钻浮窗（★★★ 34：从全屏 KeyValuePage 改成**悬浮在上层的浮窗**）
--==========================================================================
--
-- 用户原话：「单击卡片点进去页面应该也是悬浮的，怎么是在页面下一层，
--   都看不到」。
--
-- 病因：原来 `showDrillDown` 直接 `UIManager:show(KeyValuePage:new{...})`，
--   而 `KeyValuePage` 是**全屏页**（`CenterContainer` 撑满，且不是 modal）。
--   `StatisticsPage` 本身是 `modal = FocusManager`，模态层永远压在最上面 ⇒
--   全屏的 KeyValuePage 被浮窗盖住，用户只看到浮窗、看不到下钻内容
--   （「在页面下一层，都看不到」正是这个）。
--
-- 修法：下钻也用**居中浮窗**，形态与 StatisticsPage 完全一致
--   （CenterContainer + 白底圆角卡片 + NoBarScrollable 内部滚动），
--   并且同样 `modal = true`。这样它与主浮窗**同级**，show 出来就在最上层，
--   关掉又回到主浮窗 —— 用户说的「也应该是悬浮的」即此。
--
-- 为了「关掉下钻后主浮窗还在」：show 之前**不关**主浮窗（它是 modal，
--   会被压在下面但仍在栈里）；下钻浮窗一 close，UIManager 自然把主浮窗
--   重新露出来。行间用点线分隔（HRule dotted）。
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
    local region = (self.popup_frame and self.popup_frame.dimen) or self.dimen
    if region then
        pcall(UIManager.setDirty, UIManager, self, "ui", region)
    end
end

function DrillDownPopup:build()
    -- ★★★ 36：下钻浮窗要**明显小于**阅读统计主浮窗（用户要求
    --   「卡片点击进去的显示框比阅读统计要小一点」）。
    --   主浮窗宽/高分别由 POPUP_MAX_WIDTH_RATIO / POPUP_MAX_HEIGHT_RATIO 限制。
    --   下钻取 0.80 / 0.72 —— 一眼就能看出「这是叠在上面的一层」。
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
                        max_width = right_w, bold = true }) },
            },
        }
        -- 行间点线（最后一行不画）
        if _i < #self.rows then
            body[#body + 1] = HRule:new{ width = content_w, height = line_w,
                color = Blitbuffer.COLOR_GRAY_E, dotted = true }
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

local function showDrillDown(parent, plugin, title, rows)
    UIManager:show(DrillDownPopup:new{
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

local VIEW_TABS = {
    { value = "overview", label = _("总览") },
    { value = "trend", label = _("阅读趋势") },
    { value = "units", label = _("阅读字数") },
    { value = "speed", label = _("阅读速度") },
}

local METRICS = {
    { value = "seconds", label = _("阅读时间"), icon = "history" },
    { value = "units", label = _("阅读字数"), icon = "align.justify" },
    { value = "speed", label = _("阅读速度"), icon = "zoom.content" },
    { value = "average", label = _("日均阅读时长"), icon = "dogear.reading" },
}

-- ★★★ 26-popup：从「全屏页」改成「居中浮窗」。
--
-- 用户要求：照 KOReader 官方 reading insights popup 的形态 —— 居中浮窗、
-- 背后能看到书，而不是把整个阅读界面顶掉、进一个全屏页面。
--
-- 形态（对齐 D:/chrome/2-reading-insights-popup02.lua 的 ReadingInsightsPopup）：
--     StatisticsPage = FocusManager:extend{ modal = true, ... }
--     self[1] = CenterContainer:new{
--         dimen = Screen:getSize(),      -- 整屏，用来做「点外面关闭」的命中区
--         self.popup_frame,              -- 居中的白底圆角卡片
--     }
--   —— CenterContainer 把 popup_frame 摆在屏幕正中，四周露出底层
--      （阅读器页面 or Bookshelf），这就是「背后能看到书」。
--   —— modal = true 让 UIManager 把点击**只**投给本控件（不穿透到底层翻页）。
--   —— 点 popup_frame 之外、本控件范围之内 → 关闭（onTapClose）。
--
-- 尺寸策略：
--   · 宽 = min(屏宽 - 2*margin, 最大宽上限)。留出左右各 margin 的缝隙，
--     既看得到背景，也避免 e-ink 上贴边难看。
--   · 高 = min(内容高, 屏高 - 2*margin)。内容超过就**内部滚动**
--     （ScrollableContainer），而不是撑破屏幕。
--   · 竖屏/横屏都用 min/max 取，不写死。
--
-- ★★★ 35：这几个常量必须定义在 **DrillDownPopup / StatisticsPage 之前** ——
--   两个浮窗类的 build() 都会引用它们。33 版它们在本段（旧位置）没问题，
--   但 34 版把 DrillDownPopup 提到了更前面，所以统一上移到浮窗定义之前。

local StatisticsPage = FocusManager:extend{
    modal = true,
    plugin = nil,
    period = "year",
    anchor = nil,
    metric = "units",
    trend_view = "chart",
    view = "overview",
    unit_sort = "units",
    -- ★★★ 34：总览卡片样式（box / grid / hairline / plate，见 CARD_STYLES）
    card_style = "box",
    -- ★★★ 34：阅读字数页的**分页**（用户要求左右键翻页，不再上下滑动）
    unit_page = 1,
    -- ★ 这两个现在表示**浮窗内容区**的尺寸，不再等于整屏
    width = nil,
    height = nil,
    popup_frame = nil,
}

--- 阅读字数页每页行数的**上限**（实际行数按可用高度自适应，见 buildUnitsPage）。
---   · 太多 ⇒ 一页放不下（现在浮窗禁止滑动，放不下就会被裁掉）；
---   · 太少 ⇒ 翻页太频繁。
---   12 是 KPW4 竖屏的合理上限；小屏/横屏会自适应算得更少。
local UNIT_PAGE_SIZE_MAX = 12

--- 计算浮窗的最大可用尺寸（不含外层缝隙）。
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
    -- ★ self.width 表示**浮窗卡片的整体宽度**（含卡片左右内边距）。
    --   build() 里再扣 POPUP_SIDE_PADDING 得到内容区宽度去分栏/排卡片。
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
    -- ★★★ 34：按键分工。
    --   ⚠ 重要事实：**KPW4（KindlePaperWhite4）是纯触摸设备，没有实体翻页键**
    --     （device.lua:1076 `KindlePaperWhite4 = Kindle:extend{ isTouchDevice = yes }`
    --      且未设 `hasKeys`）。所以用户说的「按左右键翻页」实际是**点屏幕上的
    --      左右箭头按钮**，不是物理键。本页因此以「屏上 ‹ › 按钮」为主，
    --      物理键处理只作为「万一接了键盘/其他机型」的兼容。
    --
    --   物理键仍旧：Back / Home 关闭。
    --   若设备确有翻页键（hasKeys）：LPgFwd/RPgFwd 在 reading-words 视图翻页，
    --      其他视图当关闭。
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.AnyKeyPressed = {
            { "Back", "Home" },
        }
        -- KOReader 约定（readerrolling.lua:140-141）：
        --   下一页 = RPgFwd/LPgFwd → GotoNextView
        --   上一页 = RPgBack/LPgBack → GotoPrevView
        self.key_events.GotoNextView = { { { "RPgFwd", "LPgFwd" } } }
        self.key_events.GotoPrevView = { { { "RPgBack", "LPgBack" } } }
    end
end

function StatisticsPage:onClose()
    UIManager:close(self)
end

--- 翻到「阅读字数」列表的下一页（只在该视图有意义）。
--- 返回 true 表示已处理；非 units 视图返回 false，交给调用方决定。
function StatisticsPage:pageUnits(delta)
    if self.view ~= "units" then return false end
    local total = math.max(1, self._unit_total_pages or 1)
    local target = (self.unit_page or 1) + delta
    if target < 1 then target = total end     -- 到头往回绕
    if target > total then target = 1 end     -- 到尾往前绕
    self:reload{ view = "units", unit_page = target }
    return true
end

--- 物理键：下一页（GotoNextView）。
function StatisticsPage:onGotoNextView()
    if self:pageUnits(1) then return true end
    self:onClose()
    return true
end

--- 物理键：上一页（GotoPrevView）。
function StatisticsPage:onGotoPrevView()
    if self:pageUnits(-1) then return true end
    self:onClose()
    return true
end

--- 点空白关闭：命中区是整屏，但 popup_frame 之外的点击才算「点空白」。
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
    -- ★ 26-popup：reload（切视图/周期）时是「关掉自己、立刻开一个同尺寸的新浮窗」。
    --   如果这里老老实实刷整屏，用户会看到：
    --     浮窗消失 → 露出书页 → 新浮窗出现  ⇒ e-ink 上明显闪一下。
    --   reload 会在关之前把这个标志置 true，跳过这次重绘，
    --   由紧接着的 UIManager:show(next_page) 负责画。
    if self._skip_close_repaint then
        self._skip_close_repaint = nil
        return
    end
    -- 正常关闭：只刷浮窗所在区域，把底下的书页还回去；不做全屏 flash。
    --
    -- ★★★ 26-sample-popup 修的一个真 bug：这里原来传的是 `self.dimen`，
    --   而浮窗化之后 `self.dimen` 被设成了**整屏**（它是「点外面关闭」的
    --   命中区域，必须是整屏才行）。于是每次正常关窗都会
    --   `setDirty(self, "ui", 整屏)` —— 也就是**全屏重绘**。
    --   在上游 uimanager.lua 里，注释明确点名「ui over the full viewport」
    --   是最糟的用例（只有 region 为 nil 时才回退整屏，本意是给「必须刷
    --   全屏」的场景用）。e-ink 上表现为：关浮窗时整屏黑一下再恢复
    --   （flash），而不是「只有浮窗那块变成书页」。
    --
    --   正确做法是刷**浮窗自己的矩形**：`self.popup_frame.dimen`。
    --   这样底下书页只有被浮窗遮住的那块需要重画，观感干净、也省电。
    --   `popup_frame` 拿不到时（构建失败等极端情形）才退回整屏。
    local region = (self.popup_frame and self.popup_frame.dimen) or self.dimen
    if region then
        pcall(UIManager.setDirty, UIManager, self, "ui", region)
    end
end

--- 换周期 / 换指标 / 换视图：整页重建再替换。
--- 重建比原地 update 简单可靠得多，代价是一次重绘。
function StatisticsPage:reload(opts)
    opts = opts or {}
    local ok, next_page = pcall(StatisticsPage.new, StatisticsPage, {
        plugin = self.plugin,
        period = opts.period or self.period,
        anchor = opts.anchor or self.anchor,
        metric = opts.metric or self.metric,
        trend_view = opts.trend_view or self.trend_view,
        view = opts.view or self.view,
        unit_sort = opts.unit_sort or self.unit_sort,
        card_style = opts.card_style or self.card_style,
        -- 翻页：显式传了就按传的，没传就回到第 1 页
        -- （只有在「同一个 units 视图内翻页」时才显式传 unit_page）
        unit_page = opts.unit_page or 1,
    })
    if not ok then
        logger.err("WordCount: statistics page build failed", next_page)
        UIManager:show(InfoMessage:new{ text = T(_("统计页面打开失败：%1"), tostring(next_page)) })
        return self
    end
    -- ★ 26-popup：重建时不要先 close 再 show —— 那会在 e-ink 上闪一下
    --   （先画回底层书页，再画新浮窗）。把「关闭时不要重绘」的标志挂上，
    --   让 onCloseWidget 跳过这次刷新，由紧接着的 show(next_page) 一次画完。
    self._skip_close_repaint = true
    UIManager:close(self)

    -- ★★★ 43-no-flash：**显式**给「浮窗矩形」一个 `"ui"` 刷新。
    --
    --   用户报的「日周切换的时候年月日总会出现一个黑框然后消失」根因在这。
    --
    --   老写法是 `UIManager:show(next_page)`（不带刷新参数）。上游 `show()`
    --   会把它转成 `setDirty(widget, nil, nil)`，而 `_refresh(nil, …)` 是**直接
    --   返回**的（uimanager.lua:1122-1127：「show/close 没带刷新细节时丢弃，
    --   免得排一次没用的全屏刷新」）。于是刷新队列一直是空的，最终靠
    --   `_repaint()` 的兜底（uimanager.lua:1291-1294）补一次
    --   **`_refresh("partial")`** —— 注意：**没有 region**。
    --
    --   ⇒ 两个后果：
    --     1) region 为 nil ⇒ `_refresh` 把区域填成整屏（:1178），
    --        所以刷的是整屏而不是浮窗那一块；
    --     2) 更要命的是 :1163-1175 的**提升规则**：没有 region 的 "partial"
    --        每 `FULL_REFRESH_COUNT` 次会被提升成 **`"full"`** ——
    --        `refresh_methods["full"]` 是**带黑闪的整屏全刷**。
    --        统计页每点一下周期/视图都重建一次，这个计数器涨得飞快，
    --        于是「总会」看到黑框闪一下再消失。
    --
    --   改法：把刷新**提前、显式、带区域**地排进队列 ——
    --     · 区域 = `self.popup_frame.dimen`（旧浮窗矩形）。
    --       ✅ 这个矩形在所有视图/周期下**完全一致**，可以放心复用：
    --          `popup_frame` 的唯一子控件是 `FixedPane`（ScrollableContainer），
    --          而 `ScrollableContainer` 有 `dimen`（= frame_w × available_h），
    --          `WidgetContainer:getSize()` 见 dimen 就直接返回它 ——
    --          所以浮窗尺寸与内容高矮无关，`CenterContainer` 的居中位置也不变。
    --     · 模式 = `"ui"`（不是 "partial"）。
    --       ✅ "ui" **不在**提升名单里（名单里只有 "partial"），永远不会被
    --          提升成带黑闪的 "full"；同时它仍是 e-ink 上的灰阶局部刷新，
    --          不是 "flashui" 那种闪。
    --     · 排了刷新 ⇒ `_repaint()` 的兜底不再触发，也就不会再有整屏刷新。
    --
    --   ⚠ `popup_frame` 拿不到时（构建失败等极端情形）退回老写法，
    --     宁可多刷一次也不能不刷。
    local refresh_region = self.popup_frame and self.popup_frame.dimen or nil
    if refresh_region then
        UIManager:show(next_page, "ui", refresh_region)
    else
        UIManager:show(next_page)
    end
    return next_page
end

--- 当前周期里"正在看"的那个分桶下标（柱状图高亮 + 底部读数用）。
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

--- 底部读数里的分桶全名，例如 "2026年1月"
--- 注意：这里不能用 `local _, _, label = ...` —— 会把 gettext 的 `_` 遮蔽掉，
--- 后面再调 `_(...)` 就是"attempt to call a string value"。
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

--- ★★★ 36：统计结果**记忆缓存**（用户要求「打开统计页时只统计一次」）。
--
--   `summarize` / `trend` / `details` 都是**纯 CPU** 在整个 global store 上算的。
--   同一页里切周期/视图会反复建新页，每次都重算一遍是浪费。
--
--   做法：按 `(period, anchor, metric)` 把结果记在 plugin 实例上；
--   键里带一个**数据版本号**（`_global_stats_rev`），只要 store 有新写入，
--   版本号变，缓存自动失效 —— 不会读到过期数据。
--
--   ⚠ 只缓存「派生的统计结果」，不缓存 store 本身（store 一直被写入，
--     缓存它就得精细失效，风险大于收益）。
local function statMemoKey(plugin, period, anchor, metric)
    local rev = (plugin and plugin._global_stats_rev) or 0
    return tostring(period) .. "|" .. tostring(anchor) .. "|"
        .. tostring(metric) .. "|" .. tostring(rev)
end

-- ★ 37l-mem：`kind` 里带了 period|anchor，用户每翻一次月/年就多一个 kind。
--   旧实现「一个 kind 一个 slot 且永不删除」⇒ 翻几百次就留下几百个槽，
--   每个槽还抓着结果表（summary/buckets/details）⇒ 隐性内存增长。
--   加一个软上限：槽位数超过 48 就整体清空（缓存本来就是可重建的，
--   清掉只是下次多算一次，不影响正确性）。
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
    -- ★ 26-popup：self.width 是**浮窗卡片的整体宽度**（已含卡片左右内边距）。
    --   内容区还要再扣掉卡片自己那圈 padding，否则卡片最右会被裁掉一点。
    local frame_w = self.width
    local content_w = frame_w - 2 * POPUP_SIDE_PADDING
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local memo_key = statMemoKey(self.plugin, self.period, self.anchor, self.view)

    local summary = memoGet(self.plugin, "summary:" .. tostring(self.period)
        .. "|" .. tostring(self.anchor), memo_key)
        or memoSet(self.plugin, "summary:" .. tostring(self.period)
            .. "|" .. tostring(self.anchor), memo_key,
            GlobalStats.summarize(store, self.period, self.anchor))
    local previous
    if self.period ~= "total" then
        local prev_anchor = GlobalStats.shiftAnchor(self.period, self.anchor, -1)
        local pkey = "prev:" .. tostring(self.period) .. "|" .. tostring(self.anchor)
        previous = memoGet(self.plugin, pkey, memo_key)
            or memoSet(self.plugin, pkey, memo_key,
                GlobalStats.summarize(store, self.period, prev_anchor))
    end
    local _first, _last, range_label = GlobalStats.bounds(self.period, self.anchor)
    local page_metric = self.view == "speed" and "speed" or self.metric
    local trend_key = "trend:" .. tostring(self.period) .. "|" .. tostring(self.anchor)
        .. "|" .. tostring(page_metric)
    local buckets = memoGet(self.plugin, trend_key, memo_key)
        or memoSet(self.plugin, trend_key, memo_key,
            GlobalStats.trend(store, self.period, self.anchor, page_metric))
    local selected = self:selectedIndex(buckets)

    -- ★★★ 26-scroll-header（用户要求）：
    --   「顶部那一条能不能也随着下滑一起消失？就保留中间那个滚动的区域」
    --
    --   原来 title_bar 是**钉在浮窗顶上**的（作为竖向组的第一个子控件，
    --   后面接 scroll），下滑时它一直杵在那里，占掉一条高度。
    --   现在把 title_bar 挪进 body —— 也就是挪进 ScrollableContainer 里，
    --   它就成了「内容的第一行」，下滑会一起滚走，浮窗最上方只剩滚动区。
    --
    --   要注意的三处：
    --     1) 标题栏宽度要**减去滚动条**可能占的宽度，否则右端被裁；
    --        ScrollableContainer 用户态下滚动条是浮层（overlay），不占宽，
    --        这里保守起见仍按 content_w 给，避免未来开常显滚动条时被裁。
    --     2) title_bar 自带 bottom_line 和左右 padding，宽度与 body 其它
    --        控件对齐（body 已被 padded 包了一层 POPUP_SIDE_PADDING）。
    --     3) available_h 不用再扣标题栏高度了（它已在滚动内容里），
    --        直接用 max_h。
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

    -- ★★★ 36：可用高度要在**建 body 之前**算出来 —— 因为各视图
    --   （尤其阅读字数页）要按它自适应「每页放几行」，保证内容放得下、
    --   不依赖滚动（外层容器已是禁止滑动的 FixedPane）。
    local max_w_unused, max_h = popupBounds()
    local available_h = math.max(
        Screen:scaleBySize(80),  -- 极端小屏兜底，别算出负数高度
        max_h
    )
    self._available_h = available_h

    local body = VerticalGroup:new{ align = "left" }
    -- ★ 标题栏作为**滚动内容的第一行**（不再是钉死的顶栏）。
    body[#body + 1] = title_bar
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
    -- ★ 26-card-order：「阅读字数」+「阅读速度」要放在**其他同级卡片的最前面**，
    --   不是整个页面的最开头。所以这里什么都不插，只改 buildCardGrid 里
    --   specs 的顺序（把这两张卡挪到数组头部）—— 它们是「卡片网格」里
    --   的同级卡片，位置就该在网格内部体现，而不是在网格外面另起一块。
    body[#body + 1] = self:buildViewTabs(content_w)
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
    body[#body + 1] = self:buildTabs(content_w)
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
    body[#body + 1] = self:buildPeriodNav(content_w, range_label)
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
    if self.view == "overview" then
        -- ★★★ 34：卡片样式切换行（只在总览视图出现，换来换去才有意义）
        body[#body + 1] = self:buildCardStyleRow(content_w)
        body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
        body[#body + 1] = self:buildCardGrid(content_w, summary, previous)
    elseif self.view == "units" then
        body[#body + 1] = self:buildUnitsPage(content_w)
    else
        body[#body + 1] = self:buildTrendSection(content_w, buckets, selected,
            self.view == "speed" and "speed" or nil)
    end
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
    -- ★★★ 32：**删掉「退出」按钮**。
    --
    --   用户原话：「为什么还多了一个返回，那个返回我让你做过这个功能吗」。
    --   这个按钮是我在 26-scroll-header 那轮自己加的（理由写的是「点空白/按返回键
    --   属于隐藏操作，用户不容易发现」）—— 但用户**从来没要求过**，属于我擅自加的功能。
    --   已按要求移除。关窗方式保持原有的：
    --     · 点浮窗外空白
    --     · 按实体返回键（key_events.AnyKeyPressed）
    --     · 标题栏右上角的关闭图标（TitleBar close_callback）

    local padded = HorizontalGroup:new{
        HorizontalSpan:new{ width = POPUP_SIDE_PADDING },
        body,
    }

    -- ★★★ 36：容器改成 `FixedPane` —— **禁止上下/左右滑动**。
    --
    --   用户原话：「阅读统计总览页面为什么还是可以左右上下滑动」
    --           「切换下一页上一页也是通过图标不是滑动」。
    --
    --   历史：26 用 `ScrollableContainer`、32 换成 `NoBarScrollable`（去滚动条）。
    --   但两者都**仍然能拖**，用户要的是彻底不能滑 —— 所以换成 FixedPane
    --   （继承 ScrollableContainer，但把所有滚动手势 ignore 掉，见其定义）。
    --
    --   代价：内容超过 available_h 的部分**不会再滚动**，会被裁掉。
    --   因此各视图必须自己收敛到能放下的高度（available_h 见上，
    --   每个视图构建时都能通过 self._available_h 拿到）。
    local scroll = FixedPane:new{
        dimen = Geom:new{ x = 0, y = 0, w = frame_w, h = available_h },
        show_parent = self,
        padded,
    }

    -- ★★★ 26-popup：白底圆角卡片 = 浮窗本体。
    --   背景由 FrameContainer 自己画（COLOR_WHITE），所以卡片之外露出的
    --   就是底层的阅读页面 —— 这正是「背后能看到书」。
    --
    -- ★ 26-scroll-header：竖向组里**只剩 scroll 一个子控件**了
    --   （标题栏已进滚动区）。浮窗最上方因此就是滚动内容本身，
    --   下滑时顶部那条标题会跟着一起滚走。
    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Screen:scaleBySize(2),
        color = Blitbuffer.COLOR_GRAY_E,
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

--- 总览 / 趋势 / 阅读字数 / 阅读速度。
---
--- ★★★ 32 用户明确要求：
---   「我要的是不选中有边框（不要填充颜色），选中的区别开」
---   所以：
---     · 未选中 = **纯白底 + 黑边框**（不再是浅灰填充）
---     · 选中   = **黑底白字**（对比强烈，e-ink 上一眼能分辨）
---   注意：e-ink 上黑底是「实心反白」，比任何灰度填充都清楚，
---   而且不需要灰阶抖动，反而更省刷新。
--- ★★★ 44-segmented：干净的「分段控件」（**单圈外框 + 单条分隔线**）。
---
--- 为什么需要它 —— 用户原话：
---   「导航和导航各有一张卡片，然后中间会有一个接近重合的线不好看」
---
---   老画法给**每一格**都套了一个 `bordersize = scaleBySize(1)`（2px）
---   的圆角 `FrameContainer`，格子之间又**紧挨着**（没有 span）⇒
---     · 相邻两格的边框叠在一起 → 接缝变成 **4px 粗线**；
---     · 两格的圆角在接缝的上下端**几乎重合但不完全重合** → 挤出一个小「腰」。
---   这就是那条「接近重合的线」。视图排那边因为格子间留了 9px 缝，
---   反而没有这个问题（所以只有周期排看起来脏）—— 但两排观感不一致。
---
---   现在两排统一走标准分段控件：
---     · 外框**只画一圈**（浅灰描边 + `radius` 圆角 + 白底）；
---     · 格子内部**不画边框**，格与格之间插一条浅灰竖线；
---     · 选中格填黑，圆角取 `radius - 边宽` ⇒ 贴到两端时正好与外框内缘吻合，
---       不会在角上露出白缝。
local function buildSegmentedRow(opts)
    local width = opts.width
    local height = opts.height
    local radius = opts.radius or Size.radius.button
    local items = opts.items or {}
    local border = Screen:scaleBySize(1)              -- 2px
    local inner_w = math.max(1, width - 2 * border)
    local inner_h = math.max(1, height - 2 * border)
    local n = math.max(1, #items)
    local sep_w = border
    local cell_w = math.floor((inner_w - sep_w * (n - 1)) / n)

    local row = HorizontalGroup:new{ align = "center" }
    for i, it in ipairs(items) do
        if i > 1 then
            -- 分隔线：浅灰窄条，避免和黑底选中项争抢注意力。
            -- ⚠ `FrameContainer` 必须有子控件（`getSize()` 会取 `self[1]`），
            --   所以塞一个 1×1 的 `FixedBox` 占位；实际尺寸由 `width/height` 决定。
            row[#row + 1] = FixedBox:new{
                width = sep_w, height = inner_h,
                FrameContainer:new{
                    width = sep_w, height = inner_h,
                    bordersize = 0, margin = 0, padding = 0,
                    background = Blitbuffer.COLOR_GRAY_E,
                    FixedBox:new{ width = 1, height = 1 },
                },
            }
        end
        local label
        if it.icon then
            label = icon(it.icon, Screen:scaleBySize(16), { white = it.active })
        else
            label = text(it.label, it.face, {
                color = it.active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                bold = it.active,
                max_width = math.max(1, cell_w - Screen:scaleBySize(6)),
            })
        end
        local inner = FixedBox:new{
            width = cell_w, height = inner_h,
            align = "center", vertical_align = "center", label,
        }
        if it.active then
            inner = FixedBox:new{
                width = cell_w, height = inner_h,
                align = "center", vertical_align = "center",
                FrameContainer:new{
                    width = cell_w, height = inner_h,
                    bordersize = 0, margin = 0, padding = 0,
                    background = Blitbuffer.COLOR_BLACK,
                    radius = math.max(0, radius - border),
                    FixedBox:new{
                        width = cell_w, height = inner_h,
                        align = "center", vertical_align = "center", label,
                    },
                },
            }
        end
        if it.on_tap then
            inner = TapBox:new{ inner, on_tap = it.on_tap }
        end
        row[#row + 1] = FixedBox:new{ width = cell_w, height = inner_h, inner }
    end

    return FixedBox:new{
        width = width, height = height,
        align = "center", vertical_align = "center",
        FrameContainer:new{
            width = width, height = height,
            bordersize = border,
            color = Blitbuffer.COLOR_GRAY_E,
            radius = radius,
            margin = 0, padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            row,
        },
    }
end

--- 总览 / 趋势 / 阅读字数 / 阅读速度。
---
--- ★★★ 32 用户明确要求：
---   「我要的是不选中有边框（不要填充颜色），选中的区别开」
---   ⇒ 未选中 = 白底黑框；选中 = 黑底白字。
--- ★★★ 44-segmented：整排改成**一个分段控件**（外框一圈 + 单条分隔线），
---   不再是一格一个圆角框、也不再有 9px 缝 —— 和周期排观感统一。
function StatisticsPage:buildViewTabs(width)
    local face = Font:getFace("cfont", 16)
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
        radius = Size.radius.button,
        items = items,
    }
end

--- 日 / 周 / 月 / 年 / 总
--- ★★ 32：同「不选中描边、选中反白」的规则。
---   外层的 LIGHT_GRAY 底也去掉 —— 用户明确说不要灰色。
--- ★★★ 44-segmented：改走 `buildSegmentedRow`（单圈外框 + 单条分隔线）。
---   老画法每格各画 2px 圆角边框、格子紧挨 ⇒ 接缝叠成 4px、圆角挤出小「腰」，
---   就是用户说的「中间会有一个接近重合的线不好看」。
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
            -- ★★★ 43-pickers：**点已选中的周期标签 = 弹出该粒度的选择器**。
            --
            --   用户原话：「阅读统计里的日周月年以及总览选择能不能重新弄好
            --     （年的点击可以选择年份，月的点击可以选择月份，日的点击可以
            --      选择月份，周的点击可以选择第几周（第几周后面跟着时间））」
            --   并确认交互是「点已选中的才弹选择器」。
            --
            --   ⇒ 两级语义：
            --     · 点**未选中**的标签 → 只切粒度（不打断，不弹窗）
            --     · 点**已选中**的标签 → 弹该粒度的选择器
            --       （年→年份列表 / 月→月份列表 / 日→日期列表 / 周→周列表）
            --   ⚠ 「总」没有可选的格子（累计就是全部），点了什么都不做 ——
            --     但**不能**什么都不返回：那会让点击穿透到底下的「点空白关闭」。
            --
            --   ⚠ 切粒度时**不再**把 anchor 重置成 os.time()。
            --     老写法 `anchor = os.time()` 有个坑：用户翻到「2021年10月」，
            --     想切到「月」看一眼，结果被一脚踹回今天 —— 而选择器本身
            --     就是用来导航到指定年月的，重置只会让人重新翻一遍。
            --     保持 anchor 也和第 2 行的月/日箭头语义一致（那边也保留 anchor）。
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
        radius = Size.radius.button,
        items = items,
    }
end

--- 周期导航条（★★★ 37f 布局：双行 + **六个箭头**，37i 恢复此形状）
---
--- 用户原话（37f）：「年和月的切换放到两端（远的两端），日的放到月日的附近两端，
---   一共六个箭头」。
--- 用户原话（37i，再次确认）：
---   ```
---   ‹                 2026年                 ›
---   ‹        ‹      10月03日       ›        ›
---   ```
---   ⇒ 明确布局：
---     · 第一行「2026年」左右**最远端**各一个箭头 → 按**年**翻   （2 个）
---     · 第二行「10月03日」左右**最远端**各一个箭头 → 按**月**翻   （2 个）
---     · 第二行「月日」**紧贴两侧**各一个箭头     → 按**日**翻   （2 个）
---   合计 6 个箭头，左右各三个，呈「由外到内」的对称梯形。
---
--- 布局（★ 关键：两行，不是三行）：
---   ‹            2026年             ›       ← 年箭头（远两端）
---   ‹      ‹  10月03日  ›      ›          ← 月箭头（远两端）+ 日箭头（贴月日）
---        ↑                    ↑
---       月箭头(外)            月箭头(外)
---             ↑          ↑
---            日箭头(内)  日箭头(内)
---
---   · 年箭头 → reload{period="year",  anchor=shiftAnchor("year",  ±1)}
---   · 月箭头 → reload{period="month", anchor=shiftAnchor("month", ±1)}
---   · 日箭头 → reload{period="day",   anchor=shiftAnchor("day",   ±1)}
---   · 点标题文字（月日）→ cycleToGranularity（今→...→保留 37c 手感）
---   ⇒ 找「去年12月1日」：年箭头退到 2025 → 月箭头退到 12 月
---     → 日箭头退到 1 日。
---
---   ★ 每个箭头的粒度**写死固定**（外圈=年/月，内圈=日），位置不变 ⇒ 不用猜。
---   ★ 箭头样式**固定**（用户「箭头样式不是自己选择的，你做好固定的就可以」）：
---     裸箭头（无底色、无边框、18px 尖角 chevron）+ 透明 TapBox 热区。
---   ★ 「总」粒度：所有箭头置灰（没有可翻的格子）。
function StatisticsPage:buildPeriodNav(width, range_label)
    local f = faces()
    local line_h = Screen:scaleBySize(30)
    -- ★★★ 37f/37i：**两行**（年 / 月日）—— nav_h 相应改成 2 行高。
    --   ⚠ 改这里必须同步改 buildUnitsPage 的 PERIODNAV_H 预算，见那里的注释。
    local nav_h = line_h * 2 + Size.padding.tiny

    -- 年月日两段文字
    local year_label, month_day_label = GlobalStats.navLabels(self.period, self.anchor)
    if not year_label then year_label = range_label or "" end
    if self.period == "total" then
        year_label, month_day_label = _("累计"), nil
    end

    -- ★★★ 41-nav-compact：第二行**只说「比第一行更细」的那部分**。
    --
    --   用户原话：「日期和时间也是」—— 跟 X 轴刻度（compactTickLabels）
    --   同一套「只写变化的部分」。导航这里的问题不是重复年份，而是
    --   **第二行说了比当前粒度更细的东西**：
    --     · 第一行「2026年」，第二行「10月04日」——
    --       那个「04日」是**锚点那一天**（global_stats.navLabels 有意如此，
    --       为了让「内=日 / 外=月」两个热区在所有粒度下语义一致）。
    --       可切到「年」粒度时，导航明明在说「2026 这一年」，
    --       第二行却还在报「10月04日」，看着像被切到了某一天。
    --   所以按粒度把「比粒度更细的部分」去掉：
    --     · 年    → 「全年」 （年粒度下月、日都不该出现）
    --     · 月    → 「10月」 （月粒度下「日」是噪声）
    --     · 周/日 → 保持「10月04日」（日就是它的粒度；周需要一个起点）
    --
    --   ⚠ 只改**文字**，控件结构与热区一律不动：第二行里「内=日 / 外=月」
    --     两个下钻热区的位置、大小、点击语义全部原样保留 ——
    --     改的是显示，不是交互。所以这里不碰 navLabels 本身
    --     （那个函数同时被别处用来做「今天是几号」的判断，改它会连坐）。
    if self.period == "year" then
        month_day_label = _("全年")
    elseif self.period == "month" then
        local mm = tonumber(os.date("%m", self.anchor))
        if mm then month_day_label = string.format("%d月", mm) end
    end

    -- ★★★ 37f/37i：用户要的方案（两行 + 六箭头，由外到内对称）。
    --   ★ 箭头样式**固定成裸箭头**（无底色、无边框、细尖角 chevron）——
    --     用户明确说「箭头样式不是自己选择的，你做好固定的就可以」，
    --     所以**删除** ARROW_STYLES / buildArrowStyleRow / self.arrow_style。
    local arrow_icon = Screen:scaleBySize(18)     -- 适当放大（原来 13px 太小）
    local arrow_w = Screen:scaleBySize(30)        -- 触摸热区（透明，不画任何东西）
    local disabled = (self.period == "total")

    -- 固定粒度的翻格箭头：每个箭头翻什么粒度**写死**，位置固定 ⇒ 行为可预期。
    --   ★ 裸箭头：只有 glyph + 透明热区。
    local function stepArrow(icon_name, fixed_period, delta)
        -- ★★ 关键坑：`icon()` 出来的 IconWidget **没有 color 字段**，
        --   置灰只能 `dim = true`（沿用 37c 结论）。
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
    --
    -- ★★★ 37t：年文字改成**胶囊按钮**（对齐补丁 2-reading-insights-popup02.lua
    --   的 `buildYearHeader`）：文字左右各留 `Size.padding.large`，外面套
    --   1px 灰边框 + 7px 圆角 —— 用户一眼就知道「这里能点」。
    --   ⚠ 边框色字段是 **`color`**，不是 `bordercolor`
    --     （upstream framecontainer.lua:29 声明 `color`、:139 `paintBorder(..., self.color, ...)`）。
    --     写成 `bordercolor` 会被**静默忽略**、落回默认黑框 —— 本文件另有 5 处
    --     写的是 `bordercolor`（43 轮复查时 grep 得到：2223 / 2361 / 2712 /
    --     3051 / 3489），因为恰好都想要黑色、与默认值一致才一直没暴露。
    --     （43 轮**故意没动**这 5 处：改名 `color` 与默认值等价、零行为差异，
    --     但会扩大无关 diff，不值当。知道是雷即可。）
    --     这里必须写对，否则「灰边框」会变成黑框。
    local year_center_widget
    if disabled then
        -- 「累计」没有年份可选：只把文字居中，**不画胶囊**。
        --   画了会让人以为能点，点了却什么都不发生。
        year_center_widget = FixedBox:new{
            width = math.max(1, width - 2 * arrow_w), height = line_h,
            align = "center", vertical_align = "center",
            text(year_label or "", f.period, { bold = true }),
        }
    else
        local year_pill = FrameContainer:new{
            bordersize = Screen:scaleBySize(1),
            color = Blitbuffer.COLOR_GRAY_E,
            radius = Screen:scaleBySize(7),
            margin = 0,
            padding = 0,
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = Size.padding.large },
                text(year_label or "", f.period, { bold = true }),
                HorizontalSpan:new{ width = Size.padding.large },
            },
        }
        -- ★★★ 37r：点胶囊 = **直接选年份**（弹年份列表），不是 37b 的「下钻到月」。
        --   用户原话：「选择年份使用左右箭头切换可以，点击年份直接选择年份也可以」。
        --   左右两侧的年箭头（翻 ±1 年）完全保留，这里只是**多给一条路**。
        --   ⚠ 触摸热区仍是整条中间带（外层 `FixedBox` 撑满 `width - 2*arrow_w`），
        --     比胶囊本身大得多 —— 手指没那么准，这样更好按，视觉上也更稳。
        year_center_widget = TapBox:new{
            FixedBox:new{
                width = math.max(1, width - 2 * arrow_w), height = line_h,
                align = "center", vertical_align = "center", year_pill,
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
    --   total 时无年月日，不显示这一行。
    --
    --   ★★★ 37i2：用户「日箭头现在还是没有挨着月日」—— 根因是旧写法把中间文字框
    --   撑成 `width - 4*arrow_w`（几乎占满整行）并居中，于是紧贴文字两侧的**日箭头
    --   被推到离文字很远的地方**，看着根本没挨着。
    --
    --   改法：让**中间簇（日‹ 月日 日›）自己按内容宽紧凑居中**，两端用**弹性留白**
    --   （HorizontalSpan）把月箭头顶到最外侧。这样：
    --     · 日箭头**紧贴**月日文字（两者之间只留 `Size.padding.tiny` 的缝）；
    --     · 月箭头固定在左右最外端；
    --     · 中间簇始终居中，与第 1 行「年」对齐。
    if not disabled and month_day_label then
        local md_text = text(month_day_label, f.footer, { bold = true })
        local md_pill = FrameContainer:new{
            bordersize = Screen:scaleBySize(1),
            color = Blitbuffer.COLOR_GRAY_E,
            radius = Screen:scaleBySize(7),
            margin = 0,
            padding = 0,
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = Size.padding.small },
                md_text,
                HorizontalSpan:new{ width = Size.padding.small },
            },
        }
        -- 中间簇：日‹ + [tiny] + 月日 + [tiny] + 日›
        --   点文字下钻到「日」（保留 37c 手感）。
        local md_text_widget = md_pill
        if not disabled then
            -- ★★★ 43-pickers：点第 2 行文字 = 弹**当前粒度**的选择器。
            --
            --   37b 时这里是 `cycleToGranularity("day")`（「点月日下钻到日」）。
            --   用户这轮要的是「点一下就选格子」，所以换成选择器，并且
            --   **按当前粒度决定弹哪个**，语义才一致：
            --     年（第二行显示「全年」）→ 年份列表
            --     月（第二行显示「10月」）  → 月份列表
            --     周/日（显示「10月12日」） → 周列表 / 月份列表
            --   ⇒ 一句话：「点这行文字，就是选这一行代表的那个格子」。
            --
            --   ⚠ 第 2 行左右两个**日**箭头、最外端两个**月**箭头的行为
            --     一个字都没动（它们仍是精确翻格）；这里只是把「中间那块文字」
            --     从「切粒度」改成「弹选择器」。
            md_text_widget = TapBox:new{ md_pill, on_tap = function()
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
        --   ⚠ 弹性留白用 HorizontalSpan{width=1} 不够 —— 需要"填满剩余"。
        --   用 FixedBox 包住中间簇、宽度=剩余，并让中间簇在 FixedBox 内居中，
        --   从而把两侧月箭头挤到最外端。
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

--- 标题点击：在同一天（anchor）上循环切换粒度
--- 年 → 月 → 日 → 周 → 总 → 年 …
---
--- ★ 关键：**anchor 不变**。所以「2026年」点一下 →「2026年10月」→
---   再点 →「2026年10月03日」→ 再点 → 该日所在周 → 再点 → 累计 → 回到年。
---   这样「从某一年精准下钻到某一天」只需点几下标题，不用翻很多次。
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

--- ★★★ 37b：直接切到**指定粒度**（不循环）。
---
--- 用户对双行标题的定义：
---   · 第一行（年）    → 点它切到 **year**
---   · 第二行**外侧**（左/右 1/3）→ 点它切到 **month**
---   · 第二行**内侧**（中 1/3）   → 点它切到 **day**
--- 与 cyclePeriodGranularity 一样，**anchor 保持不变** —— 所以「切粒度」不丢日子。
---
--- ★ 幂等短路：`target == self.period`（已是这个粒度）时**不重建**。
---   在 KPW4 上重建统计页 = 一次全浮窗 e-ink 重绘，白白闪一下；用户点了
---   「已经是年」的地方，本来就不该有任何变化。
function StatisticsPage:cycleToGranularity(target)
    if not target then return end
    if target == self.period then
        -- 已经是这个粒度：什么都不做（不重建、不闪屏）
        return
    end
    self:reload{ period = target, anchor = self.anchor }
end

--- 卡片网格。
---
--- ★★★ 32：一行多张（用户：「一行不止两个，可以多放」）。
--- ★★★ 33：最小卡宽 150→118、最大列数 3→4。
--- ★★★ 34：用户明确「总览页面的卡片**每行三个卡片**」——
---   所以默认固定 3 列；只有当宽度实在塞不下 3 列（极窄窗/横屏小窗）
---   才退到 2 或 1 列。列数不再「越大越好」。
---   并支持多套卡片样式（见 CARD_STYLES / wrapCard）。
local CARD_MIN_W = Screen:scaleBySize(118)
local CARD_DEFAULT_COLS = 3     -- 用户要求的每行卡片数
local CARD_MAX_COLS = 4         -- 硬上限（宽屏也别超过，否则字太小）

--- 决定列数：优先 3 列；宽度不够才退。纯函数，便于行为测试。
local function decideCardCols(width, gap, min_w, want_cols, max_cols)
    min_w = min_w or CARD_MIN_W
    want_cols = want_cols or CARD_DEFAULT_COLS
    max_cols = max_cols or CARD_MAX_COLS
    local fit = math.floor((width + gap) / (min_w + gap))
    local cols = math.min(want_cols, fit)
    cols = math.max(1, math.min(max_cols, cols))
    return cols
end

--- ★★★ 34：卡片样式切换行。
--
-- 用户要求「多设计几种样式可以切换」。切换入口放在**总览视图的卡片网格上方**，
-- 一行小按钮：方框 / 连线 / 点线 / 标签。选中的那个黑底反白（和上面排序行、
-- 标签行同一套视觉语言，不引入新颜色）。
--
-- 切换时走 reload{ card_style = ... } —— 整页重建，与其它切换一致。
-- （重建比原地换皮肤简单可靠；本页重建开销已在耗电分析里确认可以忽略。）
function StatisticsPage:buildCardStyleRow(width)
    local f = faces()
    local row = HorizontalGroup:new{ align = "center" }

    -- 左侧小标题「卡片样式」，右侧四个样式按钮
    local label_w = Screen:scaleBySize(76)
    row[#row + 1] = FixedBox:new{
        width = label_w, height = Screen:scaleBySize(27),
        align = "left", vertical_align = "center",
        text(_("卡片样式"), f.footer, { color = Blitbuffer.COLOR_DARK_GRAY }),
    }
    row[#row + 1] = HorizontalSpan:new{ width = Size.padding.small }

    local n = #CARD_STYLES
    local btn_w = math.floor((width - label_w - Size.padding.small * (n - 1)) / n)
    if btn_w < Screen:scaleBySize(40) then
        btn_w = math.max(Screen:scaleBySize(28), math.floor(width / n))
    end
    local btn_h = Screen:scaleBySize(27)
    local current = cardStyleValid(self.card_style) and self.card_style or "box"

    for i, style in ipairs(CARD_STYLES) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = Size.padding.small } end
        local active = (style.value == current)
        local target = style.value
        row[#row + 1] = FrameContainer:new{
            width = btn_w, height = btn_h,
            bordersize = Screen:scaleBySize(1), color = Blitbuffer.COLOR_GRAY_E,
            radius = Size.radius.button,
            background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            padding = 0,
            TapBox:new{
                FixedBox:new{ width = btn_w, height = btn_h,
                    align = "center", vertical_align = "center",
                    text(style.label, Font:getFace("cfont", 14), {
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

    -- ★ 26-card-order：「阅读字数」与「阅读速度」放在**所有同级卡片的最前面**。
    --   它们是卡片网格里的同级项，所以「最前」就体现在这个数组的头部 ——
    --   不是另起一块高亮区、也不是插到标题/标签栏之上。
    --   其余卡片保持原有相对顺序不变。
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
        -- ★★★ 36：删掉「在读书籍」卡片（用户要求「卡片在读书籍删掉吧」）。
        {
            id = "notes", icon = "edit", label = _("记录笔记"),
            parts = formatCountParts(summary.notes, _("条")),
            kind = "notes", delta = diff(summary.notes, previous and previous.notes),
        },
    }

    -- 先量出最高的卡片，再统一套用，保证每行严格等高
    local contents = {}
    local card_h = 0
    for i, spec in ipairs(specs) do
        if spec.delta and spec.delta ~= 0 then
            spec.delta_text = deltaArrow(spec.delta) .. deltaText(spec.kind, math.abs(spec.delta))
        end
        contents[i] = buildCardContent(spec, inner_w)
        card_h = math.max(card_h, contents[i]:getSize().h)
    end
    card_h = card_h + 2 * Size.padding.small

    local grid = VerticalGroup:new{ align = "left" }

    -- ★★★ 34「连线」样式：相邻卡片之间靠一条竖线（VRule）连接，
    --   行与行之间一条横线（HRule）。卡片自身不带框（wrapCard 已处理），
    --   这里在每张卡**右侧**插一条竖线即可 —— 下一个格子的卡紧贴它，
    --   视觉上就是「两个卡片中间只用一条线连接」。
    --   最后一行再补一条底横线收口。
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

--- 下钻数据
--- 注意：循环变量不能叫 `_`，否则后面 T(_(...)) 会拿到下标数字。
function StatisticsPage:drillRows(kind)
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local rows = {}
    if kind == "days" then
        for _i, item in ipairs(GlobalStats.details(store, self.period, self.anchor, "days")) do
            rows[#rows + 1] = { item.date, formatDuration(item.seconds) }
        end
    else
        for _i, item in ipairs(GlobalStats.details(store, self.period, self.anchor, kind)) do
            -- ★★★ 36：用户要求卡片「只显示数字」，去掉「已读 / 全书」这类文字标签。
            --   所以右侧直接给「已读 / 全书」（有全书口径时）或「已读」，
            --   不再带「已读」「全书」两个词，纯数字（含千分位）。
            --   例：1,234 / 5,678  或  1,234
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

--- 「阅读字数」视图（★★★ 35 重做）
--
-- 用户要求：「阅读字数排序按左右键进行切换下一页，不使用上下滑动，
--   中间通过虚线或者点线分隔」。
--
-- 关键事实：KPW4 是**纯触摸设备、没有实体左右键**（device.lua:1076），
--   所以「左右键」在这里落成**屏幕底部的 ‹ 上一页 / 下一页 › 按钮**；
--   同时保留物理键 GotoNextView/GotoPrevView 的兼容（见 init）。
--
-- 布局：
--   [排序行：字数 / 最近阅读 / 书名]      ← 点它换排序，回到第 1 页
--   [第 N/M 页 + 本页合计]                ← 一眼知道翻到哪了
--   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
--   书名1                   已读 12,345
--   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─   ← 行间点线（HRule dotted）
--   书名2                   已读 9,876
--   ...
--   [ ‹ 上一页      3/7      下一页 › ]
--
-- 全程**不用 ScrollableContainer**，所以不存在「上下滑动」。
--
-- ★★★ 36：整块浮窗已改成**禁止滑动**的 FixedPane，所以本页**必须**保证
--   内容放得下 —— 每页行数不再写死 10，而是按可用高度自适应
--   （`self._available_h` 减去「标题 + 视图标签 + 周期标签 + 周期导航 +
--     排序行 + 页码状态行 + 翻页栏 + 各段间隔」这些固定占高，再除以行高）。
--   这样无论竖屏/横屏、字体大小，一页都恰好塞满、不用滑也滑不动。
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
    --
    -- ★★★ 37d 修「翻页栏被内容顶到屏幕外 / 和列表叠在一起」：
    --   以前 chrome_h 是 `Screen:scaleBySize(300)` 这个**拍脑袋的估算**，
    --   而真实 chrome（标题栏 + 视图标签 + 粒度标签 + 周期导航 + 排序行 +
    --   状态行 + 翻页栏 + 各处 vertical span）在 KPW4 上合计约 550px，
    --   300 远远低估 ⇒ rows_per_page 算多了 ⇒ 列表把翻页栏顶出可用高度。
    --
    --   现在改成**按实际控件常量逐项累加**（每一项都和构建它的那行代码
    --   用同一个常量，改了那边这里会跟着变），多留 SCROLL_SAFETY 底边。
    --   这样「列表 + 翻页栏」一定落在 available_h 之内，翻页栏永远可见。
    local row_h = Screen:scaleBySize(40)
    local line_w = Screen:scaleBySize(1)
    local v_def = Size.span.vertical_default     -- = scaleBySize(2)
    local v_large = Size.span.vertical_large     -- = scaleBySize(5)
    local SCROLL_SAFETY = Screen:scaleBySize(8)  -- 底部安全边（防浮窗边框吃掉最后一行）

    -- ── 列表**上方**的固定占高 ──────────────────────────────────────────
    -- 逐项对应 build() 里的 body 与 buildUnitsPage 开头：
    --   浮窗边框(2×border) + title_bar + span.v_def + viewTabs(38)
    --   + span.v_def + tabs + span.v_def + periodNav(line_h+btn_h+pad.tiny)
    --   + span.v_large + sortRow(36) + span.v_def + status(30) + pad.small
    local TITLEBAR_H = Screen:scaleBySize(34)    -- TitleBar 标题文字行高（含下划线内边距的保守值）
    --   ★★★ 44-compact：视图排 / 周期排都改引用统一的 `ROW_TAB_H_PX`。
    --     以前这里是 `scaleBySize(38)` / `scaleBySize(36)` 两处硬编码，
    --     和 buildViewTabs / buildTabs 里的值必须手动保持一致 ——
    --     改一处忘另一处，预算就算错、内容被顶出去（老病根）。
    local VIEWTAB_H  = Screen:scaleBySize(ROW_TAB_H_PX)
    local TABS_H     = Screen:scaleBySize(ROW_TAB_H_PX)
    --   ★ 37i：buildPeriodNav 现在是「**两**行 × line_h(30)」= scaleBySize(60)，
    --     这里必须跟着改，否则预算又对不上（这正是翻页栏被顶掉的老病根）。
    local PERIODNAV_H = Screen:scaleBySize(30)   -- ← 与 buildPeriodNav 的 line_h 一致
                      * 2                        -- ← 37f/37i 两行（年一行 + 月日一行）
                      + Size.padding.tiny
    local SORTROW_H  = Screen:scaleBySize(36)
    local STATUS_H   = Screen:scaleBySize(30)
    local POPUP_BORDER_H = 2 * Screen:scaleBySize(2)
    local chrome_top = POPUP_BORDER_H + TITLEBAR_H
        + v_def + VIEWTAB_H + v_def + TABS_H + v_def + PERIODNAV_H
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

    --------------------------------------------------------------------------
    -- 排序行：字数 / 最近阅读 / 书名（沿用 32 的黑底反白选中样式）
    --------------------------------------------------------------------------
    local sorts = {
        { value = "units", label = _("字数") },
        { value = "date", label = _("最近阅读") },
        { value = "title", label = _("书名") },
    }
    local sort_items = {}
    for i, item in ipairs(sorts) do
        local target = item.value
        sort_items[i] = {
            label = item.label,
            face = Font:getFace("cfont", 17),
            active = sort == target,
            on_tap = function()
                -- 换排序时回到第 1 页（排序变了，页码不再有意义）。
                if target ~= self.unit_sort then
                    self:reload{ unit_sort = target, view = "units", unit_page = 1 }
                end
                return true
            end,
        }
    end
    group[#group + 1] = buildSegmentedRow{
        width = width,
        height = Screen:scaleBySize(36),
        radius = Size.radius.button,
        items = sort_items,
    }
    group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }

    --------------------------------------------------------------------------
    -- 分页计算：把 details 切成每页 rows_per_page（行数自适应，见上）
    --------------------------------------------------------------------------
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

    --------------------------------------------------------------------------
    -- 页码状态行：左「第 X / Y 页」右「本页合计」（空列表时不显示）
    --------------------------------------------------------------------------
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
                    faces().footer, { color = Blitbuffer.COLOR_DARK_GRAY, bold = true }),
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

    --------------------------------------------------------------------------
    -- 行列表：书名 + 已读字数，**行间点线分隔**（不是外框、不是灰底）
    --------------------------------------------------------------------------
    -- ★★★ 36：用户要求「只显示数字」。右侧去掉「已读」二字，纯数字。
    -- （row_h / line_w 已在函数开头按可用高度算好，这里不再重复定义）
    if total_rows == 0 then
        group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
        local empty_h = row_h * 2
        local empty_padding = Size.padding.default
        local empty_inner_w = math.max(1, width - 2 * empty_padding)
        local empty_inner_h = math.max(1, empty_h - 2 * empty_padding)
        group[#group + 1] = FrameContainer:new{
            width = width, height = empty_h,
            bordersize = Screen:scaleBySize(1),
            color = Blitbuffer.COLOR_GRAY_E,
            radius = Size.radius.window,
            background = Blitbuffer.COLOR_WHITE,
            padding = empty_padding,
            margin = 0,
            FixedBox:new{
                width = empty_inner_w,
                height = empty_inner_h,
                align = "center", vertical_align = "center",
                text(_("当前周期没有阅读字数记录"), faces().footer, {
                    color = Blitbuffer.COLOR_DARK_GRAY,
                    max_width = empty_inner_w,
                }),
            },
        }
        return group
    end

    local right_w = math.floor(width * 0.36)
    local left_w = width - right_w - Size.padding.small
    -- ⚠ 绝不能写 `for _, item`：本文件顶部有 `local _ = require("gettext")`，
    --   Lua 里 `_` 是普通变量名，`for _, item` 会把它覆盖成数字下标，
    --   循环体里任何 _("...") 都会报 attempt to call local '_' (a number value)。
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
                    text(value, faces().footer, { color = Blitbuffer.COLOR_BLACK, bold = true,
                        max_width = right_w }) },
            },
        }
        -- 行间点线（本页最后一行不画，交给翻页栏上方的收口线）
        if _i < last_idx then
            group[#group + 1] = HRule:new{ width = width, height = line_w,
                color = Blitbuffer.COLOR_GRAY_E, dotted = true }
        end
    end

    --------------------------------------------------------------------------
    -- 翻页栏：‹ | 第 X / Y 页 | ›（纯图标按钮 —— 用户 36 要求「只显示图标」）
    --------------------------------------------------------------------------
    -- ★★★ 36：用户原话「上一页下一页按钮只显示图标啊，上一页图标 第1/10页
    --   下一页图标，类似于这种的」。所以按钮里**只放 ‹ / › 箭头**，
    --   不再有「上一页」「下一页」文字；中间保留「第 X / Y 页」页码。
    --
    -- ★★★ 37：用户追加「上一页图标 第1/10页 下一页图标，这个要离得近一点，
    --   不要站在两端」。以前用 `FixedBox{width = width - 2*arrow_w}` 当弹簧把
    --   两个箭头**顶到左右两端**，中间留出一大片空白。现在改成：
    --   箭头和页码先组成一个**包紧的内层组**（auto 宽度），再把这一整簇居中——
    --   两个箭头自然贴着页码，不会各站一边。
    --
    -- ★★★ 37b：用户再追加「不需要边框，直接把箭头放上去就够了」。
    --   ⚠ 边框不是我们画的 —— 是上游 `IconButton` 自带 `FrameContainer`
    --   （bordersize=Size.border.button、白底 + 圆角），所以**用 IconButton
    --   就必然有框**。改法：不再用 IconButton，改用「极简图标 + TapBox」——
    --   只有箭头本身可点，不画任何边框/底色。
    --
    -- ★★★ 37g：用户「把下面那一坨改成跟阅读洞察一样的」。（历史：当时试过
    --   浅灰圆角药丸，37h 又按用户要求退回**纯裸箭头**，见下。）
    group[#group + 1] = HRule:new{ width = width, height = line_w,
        color = Blitbuffer.COLOR_BLACK }
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.small }

    -- ★★★ 37h：用户「箭头都不需要底色和边框，可以适当的大一点」。
    --   ⇒ 退掉 37g 的灰药丸，回到 37b 的「纯箭头裸放」思路。

    -- ★★★ 37h/37i：翻页栏与 buildPeriodNav 一样，用**裸箭头**
    --   （无底色、无边框，细尖角 chevron）。
    --   ⚠ 不用 IconButton（自带白底 + 边框，去不掉）。
    local nav_h = Screen:scaleBySize(44)
    -- 热区：透明，只负责命中面积（不画任何东西）。
    local arrow_w = Screen:scaleBySize(30)
    -- 箭头与页码之间的**固定留白**（让它们「近一点」但不相撞）
    local gap = Size.padding.small
    -- ── 翻页按钮：裸 chevron（无底色、无边框）+ TapBox 热区 ──
    -- ⚠ IconWidget **没有 color 字段**（见 icon() 的注释）——
    --   想置灰只能走 `dim = true`，不能传 color。
    -- ★★★ 37i：箭头样式**固定**（用户「箭头样式不是自己选择的，你做好固定的就可以」）
    --   —— 细尖角 chevron，无底色、无边框，与 buildPeriodNav 完全一致。
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

--- 「阅读字数趋势」卡片
function StatisticsPage:buildTrendSection(width, buckets, selected, metric_override)
    local f = faces()
    local pad = Size.padding.large
    local inner_w = width - 2 * pad
    local metric = metric_override or self.metric
    local metric_label = metric == "speed" and _("阅读速度") or self:metricLabel()
    local row_h = Screen:scaleBySize(34)
    local chart_h = row_h * TREND_ROWS
    local is_chart = self.trend_view ~= "list"

    -- ★★★ 40-unit-free：上限和「这张图用哪个单位」都**提前**算 ——
    --   因为下面的**标题**要拿单位（「阅读时长趋势（分）」）。
    --   原来 scale_max 是在 `if is_chart` 里算的，标题那时还没建，拿不到。
    local maximum = 0
    for _i, bucket in ipairs(buckets) do
        maximum = math.max(maximum, tonumber(bucket.value) or 0)
    end
    local scale_max = niceMax(maximum)
    local unit = chartUnit(metric, scale_max)

    -- 标题 + 单位。只在**图表视图**里把单位拼进标题：
    --   · 图表视图的柱顶标签是**不带单位**的裸数字（chartBarLabel），
    --     单位总得有个地方说一次 —— 标题最省地方、而且永远看得见；
    --   · 列表视图每行都写着「14分钟」，标题上再重复一遍纯属啰嗦；
    --   · 指标名里已经含这个单位时不重复（「阅读字数」里已经有「字」）。
    local title_text = metric_label .. _("趋势")
    if is_chart and not string.find(title_text, unit.suffix, 1, true) then
        title_text = title_text .. "（" .. unit.suffix .. "）"
    end

    -- 标题行 + 图表/列表切换
    local toggle_width = Screen:scaleBySize(58)
    local header = HorizontalGroup:new{ align = "center" }
    header[#header + 1] = text(title_text, f.section, {
        bold = true,
        max_width = inner_w - toggle_width - Size.padding.large,
    })
    local spacer_w = math.max(0, inner_w - toggle_width
        - Size.padding.large - header[1]:getSize().w)
    header[#header + 1] = HorizontalSpan:new{ width = spacer_w }
    header[#header + 1] = buildSegmentedRow{
        width = toggle_width,
        height = Screen:scaleBySize(28),
        radius = Size.radius.button,
        items = {
            {
                icon = "column.three",
                active = self.trend_view ~= "list",
                on_tap = function()
                    if self.trend_view == "list" then
                        self:reload{ trend_view = "chart" }
                    end
                    return true
                end,
            },
            {
                icon = "align.justify",
                active = self.trend_view == "list",
                on_tap = function()
                    if self.trend_view ~= "list" then
                        self:reload{ trend_view = "list" }
                    end
                    return true
                end,
            },
        },
    }

    local section = VerticalGroup:new{ align = "left" }
    section[#section + 1] = header
    section[#section + 1] = VerticalSpan:new{ width = Size.span.vertical_large }

    -- ★★★ 41-plain-chart：这里原来有个 `local mean = nil`（本周期均值），
    --   因为「图表画虚线」和「图例写『虚线＝本期平均 X』」两处都要用它。
    --   均值虚线删掉之后它没有任何读者了，一并删除。

    if is_chart then
        -- ★★★ 40-no-y-axis：**没有 Y 轴刻度列了**。
        --
        --   原来这里是：
        --       axis_w  = floor(inner_w * 0.22)          -- KPW4 上 201px
        --       chart_w = inner_w - axis_w - padding     -- 704px
        --       axis    = buildAxisColumn(labels, axis_w, row_h, ...)
        --       HorizontalGroup{ align="center", axis, span, chart }
        --   用户要求「统计图可以只要底部，不要 y 轴」，整列刻度连同它的
        --   201px + 9px 间距一起删掉，绘图区直接吃满 inner_w（914px）。
        --   ⇒ 柱子变粗（月视图 slot 22.7 → 29.5px）、整张图**往左移**
        --     （用户要的「适当往左一点」）—— 一个改动同时满足两条要求。
        --   ⇒ 代价是没了刻度参照，但每根柱子自己带数值标签（见 chartUnit）。
        local chart_w = inner_w

        -- ★★★ 40-no-y-axis（连带修的坑）：**必须显式给柱顶标签留出上方空间**。
        --
        --   柱顶标签的 y **可以是负数**（见 chartValueLabels 的注释）：
        --   最高的那根柱子顶到图顶时，它的数字会画到**图上方**去。
        --   39 那版这块空间是**白捡**的 —— Y 轴刻度列高 377px、图只有 252px，
        --   图在 `HorizontalGroup{align="center"}` 里居中，上下各空出 62px，
        --   标签正好落进上面那 62px。
        --   40 把 Y 轴列删了 ⇒ 这 62px 一起没了 ⇒ 不留白的话，
        --   最高的那根柱子的数字会**直接压到标题上**。
        --   所以这里显式补一个 span，高度 = 标签高 + 标签与柱顶的间距 + 余量。
        --   ⚠ 别图省事写死像素：字号一改就不够了（labelMetrics 量的就是真字号）。
        local label_h = labelMetrics("0", f.value).h
        section[#section + 1] = VerticalSpan:new{
            width = label_h + Screen:scaleBySize(3) + Screen:scaleBySize(2),
        }

        -- ★★★ 37s：图 = 柱状位图 + **每根柱子顶上的数值标签**（用户要求）。
        --
        --   ⚠ 这里**故意不给图加高**：图仍是 4*row_h，标签落进图上方
        --     那一行本来就空着的区域，整个页面布局**一行没动**
        --     （x 轴刻度行、周期导航、翻页栏的位置都不会被顶走）。
        --     详见 chartValueLabels 的注释。
        --
        -- ★★★ 40-unit-free：传的是 `unit`（chartUnit 的产物）而不是 `metric` ——
        --   柱顶标签只写数字，单位由 chartUnit 统一决定、并写进标题。
        -- ★★★ 41-plain-chart：不再传 `mean`（均值虚线已删，见 buildChartImage）。
        local chart = buildChartWidget(buckets, unit, selected, chart_w, chart_h, scale_max)
        section[#section + 1] = chart

        local tick_h = Screen:scaleBySize(24)
        -- ★★★ 39-trend-axis：刻度走**真实 bucket.label**（详见 buildTickRow 的注释）。
        -- ★★★ 40-no-y-axis：不再需要给 Y 轴列让位，刻度行直接铺满。
        local tick_row = buildTickRow(buckets, chart_w, tick_h, Blitbuffer.COLOR_BLACK)
        section[#section + 1] = tick_row
    else
        section[#section + 1] = buildTrendList(buckets, metric, selected, inner_w)
    end

    section[#section + 1] = VerticalSpan:new{ width = Size.span.vertical_large }

    -- ★★★ 36：**删掉**底部的指标切换行（阅读时间/阅读字数/阅读速度/日均阅读时长）。
    --   用户原话：「点击阅读趋势的时候，下方的阅读时间阅读字数阅读速度阅读时长
    --   没必要放在那啊」。所以趋势页只显示**当前指标**的图，不再在下方堆一行切换按钮。
    --   （指标仍可在**总览页**通过点击对应卡片进入的趋势查看；当前指标由
    --    self.metric 决定，reload 时透传。）
    --   保留位置：指标名已经在标题行（`metric_label .. 趋势`）里体现了。

    section[#section + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
    section[#section + 1] = HorizontalGroup:new{
        align = "center",
        text(self:footerText(buckets, selected, metric), f.footer, {
            color = Blitbuffer.COLOR_DARK_GRAY,
            max_width = inner_w,
        }),
    }

    -- ★★★ 39-trend-mean：图表视图下补一行**图例**。
    --   用户说「趋势图看不懂」，第三个原因就是：那条虚线是什么、
    --   柱子到底能不能点，界面上一个字都没说。一句话讲清楚，成本只有一行。
    --   （列表视图没有虚线，也就不需要这行。）
    --   ★ 用最小的 `f.axis`（17px）但仍是**黑色** —— 用户明确要求
    --     「尽量不要有灰色字」，靠字号而不是灰度来降级。
    --
    -- ★★★ 41-plain-chart：图例**只剩前半句**了。
    --   原来是 `点柱子看具体数值 · 虚线＝本期平均 X`，两个分句各解释一个东西；
    --   虚线删了 ⇒ 后半句成了一句**指向不存在的东西**的说明，必须一起去掉。
    --   留下「点柱子看具体数值」这半句仍然必要：柱子能点这件事，界面上
    --   没有别的线索（没有边框、没有按钮外观）。
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

--- 指标切换：两列，选中项打勾
--- ★★ 32：未选中白底描边、选中黑底反白；不再有灰底。
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
                    color = Blitbuffer.COLOR_GRAY_E,
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

--- 顶部左图标：快速切换统计周期
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
    UIManager:show(self.dialog)
end

--- ★★★ 37r：点「2026年」**直接选年份**（用户要求）。
--
--   用户原话：「选择年份使用左右箭头切换可以，点击年份直接选择年份也可以」。
--   ⇒ 左右箭头（一格一格翻年）保留不变，**额外**给年文字挂一个年份列表弹窗，
--     想跳到「2021 年」时不用点五次箭头。
--
--   ⚠ 行为变更：第 1 行的年文字**不再**是「下钻到月」（37b 的老行为）。
--     要切到月/日粒度，走第 2 行的月箭头/日箭头即可 —— 那本来就比
--     「点年文字猜它会变成什么」更直观。cycleToGranularity 本身保留，
--     第 2 行的月日文字仍在用它。
--
--   ★★★ 37t：弹窗改成**竖排**（对齐补丁 2-reading-insights-popup02.lua 的
--     `year_button_tap_dialog`）。用户原话：
--       「年份切换按照补丁 2-reading-insights-popup02.lua 里的点击切换方式改」。
--
--     补丁的做法是 `buttons = { {a}, {a}, ... }` —— **一条一行**，配
--     `shrink_unneeded_width = true` 让弹窗窄到刚好放下最长的那个年份。
--     我们原来是一行 3 格的网格，改成竖排后：年份多了也不会挤成小方块，
--     和补丁的手感一致。
--
--     ⚠ 年份数量可能不少（数据年份 ∪ anchor 年 ∪ 今年），但不用担心溢出：
--       ButtonDialog 在内容高于屏幕时会自己套 ScrollableContainer 并整行翻页，
--       见 upstream buttondialog.lua:186-233。所以竖排是安全的。
--
--   年份列表来自 `GlobalStats.availableYears()`：有数据的年份排前面（从新到旧）。
--
--   ★ 标签只留**纯数字**（对齐补丁的 `text = i`）：原来的「年」后缀在竖排里
--     纯属噪声，「（无）」也让每行长短不一。当前年补一个 `✓` 作选中反馈
--     （用户之前问过「有选中效果吗」）。`item.has_data` 仍然返回着，
--     将来想标「无数据」随时可以加回来。
function StatisticsPage:showYearPicker()
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local years = GlobalStats.availableYears(store, self.anchor)
    local anchor = tonumber(self.anchor) or os.time()
    local current_year = tonumber(os.date("%Y", anchor)) or 1970

    -- ★ 一条一行：`buttons` 的每一项都是「一行」，里面只放一个按钮。
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
                    -- ★ 用 shiftAnchor 平移：**保留 anchor 的月日**，
                    --   只把年份挪过去。这样「2026年10月3日 → 看 2021年」之后
                    --   再切回日视图，落点还是 10月3日，不会莫名其妙变成 1月1日。
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
        -- ★ 这两项照抄补丁：宽度收到「刚好放下最宽的那行」，
        --   并置 modal 让它盖住统计浮窗（否则点击会穿透到底下的页面）。
        shrink_unneeded_width = true,
        modal = true,
        buttons = buttons,
    }
    UIManager:show(self.dialog)
end

--==========================================================================
-- ★★★ 43-pickers：周期选择器（年 / 月 / 周）
--==========================================================================
--
-- 用户原话：「阅读统计里的日周月年以及总览选择能不能重新弄好（年的点击
--   可以选择年份，月的点击可以选择月份，日的点击可以选择月份，周的点击
--   可以选择第几周（第几周后面跟着时间））」+ 确认「点已选中的才弹选择器」。
--
-- 三个选择器都是**竖排 ButtonDialog**（与 37t 的年份列表同形）：
--   · 一条一行，`shrink_unneeded_width` 让弹窗宽度收到「刚好放下最宽那行」；
--   · `modal = true` 盖住统计浮窗，否则点击会穿透到底下的页面；
--   · 内容高于屏幕时上游 ButtonDialog 会自己套 ScrollableContainer 整行翻页
--     （upstream buttondialog.lua:186-233），所以行数多也安全。

--- 把 anchor 挪到「目标年月的同一天」，**保留日**。
---
--- ⚠ 不能直接用 `GlobalStats.shiftAnchor("month", anchor, delta)`：
---   那个函数是 `dayTimestamp(year, month + delta, 1)` —— 日被写死成 1。
---   翻月箭头那样做没问题（用户本来就在逐月翻），但**选择器**是「我要跳到
---   2021 年 7 月」：把日重置成 1 号，等于顺手把用户当前看的这天弄丢了。
---   所以这里自己算：保留原来的日，目标月天数不够时夹到该月最后一天。
local function anchorAtMonth(anchor, year, month)
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

--- 统一的入口：按粒度弹对应的选择器。
---   「总」没有可选的格子（累计就是全部）⇒ 什么都不做。
---
--- ★★★ 44-day-picker：`day` 从「弹月份列表」改成**弹日期列表**。
---   用户原话：「日的没有选择日的选择器吗」。
---   以前 43 轮把「日」也接到月份列表上（理由：一个月 28~31 天，列表太长），
---   但那样「日」这个粒度其实**选不了具体的日**，只能靠第 2 行内圈箭头一天天翻。
---   现在补上真正的日列表；翻月仍然靠第 2 行的外圈（月）箭头，没丢功能。
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

--- ★★★ 43-pickers：月份列表（点「月」/「日」标签或第 2 行文字时弹出）。
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

    -- ★★★ 44-month-label：行文字现在只有「10月」（用户要的「只显示月份」），
    --   所以**跨年时**在标题里补一句范围，免得两行「1月」看着一模一样。
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
    UIManager:show(self.dialog)
end

--- ★★★ 44-day-picker：**月历网格**（点「日」标签或第 2 行文字时弹出）。
---
--- 用户原话：「日的没有选择日的选择器吗」。
---
--- 列 anchor 所在**月**的每一天，按周一至周日排成 7 列月历，当前那天带 ✓。
--- 选中某一行 ⇒ `period` 仍是 `day`，只把 anchor 挪到那一天（年月不变）。
---
--- 顶部的 ‹ / › 翻月、« / » 翻年只改变日历显示；选中日期才更新统计锚点。
--- 首日之前的空位用于保持自然的星期对齐。
function StatisticsPage:showDayPicker(display_year, display_month)
    local anchor = tonumber(self.anchor) or os.time()
    local anchor_year = tonumber(os.date("%Y", anchor)) or 1970
    local anchor_month = tonumber(os.date("%m", anchor)) or 1
    local anchor_day = tonumber(os.date("%d", anchor)) or 1
    local year = tonumber(display_year) or anchor_year
    local month = tonumber(display_month) or anchor_month
    -- 本月天数：下个月 1 号往前一天
    local last_day = tonumber(os.date("%d", os.time{
        year = year, month = month + 1, day = 0, hour = 12, min = 0, sec = 0,
    })) or 31

    local buttons = {}
    local function closePicker()
        if self.dialog then
            UIManager:close(self.dialog)
            self.dialog = nil
        end
    end
    local function showMonthChoices(target_year)
        local month_buttons = {}
        local row = {}
        for m = 1, 12 do
            local label = string.format("%d月", m)
            if target_year == year and m == month then label = label .. " ✓" end
            local selected_month = m
            row[#row + 1] = {
                text = label,
                no_vertical_sep = true,
                callback = function()
                    closePicker()
                    self:showDayPicker(target_year, selected_month)
                end,
            }
            if #row == 3 then
                month_buttons[#month_buttons + 1] = row
                row = {}
            end
        end
        local ButtonDialog = require("ui/widget/buttondialog")
        self.dialog = ButtonDialog:new{
            title = T(_("%1年 - 选择月份"), target_year),
            shrink_unneeded_width = true,
            modal = true,
            buttons = month_buttons,
        }
        UIManager:show(self.dialog)
    end
    local function showYearChoices()
        local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
        local calendar_anchor = os.time{
            year = year, month = month, day = 1, hour = 12, min = 0, sec = 0,
        }
        local years = GlobalStats.availableYears(store, calendar_anchor)
        local year_buttons = {}
        for _i, item in ipairs(years) do
            local choice_year = item.year
            local label = tostring(choice_year)
            if choice_year == year then label = label .. " ✓" end
            year_buttons[#year_buttons + 1] = {
                {
                    text = label,
                    callback = function()
                        closePicker()
                        self:showDayPicker(choice_year, month)
                    end,
                },
            }
        end
        local ButtonDialog = require("ui/widget/buttondialog")
        self.dialog = ButtonDialog:new{
            title = _("选择年份"),
            shrink_unneeded_width = true,
            modal = true,
            width_factor = 0.96,
            buttons = year_buttons,
        }
        UIManager:show(self.dialog)
    end
    local function showAdjacentMonth(month_delta)
        local target = os.time{
            year = year, month = month + month_delta, day = 1,
            hour = 12, min = 0, sec = 0,
        }
        local target_year = tonumber(os.date("%Y", target))
        local target_month = tonumber(os.date("%m", target))
        closePicker()
        self:showDayPicker(target_year, target_month)
    end
    local function showAdjacentYear(year_delta)
        showAdjacentMonth(year_delta * 12)
    end
    local year_nav = {
        {
            text = "«",
            callback = function()
                showAdjacentYear(-1)
                return true
            end,
        },
        {
            text = string.format("%d年", year),
            callback = function()
                showYearChoices()
                return true
            end,
        },
        {
            text = "»",
            callback = function()
                showAdjacentYear(1)
                return true
            end,
        },
    }
    local month_nav = {
        {
            text = "‹",
            callback = function()
                showAdjacentMonth(-1)
                return true
            end,
        },
        {
            text = string.format("%d月", month),
            callback = function()
                showMonthChoices(year)
                return true
            end,
        },
        {
            text = "›",
            callback = function()
                showAdjacentMonth(1)
                return true
            end,
        },
    }
    buttons[#buttons + 1] = year_nav
    buttons[#buttons + 1] = month_nav

    local weekdays = { _("一"), _("二"), _("三"), _("四"), _("五"), _("六"), _("日") }
    local heading = {}
    for i, name in ipairs(weekdays) do
        heading[i] = {
            text = name,
            no_vertical_sep = true,
            callback = function() return true end,
        }
    end
    buttons[#buttons + 1] = heading

    local row = nil
    local function appendBlankCell()
        row = row or {}
        row[#row + 1] = {
            text = " ",
            enabled = false,
            no_vertical_sep = true,
            callback = function() return true end,
        }
    end
    local first_day = os.time{
        year = year, month = month, day = 1,
        hour = 12, min = 0, sec = 0,
    }
    local first_weekday = tonumber(os.date("%w", first_day)) or 0 -- Sunday = 0
    local leading_blanks = (first_weekday + 6) % 7
    for _i = 1, leading_blanks do
        appendBlankCell()
    end
    for d = 1, last_day do
        local label = tostring(d)
        local is_current = year == anchor_year and month == anchor_month and d == anchor_day
        if is_current then label = label .. " ✓" end
        -- 每个按钮各自捕获自己的「日」（别用循环变量闭包）
        local day = d
        row = row or {}
        row[#row + 1] = {
            text = label,
            no_vertical_sep = true,
            callback = function()
                if self.dialog then
                    UIManager:close(self.dialog)
                    self.dialog = nil
                end
                if is_current then return end
                self:reload{
                    period = "day",
                    anchor = os.time{
                        year = year, month = month, day = day,
                        hour = 12, min = 0, sec = 0,
                    },
                }
            end,
        }
        if #row >= 7 then
            buttons[#buttons + 1] = row
            row = nil
        end
    end
    if row then
        while #row < 7 do appendBlankCell() end
        buttons[#buttons + 1] = row
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    self.dialog = ButtonDialog:new{
        title = _("选择日期"),
        shrink_unneeded_width = true,
        modal = true,
        width_factor = 0.96,
        buttons = buttons,
    }
    UIManager:show(self.dialog)
end

--- ★★★ 43-pickers：周列表（点「周」标签或第 2 行文字时弹出）。
---
--- 每行 = 「第N周  MM.DD–MM.DD」（用户明确要求「第几周后面跟着时间」，
---   44 轮把日期区间从「10月05日–10月11日」改成「10.05–10.11」）。
--- 只列 anchor 所在年（最多 53 行）—— 理由见 GlobalStats.availableWeeks 的注释。
function StatisticsPage:showWeekPicker()
    local store = self.plugin and self.plugin:_globalStore() or GlobalStats.newState()
    local anchor = tonumber(self.anchor) or os.time()
    local anchor_year = tonumber(os.date("%Y", anchor)) or 1970
    local weeks = GlobalStats.availableWeeks(store, anchor)
    local current_monday = GlobalStats.weekStart(anchor)

    local buttons = {}
    for _i, item in ipairs(weeks) do
        -- ★ 标签里不再重复年份（标题已经写了「（2026年）」）——
        --   省下的宽度让「第41周 10月05日–10月11日」这一行在 KPW4 上不至于被裁。
        local label = item.label .. "  " .. item.range
        local is_current = (item.monday == current_monday)
        if is_current then label = label .. " ✓" end
        local monday = item.monday
        buttons[#buttons + 1] = {
            {
                text = label,
                callback = function()
                    if self.dialog then
                        UIManager:close(self.dialog)
                        self.dialog = nil
                    end
                    if is_current then return end
                    -- 用 shiftAnchor("week", …) 平移：**保留星期几**（它加的是 7 天整数倍）
                    local delta = math.floor((monday - current_monday) / (7 * 86400) + 0.5)
                    self:reload{
                        period = "week",
                        anchor = GlobalStats.shiftAnchor("week", anchor, delta),
                    }
                end,
            },
        }
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    self.dialog = ButtonDialog:new{
        title = T(_("选择周（%1年）"), anchor_year),
        shrink_unneeded_width = true,
        modal = true,
        buttons = buttons,
    }
    UIManager:show(self.dialog)
end

--==========================================================================
-- 入口
--==========================================================================

function M.show(plugin, period, anchor, metric)
    local ok, page = pcall(StatisticsPage.new, StatisticsPage, {
        plugin = plugin,
        period = period or "year",
        anchor = anchor,
        metric = metric or "units",
    })
    if not ok then
        logger.err("WordCount: statistics page initial build failed", page)
        UIManager:show(InfoMessage:new{ text = T(_("统计页面打开失败：%1"), tostring(page)) })
        return nil
    end
    UIManager:show(page)
    return page
end

return M
