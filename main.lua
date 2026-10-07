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

-- ★★★ 1.3-bugM：屏幕对象必须**显式取**，不能裸用 `Screen`。
--
--   ☠ 真 bug（用户截图 + crash.log 坐实）：
--     `LiveProgressDialog:init()` 里写的是 `Screen:getWidth()`，
--     但本文件**从来没有定义过 `Screen`**（也没 require 过 device 的 screen）。
--     于是那句抛
--         attempt to index global 'Screen' (a nil value)
--     而它又在 `pcall(function() return ButtonTable:new{...} end)` **内部** ⇒
--     错误被 pcall 吞掉 ⇒ 走到 else 分支 ⇒ 日志里只剩一句
--         WARN WordCount: 取消按钮创建失败（ButtonTable 不可用）
--     用户看到的现象就是「进度条上根本不显示取消按钮」。
--
--   ★ 为什么静态扫描没抓到：check_plugin.py 把 `Screen` 当**上游全局**放行
--     （它在 KOReader 里确实是全局注入的），所以「未声明变量」检查漏了。
--     ⇒ 教训：**不要依赖上游的隐式全局**，一律自己 require 后显式局部化。
local Screen = Device.screen

local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.*/)main%.lua$") or "./")
local Counter = dofile(plugin_dir .. "word_count.lua")
local PageText = dofile(plugin_dir .. "page_text.lua")
local ReadingStats = dofile(plugin_dir .. "reading_stats.lua")
local GlobalStats = dofile(plugin_dir .. "global_stats.lua")
local StatisticsPage = dofile(plugin_dir .. "statistics_page.lua")
local BookshelfIntegration = dofile(plugin_dir .. "bookshelf_integration.lua")

local WordCount = WidgetContainer:extend{
    name = "wordcount",
    is_doc_only = false,
}

-- ProgressbarDialog only updates its bar; its subtitle is built once during
-- init and is never re-rendered by reportProgress(). We therefore keep our own
-- references to the title/subtitle TextWidgets and push text into them on every
-- tick.
--
-- ⚠ 结构坑（这是「进度条和文字都消失」的根因，改这张表前先读）:
--   frontend/ui/widget/progressbardialog.lua:97-131 里，init() 建的是
--       local vertical_group = VerticalGroup:new{}
--       if self.title    then vertical_group[#vg+1] = TextWidget{ text = title }    end
--       if self.subtitle then vertical_group[#vg+1] = TextWidget{ text = subtitle } end
--       if self.progress_bar_visible then
--           self.progress_bar = ProgressWidget{...}; vertical_group[#vg+1] = self.progress_bar
--       end
--       self[1] = FrameContainer:new{ radius, bordersize, padding, background, vertical_group }
--   —— self[1] 是 **FrameContainer**，真正的 VerticalGroup 挂在它自己的 [1] 上：
--       self[1][1]    = VerticalGroup
--       self[1][1][1] = title TextWidget      （若提供了 title）
--       self[1][1][2] = subtitle TextWidget   （若提供了 subtitle）
--       self[1][1][3] = ProgressWidget        （若 progress_max > 0）
--   而 FrameContainer 只挂 [1] 一个子节点，所以
--       self[1][2]   == nil
--       self[1][1][2] 在「只给了 title」时也是 nil（下标 = 控件数量，不是固定位置）
--   旧代码写 `local vertical_group = self[1]` 拿到的是 FrameContainer，于是
--       self._title_widget    = FrameContainer[1] = VerticalGroup（一个没有 setText 的容器）
--       self._subtitle_widget = FrameContainer[2] = nil
--   updateProgress() / setStatus() 里的 `if self._subtitle_widget then ... setText`
--   就全部静默跳过 —— 进度文字永远停在最初那句「正在打开：…」，进度条也只是
--   因为 reportProgress 直接摸 self.progress_bar 才偶尔动一下。
--
--   这里不再依赖「第几个下标是哪个控件」，改成两步：
--     1) 定位真正的 VerticalGroup（先看 self[1] 是不是容器：有 getSize 且不自己
--        当叶子用；再退回到「只有一个子节点」的 FrameContainer 特征）；
--     2) 遍历它的子节点，用「子控件的初始 text 是否等于 self.title / self.subtitle」
--        来认领标题与副标题，用有没有 setPercentage 来认领进度条。
--   这样无论上游给不给 title、给不给 subtitle，都不会认错位置。

-- ★★★ 37r：进度框标题里的书名**必须先自己截短**，不能指望 TextWidget 截。
--
--   用户报的现象（批量统计）：
--     「书名过长会出现超到进度框外面去，而且下一本还是上一本过长的书名」
--
--   两道保险，缺一不可：
--     ① **字号无关的长度上限**。上游 TextWidget 虽然带 max_width，但它的
--        截断依赖字体实际度量（RenderText:getSubTextByWidth 逐字符累加
--        glyph.ax）。字体缺失 / 度量异常 / 未来上游改实现，都会让截断失效，
--        而一旦失效就是**画到框外**（e-ink 上还擦不掉，因为刷新区域是按
--        对话框自身尺寸算的）。这里按**字符数**先砍一刀，跟字体无关，
--        最坏情况也只是一行放不下被裁，不会把框撑破。
--     ② 长度上限必须**远小于**对话框内容宽 —— 中文一个字就是一个字宽，
--        22 个字在 KPW4 竖屏（内容宽约 900px、字宽约 30px）上约 660px，
--        留足余量。
--
--   ⚠ 为什么不能用 `string.sub` 直接切：它是**按字节**切的，中文一个字 3 字节，
--     切在第 2 个字节上会产生非法 UTF-8，渲染时直接报错或画成方块。
--     这里按「UTF-8 首字节」计数（首字节 = <0x80 或 >=0xC0），逐字节走，
--     纯字节算术，不依赖任何多字节模式匹配。
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
    --    上游 self[1] = FrameContainer{ vertical_group }，即 FrameContainer 只挂
    --    [1] 一个子节点，而这个子节点（VerticalGroup）自己**不是叶子**、并且
    --    内含若干叶子。
    --    ⚠ 不要用「有 getSize」判断容器：VerticalGroup 也继承 getSize。
    --    判据取「root 不是叶子，且 root 的唯一子节点不是叶子」——这就把
    --    FrameContainer→VerticalGroup 与「上游直接挂 VerticalGroup」两种情形都覆盖了。
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

    -- ★ 刷屏控制的内部状态（20-flicker-fix）。见 _redraw / MIN_REDRAW_INTERVAL。
    self._last_redraw_at = nil       -- 上次真实重绘的 monotonic 时刻
    self._redraw_pending = false     -- 有没有被节流掉、欠着的重绘
    self._last_progress_text = nil   -- 上一句写进 subtitle 的进度文本（去重用）
    -- ★ 37r：上一帧真实重绘的区域。下次重绘要跟它取并集 ——
    --   否则「长书名 → 短书名」时框变小，上一帧多出来的那截永远擦不掉。
    self._last_region = nil

    -- ★★★ 1.2：在进度条下方挂一个「取消」按钮。
    --
    --   用户要求：「统计书籍的进度条加一个取消，点击的时候中断并清除
    --   未完成的缓存，已完成的不清除」。
    --
    --   为什么不能用上游的 dismissable（点任意处关闭）：
    --     · 那只是关掉对话框，**不会中断扫描**（job 还在跑）；
    --     · 而且误触概率极高（进度对话框占满全屏，点哪都关）。
    --   所以显式加按钮，并且按钮回调走 `cancel_callback`（由调用方注入，
    --   指向 WordCount:cancelCount）—— 那里才会真正中断 + 清缓存。
    --
    --   ⚠ 布局注意：本对话框是 InputContainer，Point 事件按子控件递归派发。
    --     按钮必须挂进 `self._progress_group`（VerticalGroup）里，才能被
    --     正确命中；直接塞 self[1] 会破坏 FrameContainer 的单子节点结构。
    self._cancel_button = nil
    if self._progress_group and type(self.cancel_callback) == "function" then
        -- ⚠ 注意：`ButtonTable:new{...}` 是**方法调用语法**，不能直接当表达式
        --   传给 pcall（Lua 语法不允许）。必须包一层 function 再 pcall。
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
            -- ★★★ 1.5-bugP：**不要清外层 self.dimen！**
            --
            --   1.2 当初写的是 `self.dimen = nil`，本意是「逼命中区域按新尺寸
            --   重算」，结果把**居中定位**一起毁了 —— 用户看到的现象是
            --   「进度条的框跑到屏幕最上方」。
            --
            --   根因（widgetcontainer.lua:49-76）：
            --       function WidgetContainer:paintTo(bb, x, y)
            --           if not self.dimen then
            --               local content_size = self[1]:getSize()
            --               self.dimen = Geom:new{x=0, y=0,
            --                                     w=content_size.w, h=content_size.h}
            --           end                       -- ← 用**内容尺寸**重建
            --           ...
            --           elseif self.align == "center" then
            --               self[1]:paintTo(bb,
            --                   x + (self.dimen.w - contentSize.w)/2,
            --                   y + (self.dimen.h - contentSize.h)/2)
            --           end                       -- ← 垂直偏移 = (dimen.h - 内容h)/2
            --       end
            --   而上游 ProgressbarDialog:init() 里是
            --       self.align  = "center"
            --       self.dimen  = Screen:getSize()      -- **整屏**
            --   也就是说：**dimen 承担两个职责** ——
            --     ① 全屏尺寸 → 让 align="center" 算出「屏幕中心」的偏移；
            --     ② 事件命中区域。
            --   把 ① 置 nil 之后重建出来的 dimen.h == 内容高 ⇒ 垂直偏移恒为 0
            --   ⇒ 框贴到最上方。这就是用户报的「框在最上方」。
            --
            --   正确修法：**保留整屏 dimen**（定位不变），只清**内层
            --   FrameContainer** 的 dimen —— 那才是命中测试真正用的那个
            --   （framecontainer.lua:105-111 只在 dimen 为空时按内容建一次，
            --   所以追加按钮后必须清掉它，否则按钮「看得见、点不到」）。
            --
            --   ★ 顺带：如果是为了让 align 生效而清空的，要注意 align 依赖
            --     dimen 的 w/h；清掉就前功尽弃。这里显式重申 dimen 为整屏。
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
            -- ★★★ 1.3-bugM：**把真实错误打出来**。
            --   以前这里只有一句「ButtonTable 不可用」，把 pcall 吞掉的真正异常
            --   （`attempt to index global 'Screen'`）藏得一干二净 ——
            --   排查时只能靠猜。现在 error_message 一定进日志。
            logger.warn("WordCount: 取消按钮创建失败：" .. tostring(btn_table))
        end
    end
end

--- ★★★ 37r：文本变了必须**同时作废两层尺寸缓存**，否则框还是按旧尺寸画的。
--
--   ☠ 真 bug（用户报的「书名超到进度框外面 / 下一本还是上一本的书名」）：
--
--     · `VerticalGroup:getSize()`（verticalgroup.lua:15-31）把算出来的
--       `self._size` / `self._offsets` **缓存起来**，之后不再重算；
--     · `FrameContainer:paintTo()`（framecontainer.lua:105-111）第一次画的时候
--       把 `self.dimen` 定死，之后**只更新 x/y，不更新 w/h**。
--
--     两者叠加 ⇒ 对话框的**外框尺寸停留在第一次 paintTo 时的样子**。
--     后续把标题换成一本很长的书名时：
--       · 文字行由 TextWidget 自己按 max_width 截断（这层是好的），
--       · 但**外框**没有跟着变，而且 `_refreshRegion()` 算出来的重绘区域
--         也是按这个旧尺寸算的 ⇒ 长出来的那截**画在框外、且永远不被重绘**，
--         e-ink 上就表现为「书名溢出到框外面」；
--       · 反过来，从长书名切到短书名时，旧的长标题同样落在新区域之外，
--         于是**屏幕上还留着上一本书的长书名**。
--
--   修法：每次真正改动了文本，就作废这两层缓存，让下一次 getSize/paintTo
--   按新内容重算。`VerticalGroup` 有现成的 `resetLayout()`（上游公开方法，
--   就是干这个的）；`FrameContainer` 清 `dimen` 即可（它在 paintTo 里
--   `if not self.dimen` 时重建）。
--
--   ⚠ **不要清 `self.dimen`**（对话框自己的）。上游把 `self.dimen` 设成
--     整屏尺寸，它同时承担「居中偏移的基准」和「事件命中区」两个职责；
--     清掉会让框贴到屏幕最上方（1.5-bugP 踩过，见 init 里的长注释）。
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

--- 把一个文本推给指定槽位。找不到控件时只更新内部字段，绝不抛错。
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
    -- ★ 37r：**不要**写成 `(slot == "title") and self._title_widget or self._subtitle_widget`。
    --   Lua 的 `and/or` 链在「and 的结果为 nil/false」时会掉到 or 那一侧 ——
    --   于是 `_title_widget` 缺失时，标题文本会被悄悄写进**副标题**控件，
    --   随后 _pushProgressText 又往同一个副标题里写，两段文字互相覆盖。
    --   这里显式分支，缺哪个就只更新内部字段，绝不串槽。
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

--- ★★ 26-batch-index：批量统计时，在**标题行**显示「第 X / N 本」。
--
-- 上游 ProgressbarDialog 的槽位只有 title / subtitle / progress_bar 三个，
-- 没有独立的「批次行」。但 title 槽本身是我们可以自由写的 TextWidget，而
-- 批量场景下 title 只写「正在批量统计字数」这句固定文案（没信息量）——
-- 所以这里把它复用成「书名 + 第 X / N 本」：
--     self:setBatchInfo(3, 12, "三体.epub")
--     → title 变成 "正在批量统计字数（第 3 / 12 本）  三体"
-- 单本统计（batch_total 为 nil）时调用它只会清掉旧状态。
--
-- ★★★ 37r：书名经 `shortBookName()` **按字符数截短**后才拼进标题。
--   理由见 shortBookName 上方的注释 —— 不能指望 TextWidget 的 max_width
--   截断一定生效，一旦失效就是「画到框外」。
function LiveProgressDialog:setBatchInfo(index, total, name)
    index = tonumber(index)
    total = tonumber(total)
    if not index or not total or total <= 0 then
        -- ★ 37r：以前这里直接 return，**什么都不写** ——
        --   于是从「批量第 3 本」切回单本统计时，标题里还挂着上一本书的名字。
        --   现在改成清空批次状态后**照样刷新一次标题**，把书名擦掉。
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

--- 把当前批次信息重新组合进标题。扫描过程中标题可能被 configureProgress
--- 改回「正在批量统计字数」，所以 configureProgress 里也要调一次。
--
--- ★★★ 37r：**单本模式下必须是 no-op**。
--   这是被测试（dialog_survives 步骤2）挡下来的一个回归：如果无条件写标题，
--   `configureProgress(240, "正在统计全书字数")` 刚设好的标题会被这里
--   用默认的「正在批量统计字数」覆盖掉 —— 单本统计的进度框就永远显示
--   批量文案了。
--
--   但「刚从批量切回单本」时又**必须**写一次：否则上一本书的书名会留在
--   标题里（正是用户报的「下一本还是上一本的书名」）。所以判据是
--   **「之前写过批次标题吗」**，而不是「现在有没有批次信息」。
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

--- ★★ e-ink 刷屏总控（20-flicker-fix）。
--
-- 症状：扫描一本书时「进度条每动一下，整个页面都在闪」。
--
-- 根因（两件事叠在一起，缺一不可）：
--
--   1) 刷新区域被放大到整屏。
--      上游 progressbardialog.lua:74 里 `self.dimen = Screen:getSize()` —— 整个
--      modal 的 dimen 就是物理屏幕大小（1072×1448）。而 setDirty(self, ...) 不传
--      refreshregion 时，uimanager.lua:684 会把 refreshtype/region 包成 lambda 塞进
--      _refresh_func_stack，_repaint 里执行该 lambda 拿到的 region 就是
--      widget.dimen —— 即**整屏**。
--      于是 _refresh("ui", 全屏region) → refresh_methods.ui = Screen.refreshUI
--      (uimanager.lua:1069)，把整块 1072×1448 都按 "ui" 模式重刷。e-ink 上
--      "ui" 是「medium fidelity」糊屏，全屏区域做就是满屏一闪。
--      （上游注释说 self.dimen 全屏是为 EPDC 的波形区域，对真机 fb 就是整屏。）
--
--   2) 刷得太密。
--      扫描循环 SCAN_TICK_DELAY = 0.08s ≈ 12.5 次/秒，虽然 PAGES_PER_TICK=16 已经
--      限制了 updateProgress 的调用（progress_step ≥1 且按页数/20 分段），但只要
--      progress_step 被触发，就是一次全屏 "ui" 刷新。Kindle 走
--      libs/libkoreader-input（已 nm 确认导出 setTimer/clearTimer/timerfd），
--      即 **timerfd backend**：scheduleIn 的回调由内核精确定时唤醒，不会被
--      INPUT_TIMEOUT 那把 200ms「伞」吃掉时间片 —— 所以 12.5 次/秒是**真的**
--      每秒刷新 12.5 次，不是被节流后的残余。这就是肉眼看到的「不停闪」。
--
-- 对策（只做减量，不动功能）：
--   a) 每次 setDirty 都**显式传最小 region**（标题/副标题/进度条的外框），
--      绝不再让它退回整屏。刷新区域从 1072×1448 降到大约几百×两百。
--   b) 加**时间节流**：距上次真实重绘不足 MIN_REDRAW_INTERVAL 的中间态只记
--      内部状态、跳过 setDirty；最后一个 100% 状态和 setStatus 强制放行，
--      保证结束时一定正确。
--   c) 百分比**量化到 5% 一档**，减少文本变化次数（文本变了才需要重绘该行）。
--
-- 这样一秒钟最多刷 2 次、且只刷对话框那一小块。
local MIN_REDRAW_INTERVAL = 0.5    -- 秒；两次真实重绘之间的最短间隔
local PERCENT_QUANTUM = 5          -- 百分比量化档位

-- ★★ 28-kpw4-tuning：单调时钟，模块级只解析一次。
--
--   原来有两处都是「用到时现 require」：
--     · 扫描 tick 里：pcall(function() now_t = require("ui/time").now() end)
--     · LiveProgressDialog:_redraw 里：更是套了**双层** pcall + 闭包
--   每次分配一个闭包（KPW4 上 GC 是实打实的卡顿源），还要走一遍 require 查表。
--   时间源在进程生命周期内不会变，纯浪费。
--
--   ★ 定义位置很关键：必须放在**第一个使用点之前**。
--     Lua 的 local 作用域从定义行之后才生效 —— 定义在后面的话，
--     前面的函数拿到的是 nil（不报错，但会静默退化成 os.time()，
--     等于白优化）。这里紧跟在 MIN_REDRAW_INTERVAL 后面，
--     对下面所有用到它的地方（_redraw / 扫描 tick）都可见。
--
--   用途只有「判断距上次重绘够不够久」（间隔 ≥ 0.5s），
--   取不到时间源时退回 os.time()（1 秒精度）完全够用。
local _now
do
    local ok, t = pcall(require, "ui/time")
    if ok and type(t) == "table" and type(t.now) == "function" then
        _now = t.now
    end
end

--- 计算这个 modal 需要重绘的最小区域。
--
-- ★★ 关键（21-region-center）：**必须把居中偏移算进去**，否则进度条永远不动。
--
--   上游 progressbardialog.lua:67 把 self.dimen 设成 Screen:getSize()（整屏，
--   x=0,y=0,w=1072,h=1448），而 InputContainer:paintTo
--   （inputcontainer.lua:66-91）是这样画的：
--
--       if self.align == "center" then
--           x = x + math.floor((self.dimen.w - content_size.w)/2)
--       end
--       if self.vertical_align == "center" then
--           y = y + math.floor((self.dimen.h - content_size.h)/2)
--       end
--
--   即**内容框被居中画在整屏中间**（大约 x≈300, y≈600），而不是画在 (0,0)。
--   所以 region 必须是「居中之后」的位置：
--       region.x = dimen.x + (dimen.w - w)/2
--       region.y = dimen.y + (dimen.h - h)/2
--
--   上一版（20b）把 region.x/y 直接写成 self.dimen.x/y（=0,0），结果每次
--   setDirty 都去刷**屏幕左上角那一小块**，而对话框在正中 ——
--   对话框本身从来没有被重绘过，用户在屏幕上看到的就是：
--     · 通知弹窗照常出现（Notification 是另一个 widget，自己画自己，位置对）
--     · 进度条/文字**从始至终一动不动**
--   这正是用户报的「一直弹窗报告进度，但是进度条没有任何变化」。
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
            -- ★ 居中偏移：与 InputContainer:paintTo 的算式保持一致
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

--- ★★★ 37r：两次重绘区域的**并集**。
--
--   为什么必须取并集（用户报的「下一本还是上一本的书名」的另一半原因）：
--     `_refreshRegion()` 只按**当前**内容尺寸算区域。当标题从一本长书名
--     换成一本短书名时，对话框外框会**变小** —— 于是上一帧画在「大框」
--     里的那截文字落在了新区域之外，e-ink 上**永远不会被重绘掉**，
--     屏幕上就留着上一本书的长书名。
--   取并集后，新旧两块都被标记为脏，旧内容一定被覆盖。
--
--   ⚠ 只并集，不并到整屏 —— 并集最多是两块对话框尺寸的矩形包络，
--     仍然远小于 1072×1448，不会把「只刷对话框那一小块」的省电优化废掉。
local function unionRegion(a, b)
    if not a then return b end
    if not b then return a end
    local x1 = math.min(a.x, b.x)
    local y1 = math.min(a.y, b.y)
    local x2 = math.max(a.x + a.w, b.x + b.w)
    local y2 = math.max(a.y + a.h, b.y + b.h)
    return Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

