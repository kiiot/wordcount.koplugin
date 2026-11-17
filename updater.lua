--[[
在线更新：查 GitHub Releases → 下载 zip → 解压覆盖插件目录 → 提示重启。

只做「用户点菜单才检查」，不做后台轮询（省电、不打扰）。
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Device = require("device")
local DataStorage = require("datastorage")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Updater = {}

local REPO = "kiiot/wordcount.koplugin"
local API_LATEST = "https://api.github.com/repos/" .. REPO .. "/releases/latest"
local RELEASES_PAGE = "https://github.com/" .. REPO .. "/releases"

--- 本模块所在目录（即插件目录，含末尾斜杠）。
local self_dir = (debug.getinfo(1, "S").source:match("^@(.*/)updater%.lua$") or "./")
local UA = "KOReader-WordCount/1.4.0"

--===========================================================================
-- 版本
--===========================================================================

function Updater.getInstalledVersion()
    local ok, meta = pcall(dofile, self_dir .. "_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return "0"
end

local function parseVersion(v)
    local parts = {}
    for part in tostring(v):gsub("^v", ""):gmatch("[^.%-+]+") do
        local n = tonumber(part)
        if n then table.insert(parts, n) end
    end
    return parts
end

--- v1 是否比 v2 新。
local function isNewer(v1, v2)
    local a, b = parseVersion(v1), parseVersion(v2)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

--===========================================================================
-- 网络
--===========================================================================

local function getJSON(url, timeout_block, timeout_total)
    local ok, body = pcall(function()
        local http = require("socket/http")
        local ltn12 = require("ltn12")
        local socket = require("socket")
        local socketutil = require("socketutil")
        local chunks = {}
        socketutil:set_timeout(timeout_block or 10, timeout_total or 30)
        local ok_req, code = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = UA,
                    ["Accept"] = "application/vnd.github.v3+json",
                },
                sink = ltn12.sink.table(chunks),
                redirect = true,
            })
        end)
        socketutil:reset_timeout()
        if ok_req and code == 200 then
            return table.concat(chunks)
        end
        return nil
    end)

    if ok and body then
        local ok_json, data = pcall(require("json").decode, body)
        if ok_json then return data end
    end

    -- 桌面 / 安卓兜底（Kindle 上通常没有 curl，popen 失败即返回 nil）
    local handle = io.popen(string.format(
        "curl -sL -m 30 -H 'User-Agent: %s' %q", UA, url))
    if handle then
        local raw = handle:read("*a")
        handle:close()
        if raw and raw ~= "" then
            local ok_json, data = pcall(require("json").decode, raw)
            if ok_json then return data end
        end
    end
    return nil
end

local function downloadFile(url, path)
    local ok = pcall(function()
        local http = require("socket/http")
        local ltn12 = require("ltn12")
        local socket = require("socket")
        local socketutil = require("socketutil")
        local file = io.open(path, "wb")
        if not file then error("无法写入 " .. path) end
        socketutil:set_timeout(15, 300)
        local ok_req, code = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                method = "GET",
                headers = { ["User-Agent"] = UA },
                sink = ltn12.sink.file(file),
                redirect = true,
            })
        end)
        socketutil:reset_timeout()
        file:close()
        if not (ok_req and code == 200) then
            error("HTTP " .. tostring(code))
        end
    end)
    if ok then return true end

    os.remove(path)
    local ret = os.execute(string.format("curl -sfL -m 300 -o %q %q", path, url))
    return ret == 0 or ret == true
end

--- 解压 zip 到 dest，剥掉压缩包的顶层目录（GitHub 的包会包一层）。
local function unpackStripRoot(zip_path, dest)
    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not (ok_req and Archiver and Archiver.Reader) then
        return false, _("缺少解压组件（ffi/archiver）")
    end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        local err = arc.err
        arc:close()
        return false, err or _("无法打开压缩包")
    end
    local err
    for entry in arc:iterate() do
        local rel = entry.path and entry.path:match("^[^/]+/(.+)$")
        if rel and rel ~= "" then
            if not arc:extractToPath(entry.path, dest .. "/" .. rel) then
                err = arc.err or _("解压失败")
                break
            end
        end
    end
    arc:close()
    if err then return false, err end
    return true
