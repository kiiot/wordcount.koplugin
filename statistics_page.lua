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

--- 图表 Y 轴刻度用的紧凑时长："2小时" / "30分" / "45秒"
local function compactDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds >= 3600 then
        local hours = seconds / 3600
        if hours >= 10 then return tostring(math.floor(hours + 0.5)) .. _("小时") end
        return trimZero(string.format("%.1f", hours)) .. _("小时")
    elseif seconds >= 60 then
        return tostring(math.floor(seconds / 60 + 0.5)) .. _("分")
    end
    return tostring(seconds) .. _("秒")
end

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

local function metricAxisText(value, metric)
    value = tonumber(value) or 0
    if metric == "seconds" or metric == "average" then
        return compactDuration(value)
    elseif metric == "speed" then
        return formatCount(value) .. _("字/分钟")
    end
    return formatCount(value) .. _("字")
end

--- ★★★ 37s：柱顶数值标签用的**紧凑**写法。
---
--- 和 `metricAxisText`（Y 轴刻度）的区别：**不带单位后缀**。
---   单位已经在 Y 轴刻度上给过一次了（如「1.2万字」），柱顶再重复一遍纯属浪费
---   横向空间 —— 而横向空间正是「能不能每根柱子都标上」的**唯一**瓶颈。
---   （时间类指标省不掉：compactDuration 的「2小时」里那个「小时」就是量纲本身。）
---
--- ⚠ 数值口径必须与 metricAxisText / 卡片完全一致（都走 formatCount），
---   否则同一根柱子上的数字会和卡片/刻度对不上。
local function metricBarLabel(value, metric)
    value = tonumber(value) or 0
    if metric == "seconds" or metric == "average" then
        return compactDuration(value)
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
        value_big = Font:getFace("cfont", 32),
        value_small = Font:getFace("cfont", 19),
        label = Font:getFace("smallinfofont", 19),
        delta = Font:getFace("smallinfofont", 18),
        tab = Font:getFace("cfont", 21),
        period = Font:getFace("cfont", 23),
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

local TREND_ROWS = 4 -- 4 条网格线 + 0 基线 => 5 个 Y 轴刻度

local function trendBucketLabels(period, count)
    local labels = {}
    for i = 1, count do
        if period == "day" then
            labels[i] = tostring(i - 1)
        elseif period == "week" then
            labels[i] = ({ _("一"), _("二"), _("三"), _("四"), _("五"), _("六"), _("日") })[i] or tostring(i)
        else
            labels[i] = tostring(i)
        end
    end
    return labels
end

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