--- 统一的重绘入口：显式 region + 时间节流。
-- @param force 布尔；true 时无视时间节流（收尾、状态变更用）
function LiveProgressDialog:_redraw(force)
    -- ★ 28-kpw4-tuning：改用模块级缓存的 _now。
    --   旧写法是**双层** pcall + 一个闭包：
    --     pcall(function() ... pcall(require, "ui/time") ... end)
    --   而 _redraw 是进度条每次刷新都要走的路径，累积起来是实打实的浪费。
    --   ★ 注意 no-op 方向：_now 取不到时退回 os.time()，行为与旧代码一致
    --     （旧代码取不到时 now 保持 0，那会让节流判据变成
    --      0 - last < 0.5 ⇒ 恒为「未到间隔」⇒ 只更新内部字段不刷屏，
    --      反而更省电。这里给真实时间则能正常放行，是更合理的行为）。
    local now = _now and _now() or os.time()

    -- 时间节流：没到间隔就只更新内部字段，不碰屏幕。
    -- （进度条 setPercentage 已在调用点直接改好，内部状态永远是最新的，
    --   下一次放行时会一并画出去。）
    if not force and self._last_redraw_at
            and (now - self._last_redraw_at) < MIN_REDRAW_INTERVAL then
        self._redraw_pending = true
        return false
    end
    self._last_redraw_at = now
    self._redraw_pending = false

    -- ★ 37r：与上一帧的区域取并集，保证「框变小 / 文字变短」时旧内容被擦掉。
    local region = unionRegion(self._last_region, self:_refreshRegion())
    self._last_region = region
    pcall(UIManager.setDirty, UIManager, self, "ui", region)
    return true
end

function LiveProgressDialog:configureProgress(total, title)
    self.progress_max = math.max(1, math.floor(tonumber(total) or 1))
    -- 进度条要在 init 时就已经建好；这里不能靠改 progress_max 让 bar 出现，
    -- 所以如果先前没有 bar（progress_max 为 nil 的「正在打开…」对话框），
    -- 就把可见性关掉并只显示文字进度，避免出现半截布局。
    self.progress_bar_visible = self._progress_bar_widget ~= nil
    if title then
        self:_pushText("title", title)
        -- ★ 26-batch-index：记住这次传进来的「基础标题」，refreshBatchTitle
        --   要拿它去拼「基础标题（第 X / N 本）」。
        if self.batch_total and self.batch_total > 0 then
            self.batch_base_title = title
        end
    end
    -- ★ 26-batch-index：批量时 title 又被写回「正在批量统计字数」了，
    --   这里补一次，否则「第 X / N 本」会被每本书开头覆盖掉。
    self:refreshBatchTitle()
    self:_syncProgressBar(0)
    self:_pushProgressText(0)
    -- 刚切到正式进度：强制放行一次，让用户立刻看到新标题/0%。
    self:updateProgress(0, true)
end

--- 只写进度条内部百分比，不刷屏。
function LiveProgressDialog:_syncProgressBar(progress)
    local bar = self._progress_bar_widget or self.progress_bar
    if not self.progress_bar_visible or not bar or type(bar.setPercentage) ~= "function" then return end
    local total = math.max(1, tonumber(self.progress_max) or 1)
    pcall(bar.setPercentage, bar,
        math.max(0, math.min(1, (tonumber(progress) or 0) / total)))
end

--- 写「已扫描 x / y 页（z%）」这行字，百分比量化以减少无谓的文本变化。
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
    local text = T(_("已扫描 %1 / %2 页（%3%）"), done, total, shown)
    if text == self._last_progress_text then return false end
    self._last_progress_text = text
    self:_pushText("subtitle", text)
    return true
end

--- @param done  已扫描页数
-- @param force 布尔；true 时无视时间节流立刻重绘（用于 0% 与 100% 这类
--              用户一定会看到的节点）
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

--- 保留给上游/外部调用的兼容入口。上游 ProgressbarDialog:reportProgress 会调
-- redrawProgressbarIfNeeded() → redrawProgressbar() → forceRePaint()（全屏糊），
-- 我们覆写掉，改成只写内部状态 + 走自己的节流重绘。
function LiveProgressDialog:reportProgress(progress)
    self:_syncProgressBar(progress)
end

--- 上游的这两个都被我们摘掉，防止它偷偷 forceRePaint。
-- ⚠ 不要写成一行 `function LiveProgressDialog:redrawProgressbar() end`：
--   luaparser（check_plugin.py 用的解析器）对「函数体为空的单行定义」会报
--   no viable alternative —— 是真机的 Lua 能过、静态检查过不了。展开成多行。
function LiveProgressDialog:redrawProgressbarIfNeeded()
    -- 故意空实现：上游这里会 redrawProgressbar() → forceRePaint()（全屏刷）
end

function LiveProgressDialog:redrawProgressbar()
    -- 故意空实现：同上。真正的重绘由 _redraw() 以最小 region 完成。
end

function LiveProgressDialog:setStatus(status)
    -- ⚠ 用 self["_last_progress_text"] 而不是 self._last_progress_text：
    --   luaparser（check_plugin.py 用的解析器）不接受 `obj:field = value`
    --   这种「冒号当索引、冒号后跟字段」的形式，会报 no viable alternative。
    --   真机 Luajit 其实接受（等价于 obj["field"] = value），但为了让静态
    --   检查保持全绿，这里用方括号写法。
    self["_last_progress_text"] = nil   -- 状态文本与进度文本不同，强制写
    self:_pushText("subtitle", status)
    -- 状态变更必须让用户看见
    self:_redraw(true)
end

--- ★ 37r：关闭时把重绘状态清干净。
--   对话框对象是**整批复用**的（batch.dialog），下一批如果复用同一个实例，
--   残留的 `_last_region` 会让第一次重绘去刷上一批留下的旧位置。
--   ⚠ 用 `self["_last_region"] = nil` 的方括号写法，理由同 setStatus 上方注释。
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
local KEY_MTIME = "word_count_file_mtime_v1"
local KEY_SIZE = "word_count_file_size_v1"
-- ★ 26-sample-estimate：记录「这个字数是估算的还是精确的」。
--   缓存命中时要据此提示用户「想看精确值请点重新统计」。
local KEY_ESTIMATED = "word_count_estimated_v1"
local KEY_SAMPLED_PAGES = "word_count_sampled_pages_v1"
-- ★★ 全局字数缓存表（24-cache-reuse）：{ [文件路径] = {count,mtime,size,at} }。
--    放在 G_reader_settings 里 —— 单文件、键就是 path，没有 sidecar 多候选的歧义，
--    保证「写过一定读得到」。
local KEY_CACHE = "word_count_cache_v1"
local KEY_READ_STATS = "word_count_read_stats_v1"
local KEY_GLOBAL_STATS = "word_count_global_stats_v1"
-- ★★ 扫描节流参数（22-progress-only：省电优先）。
--
-- 耗电主要来自两处：
--   (1) 每次 scheduleIn 回调都会唤醒 CPU + 走一遍取文本逻辑；
--   (2) 每次真实重绘都要驱动 e-ink 刷新（最贵的动作）。
--
-- 旧值 SCAN_TICK_DELAY=0.08s 是 12.5 次/秒 —— Kindle 走 timerfd backend，
-- scheduleIn 由内核精确定时唤醒，**不会被 INPUT_TIMEOUT 的 200ms 伞合并**，
-- 所以这 12.5 次/秒是真实发生的唤醒次数，不是被系统节流后的残余。
-- 一本书 1000 页、每 tick 16 页 ⇒ 63 次 wakeup；改成 0.25s / 32 页后
-- ⇒ 32 次 wakeup，**唤醒次数直接砍半**，而总工作量完全不变。
--
-- PAGES_PER_TICK 加大到 32：单次 tick 多处理一点，tick 总数就少一点。
-- 代价是单次 tick 的 CPU 占用时间变长，但 e-ink 设备本来就是「忙一阵、
-- 睡一阵」的模型，把工作合并成更少的大块反而更省电。
local PAGES_PER_TICK = 32
local SCAN_TICK_DELAY = 0.25
-- ★ 进度上报的最短时间间隔（秒）。
--   0.8s → 1.5s：进度条每秒动一次已经足够「在动」的观感，
--   e-ink 上一次刷新本身就肉眼可见，没必要刷那么勤。
local PROGRESS_REPORT_INTERVAL = 1.5
-- 阅读状态/全局统计落盘频率（每 N 次累积写一次）。攒得越大越省电，
-- 但突然断电丢的也越多。3 → 8 是「每本书结束时本来还会有一次 force_flush」
-- 前提下安全的折中。
local READ_FLUSH_EVERY = 8

-- ★ 扫描过程中的 CPU 让渡间隔（秒）。
--   扫描是连续的 scheduleIn 链，中间不给系统喘息机会的话，
--   整本书扫完之前 CPU 一直处于「忙-醒-忙-醒」的高频状态，
--   功耗明显高于阅读时的「翻页才醒」。
--   每处理 CHUNK_TICKS 个 tick 之后插入一个较长的空闲，
--   让内核有机会进 deeper idle / 降频，整体能耗更平滑。
--
-- ★★★ 28-kpw4-tuning：CHUNK_TICKS 20 → 10，CHUNK_REST_DELAY 1.0 → 1.2。
--
--   面向 KPW4 这类老设备（SoC 制程旧、发热明显、电池老化）：
--     · 休息更频繁（每 10 个 tick ≈ 2.5 秒就歇一次，原来要 5 秒）
--       ⇒ SoC 有更多窗口降频/进 idle，机身更凉
--     · 休息更久（1.2 秒，原来 1 秒）
--       ⇒ 平均功耗曲线更平，不再是「连续冲刺一阵再歇」
--
--   代价：1000 页书的扫描总时长从约 9.4 秒拉长到约 12 秒。
--   但——**默认已经是抽页模式了**（只扫 100 页，本来就只有 1 秒，
--   根本吃不到这个休息机制）。所以这个代价只在用户主动选「完整扫描」
--   并且书很大时才出现，那时他本来就在等一个精确结果，多 2 秒无感。
--
--   反过来说：如果用户切回 full 扫大书，机身温度会比以前明显低。
local CHUNK_TICKS = 10            -- 每 10 个 tick 休息一次（原来 20）
local CHUNK_REST_DELAY = 1.2      -- 休息 1.2 秒（此时不刷屏、不唤醒）

-- ★★★ 抽页统计（26-sample-estimate）—— 「太耗电就只统计前一百，可以翻页查看」。
--
-- 动机：一本 1000+ 页的书全量扫描要几十秒，虽然已经省电优化过，但
--      用户明确说「如果太耗电就只统计前一百」。
--
-- 做法：只扫前 SAMPLE_PAGES 页，算出**样本平均每页字数**，再 × 总页数
--      估算全书。样本量够大时（100 页）误差通常能控制在几个百分点 ——
--      因为正文字体、行距、页边距在整本书里是**同一套排版参数**，
--      每页容量基本恒定，差异主要来自章节首页、插图页、空页。
--
--      实测规律：越靠后的页越接近样本均值，所以取**开头连续 100 页**比
--      「均匀抽样 100 页」更贴近真实（均匀抽样要反复跳转，反而更慢）。
--
-- 两种模式：
--    full     —— 全量扫描，结果精确（**默认**）
--    sample   —— 抽页估算，结果标「约」，省电
--
-- ★★★ 36-full-by-default：默认模式从 sample **改回 full**。
--
--   缘由：用户明确反馈「统计字数为什么显示已使用缓存估算，我的统计字数功能
--   实现呢，进度条呢」—— 28-kpw4-tuning 把默认改成 sample 后，点「统计本书
--   字数」不但看不到进度条，还只得到一句「已使用缓存结果（估算）」，
--   体验上等于「功能没实现」。用户要的是**真的统计一次、看得见进度条、
--   给出精确数字**。
--
--   所以：默认回到 full（精确完整扫描 + 进度条）。
--   · 省电诉求仍然满足 —— 26/28/33 各轮的省电优化（PAGES_PER_TICK、
--     SCAN_TICK_DELAY、CHUNK_TICKS 休息、热路径 _pageKeyFast、
--     nextTick 推迟 I/O）都还在，扫描本身已比老版本省得多。
--   · 「抽页估算」没删 —— 需要省电的用户随时能在菜单里切回 sample
--     （开关保留，选择会被记住，老用户不受影响）。
local SAMPLE_PAGES = 100          -- 抽页统计的样本页数
local MODE_FULL = "full"
local MODE_SAMPLE = "sample"

-- ★★★ 31-huge-book-guard：整书一次取文本的页数上限。
--
--   整书路径（`extractWholeBook`）是**唯一精确**的取文本方式，但它把
--   全本文本一次性读成一个 Lua 字符串。页数越多，这个字符串越大：
--     3000 页 ≈ 3~6 MB 文本 → 安全
--     几万页  ≈ 几十~几百 MB  → **必然 OOM**（KPW4 只有 512MB）
--
--   所以超过这个页数就**不走整书路径**，改为逐页扫（分 tick，内存峰值
--   只与单页大小相关）。代价是精度退回「页边界近似」，但不会把设备搞崩。
local WHOLE_BOOK_MAX_PAGES = 5000

-- ★★★ 37i-huge-book-oom：**逐页扫描的页数上限**（比整书阈值更高的一层闸门）。
--
--   背景（真实崩溃，见 D:/chrome/crash (11).log）：
--     用户对 219MB / **93551 页**的《轮回乐园》点「统计本书字数」
--     （force_rescan=true）→ 走了逐页兜底路径 → 逐页扫了 9 万页之后：
--        [ue_wait_for_event:269] poll: Interrupted system call
--        Killed                       ← 内核 OOM Killer 杀掉进程 ⇒ 整机重启
--
--   为什么逐页也会 OOM（不只是整书路径）：
--     · 每页都调 `doc:getTextFromXPointer(s)`，crengine 要为 9 万页的文档
--       反复定位/构建文本片段，其**内部内存只增不减**（缓存 + 碎片）；
--     · 连续 9 万个 tick，插件侧从不主动 `collectgarbage`（Lua 堆也在涨）；
--     · KPW4 只有 512MB，叠加 crengine 自身占用 ⇒ 必然被内核杀掉。
--     `MAX_TRACKED_PAGES`（5万）只挡了 `page_units` 明细表，**挡不住扫描本身**。
--
--   修法：页数超过这个上限时，**根本不做逐页全扫**，直接退回抽样估算
--     （只扫前 SAMPLE_PAGES 页 → 外推 → 结果标「约」）。
--     取舍与 31/33 一致：**宁可数字是「约」，绝不让设备重启。**
--
--   取 20000 页：正常长篇（1000~3000 页）远远够不着；真正会触发的只有
--   「几万页的巨书」，正是 We 要保护的场景。用户若确实对巨书要精确值，
--   菜单里的「统计模式」切回「完整」也仍然受这个上限保护（安全优先）。
local PER_PAGE_SCAN_MAX_PAGES = 20000

-- ★★★ 37j-user-controllable-limits：**把「降级/拒绝」的触发点交给用户**。
--
--   用户明确要求（37j）：
--     「都按完整版来算啊，我不想要降级的，如果不够内存可以断掉避免触发重启，
--       或者给我选项让我采用哪种降级的以及多少开始降级计算」
--
--   三条诉求 → 三个设置项（全部存在 G_reader_settings，菜单可改）：
--
--     ① `word_count_scan_mode`（已有）= full | sample
--         · full   = **完整版**：不抽样、不自动降级（默认）
--         · sample = 用户主动要抽样
--
--     ② `word_count_downgrade_enabled`（新）= true | false（默认 **false**）
--         · false ⇒ **永不自动降级**：规模超限时**直接拒绝并提示**，
--                    避免硬跑触发 OOM 重启（正是用户要的「断掉」）。
--         · true  ⇒ 允许按下面的阈值自动降级为抽样。
--
--     ③ `word_count_downgrade_pages`（新，默认 20000）
--        `word_count_downgrade_mb`（新，默认按格式：epub 20MB / 其他 32MB）
--         · 用户自定义「从多少页 / 多少 MB 开始降级」。
--
--   ★ 完整模式（默认）下的行为：
--     规模在安全线内 → 精确统计；
--     规模超安全线   → **拒绝并说明原因**（"这本书太大…点『允许降级』可抽样估算"），
--                      绝不在内存不足时硬跑 ⇒ 不会触发重启。
local DEFAULT_DOWNGRADE_PAGES = 20000

--- 是否允许「自动降级」。（默认 false = 完整优先，不够就断）
local function downgradeEnabled()
    local v = G_reader_settings and G_reader_settings:readSetting("word_count_downgrade_enabled")
    return v == true   -- 只有显式设成 true 才允许
end

--- 用户自定义的「降级触发页数」。
local function downgradePages()
    local v = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_pages"))
    -- ★★★ 1.2：同样只认「> 0」。
    --   `if v or DEFAULT` 在 v == 0 时会返回 0 ⇒ `total_pages > 0` 恒真
    --   ⇒ 完整模式下每本书都被判「页数超限」（允许降级则全部变抽样，
    --   禁止降级则全部被拒绝统计）。0 对「上限」而言不是有意义的输入。
    if v and v > 0 then return v end
    return DEFAULT_DOWNGRADE_PAGES
end

-- ★★★ 33-read-page-perf：逐页字数表的**容量上限**。
--
--   动机：`job.page_units` 与持久化的 `read_state.page_units` 都是
--   **每页一条**的表（键=xpointer，值=该页字数）。页数越多，两张表越大。
--   一本几万页的「亿字书」：
--     · 表本身几万条 entry，Lua table 每条至少几十字节 ⇒ 数 MB 常驻；
--     · 键是**完整 xpointer 字符串**（`x:xpointer(/body/DocFragment[1]/body/p[12345].0)`，
--       每条约 60~80 字节）⇒ 几万条就是 2~5 MB 的**字符串**，
--       而且这些字符串还要被序列化进 sidecar 落盘（再翻倍）。
--   KPW4 只有 512MB，叠加 crengine 自己的内存，很容易把设备推向 OOM
--   —— 表现就是用户说的「亿字的会卡顿然后重启」。
--
--   取舍：**超过上限就不再记逐页明细**，但**总字数照常精确统计**。
--   逐页明细唯一的作用是「已读字数」（读到哪页算多少字），
--   对一本几万页的书，少记一部分页的字数只会让「已读字数」略偏低，
--   远比整机重启可接受 —— 这与 31-huge-book-guard 的取舍原则一致：
--   **宁可功能降级，绝不让设备重启。**
--
--   50000 页是个很宽松的界（正常长篇 1000~3000 页），
--   真正会触发它的只有「几万页」这一类极端书，正是我们要保护的场景。
local MAX_TRACKED_PAGES = 50000

-- ★★★ 28-kpw4-tuning：批量统计的自动降级阈值。
--
--   问题：Bookshelf 里一次选 50 本批量统计，如果每本都走完整扫描，
--        就是「连续跑满 CPU 好几分钟」——KPW4 会明显发烫、掉电很快。
--        用户实测反馈中对这点最敏感。
--
--   做法：这一批的**待统计本数 ≥ 阈值**时，整批自动切到抽页模式。
--        （阈值取 5：小批量 2-4 本，用户多半是有针对性地要精确数字，
--         完整扫描也就十几秒，不打扰他；5 本以上明显是「批量过一遍」，
--         要的是大致数字，省电优先。）
--
--   ★ 关键：这是**只影响这一批**的临时降级，不写进 G_reader_settings。
--     否则用户批量统计一次就把自己的全局偏好改掉了，下次单本统计
--     会意外变成估算 —— 那是很讨厌的副作用。
--
--   ★ 已经在处理缓存命中的书：那些书根本不扫描，所以阈值判断用
--     「本批总数」而不是「实际要扫的本数」是保守的（可能多降级几本），
--     但保守方向是省电，可接受。要精确统计随时可以单本重扫。
--
-- ★★★ 1.8-batch-threshold-config：**本数阈值改为用户可调**（用户要求）。
--
--   原话：「多选书籍统计没必要放阈值限制」→ 采纳为**可自己调**：
--     · 默认仍是 5（老行为，省电优先）；
--     · 用户可在菜单改大（如 20 本才降级），或设为 **0 = 关闭这条规则**
--       （多选也严格按「完整模式」精确扫，慢/费电但数字精确）。
--   ★ 只影响「本批是否自动降级」，不改全局扫描模式 —— 与 28 的原则一致。
local DEFAULT_BATCH_SAMPLE_THRESHOLD = 5
--- 本批自动降级为抽样的「本数阈值」（用户可调）。
--- 读全局设置 `word_count_batch_sample_threshold`：
---   · 未设 / 非法 → 默认 5
---   · 0          → **关闭**自动降级（多选也不按本数降级）
---   · > 0        → 本批总数 ≥ 该值才降级
local function batchSampleThreshold()
    local v = G_reader_settings
        and tonumber(G_reader_settings:readSetting("word_count_batch_sample_threshold"))
    if v == nil then return DEFAULT_BATCH_SAMPLE_THRESHOLD end
    if v < 0 then return 0 end
    return math.floor(v)
end
--- 这条规则是否处于「关闭」状态（阈值为 0）。
local function batchThresholdDisabled()
    return batchSampleThreshold() == 0
end
-- 兼容旧引用：其余代码里若还写着 BATCH_SAMPLE_THRESHOLD，统一指向默认值。
local BATCH_SAMPLE_THRESHOLD = DEFAULT_BATCH_SAMPLE_THRESHOLD

--- 读取用户选择的统计模式（存在全局设置里）。
--- ★★★ 36-full-by-default：默认 full（精确 + 进度条）。
---   用户要的是「真的统计一次、看得见进度条、给精确数字」；
---   想省电可在菜单切 sample，选择会被记住。
local function countMode()
    local mode = G_reader_settings and G_reader_settings:readSetting("word_count_scan_mode")
    if mode == MODE_SAMPLE or mode == MODE_FULL then return mode end
    return MODE_FULL
end

--- 模式的显示名（菜单 / 提示文案用）。
local function scanModeName(mode)
    if mode == MODE_SAMPLE then
        return T(_("抽页估算（前 %1 页，省电）"), SAMPLE_PAGES)
    end
    return _("完整扫描（精确）")
end