end

--===========================================================================
-- UI
--===========================================================================

local function info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

local function openReleasesPage(message)
    if type(Device.canOpenLink) == "function" and Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text = message .. "\n\n" .. _("在浏览器中打开 Releases 页面？"),
            ok_text = _("打开"),
            ok_callback = function()
                Device:openLink(RELEASES_PAGE)
            end,
        })
    else
        info(message .. "\n" .. RELEASES_PAGE, 6)
    end
end

local function stripMarkdown(text)
    text = tostring(text or "")
    text = text:gsub("\r\n", "\n")
    text = text:gsub("#+%s*", "")
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("%*(.-)%*", "%1")
    text = text:gsub("`(.-)`", "%1")
    return text
end

--===========================================================================
-- 安装
--===========================================================================

-- 下载并覆盖安装。
function Updater.install(zip_url, new_version)
    info(_("正在下载更新…"), 1)
    UIManager:scheduleIn(0.1, function()
        local cache_dir = DataStorage:getSettingsDir()
        local zip_path = cache_dir .. "/wordcount_update.zip"

        if not downloadFile(zip_url, zip_path) then
            os.remove(zip_path)
            openReleasesPage(_("下载失败。"))
            return
        end

        -- 覆盖自身目录；不可写时退到标准插件目录
        local dest = self_dir:gsub("/$", "")
        local ok, err = unpackStripRoot(zip_path, dest)
        if not ok then
            local fallback = DataStorage:getDataDir() .. "/plugins/wordcount.koplugin"
            ok, err = unpackStripRoot(zip_path, fallback)
            if ok then dest = fallback end
        end
        os.remove(zip_path)

        if not ok then
            logger.warn("WordCount updater: 安装失败 " .. tostring(err))
            info(T(_("安装失败：%1\n请手动下载覆盖。"), tostring(err)), 6)
            return
        end

        logger.info("WordCount updater: 已更新到 " .. new_version .. " -> " .. dest)
        UIManager:show(ConfirmBox:new{
            text = T(_("已更新到 v%1。\n\n现在重启 KOReader 生效？"), new_version),
            ok_text = _("重启"),
            ok_callback = function()
                UIManager:restartKOReader()
            end,
        })
    end)
end

--===========================================================================
-- 检查
--===========================================================================

function Updater.check()
    local installed = Updater.getInstalledVersion()

    NetworkMgr:runWhenOnline(function()
        info(_("正在检查更新…"), 1)
        UIManager:scheduleIn(0.1, function()
            local release = getJSON(API_LATEST)
            if not release or not release.tag_name then
                openReleasesPage(_("检查更新失败（网络或 GitHub 接口不可达）。"))
                return
            end
            if release.draft or release.prerelease then
                info(T(_("当前已是最新版本 v%1。"), installed), 3)
                return
            end

            local latest = tostring(release.tag_name):gsub("^v", "")
            if not isNewer(latest, installed) then
                info(T(_("当前已是最新版本 v%1。"), installed), 3)
                return
            end

            local zip_url
            for _i, asset in ipairs(release.assets or {}) do
                if asset.name and asset.name:match("%.zip$") then
                    zip_url = asset.browser_download_url
                    break
                end
            end

            local viewer
            local buttons = {
                {
                    {
                        text = _("关闭"),
                        callback = function()
                            UIManager:close(viewer)
                        end,
                    },
                    {
                        text = _("更新并重启"),
                        callback = function()
                            UIManager:close(viewer)
                            if not zip_url then
                                openReleasesPage(_("这个版本没有可下载的 zip。"))
                                return
                            end
                            Updater.install(zip_url, latest)
                        end,
                    },
                },
            }

            viewer = TextViewer:new{
                title = T(_("发现新版本 v%1"), latest),
                text = T(_("已安装：v%1\n最新版本：v%2\n\n%3"),
                    installed, latest,
                    (release.body and release.body ~= "")
                        and stripMarkdown(release.body)
                        or _("（该版本没有更新说明）")),
                buttons_table = buttons,
                add_default_buttons = false,
            }
            UIManager:show(viewer)
        end)
    end)
end

return Updater