--- 把 buckets 画成位图。返回 ImageWidget。
--- 用真实像素而不是字符网格：字符画依赖等宽字体，KOReader 默认字体不是等宽的，
--- 一旦列宽漂移整张图就废了。
---
--- ★★★ 37s：`scale_max` 改成**由调用方传入**（buildTrendSection 为了排 Y 轴刻度
---   已经算过一次 niceMax 了）。传进来是为了让「柱顶数值标签」和柱子共用同一个
---   上限 —— 两边各算一次不只是白算，更危险的是以后改口径只改一处。
---   不传则退回「自己算」的老行为（保持本函数可单独调用/测试）。
local function buildChartImage(buckets, metric, selected_index, width, height, scale_max)
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
    local row_h = height / TREND_ROWS

    -- 横向网格线（虚线），最后一条基线单独画实线
    -- ★ 32：网格虚线原来是 LIGHT_GRAY。用户要求「尽量不要有灰色字」——
    --   说的主要是**字**，但满屏灰线观感上也灰扑扑的。改成浅色点线
    --   （用 1px 稀疏点画，靠密度而不是灰度来区分主次）。
    local dash = math.max(1, Screen:scaleBySize(4))
    for r = 1, TREND_ROWS - 1 do
        local y = math.floor(r * row_h)
        local x = 0
        -- 稀疏度：每个 dash 之间空 dash*3，比原来的 dash*2 更淡
        while x < width do
            local w = math.min(dash, width - x)
            if w > 0 then bb:paintRect(x, y, w, 1, Blitbuffer.COLOR_LIGHT_GRAY) end
            x = x + dash * 3
        end
    end

    local count = math.max(1, #buckets)
    local slot = width / count
    -- ★★★ 37s：柱子加粗（用户：「实心柱可以粗一点」）。
    --   0.6 → 0.8：原来柱间空隙占 40%，在 e-ink 上看着像一根根细线；
    --   0.8 之后空隙 20%，柱子明显更敦实，又仍留得下相邻柱的分界。
    --   ⚠ 这个比例同时影响柱顶数值标签的观感（柱子越宽，标签越不显得飘），
    --     但**不影响**标签抽稀的计算 —— 那边只看 slot，不看 bar_w。
    local bar_w = math.max(1, math.floor(slot * 0.8))
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
---   `buildTrendSection` 里图表是 `HorizontalGroup{align="center"}` 居中在一个
---   6*row_h 高的带里的，而图本身只有 4*row_h 高 —— 图上、图下各空出一整行
---   （row_h，KPW4 上约 63px）。最高的柱子顶到图顶时，它的标签 y ≈ -(标签高+间距)，
---   正好落进**上方那行本来就空着**的区域：既不会盖住柱子，也不会顶到标题
---   （标题下面还隔着一个 vertical span）。
---   ⇒ 这正是「不挪动任何既有布局就能塞进标签」的原因，别改成给图加高。
---
--- ⚠ 由此带来一条**必须守住的约束**：`标签高 + 间距 ≤ 图上方那一行的高度`。
---   KPW4 上两者约 41 vs 62，余量够；但**以后若把 faces().value 的字号调大**，
---   必须回来重算这个约束 —— 一旦超出，标签就会顶到「阅读字数趋势」标题上。
---   （y 的公式本身是自限的：bar_h ≤ height ⇒ y ≥ -(标签高+间距)，不会更远。）
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
---   放不下时宁可少标几根，也绝不让两个数字叠在一起糊成一团 —— 那是不可读。
local function chartValueLabels(buckets, metric, selected_index, width, height, scale_max)
    local f = faces()
    local count = #buckets
    if count == 0 then return {} end
    local slot = width / count
    local gap = Screen:scaleBySize(6)
    local min_bar_h = math.max(2, Screen:scaleBySize(2))

    local texts = {}
    for i, bucket in ipairs(buckets) do
        texts[i] = metricBarLabel(bucket.value, metric)
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

    -- 锚点 = 选中柱（越界/缺省都夹回合法范围）
    local anchor = tonumber(selected_index) or 1
    anchor = math.max(1, math.min(count, anchor))

    local left_edge, right_edge = place(anchor)

    -- 向左：只要不压到已放置标签的左边沿就放
    for i = anchor - 1, 1, -1 do
        local x, w = label_x(i)
        if x + w + gap <= left_edge then
            left_edge = place(i)
        end
    end
    -- 向右：同理
    for i = anchor + 1, count do
        local x = label_x(i)
        if x >= right_edge + gap then
            local _unused, nr = place(i)
            right_edge = nr
        end
    end
    return items
end

--- ★★★ 37s：图表 = 柱状位图 + 柱顶数值标签，叠在一个绝对定位容器里。
---
--- 抽稀（桶太密时少标几根）由 chartValueLabels 自己决定，这里不关心。
--- 没有任何标签时直接返回裸位图，保持与改动前完全一致的对象结构。
local function buildChartWidget(buckets, metric, selected_index, width, height, scale_max)
    local image = buildChartImage(buckets, metric, selected_index, width, height, scale_max)
    local labels = chartValueLabels(buckets, metric, selected_index, width, height, scale_max)
    if #labels == 0 then return image end
    local items = { { x = 0, y = 0, widget = image } }
    for _i, item in ipairs(labels) do items[#items + 1] = item end
    return AbsoluteContainer:new{ width = width, height = height, items = items }
end

--- Y 轴刻度列。标签列比图高一行，靠 HorizontalGroup 的居中对齐落在网格线上。
local function buildAxisColumn(labels, label_width, row_h, color)
    local f = faces()
    local group = VerticalGroup:new{}
    group[#group + 1] = VerticalSpan:new{ width = math.floor(row_h / 2) }
    for _i, label in ipairs(labels) do
        group[#group + 1] = FixedBox:new{
            width = label_width,
            height = row_h,
            align = "right",
            vertical_align = "center",
            text(label, f.axis, { color = color }),
        }
    end
    group[#group + 1] = VerticalSpan:new{ width = math.floor(row_h / 2) }
    return group
end

--- X 轴刻度行：按每个柱子的中心 x 绝对定位。
local function buildTickRow(bucket_count, chart_width, tick_height, period, color)
    local f = faces()
    local labels = trendBucketLabels(period, bucket_count)
    local slot = chart_width / math.max(1, bucket_count)

    -- 先量一下最宽的刻度文本，决定要不要隔一个显示
    local probe = text(labels[#labels] or "0", f.axis, { color = color })
    local probe_w = probe:getSize().w
    probe:free()
    local min_slot = probe_w + Screen:scaleBySize(8)
    local stride = math.max(1, math.ceil(min_slot / math.max(1, slot)))

    local items = {}
    for i = 1, bucket_count do
        if (i - 1) % stride == 0 then
            local widget = text(labels[i] or tostring(i), f.axis, { color = color })
            local w = widget:getSize().w
            local x = math.floor((i - 1) * slot + slot / 2 - w / 2)
            x = math.max(0, math.min(x, chart_width - w))
            items[#items + 1] = { x = x, y = 0, widget = widget }
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
    end
    return group
end

--==========================================================================
-- 卡片
--==========================================================================

--- 卡片大数字的候选字号。宽度不够就整档降级，避免多列卡片互相压字。
--- ★ 32：整体上调（用户要求字体更大）；同时因为改成多列，降级档位也保留。
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
    -- ★ 32：图标不再 dim（那是灰化）；标签文字本来就是黑色，这里保持不变。
    local label_row = HorizontalGroup:new{ align = "center" }
    local icon_size = Screen:scaleBySize(15)
    label_row[#label_row + 1] = icon(spec.icon, icon_size)
    label_row[#label_row + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(5) }
    label_row[#label_row + 1] = text(spec.label, f.label, {
        color = Blitbuffer.COLOR_BLACK,
        max_width = inner_width - icon_size - Screen:scaleBySize(20),
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
                color = Blitbuffer.COLOR_BLACK,
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
local HRule = WidgetContainer:extend{
    width = nil,
    height = nil,
    color = Blitbuffer.COLOR_BLACK,
    dotted = false,
    dot_len = nil,   -- 点长（dotted 时用）
    gap_len = nil,   -- 间隔
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
    local dot = self.dot_len or Screen:scaleBySize(4)
    local gap = self.gap_len or Screen:scaleBySize(6)
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
--   · 宽 = min(屏宽 - 2*margin, 最大宽上限)。留出左右各 margin 的缝隙，
--     既看得到背景，也避免 e-ink 上贴边难看。
--   · 高 = min(内容高, 屏高 - 2*margin)。内容超过就**内部滚动**
--     （ScrollableContainer），而不是撑破屏幕。
--   · 竖屏/横屏都用 min/max 取，不写死。
local POPUP_MARGIN = Size.padding.large           -- 窗口与屏幕边缘的缝隙
local POPUP_SIDE_PADDING = Size.padding.large     -- 窗口内部左右内边距
local POPUP_MAX_WIDTH_RATIO = 0.92                -- 宽度不超过屏宽的 92%
local POPUP_MAX_HEIGHT_RATIO = 0.90               -- 高度不超过屏高的 90%

-- ★★★ 36：下钻浮窗的尺寸比例 —— 必须**明显小于**主浮窗（0.92 / 0.90），
--   这样点卡片进去时，能看到下钻框四周还露出主浮窗，一眼就是「叠在上面一层」。
local DRILL_MAX_WIDTH_RATIO = 0.80
local DRILL_MAX_HEIGHT_RATIO = 0.72

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
    --   主浮窗宽 = 屏宽 * POPUP_MAX_WIDTH_RATIO(0.92)，高 = 屏高 * 0.90；
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
    UIManager:show(next_page)
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
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
    body[#body + 1] = self:buildTabs(content_w)
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
    body[#body + 1] = self:buildPeriodNav(content_w, range_label)
    body[#body + 1] = VerticalSpan:new{ width = Size.span.vertical_large }
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

--- 总览 / 趋势 / 阅读字数 / 阅读速度。
---
--- ★★★ 32 用户明确要求：
---   「我要的是不选中有边框（不要填充颜色），选中的区别开」
---   所以：
---     · 未选中 = **纯白底 + 黑边框**（不再是浅灰填充）
---     · 选中   = **黑底白字**（对比强烈，e-ink 上一眼能分辨）
---   注意：e-ink 上黑底是「实心反白」，比任何灰度填充都清楚，
---   而且不需要灰阶抖动，反而更省刷新。
function StatisticsPage:buildViewTabs(width)
    local gap = Size.padding.default
    -- ★ 32：四个视图按钮排**一行**，不再折成两行两列。
    local cell_w = math.floor((width - gap * (#VIEW_TABS - 1)) / #VIEW_TABS)
    local cell_h = Screen:scaleBySize(38)
    local row = HorizontalGroup:new{ align = "center" }
    for j = 1, #VIEW_TABS do
        local tab = VIEW_TABS[j]
        local active = tab.value == self.view
        local label = text(tab.label, Font:getFace("cfont", 17), {
            color = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            bold = active,
            max_width = cell_w - Screen:scaleBySize(6),
        })
        local target = tab.value
        if j > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = FrameContainer:new{
            width = cell_w, height = cell_h,
            bordersize = Screen:scaleBySize(1),
            bordercolor = Blitbuffer.COLOR_BLACK,
            background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            radius = Size.radius.button,
            padding = 0,
            TapBox:new{
                FixedBox:new{ width = cell_w, height = cell_h,
                    align = "center", vertical_align = "center", label },
                on_tap = function()
                    if target ~= self.view then self:reload{ view = target } end
                    return true
                end,
            },
        }
    end
    return FixedBox:new{ width = width, height = cell_h, align = "center", vertical_align = "center", row }
end

--- 日 / 周 / 月 / 年 / 总
--- ★★ 32：同「不选中描边、选中反白」的规则。
---   外层的 LIGHT_GRAY 底也去掉 —— 用户明确说不要灰色。
function StatisticsPage:buildTabs(width)
    local f = faces()
    local tab_h = Screen:scaleBySize(36)
    local tab_w = math.floor(width / #TABS)
    local row = HorizontalGroup:new{ align = "center" }
    for _i, tab in ipairs(TABS) do
        local active = (tab.value == self.period)
        local label = text(tab.label, f.tab, {
            bold = active,
            color = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        })
        local target = tab.value
        local button = TapBox:new{
            FixedBox:new{
                width = tab_w, height = tab_h,
                align = "center", vertical_align = "center",
                label,
            },
            on_tap = function()
                if not active then self:reload{ period = target, anchor = os.time() } end
                return true
            end,
        }
        -- 相邻格子共享一条竖边：只给非第一格画左边框，
        -- 这样整排看起来是一根连续的分段控件，而不是 5 个独立小方块。
        row[#row + 1] = FixedBox:new{
            width = tab_w,
            height = tab_h,
            FrameContainer:new{
                width = tab_w,
                height = tab_h,
                radius = Size.radius.button,
                bordersize = Screen:scaleBySize(1),
                bordercolor = Blitbuffer.COLOR_BLACK,
                padding = 0,
                margin = 0,
                background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                button,
            },
        }
    end
    return FixedBox:new{
        width = width,
        height = tab_h,
        FrameContainer:new{
            width = width,
            height = tab_h,
            radius = Size.radius.button,
            bordersize = 0,
            padding = 0,
            margin = 0,
            -- ★ 32：不再是 LIGHT_GRAY 底；底色交给每个格子的黑/白。
            background = Blitbuffer.COLOR_WHITE,
            row,
        },
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
    local line_h = Screen:scaleBySize(34)
    -- ★★★ 37f/37i：**两行**（年 / 月日）—— nav_h 相应改成 2 行高。
    --   ⚠ 改这里必须同步改 buildUnitsPage 的 PERIODNAV_H 预算，见那里的注释。
    local nav_h = line_h * 2 + Size.padding.tiny

    -- 年月日两段文字
    local year_label, month_day_label = GlobalStats.navLabels(self.period, self.anchor)
    if not year_label then year_label = range_label or "" end
    if self.period == "total" then
        year_label, month_day_label = _("累计"), nil
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
    --     写成 `bordercolor` 会被**静默忽略**、落回默认黑框 —— 本文件另有 7 处
    --     写的是 `bordercolor`（grep 可见），因为恰好都想要黑色才一直没暴露。
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
        -- 中间簇：日‹ + [tiny] + 月日 + [tiny] + 日›
        --   点文字下钻到「日」（保留 37c 手感）。
        local md_text_widget = md_text
        if not disabled then
            md_text_widget = TapBox:new{ md_text, on_tap = function()
                self:cycleToGranularity("day")
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
    card_h = card_h + 2 * Size.padding.default

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
    --   + span.v_large + tabs(36) + span.v_def + periodNav(line_h+btn_h+pad.tiny)
    --   + span.v_large + sortRow(36) + span.v_def + status(30) + pad.small
    local TITLEBAR_H = Screen:scaleBySize(34)    -- TitleBar 标题文字行高（含下划线内边距的保守值）
    local VIEWTAB_H  = Screen:scaleBySize(38)
    local TABS_H     = Screen:scaleBySize(36)
    --   ★ 37i：buildPeriodNav 现在是「**三**行 × line_h(34)」= scaleBySize(102)，
    --     这里必须跟着改，否则预算又对不上（这正是翻页栏被顶掉的老病根）。
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

    --------------------------------------------------------------------------
    -- 排序行：字数 / 最近阅读 / 书名（沿用 32 的黑底反白选中样式）
    --------------------------------------------------------------------------
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

    --------------------------------------------------------------------------
    -- 行列表：书名 + 已读字数，**行间点线分隔**（不是外框、不是灰底）
    --------------------------------------------------------------------------
    -- ★★★ 36：用户要求「只显示数字」。右侧去掉「已读」二字，纯数字。
    -- （row_h / line_w 已在函数开头按可用高度算好，这里不再重复定义）
    if total_rows == 0 then
        group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
        group[#group + 1] = text(_("当前周期没有阅读字数记录"),
            faces().footer, { color = Blitbuffer.COLOR_BLACK })
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

    -- 标题行 + 图表/列表切换
    local icon_size = Screen:scaleBySize(22)
    local header = HorizontalGroup:new{ align = "center" }
    header[#header + 1] = text(metric_label .. _("趋势"), f.section, {
        bold = true,
        max_width = inner_w - 2 * icon_size - Size.padding.large,
    })
    local spacer_w = math.max(0, inner_w - 2 * icon_size
        - Size.padding.large - header[1]:getSize().w)
    header[#header + 1] = HorizontalSpan:new{ width = spacer_w }
    local is_chart = self.trend_view ~= "list"
    header[#header + 1] = IconButton:new{
        icon = "column.three",
        width = icon_size, height = icon_size, padding = 0,
        show_parent = self,
        callback = function() self:reload{ trend_view = "chart" } end,
    }
    header[#header + 1] = IconButton:new{
        icon = "align.justify",
        width = icon_size, height = icon_size, padding = 0,
        show_parent = self,
        callback = function() self:reload{ trend_view = "list" } end,
    }

    local section = VerticalGroup:new{ align = "left" }
    section[#section + 1] = header
    section[#section + 1] = VerticalSpan:new{ width = Size.span.vertical_large }

    if is_chart then
        -- Y 轴刻度列 + 图
        local axis_w = math.floor(inner_w * 0.22)
        local chart_w = inner_w - axis_w - Size.padding.default
        local labels = {}
        local maximum = 0
        for _i, bucket in ipairs(buckets) do
            maximum = math.max(maximum, tonumber(bucket.value) or 0)
        end
        local scale_max = niceMax(maximum)
        for i = 0, TREND_ROWS do
            labels[#labels + 1] = metricAxisText(scale_max * (TREND_ROWS - i) / TREND_ROWS, metric)
        end

        -- ★★★ 37s：图 = 柱状位图 + **每根柱子顶上的数值标签**（用户要求）。
        --
        --   ⚠ 这里**故意不给图加高**：图仍是 4*row_h、仍由下面这个
        --     `align="center"` 居中在 6*row_h 的带里，所以标签落进图上方
        --     那一行本来就空着的区域，整个页面布局**一行没动**
        --     （x 轴刻度行、周期导航、翻页栏的位置都不会被顶走）。
        --     详见 chartValueLabels 的注释。
        --
        --   scale_max 复用上面排 Y 轴刻度时算出来的值 —— 标签和柱子必须
        --   共用同一个上限，否则标签会跟柱顶错位。
        local chart = buildChartWidget(buckets, metric, selected, chart_w, chart_h, scale_max)
        local axis = buildAxisColumn(labels, axis_w, row_h, Blitbuffer.COLOR_BLACK)
        section[#section + 1] = HorizontalGroup:new{
            align = "center",
            axis,
            HorizontalSpan:new{ width = Size.padding.default },
            chart,
        }

        local tick_h = Screen:scaleBySize(24)
        local tick_row = buildTickRow(#buckets, chart_w, tick_h, self.period, Blitbuffer.COLOR_BLACK)
        section[#section + 1] = HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = axis_w + Size.padding.default },
            tick_row,
        }
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
            color = Blitbuffer.COLOR_BLACK,
            max_width = inner_w,
        }),
    }

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