local function fileFingerprint(path)
    local attr = path and lfs.attributes(path)
    if type(attr) ~= "table" then return nil, nil end
    return tonumber(attr.modification), tonumber(attr.size)
end

--- ★★★ 缓存查询（24-cache-reuse）—— 「统计完为什么要再统计一遍」的根因修复。
--
-- 老代码的问题：`startCount` / `startCountForPath` **从不查缓存**，
-- 无论这本书统计过多少次、文件有没有变，点一次就从头扫一遍。
-- 缓存（KEY_COUNT/KEY_MTIME/KEY_SIZE）其实一直在写，但只有
-- `showSavedStats`（「查看字数与阅读速度」那个菜单项）会读它。
-- 于是用户看到的现象就是「明明统计过了，每次还要重新统计一遍」。
--
-- 这个函数负责回答：「这本书的缓存还有效吗？」
--   有效 → 直接返回缓存的字数，调用方跳过扫描。
--   无效 → 返回 nil，调用方照常扫描。
--
-- 判据是**文件指纹**（mtime + size）：
--   文件的修改时间与大小都没变，就认为内容没变，缓存可用。
--   任何一项变了（换了文件、改了内容、重新下载）都视为失效 → 重扫。
--
-- ★ 为什么用「mtime + size」而不是只比 size：
--   只比 size 的话，改了一个字、size 恰好不变的编辑会漏检。
-- ★ 为什么不是「只比 mtime」：
--   有些同步工具（Calibre / 网盘）会保留原 mtime，此时 mtime 相同但内容已换，
--   加上 size 一起比能多挡一层。
--
-- @param prefer_settings 可选；调用方已知的 DocSettings 实例（如 self.ui.doc_settings）。
--        给了就优先用它 —— 因为 KOReader 的 sidecar 可能有多个候选位置
--        （doc / dir / hash），`DocSettings:open()` 会挑 MRU 的那个，
--        而我们写入时用的是当时那个实例。若两边挑到不同文件，缓存就永远读不到。
-- ★★ 优先放在 G_reader_settings 里（全局单文件，路径无歧义），
--    只有那里没有时才回落到 DocSettings。这样缓存命中率最稳。
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
            -- ★ 26：第三个返回值告诉调用方这是不是估算值
            return tonumber(e.count), prefer_settings, e.estimated == true
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
    local ok_c, saved_count = pcall(settings.readSetting, settings, KEY_COUNT)
    if not (ok_m and ok_s and ok_c) then return nil end

    if tonumber(saved_mtime) ~= mtime then return nil end
    if tonumber(saved_size)  ~= size  then return nil end
    local count = tonumber(saved_count)
    if not count or count <= 0 then return nil end
    -- ★ 旧数据没有 KEY_ESTIMATED 键 → readSetting 返回 nil → 当作精确值（向后兼容）
    local ok_e, saved_est = pcall(settings.readSetting, settings, KEY_ESTIMATED)
    return count, settings, (ok_e and saved_est == true) or false
end

--- 把统计结果写进**全局缓存**（键 = 文件路径，值 = 指纹 + 字数）。
-- 与 DocSettings 并存：DocSettings 保留是为了兼容旧的「已读统计」数据结构，
-- 全局缓存是为了让「统计过就不再扫」这件事有一个**无歧义、必定读得到**的家。
local function writeCachedCount(path, count, mtime, size, estimated)
    if type(path) ~= "string" or path == "" then return false end
    count, mtime, size = tonumber(count), tonumber(mtime), tonumber(size)
    if not count or count <= 0 or not mtime or not size then return false end
    if not (G_reader_settings and type(G_reader_settings.saveSetting) == "function") then
        return false
    end
    local ok_read, t = pcall(G_reader_settings.readSetting, G_reader_settings, KEY_CACHE)
    if not ok_read or type(t) ~= "table" then t = {} end
    t[path] = {
        count = count, mtime = mtime, size = size, at = os.time(),
        -- ★ 26：估算标记。false 时也显式写出来，便于排查「为什么标了约」
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

--- 删除某本书的**统计缓存**（全局缓存 KEY_CACHE 里那一条）。
--
--  ★★★ 1.2：供「取消统计」使用 —— 用户要求「取消时把**未完成的**缓存清掉，
--   已完成的保留」（多选 5 本，扫到第 3 本取消 → 前两本保留、第 3 本清除）。
--
--  为什么需要它：
--    扫描**中途**取消时，第 3 本书可能已经写了一部分状态（或根本没写），
--    但更关键的是**不能让一个「扫了一半」的结果留在缓存里冒充完整结果**。
--    清掉它，下次统计这本书会重新完整扫描，得到正确数字。
--
--  ★ 与 DocSettings sidecar 的关系：
--    缓存有「全局 KEY_CACHE」与「DocSettings sidecar」两个家（见 readCachedCount）。
--    这里**两个都清**，否则全局清了、sidecar 还在，读缓存时又会命中旧值
--    （readCachedCount 第 ① 步查全局，查不到才回落 ②，但 sidecar 里的
--     旧 KEY_COUNT 若指纹仍匹配就会被当成有效结果 —— 那是「取消没生效」）。
--
--  @return boolean 是否确实清掉了（或本来就无缓存）
local function removeCachedCount(path, prefer_settings)
    if type(path) ~= "string" or path == "" then return false end

    -- ① 全局缓存：删掉这个 path 的那一条，其余条目**原样保留**（不要整表清空！
    --    那样会把其他已完成的书也一起清掉 —— 正是用户明确要求避免的）。
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local ok, t = pcall(G_reader_settings.readSetting, G_reader_settings, KEY_CACHE)
        if ok and type(t) == "table" and t[path] ~= nil then
            t[path] = nil
            local ok_save = pcall(G_reader_settings.saveSetting, G_reader_settings, KEY_CACHE, t)
            if ok_save then pcall(G_reader_settings.flush, G_reader_settings) end
        end
    end

    -- ② DocSettings sidecar：清掉四个键（count / mtime / size / estimated），保留其他设置。
    --
    -- ★★★ 1.2-bugI：**prefer_settings 必须先验明「它是不是 path 那本书的」**。
    --
    --   ☠ 真 bug（1.2 排 bug 轮发现）：
    --     调用方（cancelCount / _startNextBatch 的收尾）传进来的常常是
    --     `self.ui.doc_settings` —— 那是**当前打开着的那本书**的 settings。
    --     批量场景下它们往往不是同一本：
    --       用户在书库里、正在读 A，批量扫到 C 时点「取消」
    --       ⇒ 传进来的 settings 属于 A，而我们要清的是 C。
    --       旧代码无条件用 prefer_settings ⇒ **删掉了 A 的 count/mtime/size**
    --       ⇒ 用户回头打开 A，字数没了、要重扫；而 C 的 sidecar 一点没动。
    --     这正是「清了不该清的、放过该清的」，两个方向都错。
    --
    --   判据：DocSettings 实例上能读回它自己的 path（上游 DocSettings 有
    --     `self.file`；也兼容 `getFilePath()`）。只有当它与 path 一致时才用它，
    --     否则老老实实 `DocSettings:open(path)` 打开正确的那个。
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
        pcall(settings.delSetting, settings, KEY_MTIME)
        pcall(settings.delSetting, settings, KEY_SIZE)
        pcall(settings.delSetting, settings, KEY_ESTIMATED)
        pcall(settings.flush, settings)
    end
    return true
end


--- 统一提示入口：显式构造 Notification 实例并 show。
--- （原因见下方 notify_source 的说明：模块级 `Notification:notify` 会被静默吞。）
---
--- ★★★ 35-forward-local-fix：本函数**必须定义在所有调用点之前**。
---   33 版把它放在第 1066 行，而 `notifyCached`（上面）就调用了它 ——
---   Lua 的 `local function` 只从声明处往后可见，导致那两处解析成 nil 全局：
---       attempt to call global 'notifyUser' (a nil value)
---   与 fmtCount 是同一类致命 bug，一起修掉。
---   回归测试：_verify/no_forward_local.lua。
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
        UIManager:show(Notification:new{
            text = tostring(text or ""),
            timeout = timeout or 2,
        })
    end)
end

--- 千分位格式化：1234567 → "1,234,567"。
---
--- ★★★ 35-forward-local-fix：这个函数**必须定义在所有调用点之前**。
---   33 版把它写在了 `notifyCached` **下面**（第 752 行），而 `notifyCached`
---   在第 740/743/748 行就调用了它 —— Lua 的 `local function` 只从声明处
---   往后可见，所以那三处调用实际解析成**全局** `fmtCount`（nil），
---   一进「读缓存」分支就报：
---       main.lua:743: attempt to call global 'fmtCount' (a nil value)
---   用户设备截图就是这个（字数统计启动失败 + 整段 stack traceback）。
---   修法：把定义整体上移到 `notifyCached` 之前，并配回归测试
---   `_verify/no_forward_local.lua`（扫全文件：任何 `fmtCount` 调用点行号
---   都必须大于它的定义行号）。
local function fmtCount(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local rev = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (rev:gsub("^,", ""))
end

--- 轻量提示：告知「用的是缓存」并给出数字，不弹对话框、不扫描。
--- @param estimated  这个缓存值是不是抽页估算出来的（26-sample-estimate）。
---                   true 时明说「估算」并提示怎么拿到精确值。
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
        -- ★★★ 37h：菜单里的「重新统计」已删除 ⇒ 文案改成指「统计本书字数」
        --   （该入口现在自带 force_rescan，点了就会精扫）。
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

--- ★★ 打开一个「后台文档」并把它**准备好**，让 getPageCount() 能返回真实页数。
--
-- 为什么必须有这个函数（这是「页数=0，无法统计」的根因）：
--
--   对 EPUB / HTML / FB2 / TXT 这类由 crengine 渲染的文档，
--   `DocumentRegistry:openDocument(path)` **只是创建了对象并登记进 registry**，
--   **完全没有加载文件内容**。frontend/document/credocument.lua:177-180 的注释
--   把这件事写得很直白：
--
--       -- We would have liked to call self._document:loadDocument(self.file)
--       -- here, to detect early if file is a supported document, but we
--       -- need to delay it till after some crengine settings are set for a
--       -- consistent behaviour.
--
--   而 `Document:getPageCount()` 返回的是 `self.info.number_of_pages`，
--   这个字段由 `self._document:getPages()` 在 **loadDocument + render 之后**
--   才会有值（document.lua:204）。所以：
--
--       doc = DocumentRegistry:openDocument(path)
--       doc:getPageCount()          -->  0        ← 就是这个「0」
--
--   ReaderUI 的正常流程是（apps/reader/readerui.lua:330-345）：
--       1) doc:setupDefaultView()   -- 读 cr3.ini 默认值，必须在 loadDocument 之前
--       2) doc:loadDocument()       -- 真正读文件
--       3) doc:render()             -- 排版分页 → number_of_pages 才有值
--   本函数把这三步补齐。
--
-- 幂等性：三个上游方法各自都有 `if not self.loaded` / `if not self._loaded`
-- 保护，重复调用是安全的；对已经在阅读器里打开的同一文档也安全
-- （此时它早就 load+render 过了，再调等于空转）。
--
-- 非 CRE 文档（PDF/DJVU 等）：没有这几个方法，直接跳过，走原本的路径。
--
-- ★★★ 31-huge-book-guard —— 「亿字书统计时卡死 → 自动重启」的根因修复。
--
-- 症状（用户报告）：
--   一本几万页的 EPUB，「统计字数」时**进度条不动、整机没反应，
--   很久后自己重启**；重试一次又重启。
--
-- 根因：本函数第 3 步的 `doc:render()`。
--   crengine 的 `renderDocument()` 是**整本一次性排版**，而且是**同步**跑在
--   主进程里。KOReader 自己的注释（readerrolling.lua:1918-1925）说得很清楚：
--
--       with a big book and KOReader taking 120 MB, the subprocess would
--       additionally use: 60 MB when doing a simple rerendering,
--       **130 MB when doing a full load+render**
--
--   也就是说：一本大书做一次 full load+render 要额外吃 ~130MB。
--   KPW4 只有 512MB，KOReader 本体已占 ~120MB，再叠这一次 ⇒ **OOM**，
--   Linux OOM killer 杀掉 KOReader 进程 ⇒ 用户看到的就是「自动重启」。
--   而 render 期间是**同步**的，主线程卡在 C 层 ⇒ 「进度条不动、整机没反应」。
--
-- 修复（三层，从「不犯错」到「兜底」）：
--
--   ① **先看能不能不 render**：CRE 文档在 `loadDocument()` 之后，
--      `getPages()` 往往已经有值（crengine 会做惰性/增量分页，
--      `CreDocument:getPageCount()` 是**实时查询**，不是读缓存的
--      `info.number_of_pages`）。所以先 loadDocument → 探页数，
--      **拿到就直接跳过 renderDocument**，省掉最贵的那一步。
--
--   ② **超大文件硬保护**：如果探不到页数、又必须 render，
--      那就按**文件大小**判断风险。超过 HUGE_FILE_BYTES 的一律**不 render**，
--      返回明确错误让上层告诉用户「这本书太大，无法统计」。
--      —— 最坏是「功能不可用」，但**绝不至于把设备搞重启**。
--      这是有意的取舍：重启会打断用户正在看的书，代价远大于「统计不了」。
--
--   ③ 小文件才真 render，此时 §① 已经拿不到页数（少数文档），render 也快。
--
-- ★ 阈值按格式区分：
--   纯文本类（txt/fb2/html）文件大小 ≈ 内存里的文本量，32MB 已经不小；
--   EPUB 是**压缩包**，正文文本通常被压缩 2~5 倍 ⇒ 同样 32MB 的文件，
--   解压后的文本可能有 100MB+。所以对 epub 用更保守的阈值。
--
--   ★ 37k：用户要求把 epub 默认从 12MB 放宽到 20MB。
--     取舍：20MB epub 解压后正文约 40~100MB，在 KPW4（512MB，KOReader 自身
--     已占 ~120MB）上属于「可能过、也可能被 OOM 杀」的边缘区。
--     所以这里**放宽的只是默认值**，风险仍在用户手里：
--     菜单「降级触发大小」可随时改回 12MB 或更低；真正危险时拒绝逻辑照旧触发。
--     注意 20MB 仍**低于** render 硬保护线，不会让「必须 render 的极端文档」被放行。
local HUGE_FILE_BYTES = 32 * 1024 * 1024        -- 一般格式：32MB
local HUGE_FILE_BYTES_EPUB = 20 * 1024 * 1024   -- epub（压缩）：20MB

--- 按扩展名取「超大文件」阈值。
local function hugeFileThreshold(path)
    local ext = tostring(path or ""):lower():match("%.([%w]+)$")
    if ext == "epub" then return HUGE_FILE_BYTES_EPUB end
    return HUGE_FILE_BYTES
end

--- ★★★ 37j：用户自定义的「降级触发文件大小」（字节）。
--- 未设置时回落到按格式的默认阈值（epub 20MB / 其他 32MB）。
local function downgradeBytes(path)
    local v = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_mb"))
    -- ★★★ 1.2：判据必须和 hardRenderGuardBytes 完全一致（都用 `v > 0`）。
    --   旧写法是 `if v then` —— 一旦值被存成 0（或负数），
    --   downgradeBytes 会返回 0 字节 ⇒ startCount 里 `size > 0` 恒真 ⇒
    --   **每一本书都被判「超大」强制抽样**（哪怕它只有 200KB）。
    --   而同一时刻 hardRenderGuardBytes 因为用了 `v > 0` 走的是默认线 ——
    --   两处阈值语义不同，会出现「降级说超大、硬保护说不大」的矛盾现象。
    if v and v > 0 then return v * 1024 * 1024 end
    return hugeFileThreshold(path)
end

--- ★★★ 37o → 1.2：`prepareDocument` 里那条「探不到页数就拒绝 render」的**硬保护线**。
--
--   ☠ 修 「降级触发大小设了不生效」的根因 ②：
--   用户把「降级触发大小」改成 30MB，`startCount` 确实按 30 判定，
--   但 `prepareDocument` 读的却是 `hugeFileThreshold()`（写死 epub 20MB）——
--   于是 21~30MB 的书在**更早的阶段**就被判 huge，探不到页数直接拒绝，
--   连 `startCount` 都进不去。用户看到的现象就是「设了跟没设一样」。
--
--   ★★★ 1.2（用户第二轮追问后的**最终决定：完全放开**）：
--     1.0/1.1 的做法是「跟随用户设置，但**封顶在格式默认红线**」——
--     用户设 30 仍只生效到 20，实测反馈**还是「设了不生效」**。
--     用户明确要求：「完全放开，允许 render」。
--
--     ⇒ 现在：**用户设多少就是多少**，不再封顶。
--       设 30 → 30 生效；设 100 → 100 生效。
--       代价（已如实告知用户并获确认）：
--         超过默认红线后再探不到页数时，会**真的调用 render()**，
--         而 epub 全量 render 在 KPW4（512MB）上有 OOM 风险。
--       但这只在「loadDocument + 3 次重试都拿不到页数」这个**少数**情况触发；
--       绝大多数书 loadDocument 后就有页数，根本不会 render。
--
--     ★ 为什么这次不再坚持封顶：
--       上一轮的封顶逻辑出发点是「保护设备」，但它把「用户已明确表达的
--       意愿」也一起挡掉了 —— 用户看到的现象就是「设置项是个摆设」。
--       设备安全的正确落点应该是**让用户知情后自己决定**，而不是替用户否决。
--       而且封顶拦掉的那批书（21~30MB epub）恰恰是「可能能统计」的，
--       一刀切拒绝比「允许尝试」更糟。
--
--   ☠ 兼容性：未设置时仍回落到按格式默认（epub 20 / 其他 32）。
local function hardRenderGuardBytes(path)
    local v = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_mb"))
    if v and v > 0 then
        -- ★ 1.2：用户设了值 ⇒ **完全以用户为准，不封顶**。
        return v * 1024 * 1024
    end
    return hugeFileThreshold(path)
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

    -- ★ 31：loadDocument 与 render 是两步，**先把文件加载进 DOM**。
    --   crengine 在 loadDocument（full）之后通常就能给出页数，
    --   此时 renderDocument 属于纯浪费（而且是最贵的那一步）。
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

    -- ★★★ 37i2-huge-book-count：**超大书不再一律拒绝**。
    --
    --   旧行为（31）：文件 > 阈值且 loadDocument 后仍探不到页数 ⇒ 直接
    --   返回 "huge_document" 拒绝统计。用户抱怨「亿万字的书统计不成功，
    --   显示无法打开文件」——而日志显示**同一本书有时 loadDocument 后
    --   明明能拿到 pageCount=93551**（crengine 惰性分页不稳定），有时又
    --   探不到。一刀切拒绝把「其实能统计」的情况也毙掉了。
    --
    --   新行为：超大书**再给几次机会**（重试 loadDocument + 多等一会），
    --   拿到页数就走**抽样**路径（startCount 里的 PER_PAGE_SCAN_MAX_PAGES
    --   会强制抽样，不会逐页全扫）；**始终不调用 render()**（render 才是
    --   吃 130MB 内存、导致 OOM 重启的那一步）。
    --   只有反复重试仍拿不到页数，才如实报告「这本书太大」。
    --
    --   ★★★ 1.2：硬保护线 = `hardRenderGuardBytes`，**完全以用户设置为准**
    --     （不再封顶）。所以：
    --       · 用户设 30 → 21~30MB 的书**不再进 is_huge 分支**，
    --         直接走下面的正常 render 路径（用户已明确放宽，允许 render）。
    --       · 只有**超过用户设定值**的书，才走「重试 loadDocument、
    --         拿不到页数就拒绝（绝不 render）」这条保守路径。
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

    -- ★ 31 §③ / ★ 1.2：走到这里 = 文件在**用户设定线以内**，正常 render。
    --   注意 1.2 起「用户设定线」可能高于格式默认红线（如设 30MB），
    --   此时这里会真的 render 一本 25MB 的 epub —— 这是用户**明确选择**
    --   的结果（见 hardRenderGuardBytes 的注释），不再由插件代为否决。
    --   仍在 pcall 里保护：render 失败不会让整个扫描流程炸掉。
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

--- 打开后台文档并准备到可取页数的状态。
--- 返回 doc, err；失败时 doc 为 nil（调用方负责报错）。
--
-- ★ 31-huge-book-guard / ★ 1.2：prepareDocument 可能返回特殊的 "huge_document"
--   （文件超过**用户设定的线**、且反复重试仍探不到页数 → 拒绝）。
--   这种情况必须**把刚打开的文档关掉** —— 它已经 loadDocument 进内存了，
--   留着会白占内存，又会把设备推向 OOM。
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

--- KOReader 把高亮 / 书签 / 笔记统一存在 sidecar 的 "annotations" 里，
--- 每条带 datetime 字段。这里只关心条数，用来算「记录笔记」。
local function countAnnotations(settings)
    if not settings or type(settings.readSetting) ~= "function" then return nil end
    local ok, annotations = pcall(settings.readSetting, settings, "annotations")
    if not ok then return nil end
    if type(annotations) ~= "table" then return 0 end
    return #annotations
end

local function fmtDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local rest = seconds % 60
    if days > 0 then return T(_("%1天%2小时"), days, hours) end
    if hours > 0 then return T(_("%1小时%2分钟"), hours, minutes) end
    if minutes > 0 then return T(_("%1分钟"), minutes) end
    return T(_("%1秒"), rest)
end

function WordCount:init()
    -- 诊断打点：确认设备上加载的是哪一版、以及 Bookshelf 钩子装没装上。
    -- 用 logger.info（会落进 crash.log），便于出问题时直接对日志。
    logger.info("WordCount: plugin init start")
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
        -- ★★★ 1.3-bugN：只要**两条腿里任意一条**装上了就算成功。
        --   单本钩子 + 批量菜单钩子任一成立即可，不必两者都齐；
        --   批量对话框钩子（wrap BulkActions.show）失败也不阻塞（有菜单钩子兜底）。
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

