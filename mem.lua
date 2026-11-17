-- 内存探测 —— 只读 /proc，零依赖。
--
-- 为什么需要它：在 512MB 内存的阅读器（Kindle PW4 之类）上，插件最危险的
-- 动作是「一次性把全本文本读成一个 Lua 字符串」。这一步的分配量取决于**这本
-- 书本身有多大**，而书有多大事先是不知道的 —— 所以不能用任何静态阈值去猜。
-- 唯一可靠的判据是「此刻系统还剩多少能分配的内存」。
--
-- 注意：这里读的是 MemAvailable 而不是 MemFree。MemFree 会把可回收的页缓存
-- 排除在外，看起来小得离谱；MemAvailable 是内核估算的「真正还能分配出去的量」，
-- 才是判断会不会被 OOM Killer 干掉的那条线。
local M = {}

-- 剩余内存低于这个值：立刻停止扫描，按已扫的比例估算收尾。
-- ⚠ 定得太高会在本该能扫完的书上误伤，太低就来不及刹车。
-- 28MB 是针对 512MB 设备 + crengine 已有 120~150MB 常驻的情况。
M.ABORT_AVAIL_MB = 28

-- 剩余内存低于这个值：进入「紧张模式」——
-- 块扫描的块减半、GC 更频繁（宁可慢一点，也不要把自己顶穿）。
M.TIGHT_AVAIL_MB = 70

local function readFile(path)
    -- 某些 Lua 运行时（或受限环境）没有 io 库；拿不到就返回 nil，
    -- 让调用方走「不知道」的保守分支，而不是在这里抛错。
    if type(io) ~= "table" or type(io.open) ~= "function" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local ok, text = pcall(f.read, f, "*a")
    pcall(f.close, f)
    if not ok then return nil end
    return text
end

local function toMB(kb)
    local n = tonumber(kb)
    if not n or n <= 0 then return nil end
    return n / 1024
end

-- 系统还能分配多少内存（MB）。读不到就返回 nil —— 调用方必须把 nil
-- 当作「不知道」，退回保守策略，绝不能当成「内存充足」。
function M.availableMB()
    local text = readFile("/proc/meminfo")
    if not text then return nil end
    local avail = text:match("MemAvailable:%s*(%d+)%s*kB")
    if avail then return toMB(avail) end
    -- 3.14 以前的内核没有 MemAvailable，退回 Free+Buffers+Cached 的粗估。
    local free = tonumber(text:match("MemFree:%s*(%d+)%s*kB") or 0)
    local buffers = tonumber(text:match("Buffers:%s*(%d+)%s*kB") or 0)
    local cached = tonumber(text:match("^[^/]-Cached:%s*(%d+)%s*kB") or 0)
    local sum = free + buffers + cached
    if sum > 0 then return toMB(sum) end
    return nil
end

-- 本进程当前常驻内存（MB），只用于日志对照。
function M.rssMB()
    local text = readFile("/proc/self/status")
    if not text then return nil end
    return toMB(text:match("VmRSS:%s*(%d+)%s*kB"))
end

-- 本进程历史峰值（VmHWM），只用于日志对照。
function M.peakMB()
    local text = readFile("/proc/self/status")
    if not text then return nil end
    return toMB(text:match("VmHWM:%s*(%d+)%s*kB"))
end

-- 剩余内存已经低到必须立刻停手。
function M.critical()
    local a = M.availableMB()
    return a ~= nil and a < M.ABORT_AVAIL_MB, a
end

-- 剩余内存偏紧：放慢、减小块、勤 GC。
function M.tight()
    local a = M.availableMB()
    return a ~= nil and a < M.TIGHT_AVAIL_MB, a
end

-- 一行日志，同时带上系统剩余与本进程占用，方便事后校准阈值。
function M.describe()
    local a, r, p = M.availableMB(), M.rssMB(), M.peakMB()
    local function fmt(v) return v and string.format("%.1f", v) or "?" end
    return "avail=" .. fmt(a) .. "MB rss=" .. fmt(r) .. "MB peak=" .. fmt(p) .. "MB"
end

-- 扫描期间把 GC 调激进一点。
--
-- LuaJIT 默认 pause=200，意思是「等内存涨到上轮的两倍再回收」—— 对这台机器
-- 就是「涨到 120MB 才开始收」。统计过程中会不断产生临时字符串（每页/每块的
-- 文本），默认策略会一路顶到 200MB+ 才动手，正好撞上 OOM。
-- 调成 130 = 涨 30% 就收，代价是多花点 CPU（反正扫描本来就慢），换来峰值明显下降。
local DEFAULT_PAUSE = nil

function M.beginScan()
    if DEFAULT_PAUSE == nil then
        local ok, v = pcall(collectgarbage, "setpause", 200)
        DEFAULT_PAUSE = (ok and tonumber(v)) or 200
        pcall(collectgarbage, "setpause", 200)
    end
    pcall(collectgarbage, "setpause", 130)
    pcall(collectgarbage, "setstepmul", 300)
end

function M.endScan()
    pcall(collectgarbage, "setpause", DEFAULT_PAUSE or 200)
    pcall(collectgarbage, "setstepmul", 200)
end

return M