--- 判断某个 widget 当前是否还在 UIManager 的显示栈上。
--- 用于「复用准备对话框」时做保险：如果它已被别处摘掉，就补一次 show()，
--- 否则 configureProgress 刷新的会是一个不在屏幕上的对象（用户看到空白）。
--- UIManager._window_stack[i] 的结构是 { widget = ..., ... }（见 uimanager.lua:233）。
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

--- ★★ 正确的「弹一条提示」写法。**不要再直接用 `Notification:notify(...)`。**
--
-- 这是一个真实、可复现、且**静默**的坑（在 KOReader v2026.07 上验证过）：
--
--   frontend/ui/widget/notification.lua:162-175
--       function Notification:notify(arg, source, refresh_after)
--           source = source or self.notify_source          -- ← 读 self 的字段
--           local mask = G_reader_settings:readSetting("notification_sources_to_show_mask")
--                        or SOURCE_DEFAULT
--           if source and (source == SOURCE_ALWAYS_SHOW or band(mask, source) ~= 0) then
--               UIManager:show(Notification:new{ text = arg })
--               return true
--           end
--           return false                                   -- ← 什么都不显示
--       end
--
--   而 `notify_source` 只在**实例**上被赋值（`Notification:init()` 第 150 行、
--   `Notification:setNotifySource()` 第 154 行）。
--   模块导出的是**类表**（`return Notification`），类表上
--   `rawget(Notification, "notify_source") == nil`。
--
--   ⇒ `Notification:notify("hi")` 在类表上冒号调用时：
--         self = 类表 → self.notify_source = nil → source = nil
--         → `if nil and ...` = false → **直接 return false，屏幕上什么都不出现**
--
--   这解释了「点了字数统计，屏幕上什么都没弹」——所有用户提示都被静默吞了。
--
-- 所以本插件统一走 `notifyUser()`：显式构造 Notification 实例并 show。
-- `_verify/notify_source.lua` 用**上游真源码**把上面这个行为断言死了。
--
-- ⚠ 唯一例外：如果**手上有 Notification 的实例**（`setNotifySource` 过的），
--   那时 `inst:notify(...)` 是合法的 —— 但那不是本插件的用法。
--
-- ★★★ 35-forward-local-fix：`notifyUser` 的定义**已上移到 `notifyCached` 之前**
--   （见文件前部），这里不再重复定义 —— 33 版把定义放在此处，导致
--   `notifyCached`（更靠前）调用它时解析成 nil 全局：
--       attempt to call global 'notifyUser' (a nil value)
--   回归测试：_verify/no_forward_local.lua。

--- 千分位格式化 fmtCount 同样已上移，这里不再重复定义。

local function runEntrySafely(fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        logger.err("WordCount: operation entry failed", err)
        UIManager:show(InfoMessage:new{
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
                            -- ★★★ 37h：用户「点击统计本书的时候自动忽略缓存重新统计」。
                            --   这个入口就是用户手动点「统计本书字数」⇒ 意图明确要重算，
                            --   直接 force_rescan=true 跳过缓存。
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

-- ★★★ 1.3-bugN：把 BulkActions 的接线从 `_installBookshelfBulkAction` 里**拆出来**，
--   并做「两条腿走路」，因为 `require("lib/bookshelf_bulk_actions")` 在本插件里
--   **不是一定能成**：
--     1) KOReader 的 PluginLoader 用 **dofile**（不是 require）加载各插件，
--        `lib/?.lua` 只在**所有插件 dofile 完之后**才追加进 package.path
--        （pluginloader.lua:283-287），而插件 `init()` 是在那之后跑的 ——
--        顺序上勉强够，但**任何一个前置模块解析失败**（例如 bookshelf 的
--        `lib/bookshelf_i18n` 又要 `logger`）就会让整条 require 链 pcall 失败，
--        于是 `if not ok ... then return end` 直接 return ⇒ **BulkActions.show
--        永远没被包裹 ⇒ 「统计选中字数」按钮永不出现**。
--        这就是用户报的「多选统计不生效」。
--     2) 即使 require 成功，Bookshelf 那边 `bookshelf_widget.lua:8337` 是
--        **每次点 bucket 时**才 `require` 一次 —— 只要它拿到的是同一个
--        `package.loaded` 表，我们的包裹就能生效；但如果包裹时机早于模块
--        首次加载，我们包裹的是**即将被缓存的那一份**，也没问题。
--        真正的风险在 (1)。
--   对策：
--     A. 先查 `package.loaded`，再 `require`，两条都记日志；
--     B. 同时挂 **BookshelfWidget._openBulkMenu** —— 这条路**完全不依赖
--        require("lib/...")**，只依赖已经拿到的 BookshelfWidget 类表
--        （widget 那条 require 在本插件里是能成的，日志已证明
--        `hasFileDialogPluginRows=true`），比直接摸 bulk 模块稳得多。
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
        local ok_bt, ButtonDialog = pcall(require, "ui/widget/buttondialog")
        if not ok_bt or type(ButtonDialog) ~= "table"
                or type(ButtonDialog.new) ~= "function" then
            logger.warn("WordCount: 批量对话框钩子无法取得 ButtonDialog："
                .. tostring(ButtonDialog))
            return original_show(opts)
        end
        local old_new = ButtonDialog.new
        local bulk_dialog
        ButtonDialog.new = function(class, args, ...)
            if type(args) == "table" and type(args.buttons) == "table"
                    and not args._wordcount_injected then
                -- 不比对按钮文案（Bookshelf 用 gettext 包了一层，中文设备上
                -- 英文原文根本不存在）；改用**形状**识别，但**不写死**只匹配
                -- 某一个 Bookshelf 发行版的形状。
                --
                -- 实测 Bookshelf（本地 E:/kindle越狱/Koreader/plugins/
                -- bookshelf.koplugin/lib/bookshelf_bulk_actions.lua）的批量
                -- 对话框是 6 行：
                --   { collections, rating }   -> 2
                --   status_row                -> 4
                --   { favorite, refresh }     -> 2
                --   { remove_history }        -> 1   ← 唯一的单按钮行
                --   { reset, delete }         -> 2
                --   { cancel, apply }         -> 2
                -- 所以「#buttons[1]==1」是 **false**；旧代码假设单按钮行在第一行，
                -- 恰好错了。现在的判据放宽成：行数够多 + 存在任一单按钮行 +
                -- 末行多按钮。已用真实源码跑通（matcher => true，按钮落在
                -- Cancel/Apply 之上）。
                local rows = args.buttons
                local has_single_row = false
                for i = 1, #rows do
                    if type(rows[i]) == "table" and #rows[i] == 1 then
                        has_single_row = true
                        break
                    end
                end
                local last_row = rows[#rows]
                local is_bulk_dialog = #rows >= 6
                    and has_single_row
                    and type(last_row) == "table" and #last_row >= 2
                if is_bulk_dialog then
                    args._wordcount_injected = true
                    table.insert(args.buttons, #args.buttons, {
                        {
                            text = _("统计选中字数"),
                            callback = function()
                                local paths = opts.selection:paths()
                                if bulk_dialog then
                                    pcall(UIManager.close, UIManager, bulk_dialog)
                                else
                                    closeCurrentModal()
                                end
                                if opts.bw and opts.bw._selection
                                        and type(opts.bw._selection.exitMode) == "function" then
                                    pcall(opts.bw._selection.exitMode, opts.bw._selection)
                                    if type(opts.bw._rebuild) == "function" then
                                        pcall(opts.bw._rebuild, opts.bw)
                                    end
                                    pcall(UIManager.setDirty, UIManager, opts.bw, "ui")
                                end
                                UIManager:nextTick(function()
                                    runEntrySafely(function()
                                        plugin:startBatchCount(paths)
                                    end)
                                end)
                            end,
                        },
                    })
                end
            end
            bulk_dialog = old_new(class, args, ...)
            return bulk_dialog
        end
        local ok_call, err = pcall(original_show, opts)
        ButtonDialog.new = old_new
        if not ok_call then error(err) end
    end
    return true
end

-- ★★★ 1.3-bugN：第二条腿 —— 直接挂 BookshelfWidget._openBulkMenu。
--   这条路不碰 `require("lib/bookshelf_bulk_actions")`，只把已经拿到的
--   BookshelfWidget 类表里那个 `_openBulkMenu` 换掉：先照原样让 Bookshelf
--   自己弹批量对话框（这样所有原生按钮一个不少），再在下一次 tick 往
--   **栈顶那个 ButtonDialog** 里补一行「统计选中字数」。
--   即使 bulk 模块 require 失败，这条腿也能让功能可用。
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
            -- ButtonDialog 的内部结构随版本而变，这里只认「有 buttons 表且
            -- 已经有多行」的形态，命中就补按钮，否则安静放弃（第一条腿若
            -- 生效，这里会因为 _wordcount_injected 已置位而自动跳过）。
            local args = top.buttons and top or nil
            local rows = nil
            if type(top[1]) == "table" and type(top[1].buttons) == "table" then
                rows = top[1].buttons           -- ButtonDialog 把 buttons 放在 [1]
            elseif type(args) == "table" and type(top.buttons) == "table" then
                rows = top.buttons
            end
            if type(rows) ~= "table" or #rows < 4 then return end
            for _i, r in ipairs(rows) do
                if type(r) == "table" then
                    for _j, b in ipairs(r) do
                        if type(b) == "table" and b.text == _("统计选中字数") then
                            return                  -- 已经有了（第一条腿干的）
                        end
                    end
                end
            end
            local selection = widget and widget._selection
            if not selection or type(selection.paths) ~= "function" then return end
            table.insert(rows, #rows, {
                {
                    text = _("统计选中字数"),
                    callback = function()
                        local paths = selection:paths()
                        pcall(UIManager.close, UIManager, top)
                        if widget and widget._selection
                                and type(widget._selection.exitMode) == "function" then
                            pcall(widget._selection.exitMode, widget._selection)
                            if type(widget._rebuild) == "function" then
                                pcall(widget._rebuild, widget)
                            end
                            pcall(UIManager.setDirty, UIManager, widget, "ui")
                        end
                        UIManager:nextTick(function()
                            runEntrySafely(function()
                                plugin:startBatchCount(paths)
                            end)
                        end)
                    end,
                },
            })
            if type(top.reinit) == "function" then pcall(top.reinit, top) end
            pcall(UIManager.setDirty, UIManager, top, "ui")
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
                            -- ★★★ 37h：显式点「统计本书字数」⇒ 忽略缓存重新统计。
                            runEntrySafely(function() plugin:startCountForPath(file, true) end)
                        end)
                    end,
                },
            }
            return rows
        end
    end

    -- ★★★ 1.3-bugN：第二条腿先挂上 —— 它只依赖 BookshelfWidget（上面那条
    --   require 已经成功过），完全不碰 lib/bookshelf_bulk_actions，最稳。
    if ok_widget and BookshelfWidget then
        local ok_menu = installBulkMenuButtonPatch(BookshelfWidget, self)
        if ok_menu then
            logger.info("WordCount: bookshelf bulk-menu button patch installed")
        end
    end

    -- ★★★ 1.3-bugN：第一条腿 —— 包裹 BulkActions.show。
    --   先看 package.loaded（Bookshelf 可能已经加载过），再尝试 require，
    --   两条都失败就**记日志**（旧代码是静默 return，正是它让这个问题
    --   在日志里完全不可见）。
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
    -- ★★★ 37i2：把**版本号**顶到菜单最上面一行：点它弹通知显示当前装的是哪一版。
    --   用户抱怨「为什么不重构版本号」——根因是插件从来不把版本显示出来，
    --   他装完新包也没法确认自己装的是新版还是旧版（zip 名又一直没变）。
    local version_text = "unknown"
    do
        local ok, meta = pcall(dofile, plugin_dir .. "_meta.lua")
        if ok and type(meta) == "table" and meta.version then
            version_text = tostring(meta.version)
        end
    end
    menu_items.word_count = {
        text = _("字数与阅读速度"),
        -- ★★★ 37p：把入口挪进**文件管理器顶部菜单的「设置」标签**
        --   （`filemanager_settings`）——用户要求放到「书籍状态 / 排序依据」
        --   那一带，而不是原来的「工具」标签。
        --
        --   ★ 机制说明（别再踩）：插件在顶部菜单里的归属**不是自由坐标**，
        --     而是由 `sorting_hint` 指定一个**已有分组名**，再由
        --     `MenuSorter:mergeAndSort("filemanager", ...)` 按
        --     `ui/elements/filemanager_menu_order.lua` 的分组顺序摆放。
        --     所以「插到某两项之间」做不到；能做的是换分组。
        --     · "tools"               → 工具标签（原来的位置）
        --     · "filemanager_settings"→ 设置标签，与 sort_by / show_filter 同组
        --                               ⇒ 就是「排序依据」所在的那一带 ✅
        sorting_hint = "filemanager_settings",
        sub_item_table = {
            {
                -- ★ 版本号：点一下弹通知，方便核对装的是哪一版。
                text_func = function()
                    return T(_("版本：%1"), tostring(version_text))
                end,
                callback = function()
                    notifyUser(T(_("字数与阅读速度\n当前版本：%1\n（点此可确认装的是最新包）"),
                        tostring(version_text)), 5)
                end,
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
                -- ★★★ 37n：显式点「统计全书字数」= 用户明确要求**现在重新统计一次**。
                --   旧写法传 false 走缓存：用户改完「降级触发大小/页数」再点这里，
                --   命中缓存就直接弹「已使用缓存结果」return —— startCount 里的
                --   阈值判断**根本没被执行**，用户看到的现象就是
                --   「设置在菜单里改了，但点统计毫无变化 ⇒ 设置没生效」。
                --   （37j~37l 一直如此，这是本轮修的根因。）
                --   ⇒ 与 37h 的「统计本书字数」入口保持一致：传 true，跳过缓存重扫。
                text = _("统计全书字数"),
                callback = function() self:startCountFromMenu(true) end,
            },
            -- ★★★ 37h：用户「字数与统计中的重新统计可以删掉了」——
            --   删除「忽略缓存重扫」那一项菜单。需要重算时直接在书/文件上
            --   点「统计本书字数」（见 37h：该入口现在自带 force_rescan）。
            {
                text = _("查看字数与阅读速度"),
                callback = function() self:showSavedStats() end,
            },
            {
                -- ★★★ 37o：单位显示 —— 改成二级菜单选择（原来是点一下循环切换）。
                text_func = function() return self:unitFormatLabel() end,
                sub_item_table_func = function() return self:unitFormatSubMenu() end,
            },
            {
                -- ★★★ 37o：统计模式 —— 同样改成二级菜单选择。
                --   完整扫描：逐页精确，大书慢、耗电。
                --   抽页估算：只扫前 SAMPLE_PAGES 页，按比例放大到全书，
                --            快很多、省电，但数字是「约」值。
                text_func = function() return self:scanModeLabel() end,
                sub_item_table_func = function() return self:scanModeSubMenu() end,
            },
            {
                -- ★★★ 37o：大书处理方式 —— 原来是「点一下开关」的 toggle，
                --   用户要求「降级的选项能不能自己选」⇒ 改成二级菜单单选：
                --     · 超限直接取消（默认，最安全，绝不 OOM）
                --     · 超限自动降级为抽样估算（要速度/省电时选）
                --   比 toggle 好在：一眼能看清有哪两种行为、当前选的是哪个，
                --   而且选中项的 desc 会把「代价」写清楚（toggle 只有一行标签）。
                text_func = function() return self:downgradeEnabledLabel() end,
                sub_item_table_func = function() return self:downgradeModeSubMenu() end,
            },
            -- ★★★ 37j/37l：两个阈值（页数 / 大小）挪进「降级阈值」二级菜单里，
            --   一级菜单只留一行，少占屏幕。
            {
                text_func = function() return self:downgradeThresholdLabel() end,
                sub_item_table_func = function() return self:downgradeThresholdSubMenu() end,
            },
            -- ★★★ 1.8-batch-threshold-config：多选「本数阈值」单独一行，
            --   因为它管的是「多选时按本数降级」，与上面按单本规模的降级不同。
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

--===========================================================================
-- ★★★ 37j：大书降级 / 拒绝 —— 用户可调的三个设置
--===========================================================================

--- 「允许大书自动降级」的开关标签。
function WordCount:downgradeEnabledLabel()
    if downgradeEnabled() then
        return _("大书处理：超限转抽样估算")
    end
    return _("大书处理：超限直接取消（防重启）")
end

--- ★★★ 37o：大书处理方式的 radio 子菜单（替代原来的 toggle）。
function WordCount:downgradeModeSubMenu()
    return {
        {
            text = _("超限直接取消统计"),
            desc = _("最安全。超过阈值的书不统计，绝不会耗尽内存重启设备。"),
            checked_func = function() return downgradeEnabled() ~= true end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting("word_count_downgrade_enabled", false)
                G_reader_settings:flush()
            end,
        },
        {
            text = _("超限改用抽样估算"),
            desc = T(_("超过 %1 页或 %2 的书只扫前 %3 页再按比例外推，"
                .. "快且省电，但数字为「约」。"),
                fmtCount(downgradePages()), self:downgradeMbLimitText(), SAMPLE_PAGES),
            checked_func = function() return downgradeEnabled() == true end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting("word_count_downgrade_enabled", true)
                G_reader_settings:flush()
            end,
        },
    }
end

--- ★★★ 37o：降级阈值的二级菜单（页数 / 大小两项，点进去弹输入框）。
---   一级菜单不再平铺两行，省屏幕；父项 text_func 同时回显两个当前值。
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

--- 降级阈值菜单的父项标签（两个值一起回显）。
function WordCount:downgradeThresholdLabel()
    return T(_("降级触发阈值：%1 页 / %2"),
        fmtCount(downgradePages()), self:downgradeMbLimitText())
end

--- ★ 37o：`toggleDowngradeEnabled` 已删除 —— 大书处理方式改由
---   `downgradeModeSubMenu` 的 radio 子菜单直接写入 `word_count_downgrade_enabled`。
---   （旧的「点一下开关 + 弹通知」被二级菜单取代：菜单本身用单选勾告诉用户
---     当前选的是哪个，再弹通知纯属噪音。）

--- ★ 37n：当前生效的「降级触发大小」文字（含按格式默认时的实际值）。
---   供菜单旁白 / 提示回显用，让用户能一眼确认设置生效。
---
---  ★★★ 1.2：**回显如实反映「实际生效的线」**。
--
--   1.0/1.1 的回显在用户设 30 时会附注「epub 实际按 20 MB 安全线」，
--   因为那时硬保护线是**封顶**的。1.2 起改为**完全放开、不封顶**，
--   所以回显也要跟着改：用户设多少就报多少，并**如实提示风险**
--   （超过默认红线后，极端情况下会真 render，KPW4 有 OOM 风险）。
--
--   规则：
--     · 未设         → 报按格式默认（epub 20 / 其他 32）
--     · 设了值       → 报用户的值；若超过该格式默认红线，附一句风险提示
function WordCount:downgradeMbLimitText()
    local mb = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_mb"))
    local epub_mb = math.floor(HUGE_FILE_BYTES_EPUB / 1024 / 1024)
    local other_mb = math.floor(HUGE_FILE_BYTES / 1024 / 1024)
    if mb and mb > 0 then
        if mb > epub_mb then
            -- 超过 epub 默认红线：如实提示「这是放宽后的值，极端情况可能变慢/重启」
            return T(_("%1 MB（自定义，已放宽；超过 epub 默认 %2 MB，"
                .. "极端大书可能需要更多时间或内存）"),
                tostring(mb), tostring(epub_mb))
        end
        return T(_("%1 MB（自定义）"), tostring(mb))
    end
    return T(_("epub %1 MB / 其他 %2 MB（按格式默认）"),
        tostring(epub_mb), tostring(other_mb))
end

--- ★ 37n：档位常量已删除 —— 两个阈值入口都只留 取消 / 默认 / 确定。
---   （旧常量 DOWNGRADE_PAGE_STEPS / DOWNGRADE_MB_STEPS_INPUT 已随快捷按钮一起移除。）
--- 合法区间（防手滑输入 0 或天文数字让判断失效）。
local DOWNGRADE_PAGES_MIN, DOWNGRADE_PAGES_MAX = 100, 10000000

function WordCount:downgradePagesLabel()
    return T(_("降级触发页数：%1 页"), fmtCount(downgradePages()))
end

--- 应用一个页数阈值（带校验）。
--- @return boolean ok, string msg
local function applyDowngradePages(v)
    v = tonumber(v)
    if not v or v ~= math.floor(v) then
        return false, _("请输入整数页数")
    end
    if v < DOWNGRADE_PAGES_MIN or v > DOWNGRADE_PAGES_MAX then
        return false, T(_("页数需在 %1 ~ %2 之间"),
            fmtCount(DOWNGRADE_PAGES_MIN), fmtCount(DOWNGRADE_PAGES_MAX))
    end
    G_reader_settings:saveSetting("word_count_downgrade_pages", v)
    G_reader_settings:flush()
    return true, T(_("降级触发页数：%1 页"), fmtCount(v))
end

--- ★ 37n：手动输入「降级触发页数」。
---   与大小阈值同款：只留 取消 / 默认 / 确定 三个按钮（去掉那一排档位快捷按钮）。
---   「默认」= 恢复 DEFAULT_DOWNGRADE_PAGES（点一下直接生效并关框）。
function WordCount:editDowngradePages()
    local InputDialog = require("ui/widget/inputdialog")
    local cur = downgradePages()

    local dialog
    dialog = InputDialog:new{
        title = _("降级触发页数"),
        description = T(_("超过此页数的大书按下面的设置处理。\n当前：%1 页（默认 %2）"),
            fmtCount(cur), fmtCount(DEFAULT_DOWNGRADE_PAGES)),
        input = tostring(cur),
        input_type = "number",
        input_hint = T(_("%1 - %2"),
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
                    text = _("默认"),
                    callback = function()
                        local ok, msg = applyDowngradePages(DEFAULT_DOWNGRADE_PAGES)
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
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 降级触发文件大小的合法区间（MB）。
local DOWNGRADE_MB_MIN, DOWNGRADE_MB_MAX = 1, 100000

function WordCount:downgradeMbLabel()
    return T(_("降级触发大小：%1"), self:downgradeMbLimitText())
end

--- 应用一个「降级触发大小」（MB，带校验）。v 为 nil/0 表示恢复按格式默认。
--- @return boolean ok, string msg
local function applyDowngradeMb(v)
    if v == nil or v == 0 then
        G_reader_settings:delSetting("word_count_downgrade_mb")
        G_reader_settings:flush()
        return true, _("降级触发大小：按格式默认（epub 20MB / 其他 32MB）")
    end
    v = tonumber(v)
    if not v or v ~= math.floor(v) then
        return false, _("请输入整数 MB")
    end
    if v < DOWNGRADE_MB_MIN or v > DOWNGRADE_MB_MAX then
        return false, T(_("大小需在 %1 ~ %2 MB 之间（填 0 恢复默认）"),
            DOWNGRADE_MB_MIN, DOWNGRADE_MB_MAX)
    end
    G_reader_settings:saveSetting("word_count_downgrade_mb", v)
    G_reader_settings:flush()
    return true, T(_("降级触发大小：%1 MB"), tostring(v))
end

--- ★ 37n：手动输入「降级触发大小」（MB）。
---   用户要求：「设置 mb 限制的时候没必要给选项，只需要取消 / 默认 / 确定就可以了」
---   ⇒ 去掉那一排档位快捷按钮（8/12/20/.../500），只留三个按钮：
---     取消 = 不保存；默认 = 恢复按格式默认（= 清掉设置）；确定 = 保存输入值。
---   ★ 「默认」按钮直接生效并关框（不再只是把输入框填成 0 让用户再点确定）——
---     少一步操作，也就不存在「填了 0 但忘了点确定」这种看起来没生效的情况。
function WordCount:editDowngradeMb()
    local InputDialog = require("ui/widget/inputdialog")
    local cur = G_reader_settings and tonumber(G_reader_settings:readSetting("word_count_downgrade_mb"))

    local dialog
    dialog = InputDialog:new{
        title = _("降级触发大小"),
        description = T(_("超过此大小的书按上面的设置处理。\n当前：%1\n"
            .. "填 0 或点「默认」= epub 20MB / 其他 32MB。"),
            (cur and (tostring(cur) .. " MB")) or _("按格式默认")),
        input = cur and tostring(cur) or "0",
        input_type = "number",
        input_hint = T(_("%1 - %2 MB，0=默认"), DOWNGRADE_MB_MIN, DOWNGRADE_MB_MAX),
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
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--===========================================================================
-- ★★★ 1.8-batch-threshold-config：多选「本数阈值」用户可调
--===========================================================================
--
--  用户原话：「多选书籍统计没必要放阈值限制」。
--  采纳为「可自己调」：
--    · 默认 5（老行为）；
--    · 可改大（如 20 = 20 本以上才降级）；
--    · 可设 0 = **完全关闭**这条规则（多选也精确扫，数字不带「约」）。
--
--  ★ 只影响「本批是否自动降级」，不动全局扫描模式。
--    —— 所以用户在菜单把扫描模式设成 full 后，只要这里设 0，多选就一定能精确。

--- 多选本数阈值的合法区间（本）。0 是特殊值 = 关闭。
local BATCH_THRESHOLD_MIN, BATCH_THRESHOLD_MAX = 0, 10000

--- 菜单标签（一行回显当前值 + 语义）。
function WordCount:batchThresholdLabel()
    local v = batchSampleThreshold()
    if v == 0 then
        return _("多选本数阈值：已关闭（多选也精确）")
    end
    return T(_("多选本数阈值：%1 本起改用估算"), v)
end

--- 应用一个本数阈值（带校验）。0 = 关闭。
--- @return boolean ok, string msg
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

--- 手动输入「多选本数阈值」。
---   与页数/大小阈值同款：只留 取消 / 默认 / 确定 三个按钮。
---   「默认」= 恢复 DEFAULT_BATCH_SAMPLE_THRESHOLD（点一下直接生效并关框）。
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
    UIManager:show(dialog)
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

--- ★★★ 37o：单位显示 / 统计模式改成**二级菜单选择**。
--
--   用户反馈：「那个单位显示，以及统计模式都可以进入下级页面进行选择，
--              比点一下切换要方便」——
--   旧的 `cycleUnitFormat` / `cycleScanMode` 是「点一下轮到下一个」，
--   想从 auto 切到 wan 要点两次，而且点之前不知道有哪几个选项。
--   改成 KOReader 标准的 **radio 子菜单**（与上游「Back to exit」同款写法）：
--     · 父项 `text_func` 回显当前选中值；
--     · 子项 `radio = true` + `checked_func` 画出单选框；
--     · 子项 `callback` 直接写入该值（菜单自动刷新勾选状态、不关菜单）。
--
--   ★ 坑（踩过才知道）：子项**不要**设 `keep_menu_open = true`。
--     touchmenu.lua:896 的逻辑是「有 checked_func 就自动 updateItems() 刷新 +
--     菜单保持打开」；再显式设 keep_menu_open 反而走不到那条分支，
--     勾选状态不会即时更新。所以照上游 `genGenericMenuEntry` 的写法即可。
--
--   单位显示的选项与 `bookshelf_integration.lua:formatUnits` /
--   `statistics_page.lua:unitFormatMode` 的取值一一对应。
--
--   ★★★ 37r：按用户要求扩成 5 项 —— 「完整数字 / k / 千 / 万」，
--   并保留「自动」作为默认；`desc` 会在选项下方以灰色小字显示，
--   用户**选之前**就能看懂每种模式长什么样（这是用户明确要的
--   「自动后面加介绍」）。
--   ⚠ 每加/改一项，三处口径都要跟着改：
--       本文件 UNIT_FORMAT_OPTIONS / unitFormatMode / setUnitFormat
--       bookshelf_integration.lua:formatUnits
--       statistics_page.lua:unitFormatMode / formatCount / formatCountParts
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

--- 当前单位显示模式（带兜底，非法值一律当 auto）。
function WordCount:unitFormatMode()
    local mode = G_reader_settings and G_reader_settings:readSetting("word_count_unit_format")
    if mode == "full" or mode == "wan" or mode == "auto"
            or mode == "k" or mode == "qian" then
        return mode
    end
    return "auto"
end

--- 写入单位显示模式。原来还有个 `cycleUnitFormat` 已随二级菜单一起删除。
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

--- 构造「单位显示」的 radio 子菜单。
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

--- ★★★ 37o：写入统计模式（原 `cycleScanMode` 已随二级菜单删除）。
--
--   ⚠ 注意这里与「单位显示」不同：**不弹通知**。
--   改单位是纯显示层的事，弹一下告诉用户选了什么无所谓；
--   但统计模式改变的是**扫描行为**，用户从二级菜单里挑完，
--   菜单本身已经用单选勾明确回答了「现在选的是哪个」，
--   再弹一个通知纯属噪音（而且选完还要手动关）。
--   真正需要提醒的是「已缓存的结果仍按原模式」这件事 ——
--   那条信息已经写进子菜单的 `desc` 里（见 scanModeSubMenu），
--   在用户**做选择之前**就能看到，比事后弹窗更有用。
function WordCount:setScanMode(mode)
    if mode ~= MODE_FULL and mode ~= MODE_SAMPLE then return end
    G_reader_settings:saveSetting("word_count_scan_mode", mode)
    G_reader_settings:flush()
end

function WordCount:scanModeLabel()
    return T(_("统计模式：%1"), scanModeName(countMode()))
end

--- 构造「统计模式」的 radio 子菜单。
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

function WordCount:_globalStore()
    if self._global_stats then return self._global_stats end
    local saved = G_reader_settings and G_reader_settings:readSetting(KEY_GLOBAL_STATS)
    self._global_stats = GlobalStats.normalize(saved)
    -- ★★★ 36：数据版本号 —— 统计页的结果缓存（见 statistics_page 的 statMemoKey）
    --   用它做失效判据：只要 store 有新写入就 +1，缓存自动作废。
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
        -- ★★★ 36：写完就让统计结果缓存失效（统计页下次打开/重建会重算一次）。
        self._global_stats_rev = (self._global_stats_rev or 0) + 1
        self._global_stats_flush_count = 0
    end
end

--- ★★★ 33-read-page-perf：`_bookInfo` 加了**实例缓存**。
--
--   它在阅读热路径上被频繁调用（每次翻页结算都会经 `_finishPageTimer`
--   → `_bookInfo`）。老实现每次都可能走 `DocSettings:open(path)` ——
--   那要遍历 sidecar 的 11 个候选位置，是实打实的磁盘 I/O。
--
--   现在按 **path** 缓存那本已打开的 settings 实例：
--     · 同一本书连续调用 ⇒ 第二次起零 I/O；
--     · 换书时自动失效（键就是 path）。
--   ★ 缓存的是「当前正在读的那本的 settings」，所以只保留一项即可 ——
--     没必要做 LRU（同时打开的书只有一本）。
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
    -- ★ 37l-mem：这份缓存是**按 path 累加**的（批量统计会依次碰很多本书）。
    --   每项是一个 DocSettings 实例（带完整 sidecar 表），几百本累计起来不小。
    --   用「显式计数 + 到顶清空」控制占用：平时只是 +1 的整数操作，
    --   到 64 项整体清掉重建（无 LRU 开销；代价仅是偶尔多开一两次 sidecar）。
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
        total_units = tonumber(settings:readSetting(KEY_COUNT))
    end
    -- ★★★ 37b：调用方明确给了全书字数（例如来自全局缓存）就用它 ——
    --   「重置设置」后 DocSettings 里的 KEY_COUNT 可能已被清掉，
    --   但全局缓存 KEY_CACHE 里还有，这时必须以缓存值为准。
    total_units = tonumber(total_units_override) or total_units
    return { path = path, title = tostring(title), status = summary.status or "reading",
        total_units = total_units, date = GlobalStats.dateKey(os.time()) }
end

--- ★★★ 37m：`force_flush` 参数化。
---   旧实现硬编码 `_saveGlobalStats(false)`，调用者想强制落盘也做不到
---   （只能事后自己再补一次 `_saveGlobalStats(true)`），是脆弱设计。
---   现在把「是否立即落盘」交给调用者，与 `_saveReadState` / `_syncNotes` 一致。
function WordCount:_syncGlobalBook(state, new_page, book_path, total_units_override, force_flush)
    if not state then return end
    local info = self:_bookInfo(book_path and { file = book_path } or nil, total_units_override)
    if type(info.path) ~= "string" or info.path == "" then return end
    GlobalStats.upsertBook(self:_globalStore(), {
        path = info.path, title = info.title, status = info.status,
        total_units = info.total_units,
        read_units = tonumber(state.read_units) or 0,
        read_seconds = tonumber(state.read_seconds) or 0,
        read_pages = countReadPages(state), date = info.date, new_page = new_page == true,
    })
    self:_saveGlobalStats(force_flush == true)
end

--- ★★★ 37b：缓存命中时**补写全局聚合**。
---
--- 用户报：「统计字数依旧显示正在读取缓存内容，但依旧不显示重置过设置的书籍字数」。
--- 根因（两步）：
---   ① 「重置为默认」清空了 `G_reader_settings` —— 里面既有全局字数缓存
---      `KEY_CACHE`，也有聚合统计 `KEY_GLOBAL_STATS`。
---   ② 之后用户打开过这本书 → `_syncGlobalBook` 把 `KEY_CACHE` 里这本书的
---      **字数**补了回来（因为是按 path 逐本写的），但**「统计字数」菜单**
---      命中缓存时只弹一句「已使用缓存结果…」就 `return` 了，
---      **从不往聚合统计里写**。
---   ⇒ 表现就是：字数明明在（所以显示「读取缓存」），
---      但阅读统计总览里这本书依旧是 0（聚合里没有这条）。
---
--- 修法：任何「命中缓存」的分支，都要顺手把这本书的聚合记录补齐
---   （字数取缓存值，已读时长/字数取 DocSettings 里的阅读状态）。
---   这样重置过设置之后，只要用户碰过一次这本书（打开 / 点统计），
---   总览里就能重新看到它 —— 无需真的重扫。
---   ★ 幂等：upsertBook 是「赋值替换」不是累加，重复调用不会叠加。
function WordCount:_resyncBookFromCache(path, cached_count)
    if type(path) ~= "string" or path == "" then return false end
    local settings = cachedDocSettings(self, path)
    local state = nil
    if settings and type(settings.readSetting) == "function" then
        local ok, st = pcall(settings.readSetting, settings, KEY_READ_STATS)
        if ok and type(st) == "table" then state = st end
    end
    -- 没有阅读状态：构造一个最小 state（只有字数，时长/已读为 0），
    --   这样至少「全书字数」这一项能回到总览里。
    if not state then state = { read_units = 0, read_seconds = 0 } end
    -- ★ 主动把**缓存里的全书字数**传进去：重置后 DocSettings 的 KEY_COUNT
    --   可能已被清掉，不能指望 _bookInfo 自己从 DocSettings 读到。
    -- ★★★ 37m：这是「重置后恢复」路径，必须立即落盘（force_flush=true），
    --   否则用户重置完可能看不到恢复结果（要等 8 次才写）。
    local ok2, err = pcall(self._syncGlobalBook, self, state, false, path,
        tonumber(cached_count), true)
    if not ok2 then
        logger.warn("WordCount: resync global book from cache failed: " .. tostring(err))
        return false
    end
    return true
end

--- 「记录笔记」的采集：KOReader 的标注是每本书一个数组，我们只记增量。
--- 第一次看到某本书时先把存量写进书档案（这样"总览"能立刻显示已有笔记数），
--- 之后每次条数变化才计入当天。
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

-- ★★★ 33-read-page-perf：页 key 的**廉价版**。
--
-- 这是整个插件里被调用得最频繁的函数：每一次翻页、每一次 pos 更新
-- （`onPageUpdate` / `onPosUpdate`）都会走一趟。
--
-- 老实现每次调用都执行 `doc:getPageXPointer(page)` —— 那不是纯 Lua 查表，
-- 而是**跨 FFI 层问 crengine**（`credocument.lua` → `self._document:getPageXPointer()`，
-- 走 C++ 的 `getPageXPointer` / 段落遍历）。在 KPW4（单核 1GHz）上，
-- 一本排版较重的书单次就要几十毫秒；而它又被「翻页」这条最敏感的路径调用
-- ⇒ 手感发涩、翻页掉帧。
--
-- 关键观察：**大多数调用点根本不需要精确的 xpointer key**。
-- `_startPageTimer` 要 key 只是为了「判断当前页是不是和上一页同一页」，
-- `_trackPageUpdate` 同理 —— 对这两个用途，`page` 这个数字**完全够用**，
-- 而且它零成本、绝对稳定。
--
-- 所以拆成两个：
--   `_pageKeyFast(doc, page)`   —— 只返回 "p:<n>"，零开销（热路径用这个）
--   `_pageKey(doc, page)`       —— 保留精确 xpointer 版本（落盘/统计用）
--
-- ★ 为什么精确版还不能删：`page_units[key]` 的持久化键必须**跨重排稳定**。
--   KOReader 改字号/行距会重排，同一个 `p:5` 可能变成完全不同的内容，
--   此时用页号做持久化键会张冠李戴；xpointer 则跟着正文走。
--   所以「落盘用精确 key、热路径判重用快 key」才是对的分工。
--
-- ★ 快 key 绝不能进 page_units 的持久化键位 —— 见 `_getPageUnits`：
--   它在真正要写盘时**才**算精确 key。
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

--- ★★★ 33-read-page-perf：扫描循环专用的页 key。
--
--   为什么需要它（这是「亿字书卡顿然后重启」的直接元凶之一）：
--     `_pageKey(doc, page)` 每次调用都会执行 `doc:getPageXPointer(page)` ——
--     一次跨 FFI 的 crengine 查询。整书快路径里那处（25-cache-perf）已经
--     改成「只查首页一次、其余页用模板填」，但**逐页路径的两个赋值点漏了**：
--     它们对**每一页**都调一次 `_pageKey`。
--     几万页的书 ⇒ 几万次跨层调用，全部串在 tick 里 ⇒ 越扫越慢、
--     最后把看门狗/内存拖垮 ⇒ 用户看到的「卡顿然后重启」。
--
--   做法和整书路径完全一致（同一套模板 + 兜底语义），但抽成函数让两处共用，
--   避免以后又只改一处（这正是 25 修完又漏的教训）：
--     · `job._key_stem` 惰性初始化：第一次用时查**一次**首页 xpointer，
--       把页号位置换成 `%d` 得到模板；
--     · 之后每页只做 `string.format(stem, page)` —— 纯 Lua，O(1)；
--     · 取不到模板（非 CRE / 首页查失败）⇒ 退回 `"p:<n>"`，仍然零成本。
--
--   ★ gsub 限次 1 + pcall(format) 两道保险，理由见下方 `_pageKeyTemplate`。
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

--- ★★★ 33-read-page-perf：把「本页字数」记进 job 的逐页表，**带容量闸门**。
--
--   为什么需要闸门：`job.page_units` 是「每页一条」的表，键是完整 xpointer
--   字符串。几万页的书 ⇒ 表里有几万条 entry + 几万个小字符串，
--   Lua 侧就是好几 MB 常驻内存，落盘时还要再序列化一遍。
--   在 512MB 的 KPW4 上这是实打实的 OOM 风险（用户报的「亿字书重启」）。
--
--   ★ 关键：**超限只停「记明细」，绝不停「数字数」。**
--     调用方在调本函数**之前**已经 `Counter.addPage` 累加过总数了，
--     所以总字数永远精确、进度条照常走完；只是不再为超出的页存明细。
--     代价仅限于「已读字数」对超限页会偏低 —— 与「设备重启」相比微不足道。
--
--   ★ 用 `job.page_count`（本次扫描上限）判断：抽页模式只扫 100 页，
--     永远进不到这个闸门；只有完整扫描的大书才会触发。
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

--- 取「页号模板」：把首页 xpointer 里的页号替换成 `%d`。
--   返回 nil 表示拿不到模板（调用方应退回页号 key）。
--
--   ★ 两个必须遵守的细节（都是踩过的坑，见 25-cache-perf / 27-scroll-header）：
--     1) gsub **必须限次 1**。不限次数时，若 xpointer 有两处 `p[...]`
--        （嵌套片段路径很常见），模板里会有两个 `%d`，而 format 只传一个
--        参数 ⇒ `string.format` 抛错 ⇒ 在 scheduleIn 回调里无 pcall ⇒
--        整条扫描链崩掉（用户看到「点了没反应」）。
--     2) 锚定 `([Pp]%[)(%d+)(%])`，**绝不能**写 `(%[)%d+(%])` ——
--        后者会换掉第一个 `[数字]`，也就是固定的 `DocFragment[1]`，
--        于是每页被指向「不同的文档分片」，key 语义全错。
function WordCount:_pageKeyTemplate(doc)
    if not doc or type(doc.getPageXPointer) ~= "function" then return nil end
    local ok, k1 = pcall(self._pageKey, self, doc, 1)
    if not ok or type(k1) ~= "string" then return nil end
    local s, n = k1:gsub("([Pp]%[)(%d+)(%])", "%1%%d%3", 1)
    if n <= 0 then return nil end
    return s
end

function WordCount:_ensureReadState(doc, path, known_page_count)
    -- ★★★ 33-read-page-perf：走 `cachedDocSettings`，避免热路径上重复 I/O。
    --   老写法 `self.ui.doc_settings or DocSettings:open(path)` 在
    --   「path 不是当前阅读文档」时每次都会开一次 sidecar。
    local settings = cachedDocSettings(self, path)
    if not settings or type(settings.readSetting) ~= "function" then return nil end
    local pages = tonumber(known_page_count) or pageCount(doc)
    local mtime, size = fileFingerprint(path)
    local state = settings:readSetting(KEY_READ_STATS)
    if not ReadingStats.isValidForFile(state, pages, mtime, size) then
        state = ReadingStats.newState(pages, mtime, size)
        self._read_save_count = 0
        self._read_dirty = true
    else
        ReadingStats.recompute(state)
    end
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
    -- 把 saveSetting 与 flush 一起批量化，关闭/挂起时 force_flush 仍立即落盘。
    if force_flush or self._read_save_count >= READ_FLUSH_EVERY then
        settings:saveSetting(KEY_READ_STATS, self._read_state)
        settings:flush()
        self._read_dirty = false
        self._read_save_count = 0
    end
end

-- ★★★ 33-read-page-perf：`key` 参数现在允许是**廉价 key**（"p:<n>"）。
--
--   分工（见 `_pageKeyFast` 的注释）：
--     热路径（翻页/判重）走廉价 key，零开销；
--     只有**真的要读/写持久化的 page_units** 时，才花一次 getPageXPointer
--     换精确 key。
--
--   所以这里不再信任调用方传进来的 key，而是在「需要碰 page_units」时
--   统一把它换成精确 key。这样上层所有调用点（`_startPageTimer` /
--   `_finishPageTimer`）都可以安全地传廉价 key。
--
--   `precise_key` 可选：调用方已经算好了就直接给，省一次重复计算。
function WordCount:_getPageUnits(doc, page, key, precise_key)
    local state = self._read_state
    -- ★ 精确 key 按需计算：这里只算一次，下面读/写都用它。
    if precise_key == nil then
        precise_key = self:_pageKey(doc, page)
    end
    -- 传进来的 key 若和精确 key 不同（廉价 key），只用于内存里的临时判重，
    -- 真正读 page_units 一律用 precise_key。
    local lookup_key = precise_key

    -- ★★★ 30-estimate-shadow-fix：这里以前是「只要 page_units[key] 有值就直接返回」。
    --   但抽页估算会给前 100 页垫一份**样本均值**（page_units_estimated 标记），
    --   于是用户真读到某一页时，返回的仍是平均值 —— 真实字数被**永久遮蔽**，
    --   逐页精度再也回不来。
    --   现在：真实值（非估算）才短路；估算值继续往下走真实抽取并覆盖。
    if state and state.page_units[lookup_key] ~= nil
            and not ReadingStats.isEstimatedPageUnit(state, lookup_key) then
        return tonumber(state.page_units[lookup_key]) or 0
    end
    if not doc then return 0 end
    local ok, text, err = pcall(PageText.extract, doc, page, pageCount(doc))
    if not ok or text == nil then
        logger.warn("WordCount: could not extract text for page", page, ok and err or text)
        return 0
    end
    local units = Counter.count(text)
    if state then
        ReadingStats.setPageUnits(state, lookup_key, units)
        self._read_dirty = true
    end
    return units
end

function WordCount:_startPageTimer(doc, page)
    if self._reading_paused or not doc or not page then return end
    local path = doc.file
    local pages = pageCount(doc)
    local state = self._read_state
    if not state or self._read_doc_path ~= path or self._read_page_count ~= pages then
        state = self:_ensureReadState(doc, path, pages)
    end
    if not state then return end
    -- ★★★ 33-read-page-perf：判重只用**廉价 key**（页号），
    --   绝不为「是不是同一页」去付 `getPageXPointer` 的跨 FFI 代价。
    --   精确 xpointer key 推迟到 `_getPageUnits` 真正要写盘时才算。
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

function WordCount:_finishPageTimer(force_flush)
    local active = self._active_page
    if not active then
        if force_flush then self:_saveReadState(true) end
        return
    end
    self._active_page = nil
    local elapsed = math.max(0, os.time() - active.started)
    local min_sec, max_sec = readLimits()
    if elapsed >= min_sec and self._read_state then
        -- ★★★ 33-read-page-perf：**结算时才计算精确 key，只算这一次**。
        --
        --   这是热路径上唯一真正需要 xpointer 的地方（因为要写 page_units /
        --   page_seconds，键必须跨重排稳定）。注意 `active.key` 是廉价 key，
        --   不能用它落盘。
        --
        --   ★ 两处必须用**同一个** key：`_getPageUnits` 写 page_units，
        --     `addPageVisit` 写 page_seconds。ReadingStats.recompute 靠
        --     `page_units[key]` 给 `page_seconds[key]` 配字数，键不一致
        --     就会算出「有秒数没字数」的错值。
        local precise_key = self:_pageKey(active.doc, active.page)
        local units = self:_getPageUnits(active.doc, active.page, precise_key, precise_key)
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
        -- ★★★ 37m：这里补上 `_saveGlobalStats(true)`。
        --   场景：`force_flush`（关书/挂起）时若 `_active_page == nil`
        --   （例如用户停在同一页、已结算过至少一次 ⇒ _startPageTimer 的判重
        --   会让 _active_page 保持 nil），旧代码只落盘「已读状态 + 笔记」，
        --   **漏了全局统计**。而挂起后设备可能被杀进程 ⇒ 这段阅读记录丢失。
        --   与 onCloseDocument 的三连落盘对齐。
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
    -- ★★★ 33-read-page-perf：这里同样只比较**廉价 key**。
    --   原来的 `self:_pageKey(doc, page)` 会在每次 onPageUpdate / onPosUpdate
    --   时各问一次 crengine，是阅读页卡顿的直接来源之一。
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

--- ★★★ 33-read-page-perf：`onReaderReady` 是**开书流程的同步尾巴**。
--
--   上游 `ReaderUI` 打开一本书时会 `sendEvent(Event:new("ReaderReady"))`，
--   这个事件的处理是**同步**的 —— 我们的回调跑多久，开书就多卡多久，
--   期间屏幕停在「正在打开」上、输入被 inhibit（日志里的 `Inhibiting user input`）。
--
--   老实现直接在这个回调里干了三件重活：
--       ① `_ensureReadState` → `DocSettings:open(path)`（磁盘 I/O）
--       ② `_syncGlobalBook`  → `_bookInfo` → 又一次 `DocSettings:open` +
--                              `fileFingerprint` + `settings:readSetting`
--       ③ `_syncNotes`       → 再读一次 annotations
--   其中 `DocSettings:open` 要**遍历 sidecar 的 11 个候选位置**并解析，
--   在 KPW4 上对大书/大 sidecar 明显偏慢。三件事叠加，正撞在「开书」这个
--   用户最敏感的时刻上。
--
--   改法：把这三件事**推迟到下一个 tick**（`UIManager:nextTick`）。
--   开书流程立刻结束、界面先出来，统计数据随后补上 —— 用户完全无感，
--   因为这几件事的结果（阅读进度、笔记数）本来就不需要「开书瞬间」可见。
--
--   ★ 为什么不是 `scheduleIn(0.5)` 这种延迟：`nextTick` 在本帧的 UI 工作
--     做完之后立刻跑，既让开了书、又几乎不等待。延迟太久反而会让
--     「翻页触发结算」和「开书初始化」两个流程抢同一个 `_active_page`。
function WordCount:onReaderReady(_config)
    local doc = self.ui.document
    if not doc then return end
    self._reading_paused = false
    -- ★ 先做**最廉价**的一件事：启动当前页计时（只有 os.time 和字符串拼接）。
    --   它必须在开书时同步完成 —— 否则用户「打开书就一直停在这一页」的
    --   那段阅读时间会被漏掉。
    self._active_page = nil
    self:_startPageTimer(doc, self:_currentPage())

    -- ★★★ 剩下的磁盘 I/O 全部推迟一拍。
    --   闭包捕获 doc/path，避免 nextTick 执行时 ui.document 已经变了。
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

function WordCount:onDocumentPartiallyRerendered(_first_partial_rerender)
    local doc = self.ui.document
    if not doc then return end
    local pages = pageCount(doc)
    if self._read_state and pages ~= self._read_state.page_count then
        self:_finishPageTimer(false)
        self:_ensureReadState(doc, doc.file, pages)
        self._active_page = nil
        self:_startPageTimer(doc, self:_currentPage())
    end
end

--- ★★★ 36：打开阅读统计页面。
---
--- 用户诉求（本轮）：
---   「打开阅读统计的时候不给个进度条提示统计打开进度吗」
---   → 选定方案：「打开时若有扫描，显示进度条」。
---
--- 语义：
---   · 统计页本身只读内存里的聚合数据（`_global_stats`），**不再扫描**；
---     但如果**当前正在读的这本书**从来没有统计过字数（重置设置后、
---     或第一次打开），那它就没有任何可显示的数据 —— 用户会看到「全是 0」，
---     正是他说的「重置设置后字数消失、再次点击依旧不显示」。
---   · 所以：打开统计页前先看一眼当前书有没有字数。
---       - 有 → 直接开统计页（瞬间，和以前一样）。
---       - 没有 → **先起一次扫描并显示进度条**，扫完再开统计页。
---   · 只有在「阅读界面里打开」时才做这件事（有 self.ui.document）；
---     从文件管理器/书架打开时没有当前文档，直接开页。
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
            -- ★★★ 37b：字数在缓存里（所以不会起扫描）——
            --   但「重置设置」可能把**聚合统计**清掉了，导致总览里这本书是 0。
            --   这里顺手补写一次聚合，用户无需先点一遍「统计字数」。
            self:_resyncBookFromCache(doc.file, count)
        end
    end
    return StatisticsPage.show(self, period, anchor, metric)
end

--- 扫描收尾后，如果这次扫描是为了「打开统计页」而起的，就把页打开。
--- 由 startCount 的收尾分支调用（见 step 里 result 之后）。
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
    local total
    if settings and self.ui.document then
        local mtime, size = fileFingerprint(self.ui.document.file)
        if tonumber(settings:readSetting(KEY_MTIME)) == mtime
                and tonumber(settings:readSetting(KEY_SIZE)) == size then
            total = tonumber(settings:readSetting(KEY_COUNT))
        end
    end
    local state = self._read_state
    if type(state) == "table" then ReadingStats.recompute(state) end
    if total == nil and type(state) ~= "table" then
        notifyUser(_("本书还没有可显示的字数统计"))
        return
    end
    total = total or 0
    local read_units = state and tonumber(state.read_units) or 0
    local speed = state and tonumber(state.speed_units_per_minute)
    if speed then
        notifyUser(T(_("全书约 %1；已读约 %2；平均 %3 单位/分钟"),
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

    -- ★★★ 1.2：清理**未完成**的缓存。
    --   用户要求：「取消时把未完成的缓存清掉，已完成的保留」
    --   （多选 5 本，扫到第 3 本取消 → 前两本保留、第 3 本清除）。
    --
    --   哪些算「未完成」：
    --     · 单个 job（self._job）：它正在扫的那本书 —— 就是当前中途取消的这本。
    --     · 单个 preparing（self._preparing_single）：正在准备、还没开扫的那本。
    --     · 批量（self._batch）：正在扫的**这一本**（batch.paths[1]，因为
    --       _startNextBatch 用 table.remove 从头吃）；已扫完的（completed）
    --       和跳过的都不动 —— 它们的缓存是完整结果，必须保留。
    --
    --   ★ 为什么一定要清：
    --     扫描中途取消时，这本可能写了半截状态；更关键是**不能让
    --     「扫了一半」的结果留在缓存里冒充完整结果**，否则下次打开这本书
    --     显示的是错误（偏小）的字数，而且因为指纹匹配还会一直不重扫。
    local removed = {}
    local function wipe(path)
        if type(path) == "string" and path ~= "" and not removed[path] then
            removed[path] = true
            -- ★★★ 1.2-bugI：只在「当前打开的正是这本书」时才把 doc_settings
            --   传下去当 prefer_settings。否则它属于**另一本书**，
            --   传进去会让 removeCachedCount 删错书的 sidecar
            --   （批量扫 C 时取消 ⇒ 正在读的 A 被清掉）。
            --   removeCachedCount 内部还有一层同名校验兜底，这里是第一道闸。
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
        -- ★★★ 1.2-bugL：**不要再用 batch.paths[1] 当「当前正在处理的那本」**。
        --
        --   ☠ 真 bug（1.2 排 bug 轮发现）：
        --     `_startNextBatch` 一进来就 `table.remove(batch.paths, 1)` ——
        --     也就是说**一旦某本开始被处理，它就已经从表里被摘掉了**。
        --     于是「正在扫 C」的那段时间里，`batch.paths[1]` 其实是**下一本 D**。
        --     旧代码 `local cur = self._batch.paths[1]` 拿到的正是 D：
        --       · 清错对象：把还没开始的 D 的缓存删了（若 D 有历史有效缓存，
        --         就等于**破坏了用户明确要求保留的已完成结果**）；
        --       · 该清的 C 反而只能靠下面的 dialog 兜底才侥幸对上。
        --
        --   正确来源：`batch.dialog._wordcount_path` —— 它在
        --     `_startNextBatch` 里、**打开文档成功之后**被赋成当前这本
        --     （见那里的 `preparing._wordcount_path = path`）。
        --     `batch._busy_retry` 期间虽已摘表但尚未赋值，此时宁可不清
        --     （那本书一个字都还没写，本来也没有脏缓存要清）。
        if self._batch.dialog and self._batch.dialog._wordcount_path then
            wipe(self._batch.dialog._wordcount_path)
        end
        -- 「正在准备」的那本也算未完成（批处理第一本：此时 dialog 还没建）。
        if self._batch_preparing and self._batch_preparing._wordcount_path then
            wipe(self._batch_preparing._wordcount_path)
        end
        -- 兜底：批处理刚起步、上面两个来源都还是 nil 时，才用 paths[1]。
        --   （只有「一本都还没开始」时才会走到这里；那本书尚未写任何缓存，
        --    所以这里清它是安全的，也是必要的 —— 它即将要开始。）
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
    -- ★★★ 36：用户取消扫描时，也把「扫完自动开统计页」的挂起请求清掉，
    --   否则取消后统计页还会突然弹出来。
    self._stat_open_pending = nil
    notifyUser(_("全书字数统计已取消"))
end

function WordCount:startCountFromMenu(force_rescan)
    if self._batch then
        notifyUser(_("批量字数统计正在进行中"))
        return false
    end
    -- ★★ 24-cache-reuse：先查缓存。除非用户明确要求「重新统计」，
    --    否则文件没变就直接用缓存结果，绝不重复扫描。
    if not force_rescan then
        local doc = self.ui and self.ui.document
        local path = doc and doc.file
        local count, cached_settings, cached_estimated = path and readCachedCount(path,
            self.ui and self.ui.doc_settings)
        if count then
            logger.info("WordCount: cache HIT for " .. tostring(path)
                .. " count=" .. tostring(count) .. " → skip scan")
            -- ★★★ 37b：命中缓存也要把这本书补进**聚合统计**，
            --   否则「重置设置」后总览里这本书一直是 0（用户报的 bug）。
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
        UIManager:show(InfoMessage:new{ text = message })
    end)
    if not shown then
        -- ★ 这里以前写的是 `pcall(Notification.notify, Notification, message)` ——
        --   在**类表**上点调用，`notify_source` 为 nil ⇒ 静默返回 false，什么也不显示。
        --   这正是 notify_source 那个坑（见 notifyUser 的注释）。虽然它在兜底路径里，
        --   但兜底路径才最需要「真的显示出来」，所以改成构造实例。
        pcall(function()
            UIManager:show(Notification:new{ text = message, timeout = 4 })
        end)
    end
    return false
end

-- ★★★ 1.5-bugQ：统一的「有没有任务在跑」判据。
--
--   ☠ 真 bug（用户原话：「单本统计正常，一旦多选就不行了」）：
--     `_preparing_single` 是**第三种忙状态** —— 「正在打开文档、还没开扫」。
--     单本入口 `startCountForPath()` 会在打开 epub 的**几十秒**里一直持有它，
--     而那时 `_job` 和 `_batch` **都还是 nil**。
--     于是：
--       ① 用户点了一本单本统计（打开中大文件，比如 2940 页的诡秘之主）；
--       ② 等得不耐烦，切去多选，点「统计选中字数」；
--       ③ `startBatchCount` 的守卫只查 `self._job or self._batch` ⇒ 两个都是 nil
--          ⇒ **判定「没有任务」，照常起批**；
--       ④ 单本那个还在途的 nextTick 回调也只看 `_job/_batch`，同样判定「空的」，
--          于是它**也**继续跑，把 doc 交给 startCount；
--       ⑤ 两边同时抢 UIManager 的对话框栈 + 同一批文档对象 ⇒ 界面错乱、
--          进度条乱跳、「多选不生效」。
--
--   修法：把「有任务在跑」收敛成一个函数，**四个状态一起查**，
--   单本/批量两条入口都用它。
--   ⚠ 必须定义在所有调用点**之前**（它是 local，Lua 不做前向提升）。
local function isBusy(self)
    return (self._job ~= nil)
        or (self._batch ~= nil)
        or (self._batch_preparing ~= nil)
        or (self._preparing_single ~= nil)
end

function WordCount:startCountForPath(path, force_rescan)
    logger.info("WordCount: startCountForPath path=" .. tostring(path)
        .. " force_rescan=" .. tostring(force_rescan))
    -- ★★★ 1.5-bugQ：统一忙判据（含 _preparing_single / _batch_preparing）。
    --   旧写法只查 _job/_batch，会放过「另一本正在打开中」这个状态，
    --   于是两本单本统计可以叠加，互相抢对话框。
    if isBusy(self) then
        notifyUser(_("已有字数统计任务正在进行中"))
        return
    end
    -- ★★ 24-cache-reuse：先查缓存 —— 这本书统计过、文件也没变，就别再扫一遍。
    --    这是「每次都要统计一遍」的根因修复（Bookshelf 点单本的入口）。
    --
    -- ★★★ 1.8-force-rescan-clears-cache：**用户显式点「统计」时，先清掉旧缓存**。
    --
    --   用户原话：「点击统计为什么不会清理之前的缓存并开始重新统计」。
    --   老行为只在 force_rescan 时**跳过读取**缓存，但**旧的缓存条目还留在
    --   KEY_CACHE / sidecar 里** —— 后果有两个：
    --     ① 这次扫描若中途取消，旧缓存**仍在**，下次又命中旧值 ⇒ 用户看到
    --        「我点了重算，它还是显示老数字」（以为重算无效）；
    --     ② 扫描失败（比如书太大被拒）时，旧缓存没被清 ⇒ 结果与「重算过」的
    --        心理预期不符。
    --   ⇒ 显式重算就该**先删后扫**，语义干净：点了重算 = 旧结果作废。
    --   ★ 只在 force_rescan 时清；隐式（缓存优先）路径不动，保持省电。
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
            -- ★★★ 37b：同上 —— Bookshelf 点单本命中缓存时也补写聚合。
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
        -- ★ 1.2：准备阶段也能取消（会中断并清掉这本未完成的缓存）
        cancel_callback = function() self:cancelCount() end,
    }
    preparing:show()
    logger.info("WordCount: preparing dialog shown (正在准备字数统计)")
    -- ★ 1.2：把 path 挂在对话框上，供 cancelCount() 定位「未完成的那本」并清缓存。
    preparing._wordcount_path = path
    self._preparing_single = preparing
    -- 取消安全：cancelCount() 只是把 _job/_batch/_preparing_single 置 nil，
    -- 单看这两个字段无法区分「用户取消」与「还没有任务」。以前 scheduleIn
    -- 的回调写的是 `if self._job or self._batch then return end`，取消之后
    -- 两者都是 nil，判定成「可以开始」，于是取消后 0.25 秒扫描仍会偷偷启动
    -- （用户在 0.25 秒的空窗期里点了取消，扫描照跑，看起来像取消无效）。
    -- 用一个自增的请求序号作为令牌：任何回调都必须持有当下有效的令牌才允许
    -- 继续，cancelCount() 递增序号即让所有在途回调立刻失效。
    self._request_seq = (self._request_seq or 0) + 1
    local seq = self._request_seq
    -- 只有序号才代表「这次请求还有效」。不要再用
    -- `self._preparing_single == preparing` 当令牌：preparing 在下面会被
    -- 主动置 nil（正常流程），那样 scheduleIn 回调会被误判成「已取消」。
    local function still_wanted()
        return self._request_seq == seq
    end
    UIManager:nextTick(function()
        -- ★ 整段包 pcall：这个回调跑在 UIManager 的任务队列里（_checkTasks 里是
        --   直接 `task.action(...)`，**没有 pcall**），一旦抛错就只剩顶层兜底，
        --   而用户看到的是「对话框停在『正在打开』、之后再无任何反应」。
        --   包一层，把错误直接显示到屏幕上，不再靠猜。
        local ok_cb, err_cb = pcall(function()
        if not still_wanted() then return end
        -- ★★★ 1.5-bugQ：这里**必须**用「除了我自己之外还有别人在忙」的判据。
        --   旧写法 `if self._job or self._batch` 有两个毛病：
        --     ① 漏掉别人也在「打开文档」的情况（_preparing_single 被别人占了）；
        --     ② 用统一 isBusy() 会把**自己**也算进去（自己就是 _preparing_single），
        --        那样这条回调永远早退，单本统计直接废掉。
        --   判据：有别的东西占着忙状态，且那个「正在准备的」**不是我**。
        local other_preparing = self._preparing_single
            and self._preparing_single ~= preparing
        if self._job or self._batch or self._batch_preparing or other_preparing then
            preparing:close()
            if self._preparing_single == preparing then self._preparing_single = nil end
            return
        end
        logger.info("WordCount: opening document " .. tostring(path))
        -- ★ 用 openPreparedDocument：openDocument 只创建对象，CRE 文档还要
        --   setupDefaultView + loadDocument + render 之后 getPageCount 才非 0。
        -- ★★★ 37i2：必须接住 openPreparedDocument 的**第二个返回值**（错误原因）。
        --   ☠ 旧代码 `local ok, doc = pcall(openPreparedDocument, path)` 把
        --   `openPreparedDocument` 返回的 `(nil, "huge_document")` 里的
        --   **第二个返回值整个丢掉了** —— 于是下面 `doc == "huge_document"`
        --   永远不成立，巨书会一路掉到「无法打开文件：nil」这个**误导性通用文案**。
        --   用户看到的「显示无法打开文件」就是这么来的。
        local ok, doc, open_err = pcall(openPreparedDocument, path)
        if not still_wanted() then
            -- 打开文档耗时期间用户取消了：把这个刚打开的文档还回去。
            if ok and doc and type(doc.close) == "function" then pcall(doc.close, doc) end
            return
        end
        if not ok or not doc then
            preparing:close()
            self._preparing_single = nil
            -- ★ 31-huge-book-guard：区分「文件太大、拒绝排版」与一般打开失败。
            --   直接说清楚原因 + 给可行的出路，别让用户以为是插件坏了。
            local err = open_err
            if not err and not ok then err = tostring(doc) end
            if err == "huge_document" then
                -- ★★★ 37o：报的必须是**实际生效**的那条线（跟随用户设置），
                --   否则用户会看到「我明明设了 N，提示还说 M」的错乱。
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
        -- 直接把 preparing 复用成正式对话框（它就是 LiveProgressDialog，
        -- 有 bar 也有文字），用 configureProgress 把标题/总量/文字一次性刷新。
        UIManager:scheduleIn(0.25, function()
            if not still_wanted() then
                logger.info("WordCount: cancelled before startCount")
                if type(doc.close) == "function" then pcall(doc.close, doc) end
                return
            end
            -- ★★★ 1.5-bugQ：这条早退以前是「什么都不做就 return」——
            --   两个泄漏：
            --     ① `preparing` 对话框没关 ⇒ 在 UIManager 栈上永久残留，
            --        覆盖住后起的那个（批量）对话框；
            --     ② 刚打开的那本 `doc` 没还回去 ⇒ KPW4 上几十 MB 的
            --        crengine 内存泄漏（Lua GC 不会及时回收）。
            --   所以早退必须把「自己那份资源」收干净。
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

-- ★★★ 30-estimate-shadow-fix：判断「某个 job 所属的那一批」是否仍是当前活跃批次。
--   收尾 / 失败 / 跳过等分支都要用它来推进下一本，避免跨批串号：
--   「批量 A 进行中 → 取消（self._batch=nil）→ 立刻发起批量 B」时，
--   A 的 job 收尾会看到 self._batch 指向 B，若不加校验就会错误推进 B。
--   job.batch 为 nil（单本任务）时返回 false —— 单本本来就不该推进任何批次。
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
        -- ★★★ 1.6-bugR：「跳过 N 本」必须**说清跳的是哪几本、为什么**。
        --   ☠ 老代码只有一句「跳过 2 本」——用户看到「书很小啊，为什么跳过」
        --   只能来问。现在把每一条跳过原因（打开失败 / 无法分页 /
        --   无文本层 / 等待超时）附在后面，用户自己能判断该怎么办。
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
    -- ★ 26-batch-index：进到这一本就把「第几本」推一格。计数在**取 path 之后**
    --   自增，无论这本书最后是成功、跳过还是打开失败，序号都已经占掉，
    --   保证「第 X / N 本」严格单调、不会因为跳过而回退或跳号。
    batch.index = (batch.index or 0) + 1
    local book_name = path and path:match("([^/\\]+)$") or nil
    -- ★★ 24-cache-reuse：批量里这本书若已有有效缓存，直接跳过 ——
    --    连文档都不用打开（打开 epub 才是批量里最慢的一步）。
    --    计入 completed（视为「已经有结果了」），不计 skipped。
    --
    -- ★★★ 1.8-batch-cache-clear：**显式统计入口不走这条跳过**。
    --   用户点「统计选中字数」的语义是「重算」，缓存已在 startBatchCount 里
    --   清掉；这里再以 force_rescan 兜一道，确保即使某本清理失败也会真扫。
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
        -- ★ 同样要用 prepare 版：否则每一本 epub 的页数都是 0，全被当「跳过」。
        --   ★★ 37i2：必须接住第二个返回值（错误原因），否则 huge_document 判断
        --   永远不成立（和单本入口是同一个 bug）。
        local ok, doc, open_err = pcall(openPreparedDocument, path)
        if self._batch ~= batch then
            -- 取消（或又开了新批量）发生在 openDocument 期间：把刚打开的文档还回去。
            if ok and doc and type(doc.close) == "function" then pcall(doc.close, doc) end
            return
        end
        if not ok or not doc then
            -- ★ 31-huge-book-guard：批量里遇到超大书（拒绝排版）→ 直接跳过，
            --   计 skipped 并推进下一本。批量场景**不要**弹窗打断，
            --   否则一次批量可能弹出一串「书太大」提示，很吵。
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
                -- ★★★ 1.6-bugR：**打开失败也必须给出可见原因**。
                --   ☠ 老代码这里什么都不说就 skipped+1 —— 用户只看到
                --   「跳过 2 本」，却永远不知道是**哪两本**、**为什么**。
                --   批量里最容易被跳过的恰恰是「打不开的小书」（编码坏、
                --   文件损坏、扩展名与实际不符），所以「书很小却被跳过」
                --   的第一嫌疑就是这条路径。
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
        -- ★★★★ 1.6-bugR：**批量路径必须和单本路径一样"补一刀"重试！**
        --
        --   ☠ 这就是「为什么会跳过两本，书籍大小很小啊」的**真正根因**：
        --
        --     日志证据（crash(14).log）：`pages==0, retrying prepareDocument`
        --     出现 **12 次，12 次都能靠重试拿到真实页数**
        --     （81 / 316 / 444 / 1456 / 2948 … 页）。
        --     ⇒ **「loadDocument 后第一次取页数拿到 0」是 crengine 的常态**
        --       （惰性分页），**与书的大小完全无关** —— 小书一样会先返回 0。
        --
        --     单本入口 `startCountForPath` 对此有显式补刀：
        --         if pages < 1 then
        --             logger.info("...pages==0, retrying prepareDocument")
        --             prepareDocument(doc)      -- ← 再 prepare 一次
        --             pages = pageCount(doc)
        --         end
        --     而**批量入口这里从来没有这段** ⇒ 只要第一本恰好是
        --     「loadDocument 后还没算出页数」的，就**直接被判 pages<1 跳过**。
        --     一次批量跳过 2 本 = 恰好有 2 本撞上这个时序。
        --
        --   ★ 为什么这次「书小」反而更容易中招：小书 load 快，`prepareDocument`
        --     返回得也快，因而**更容易在 crengine 尚未完成惰性分页时**就去取页数。
        --     大书 load 耗时久，等它返回时页数往往已经算好了。
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
            -- ★★★ 1.6-bugR：这一条也是**静默**的（老代码直接 skipped+1）。
            --   现在把**具体原因**分清楚，写进状态行 + 记进 skip_reasons，
            --   并记下**重试也救不回来**这一事实（说明是真取不到页数）。
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
        -- 旧逻辑是每本书都关掉上一本的对话框、再新建一个，e-ink 上表现为
        -- 「批量统计时屏幕一直闪 / 中间出现空白」——正是用户报的
        -- 「进度条和文字都消失了」。
        -- 这里：批次开始时（第一次进来）用 _batch_preparing，之后每本书都
        -- 复用 batch.dialog，只通过 configureProgress 换标题、换总量、归零进度。
        local preparing = batch.dialog
        if not preparing then
            preparing = self._batch_preparing
            self._batch_preparing = nil
            batch.dialog = preparing
        end
        -- ★ 1.2：把「当前正在处理的这本」挂在对话框上，供 cancelCount()
        --   定位未完成的缓存并清除（已完成的书不在这个字段里，自然保留）。
        if preparing then preparing._wordcount_path = path end
        -- 防御：万一准备对话框已经不存在（正常流程不会），兜一个新建的，
        -- 保证本批次后续每一本都有对话框可复用。
        if not preparing then
            preparing = LiveProgressDialog:new{
                title = _("正在批量统计字数"),
                subtitle = _("准备中…"),
                progress_max = 1,
                dismissable = false,
                -- ★ 1.2：取消整批（已完成的书保留缓存，未完成的清掉）
                cancel_callback = function() self:cancelCount() end,
            }
            preparing:show()
            batch.dialog = preparing
        end
        -- ★ 26-batch-index：把「第 X / N 本」+ 当前书名推给标题行。
        --   必须在 configureProgress 之前，因为 configureProgress 内部会用
        --   title 参数覆盖标题，然后再调 refreshBatchTitle() 把它拼回来。
        if type(preparing.setBatchInfo) == "function" then
            preparing:setBatchInfo(batch.index, batch.total, book_name)
        end
        -- 与 DocumentRegistry 无关的 UI 安全：openDocument 只做 registry /
        -- refcount / GC，不碰 UI 栈（已对照 documentregistry.lua 全文确认），
        -- 所以保留的对话框不会因为打开文档而消失。
        UIManager:scheduleIn(0.25, function()
            -- ★★★ 30-estimate-shadow-fix：这里以前是 `if self._job then return end`。
            --   静默 return 的后果很严重：doc 没关、本批也**不再推进**
            --   ⇒ 整个批量任务就此停摆（不报错、不结束，用户看着进度条不动）。
            --   实际上 _job 非空只会是「上一本的异步收尾还没跑完」这种瞬时态，
            --   稍等一个 tick 多半就没了。所以改成**有界延后重试**：
            --   重试若干次仍不让路，才把这本书当跳过处理并继续下一本，
            --   保证整批永远不会卡死。
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
                -- ★★★ 1.6-bugR：**等不及了也不能静默丢弃**。
                --   ☠ 老代码这里只 `skipped+1` 就往下走 —— 用户看到
                --   「跳过 2 本」但完全不知道原因。而**这一条恰恰是
                --   「书很小却被跳过」的真正高发路径**：跳过与书的大小
                --   **毫无关系**，纯粹是「上一本的异步收尾迟迟不放手
                --   `self._job`」⇒ 重试 5 秒仍被占着 ⇒ 这本书被丢掉。
                --   （与 1.5-bugQ 同族：都是「忙状态被别人占着」。）
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
        -- ★ 区分文案：卡在「正在打开文档」时，明确告诉用户等的是哪一本，
        --   否则他会以为插件坏了（旧文案「已有字数统计任务正在进行中」太含糊）。
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
    -- ★★★ 1.8-batch-cache-clear：用户显式点「统计选中字数」⇒ **清掉这些书的旧缓存并全部重算**。
    --
    --   用户原话：「点击统计为什么不会清理之前的缓存并开始重新统计」。
    --   老行为：批量里每本书先 `readCachedCount`，命中就跳过（计 completed）。
    --   后果：用户选了一批「想重新算」的书，结果大部分被判「有缓存」直接跳过，
    --   实际一本都没重算 —— 与他「点了统计就该重算」的预期完全相反。
    --
    --   ⇒ 批量与单本统一：**显式统计 = 先清缓存、再全部重扫**。
    --     （隐式的缓存复用只在「不经过统计入口」的展示路径才有意义。）
    --   ★ 清缓存**逐本进行**（保留其他未选中的书），禁止整表清空。
    local cleared = 0
    for _i, p in ipairs(list) do
        local ok_rm, rm = pcall(removeCachedCount, p)
        if ok_rm and rm then cleared = cleared + 1 end
    end
    logger.info("WordCount(batch): force batch rescan — cleared caches for "
        .. tostring(cleared) .. "/" .. tostring(#list) .. " book(s)")
    -- 让任何在途的单本 startCountForPath 回调失效（取消令牌语义一致）。
    self._request_seq = (self._request_seq or 0) + 1
    -- ★ 26-batch-index：batch.index 是**当前正在处理第几本**（1 起），
    --   batch.total 是这批的总本数。注意 paths 表在 _startNextBatch 里会被
    --   table.remove 逐个吃掉，所以「已完成数」不能由 #paths 反推，
    --   必须自己用一个只增不减的计数器。
    self._batch = {
        paths = list,
        completed = 0,
        skipped = 0,
        index = 0,          -- 已开始处理的（含跳过的）本数
        total = #list,
        -- ★★★ 1.8：显式统计入口 ⇒ 缓存已在上方清掉，本批每本都要真扫，
        --   _startNextBatch 里据此**不做 cache HIT 跳过**（双保险）。
        force_rescan = true,
    }
    self._batch_preparing = LiveProgressDialog:new{
        title = _("正在准备批量统计"),
        subtitle = T(_("正在准备 %1 本书"), #list),
        progress_max = 1,
        dismissable = false,
        -- ★ 1.2：批量准备阶段也能取消
        cancel_callback = function() self:cancelCount() end,
    }
    self._batch_preparing:setBatchInfo(0, #list, nil)
    self._batch_preparing:show()
    -- ★ 28-kpw4-tuning：批量本数多时自动降级抽页 —— **必须告诉用户**，
    --   否则他拿到一堆「约」的数字会以为精确统计坏了。
    --   用法：只在「用户当前是 full 模式 + 本数达阈值」时才提示。
    --   ★★★ 1.8：阈值改为用户可调（batchSampleThreshold，0 = 关闭）。
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
    -- ★★★ 1.2-bugJ：早退时必须把**调用方传进来的那个文档**还回去。
    --
    --   ☠ 真 bug（1.2 排 bug 轮发现）：
    --     `startCountForPath` / `_startNextBatch` 都会先
    --     `openPreparedDocument(path)` 打开一本**后台文档**再交进来
    --     （`doc_override` 非 nil）。那本文档已经 `loadDocument` 过，
    --     在 KPW4 上动辄几十~上百 MB（crengine 的 FFI 侧内存，
    --     Lua GC **不会及时**回收）。
    --
    --     而下面四条早退路径（已有任务 / 路径无效 / 文档不支持 / 页数<1）
    --     以前只调 `close_preparing()` —— **从不 close 这个 doc**。
    --     于是「批量扫到一本不支持的书 + 恰好又起了另一个任务」这类
    --     组合下，每次早退都留下一本没关的文档，越积越多 ⇒ OOM。
    --
    --   判据（必须同时成立才关）：
    --     · doc_override 非 nil（是调用方传来的一次性文档，不是用户正在读的）
    --     · 它不是当前阅读器打开的文档（绝不能把用户在读的那本关掉）
    --     · 有 close 方法
    local function close_override_doc()
        if doc_override and type(doc_override) == "table"
                and doc_override ~= (self.ui and self.ui.document)
                and type(doc_override.close) == "function" then
            pcall(doc_override.close, doc_override)
        end
    end
    -- ★ 22-progress-only：「已触发…正在检查文档…」这句弹窗去掉了。
    --   用户已经点过菜单，preparing 对话框马上就会显示（「正在打开：xxx」），
    --   这句弹窗纯属重复 + 白刷一次全屏。
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
    logger.info("WordCount: pageCount=" .. tostring(pages))
    if pages < 1 then
        logger.info("WordCount: EARLY-RETURN pages<1")
        close_preparing()
        close_override_doc()
        notifyUser(_("无法获取文档页数"))
        return
    end

    local mtime, size = fileFingerprint(path)
    -- ★★★ 26-sample-estimate：决定这次是「全量扫」还是「抽页估算」。
    --   抽页模式把扫描范围收窄到前 SAMPLE_PAGES 页；收尾时按比例放大到全书。
    --   书本身不足 SAMPLE_PAGES 页时，抽页 = 全扫（没有估算误差），
    --   所以 estimated 标志要按「是否真的做了外推」来定，而不是按模式。
    --
    -- ★★★ 28-kpw4-tuning：批量时按本数自动降级（见 batchSampleThreshold）。
    --   注意这里的判据组合：
    --     · 用户自己选了 full（countMode() == MODE_FULL）
    --     · 且这一批本数 ≥ 阈值（阈值用户可调；0 = 关闭这条规则）
    --   ⇒ 本批临时改成 sample。用户主动选 sample 时不重复判断（本来就省电）。
    local scan_mode = countMode()
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
    -- ★★★ 37j-user-controllable-limits：降级行为完全由用户设置决定。
    --
    --   · 用户选了 sample          → 抽样（用户自己要的，不算降级）
    --   · 用户选了 full + 禁止降级 → **规模超线就拒绝并提示**（不硬跑，避免重启）
    --   · 用户选了 full + 允许降级 → 按用户设的页数/MB 阈值自动降级为抽样
    --
    --   判据用的阈值都是**用户可改的**：downgradePages() / downgradeBytes(path)。
    local huge_book_forced_sample = false
    local refuse_reason = nil
    if scan_mode == MODE_FULL then
        local page_limit = downgradePages()
        local byte_limit = downgradeBytes(path)
        local too_many_pages = total_pages > page_limit
        local too_big = size and size > byte_limit
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

    -- ★★★ 37j：完整模式下规模超线且用户禁止降级 ⇒ 中止本次扫描（避免重启）。
    if refuse_reason then
        close_preparing()
        -- ★★★ 37j-cleanup：既然处理不了，就把为它占用的资源**全部还回去**，
        --   避免「打不开的书」残留一份文档对象 / 内存，越积越多。
        --   · 关掉可能已打开的文档（doc_override 不是当前阅读的书时才关，
        --     别把用户正在读的那本关了）；
        --   · 清空本次可能建立的临时引用；
        --   · 主动 GC 一次，让 Lua 堆立刻回收。
        do
            -- ★ 1.2-bugJ：复用统一的 close_override_doc()（判据一致，避免两处漂移）。
            close_override_doc()
            self._refused_doc = nil
            collectgarbage("collect")
        end
        local limit_desc
        if refuse_reason == "pages" then
            limit_desc = T(_("%1 页（上限 %2 页）"), fmtCount(total_pages), fmtCount(downgradePages()))
        else
            local mb = tostring(math.floor((tonumber(size) or 0) / 1024 / 1024))
            local lim_mb = tostring(math.floor(downgradeBytes(path) / 1024 / 1024))
            limit_desc = T(_("%1 MB（上限 %2 MB）"), mb, lim_mb)
        end
        notifyUser(T(_("这本书太大：%1。\n为避免耗尽内存导致设备重启，已取消统计。\n"
            .. "如需统计，请到「字数与阅读速度 → 允许大书自动降级」打开抽样估算，"
            .. "或在同处调高上限。"), limit_desc), 10)
        return
    end

    local job = {
        doc = doc,
        background_doc = (doc_override and (not self.ui or self.ui.document ~= doc_override)) and doc_override or nil,
        path = path,
        -- page_count 是**本次扫描的上限**（抽页模式下就是样本页数），
        -- 全书真实页数放在 total_pages，收尾外推时用。
        page_count = scan_pages,
        total_pages = total_pages,
        scan_mode = scan_mode,
        -- ★ 28-kpw4-tuning：标记「这次是被批量规则降级的」，
        --   收尾文案 / 完成提示据此说明「因为批量所以用了估算」。
        batch_forced_sample = batch_forced_sample,
        -- ★★★ 37i：标记「这次是因为书太大被强制降级的」，
        --   收尾文案据此说明「书太大，为防卡死改用估算」。
        huge_book_forced_sample = huge_book_forced_sample,
        sampled = sampled,
        page = 1,
        state = Counter.newState(),
        page_units = {},
        mtime = mtime,
        size = size,
        failed_pages = 0,
        pages_with_text = 0,
        first_error = nil,
        next_notice = math.max(1, math.floor(scan_pages / 4)),
        last_progress_page = 0,
        last_progress_time = 0,
        -- ★ 22-progress-only：用于「每 CHUNK_TICKS 个 tick 让 CPU 休息一次」的计数
        --   （28-kpw4-tuning：CHUNK_TICKS 已是 10，别在这里写死数字）
        tick_count = 0,
        -- ★★★ 30-estimate-shadow-fix：记住本 job 属于哪一批。
        --   收尾推进下一本前要校验「self._batch 是否仍是这一批」——
        --   否则「批量 A 进行中 → 取消 → 立刻发起批量 B」时，A 的 job 收尾会
        --   看到 self._batch 是 B（非 nil）而错误地推进 B，造成跳号 / 两个
        --   批量流程同时跑。
        batch = self._batch,
    }
    self._job = job
    if preparing_dialog then
        job.progress_dialog = preparing_dialog
        local on_stack = is_widget_on_stack(preparing_dialog)
        logger.info("WordCount: reusing preparing dialog, on_stack=" .. tostring(on_stack)
            .. " has_configureProgress=" .. tostring(type(preparing_dialog.configureProgress) == "function"))
        job.progress_dialog:configureProgress(scan_pages,
            batch_mode and _("正在批量统计字数") or _("正在统计全书字数"))
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
            title = batch_mode and _("正在批量统计字数") or _("正在统计全书字数"),
            subtitle = T(_("已扫描 0 / %1 页（0%）"), scan_pages),
            progress_max = scan_pages,
            dismissable = false,
            refresh_time_seconds = 1.5,
            -- ★★★ 1.2：页面扫描进度条上的「取消统计」按钮。
            --   点了会中断本次扫描，并**清掉这本未完成的缓存**。
            --   批量场景：已完成的书缓存保留，只有当前这本（未完成）被清。
            cancel_callback = function() self:cancelCount() end,
        }
        job.progress_dialog:show()
        job.progress_dialog:updateProgress(0, true)
    end
    -- ★ 22-progress-only：不再用弹窗宣告「正在统计全书：0 / N 页」——
    --   这个信息已经写在对话框的副标题里了。弹窗只会盖住它、白耗一次全屏刷新。

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
            -- ★ prepare 版：这里重开的文档如果没 load+render，getPageXPointer
            --   等取文本的 API 都会失败（页数 0 / XPointer 为空）。
            local ok, background_doc, bg_err = pcall(openPreparedDocument, path)
            if not ok or not background_doc then
                -- ★ 31-huge-book-guard：把「文件太大」和一般失败区分开
                --   ★★ 37i2：接住第二个返回值（否则判断永不成立）。
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
            -- ★ 31-huge-book-guard：文件过大导致无法重开时，给出明确说明，
            --   不要显示成含糊的「无法打开文档」。
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

        -- ★★★ 精确路径（23-accurate-count）：第一个 tick 先试「整书一次取文本」。
        --
        -- 逐页 XPointer 拼接有结构性误差（crengine 会把页边界吸附到文本节点，
        -- 相邻页重复/漏计，误差随页数线性累积），见 page_text.extractWholeBook
        -- 的注释。整书取一次则**没有任何边界**，计数是精确的。
        --
        -- 代价：整书文本可能几 MB，一次取回 + 计数需要几百毫秒到一两秒，
        -- 期间进度条不动。所以：
        --   · 只有 CRE 系（有 getTextFromXPointers）才走这条路；
        --   · 取回后一次性数完，进度条直接拉到 100%；
        --   · 如果整书取失败（返回 nil），自动回落到原来的逐页路径 ——
        --     功能不退化，只是精度回到「近似」。
        -- ★★★ 26-sample-popup 修的一个真 bug（抽页模式下虚高 ~total_pages/100 倍）：
        --
        --   整书快路径 `extractWholeBook` 取的是**整本**文本（几 MB、几千页全都读
        --   回来了），与 job.page_count（本次扫描上限）毫无关系。而收尾外推却按
        --     `sample_total / eff * total_pages`
        --   放大 —— 因为抽页模式下它以为 sample_total 只是「前 100 页的和」。
        --   于是 1000 页的书会得到 `全书字数 / 100 * 1000` = **虚高 10 倍**，
        --   而且这个错值会写进 DocSettings、全局缓存，还会显示成「约」。
        --   更讽刺的是：抽页本来是为了省电，走整书路径反而**把整本读了一遍**，
        --   一点电都没省。
        --
        --   所以：抽页模式**禁止**走整书快路径，强制走逐页（只扫前 100 页）。
        if job.page == 1 and not job.whole_book_tried and not job.sampled then
            job.whole_book_tried = true
            -- ★★★ 31-huge-book-guard：整书路径会**一次性**把全本文本读成
            --   一个 Lua 字符串（外加 crengine 内部缓冲）。页数特别多的书，
            --   这一步就能吃掉几百 MB ⇒ OOM ⇒ 设备重启。
            --   所以页数超过阈值时**直接跳过整书路径**，老老实实逐页扫
            --   （逐页是分 tick 的，内存峰值只与单页大小有关，安全得多）。
            --   代价：精度退回「近似」（页边界累积误差），但不会把设备搞崩。
            local total_pages = tonumber(job.total_pages) or 0
            -- ★★★ 37j：整书路径阈值也受用户设置控制。
            --   · 允许降级 ⇒ 超过 WHOLE_BOOK_MAX_PAGES 就跳过整书路径（改逐页，省内存）
            --   · 禁止降级 ⇒ **无论如何都走整书路径**（这是唯一无边界误差的精确路径）；
            --     若真 OOM，那是用户明确选择的取舍（他在设置里关掉了保护）。
            --     注意：能走到这里，说明前面 startCount 的「拒绝」闸门已放行，
            --     即规模在用户设的上限内 —— 所以这里照他的意图走精确路径是安全的。
            local whole_book_allowed = downgradeEnabled() and (total_pages > WHOLE_BOOK_MAX_PAGES)
            if whole_book_allowed then
                logger.info("WordCount: skip whole-book path, total_pages="
                    .. tostring(total_pages) .. " exceeds "
                    .. tostring(WHOLE_BOOK_MAX_PAGES) .. " (memory guard)")
                if job.progress_dialog then
                    job.progress_dialog:setStatus(_("正在逐页统计字数…"))
                end
            else
                if job.progress_dialog then
                    job.progress_dialog:setStatus(_("正在读取全书文本…"))
                end
                local whole, whole_err = PageText.extractWholeBook(scan_doc)
                if type(whole) == "string" and #whole > 0 then
                    logger.info("WordCount: whole-book extraction OK, text length=" .. #whole)
                    job.whole_book = true
                    -- 一次性计数。注意：这里不做 per-page page_units（无法从整段文本
                    -- 反推每页归属），所以「已读字数」在这次统计里会退化成
                    -- 「按比例均分」。这是精度与「已读进度」之间的取舍，
                    -- 我们选择先保证**总字数准确**。
                    Counter.addPage(job.state, whole)
                    job.pages_with_text = job.page_count
                    job.page = job.page_count + 1
                    -- ★ 整书取文本拿不到「每页各有多少字」，但「已读字数」需要每页归属。
                    --   退而求其次：把总字数**按宽度均分**到每一页，让阅读进度功能
                    --   仍然可用（误差是「页与页之间字数的自然不均」，通常 <30%，
                    --   而总字数是精确的）。
                    --
                    -- ★★★ 性能修复（25-cache-perf）：
                    --   老写法每页调一次 `self:_pageKey(scan_doc, p)`，而 `_pageKey`
                    --   内部会执行 `doc:getPageXPointer(p)` —— crengine 的跨 C 层查询。
                    --   1000 页书就是 **1000 次**这种查询，而且整段是**同步**跑完的
                    --   （不在 tick 循环里，`scheduleIn` 在它之后），期间：
                    --     · 界面完全冻结，用户感觉「卡死」
                    --     · CPU 全速跑，绕过了 CHUNK_TICKS 的休息机制 ⇒ 费电
                    --   新写法只查**首页一次**取到 XPointer 前缀，其余页用「前缀+页号」
                    --   构造 key —— 调用次数 O(1)，跟页数无关。
                    --   key 只需满足「稳定且每页互不相同」，不要求是真 XPointer：
                    --   它只在本机的「已读统计」里做页标识，跨版本不共享。
                    do
                        local per = math.floor((tonumber(job.state.count) or 0)
                            / math.max(1, job.page_count))
                        local acc = 0
                        -- ★★★ 33-read-page-perf：模板逻辑抽到 `_pageKeyTemplate`，
                        --   和逐页路径共用一份 —— 两处各写一遍正是
                        --   25-cache-perf 修完又漏掉逐页路径的原因。
                        local stem = self:_pageKeyTemplate(scan_doc)
                        for p = 1, job.page_count do
                            local units = per
                            if p == job.page_count then
                                units = (tonumber(job.state.count) or 0) - acc
                            else
                                acc = acc + per
                            end
                            local key
                            if stem then
                                -- ★★ 双保险：即使 stem 因为某种未知 xpointer 形态仍留下
                                --    多个 %d，pcall 也只是让这一页退回页号 key，
                                --    不会把整个扫描带崩。
                                local ok_fmt, formatted = pcall(string.format, stem, p)
                                if ok_fmt and type(formatted) == "string" then
                                    key = formatted
                                else
                                    key = "p:" .. tostring(p)
                                end
                            else
                                -- 兜底：拿不到模板就直接用页号 key（仍然 O(1)）
                                key = "p:" .. tostring(p)
                            end
                            -- 与逐页路径使用同一个容量闸门。旧代码在这里直接写表，
                            -- 绕过 _recordPageUnits；自定义超大阈值时会为几十万页
                            -- 创建 key/value，老设备可能因此 OOM。总字数仍然准确。
                            if job.page_count <= MAX_TRACKED_PAGES then
                                job.page_units[key] = units
                            end
                        end
                        -- 顺带把模板记在 job 上，后续若因故重扫同一本可复用。
                        job._key_stem = stem
                        job._key_stem_tried = true
                    end
                    -- whole 是本地变量；先断开引用，给增量 GC 回收大字符串的机会。
                    whole = nil
                    job.whole_text = nil
                    collectgarbage("step")
                    if job.progress_dialog then
                        job.progress_dialog:updateProgress(job.page_count, true)
                    end
                    UIManager:scheduleIn(0.05, step)
                    return
                end
                logger.info("WordCount: whole-book extraction unavailable ("
                    .. tostring(whole_err) .. "), falling back to per-page scan")
                if job.progress_dialog then
                    job.progress_dialog:setStatus(_("正在逐页统计字数…"))
                end
            end   -- ★ 31: 闭合「页数未超阈值才走整书路径」的 else 分支
        end

        while job.page <= stop_at do
            local ok, text, extract_error = pcall(PageText.extract, scan_doc, job.page, job.page_count)
            if not ok or text == nil then
                job.failed_pages = job.failed_pages + 1
                local reason = ok and extract_error or text
                job.first_error = job.first_error or tostring(reason or "unknown extraction error")
                logger.warn("WordCount: failed to extract page", job.page, reason)
            else
                if text ~= "" then
                    job.pages_with_text = job.pages_with_text + 1
                    -- ★ 31-huge-book-guard：一次遍历同时得到「累计」与「本页增量」。
                    --   旧写法先 addPage（遍历一遍）再 Counter.count(text)
                    --   （**把同一段文本又遍历一遍**）只为拿本页字数 ——
                    --   页大时这是实打实的双倍 CPU，在 KPW4 上就是更长的卡顿。
                    local _total, page_units = Counter.addPage(job.state, text)
                    -- ★★★ 33-read-page-perf：**逐页路径也不能每页问一次
                    --   `getPageXPointer`**！
                    --
                    --   25-cache-perf 修的是「整书快路径里按页均分」那一处，
                    --   但**逐页路径这两个赋值点漏掉了** —— 它们仍然每页调一次
                    --   `self:_pageKey(scan_doc, job.page)`，也就是每页一次
                    --   跨 FFI 的 crengine 查询。
                    --
                    --   对几万页的「亿字书」，这就是**几万次**跨层调用，全部
                    --   串在 tick 循环里；而且 `getPageXPointer` 在超大文档上
                    --   本身就更慢（要定位段落）。这正是用户报的
                    --   「亿字的会卡顿然后重启」的第二个来源。
                    --
                    --   改用 `job.whole_book_key_stem`（首次用到时只查一次
                    --   首页 xpointer 当模板，其余页填页号）。查不到模板就
                    --   退回页号 key —— 与整书路径同一套逻辑，见
                    --   `_pageKeyTemplate` 的注释。
                    self:_recordPageUnits(job, scan_doc, job.page, page_units)
                else
                    self:_recordPageUnits(job, scan_doc, job.page, 0)
                end
            end
            job.page = job.page + 1
        end

        if job.page <= job.page_count then
            local done = job.page - 1
            local percent = math.floor(done * 100 / job.page_count + 0.5)
            -- ★ 进度上报频率（20-flicker-fix 重写）。
            --
            -- 旧代码的判据是「跨过 progress_step 页」，然后**每个 tick 都**调
            -- updateProgress。SCAN_TICK_DELAY=0.08s 时那是 12.5 次/秒的判定，
            -- 只要 progress_step 满足就立刻重绘 —— 在 Kindle 的 timerfd
            -- backend 下 scheduleIn 是内核精确唤醒，不会被 INPUT_TIMEOUT 的
            -- 200ms 伞挡住，所以真的是每秒刷 12.5 次，肉眼就是「不停闪」。
            --
            -- 现在改成**双闸门**：
            --   · 页数闸门：至少跨过 progress_step 页（保持进度条的观感连贯）
            --   · 时间闸门：距上次真实重绘至少 PROGRESS_REPORT_INTERVAL 秒
            -- 时间闸门在这里提前判一次，省掉 updateProgress 内部的时间换算；
            -- updateProgress 内部还有一层 MIN_REDRAW_INTERVAL 兜底。
            --
            -- 不要用 max(PAGES_PER_TICK, page_count/20)：那会把「每 tick 扫 16 页」
            -- 的批量大小误当成进度粒度。只要一本书 ≤320 页，progress_step 就恒为
            -- 16 —— 一本 20 页的书只被切成 2 段，进度条 0%→80%→100% 地跳；
            -- 一本 5 页的书更是一个 tick 就扫完，`done` 永远进不到比较分支，只有
            -- 收尾那次 updateProgress 生效，屏幕表现就是「进度条从头到尾不动」。
            -- 改为按页数均匀切成大约 20 段，粒度至少 1 页，且不超过每 tick 的
            -- 处理量（超过它本来也不会被触发）。
            local progress_step = math.max(1, math.min(PAGES_PER_TICK,
                math.ceil(job.page_count / 20)))
            -- ★★ 28-kpw4-tuning：时间源只 require 一次，缓存在模块级。
            --
            --   旧写法每个 tick 都执行
            --     pcall(function() now_t = require("ui/time").now() end)
            --   两个开销：
            --     (1) 每次分配一个**闭包**（GC 压力，KPW4 上 GC 是实打实的卡顿源）
            --     (2) 每次都走一遍 require 的 package.loaded 查表
            --   改成一次性取出 now() 函数缓存起来，tick 里直接调用。
            --   取不到就退回 os.time()（精度 1 秒，省电模式下够用）。
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
            -- ★★ 扫描期间**不发任何通知弹窗**（22-progress-only）。
            --
            -- 用户明确要求：「我要的是进度条显示，不是弹窗显示进度」。
            -- 进度信息只有一个出口 —— 对话框里的进度条 + 「已扫描 x / y 页」文字。
            -- 弹窗盖在对话框上，既费电（每次都是一次全屏刷新）又让人以为
            -- 「进度条不动、弹窗在动」。
            --
            -- 所以这里**彻底删掉**扫描循环里的 notifyUser。next_notice 只在
            -- 没有进度对话框（极端兜底情形）时才用一次。
            if not job.progress_dialog and done >= job.next_notice then
                notifyUser(T(_("正在统计全书：%1 / %2 页（%3%）"),
                    done, job.page_count, percent))
                job.next_notice = job.next_notice
                    + math.max(1, math.floor(job.page_count / 4))
            end
            -- ★★ 省电（22-progress-only）：每 CHUNK_TICKS 个 tick 让 CPU 休息一下。
            --
            -- 扫描是连续的 scheduleIn 自链，每个 tick 之间只隔 SCAN_TICK_DELAY。
            -- 如果整本书都不给系统喘息机会，CPU 就一直处在高频「醒-忙-醒-忙」
            -- 的状态，功耗明显高于阅读时「翻页才醒」的模型。
            -- 每 CHUNK_TICKS 个 tick 插一次 CHUNK_REST_DELAY 的长空闲：
            -- 这段时间不刷屏、不取文本，内核可以进 deeper idle / 降频。
            -- （28-kpw4-tuning：参数从 20/1.0 调成 10/1.2，面向老设备。
            --   具体值见文件上方常量定义处，**不要在这里写死数字** ——
            --   这行注释以前写的就是「每 20 个 tick（约 5 秒）」，
            --   改常量时忘了同步，成了误导。）
            --
            -- 感知上完全看不出来（进度条只是偶尔走一下），但整体能耗更平滑。
            job.tick_count = (job.tick_count or 0) + 1
            -- ★★★ 37i-huge-book-oom：**主动 GC**，压住内存峰值。
            --   逐页扫一本几万页的书要跑几万个 tick，每 tick 都会产生临时字符串
            --   （`PageText.extract` 的返回值、normalize 的结果等）。Lua 的 GC 是
            --   增量式的，如果从不主动跑，堆会一直涨到触发「全量 GC 的一刻」——
            --   那一次停顿在 KPW4 上很明显，而且峰值内存叠上 crengine 内部缓存
            --   （它不归 Lua GC 管）就够把 512MB 撑爆 → 内核 OOM Killed → 重启。
            --   每 8 个 tick 跑一次 `collectgarbage("step")`（增量、几乎无停顿），
            --   让内存平稳回收，而不是攒到最后一次性收。
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
        if job.progress_dialog then job.progress_dialog:updateProgress(job.page_count, true) end
        releaseBackgroundDocument()
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
        -- ★★★ 26-sample-estimate：抽页模式的结果要从「样本页字数」外推到「全书字数」。
        --
        -- 扫描阶段只扫了前 scan_pages 页（= job.page_count），job.state.count 是
        -- **样本总和**。估算全书用「平均每页字数 × 全书页数」：
        --     sample_total / scan_pages * total_pages
        -- 其中用「实际有文本的页数」而不是 scan_pages 当分母更准 ——
        -- 章节首页、插图页、空白页会拉低平均，用有效页数当分母能少受它们干扰。
        --
        -- ★ 样本量为 0（一页都没提到文本）时上面已经 return 了，这里不会除零。
        --
        -- ★★ 第二道保险（26-sample-popup）：即便将来有人再放开整书快路径，
        --    只要 `job.whole_book` 为真，就说明 state.count 已经是**全书口径**，
        --    绝不能再外推一次。抽页模式走不到这里（上面已禁止整书路径），
        --    这一条是为「完整扫描模式误入整书路径」兜底，也顺手把语义写死。
        local sample_total = tonumber(job.state.count) or 0
        local total = sample_total
        local sampled = job.sampled == true
        if job.whole_book == true then
            -- 整书一次数完 → 本身即全书口径，禁止外推。
            sampled = false
        end
        if sampled then
            local eff = tonumber(job.pages_with_text) or 0
            if eff <= 0 then eff = tonumber(job.page_count) or 1 end
            if eff > 0 then
                local per_page = sample_total / eff
                total = math.floor(per_page * (tonumber(job.total_pages) or job.page_count) + 0.5)
            end
        end
        logger.info("WordCount: result sample_total=" .. tostring(sample_total)
            .. " scan_pages=" .. tostring(job.page_count)
            .. " total_pages=" .. tostring(job.total_pages)
            .. " sampled=" .. tostring(sampled)
            .. " final_total=" .. tostring(total))

        -- ★ 把外推后的总量回写到 state.count，让下游（读状态、全局统计、
        --   提示文案）拿到的是**全书**口径，而不是样本口径。
        if sampled then
            job.state.count = total
        end

        settings:saveSetting(KEY_COUNT, total)
        settings:saveSetting(KEY_MTIME, job.mtime)
        settings:saveSetting(KEY_SIZE, job.size)
        -- ★ 记录「这个数字是怎么来的」：下次读缓存时能告诉用户「这是估算值，
        --   想看精确的就点重新统计」。旧版本没有这个键 → 当作精确值（向后兼容）。
        if sampled then
            settings:saveSetting(KEY_ESTIMATED, true)
            -- ★★★ 30-estimate-shadow-fix：这里以前存的是 job.page_count，那只是
            --   **扫描上限**（前 100 页），而外推的分母其实是**有文本的页数**
            --   （job.pages_with_text，例如只有 80 页有字）。拿 100 去展示
            --   「依据：前 100 页推算」会**夸大样本量、让用户低估误差**。
            --   改存真正的分母；极端情况（pages_with_text 为 0/未知）回退扫描上限。
            local eff_pages = tonumber(job.pages_with_text) or 0
            if eff_pages <= 0 then eff_pages = tonumber(job.page_count) or 0 end
            settings:saveSetting(KEY_SAMPLED_PAGES, eff_pages)
        else
            settings:saveSetting(KEY_ESTIMATED, nil)
            settings:saveSetting(KEY_SAMPLED_PAGES, nil)
        end
        settings:flush()
        -- ★★ 24-cache-reuse：同时写全局缓存 —— 下次点「统计全书字数」
        --    会直接命中这里，不再重复扫描。
        --    注意用**文件当前的真实指纹**，而不是 job 里那个扫描开始时抓的快照：
        --    扫描期间文件不太可能变，但用最新值更稳妥（万一变了，缓存下次自然失效）。
        do
            local cur_mtime, cur_size = fileFingerprint(path)
            writeCachedCount(path, total, cur_mtime or job.mtime, cur_size or job.size,
                sampled)
        end

        -- ★★★ 26-sample-estimate 修的一个真 bug：
        --   这两处以前传的是 job.page_count。抽页模式下 job.page_count 已经
        --   变成「扫描上限」（100），不是全书页数 —— 若照旧传下去：
        --     1) read_state.page_count = 100（这本 1000 页的书）
        --     2) ReadingStats.isValidForFile(read_state, 100, ...) 会与真实
        --        页数不符，每次打开都判定「失效 → 重建」，阅读进度全丢
        --     3) 已读页码百分比按 100 算 → 读到第 500 页 = 500%
        --   所以这两处必须用 **全书页数** job.total_pages。
        --
        --   ★ 另外：抽页模式下 job.page_units 里那 100 条是「按页均分」出来的
        --   **假数据**（只求过一次平均），不能拿它去覆盖**已有的、真实的**
        --   逐页字数表 —— 否则用户之前精确统计过的页码字数会被抹成平均值，
        --   「已读字数」立刻失真。
        --   但也不能一味不写：如果这本书从来没有逐页数据，那一味跳过会让
        --   「已读字数」永远是 0（用户读了半天却显示 0，更糟）。
        --   所以判据是「**有没有已有的真实逐页数据**」：
        --     有 → 保留（不覆盖）；没有 → 用样本均值垫一份（近似，聊胜于无）。
        --   ★★★ 30-estimate-shadow-fix：垫数据必须**打上「估算」标记**。
        --   否则（旧行为）:
        --     1) applySampledPageUnits 给前 100 页填样本均值
        --     2) 之后 _getPageUnits 见 page_units[key] 非空 → 直接返回均值
        --     3) 用户真读到第 5 页 → 显示的还是均值，**真实逐页字数被永久遮蔽**
        --   所以两条一起改：
        --     · 这里用 setEstimatedPageUnits 写（同时记进 page_units_estimated）
        --     · _getPageUnits 遇「估算值」不短路，照常 extract 并覆盖
        --
        --   判据也收紧为「**page_units 与 page_seconds 同时为空**」：
        --   只有这种情况才确定是「这本书从没有过真实逐页数据」（全新，或
        --   _ensureReadState 因指纹变化重建过），垫一份均值聊胜于无；
        --   只要有任何一侧有真实数据，就一律不动，绝不覆盖。
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
        -- ★★★ 37m：扫描收尾立刻落盘（force_flush=true）——用户扫完就等着看
        --   总览数字，不能让它卡在「第 8 次才写」的批次里。
        self:_syncGlobalBook(read_state, false, path, nil, true)
        self._scan_path = nil
        if self:_batchAlive(job) then job.batch.completed = job.batch.completed + 1 end
        -- 是否处于「一个批次里」要看 self._batch，而不是 batch_mode 参数：
        -- startCountForPath（从书菜单点单本）也会传 batch_mode=true，但它
        -- 根本不是批量任务（self._batch 为 nil），对话框必须照常关闭。
        -- 只有真正在批量里才保留对话框给下一本复用（整批结束才关）。
        -- ★★★ 30-estimate-shadow-fix：这里以前用 `self._batch ~= nil`。
        --   但 _job 还没清（下面才清），self._batch 可能已经换成**另一批**
        --   （取消后立刻发起新批量）⇒ 对话框会被错误地留给新批。改用
        --   _batchAlive(job)：只认「自己那一批仍是当前批」。
        local in_batch = self:_batchAlive(job)
        -- ★ 22-progress-only：完成结果也走对话框，不走弹窗。
        --
        -- 以前这里的顺序是：先 close 掉对话框，再 notifyUser 弹一条「统计完成：…」。
        -- 用户看到的就是「对话框消失 → 屏幕中央弹一个小通知」，还是弹窗形态。
        -- 现在改成：把结果**写进对话框**（进度条拉满到 100%）显示几秒，
        -- 用户看完了自己让它关，或者我们延时关。
        --
        -- 关掉对话框的时机：单本 → 显示 3 秒后自动关；
        --                   批量 → 留给下一本复用，整批结束再关。
        if job.progress_dialog then
            if type(job.progress_dialog.setStatus) == "function" then
                -- ★★★ 37i：如果是「书太大被强制降级」，明说是估算、并说明原因，
                --   否则用户会以为我们把他要的精确值做错了。
                if job.huge_book_forced_sample then
                    job.progress_dialog:setStatus(
                        T(_("书太大（%1 页），为防卡死改用估算：全书约 %2 个阅读单位"),
                            fmtCount(total_pages), fmtCount(total)))
                else
                    job.progress_dialog:setStatus(
                        T(_("统计完成：全书约 %1 个阅读单位"), fmtCount(total)))
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
                notifyUser(T(_("书太大（%1 页），为防卡死改用估算：全书约 %2 个阅读单位"),
                    fmtCount(total_pages), fmtCount(total)))
            else
                notifyUser(T(_("统计完成：全书约 %1 个阅读单位"), fmtCount(total)))
            end
        end
        if batch_mode and in_batch then self:_startNextBatch() end
        -- ★★★ 36：如果这次扫描是「打开阅读统计」时顺带起的（当前书没数据），
        --   扫完就把统计页打开 —— 这就是用户要的「打开时有扫描 → 显示进度条 →
        --   扫完看到数字」。
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
