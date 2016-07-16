local Waterfall = {}

Waterfall.Event = {
    kEleHide            = 1, -- 条条不在显示区域内
    kEleOnLine          = 2, -- 条条是显示的并且压基准线了
    kEleShownFromHide   = 3, -- 条条在从隐藏状态切换到了显示区域内
    kEleShownFromOnLine = 4, -- 条条从压线状态切换到显示在区域内的状态
    kElePosChanged      = 5, -- 条条的位置改变了(只有在显示区域内的条条才会收到此通知)
    kEleSizeChanged     = 6, -- 条条的大小改变了(只有在显示区域内的条条才会收到此通知)
    kBarLineShown       = 7, -- 显示一条小节线
    kBarLineHide        = 8, -- 隐藏一条小节线
    kBarLineYChanged    = 9, -- 小节线y坐标发生改变了
}

Waterfall.ViewState = {
    kOutView    = 1, -- 不在显示区域内
    kInView     = 2, -- 在显示区域内
    kOnViewLine = 3, -- 在显示区域内，并且压基准线
}

------------------------| 内部工具 |------------------------

local sInitTick = -9999
--[[
@brief 将tick转换成对应的y坐标
--]]
local function tick2y(tick, eleHPerSec, speed, midi)
    return eleHPerSec * UtilsMusicCore:ticksToSeconds(tick, midi) / speed
end

------------------------| 外部接口 |------------------------
--[[
@brief 创建瀑布流
@param w, h 视图的宽高
@param midi 用于生成瀑布流的midi事件
@param elePosInfo { 用于定位瀑布流条的信息
    [pitch1] = {瀑布流条的宽度, 左下角为锚点的x坐标},
    [pitch2] = {瀑布流条的宽度, 左下角为锚点的x坐标},
    ...
}
@param eventCB(eleID, eventType, ...)
    kElePosChanged 将传递x, y
    kEleSizeChanged 将传递w, h
    kEleOnLine, kEleShownFromHide, kEleShownFromOnLine 将传递一个info表。表结构见下面的tryAddEleInfo函数
    kBarLineYChanged 将传递小节线的y坐标
    其它事件传递nil
@param speed 滚动速率, 默认为1.0
@param hand Waterfall.Hand 类型。指定midi表示哪只手。双手或者不知道使用哪个手就传递nil
--]]
function Waterfall:init(w, h, midi, elePosInfo, eventCB, speed, hand)
    self._midi            = midi
    self._eventCB         = assert(eventCB)
    self._eleHPerSec      = 160          -- 每秒物理时间在瀑布流表现为多长
    self._speedScale      = speed or 1.0 -- 速率
    self._eleList         = {}           -- 条条的信息列表
    self._viewEleList     = {}           -- 能看到的瀑布流元素信息
    self._barlineList     = {}           -- 小节线位置信息列表
    self._w               = w            -- 视图区域的宽度
    self._h               = h            -- 视图区域的高度
    self._curTick         = sInitTick
    self._midi            = midi
    self._ticksPerBar     = 4 / midi:getTimeBeatType() * 480 * midi:getTimeBeats()

    -- 确定手
    local is1Track = midi:getTrackNumber() == 1
    local function getHand(track, pitch)
        if is1Track then
            -- 如果midi只有一条轨，那么根据pitch 小于C4就当是左手
            return (pitch < 48) and PLAY_HAND.LEFT or PLAY_HAND.RIGHT
        else
            -- 如果midi有两条轨，那么根据track来判定
            return (0 == track) and PLAY_HAND.RIGHT or PLAY_HAND.LEFT
        end
    end

    -- 瀑布流配置生成
    local defaultVState = Waterfall.ViewState.kOutView
    local function tryAddEleInfo(e, endTick, pitch)
        local posInfo = elePosInfo[pitch]
        local sTick   = e:getTick()
        -- 生成一个配置, y和h在updateLayout中被确定
        local info = {
            w         = posInfo[1],
            h         = 0,
            x         = posInfo[2],
            y         = 0,
            pitch     = pitch,
            finger    = e:getFinger(),
            startTick = sTick,
            endTick   = endTick,
            hand      = getHand(e:getTrack(), pitch),
            viewState = defaultVState,
        }
        table.insert(self._eleList, info)
    end

    -- 遍历midi事件，生成瀑布流信息
    local events = midi:getEvents(hand or PLAY_HAND.BOTH, -1, -1)
    local onEvents = {}
    for _, e in ipairs(events) do
        if e:getType() == MIDI_EVENT_TYPE.PITCH then
            local pitch = e:getPitch()
            if e:isOn() then
                onEvents[pitch] = e
            else
                local pree = onEvents[pitch]
                if pree then
                    tryAddEleInfo(pree, e:getTick(), pitch)
                    onEvents[pitch] = nil
                end
            end
        end
    end

    -- 更新UI信息
    if #self._eleList > 0 then
        -- 根据startTick来排序
        table.sort(self._eleList, function(a, b)
            return a.startTick < b.startTick
        end)
        self:updateLayout()
        self:scrollToTick(self._eleList[1].startTick)
    end
end

--[[
@brief 用于判定碰撞，更新ele的显示情况，创建ele，发送事件
--]]
function Waterfall:updateElements()
    if self._curTick == sInitTick then return end
    -- 获得能够显示的区间
    local sy = tick2y(self._curTick, self._eleHPerSec, self._speedScale, self._midi)
    local ey = sy + self._h
    local viewState = Waterfall.ViewState
    -- 通过info获取这个显示元素的显示状态
    local function getViewState(y, hy)
        if hy <= sy or y > ey then
            return viewState.kOutView
        end

        if y <= sy and hy > sy then
            return viewState.kOnViewLine
        end

        return viewState.kInView
    end

    -- 遍历正在显示的元素，调整他们的位置，执行更新和删除操作
    local callback = self._eventCB
    local event = Waterfall.Event
    local viewList = self._viewEleList
    local viewKeys = {}
    for k in pairs(viewList) do
        table.insert(viewKeys, k)
    end
    table.sort(viewKeys)
    for _, i in ipairs(viewKeys) do
        local info = viewList[i]
        -- 判定碰撞
        local y = info.y
        local vst = getViewState(y, info.h + y)
        local prevst = info.viewState -- 当前肯定是显示的状态

        info.viewState = vst
        -- 如果已经看不见了那么就直接发送消失信号
        if vst == viewState.kOutView then
            -- 从显示列表中删除
            viewList[i] = nil
            callback(i, event.kEleHide)
        else
            callback(i, event.kElePosChanged, info.x, y - sy)
            if vst ~= prevst then
                callback(i, (vst == viewState.kOnViewLine) and event.kEleOnLine or event.kEleShownFromOnLine, info)
            end
        end
    end

    -- 遍历列表调整不在原显示范围内的瀑布流条信息
    for i, info in ipairs(self._eleList) do
        -- 只更新不在显示区域内的元素
        local y = info.y
        local hy = info.h + y
        if y > ey then break end

        if hy > sy and not viewList[i] then
            local vst = getViewState(y, hy)
            local prevst = info.viewState -- 当前肯定是隐藏的
            if vst ~= prevst then
                info.viewState = vst
                viewList[i] = info
                callback(i, (vst == viewState.kInView) and event.kEleShownFromHide or event.kEleOnLine, info)
                callback(i, event.kElePosChanged, info.x, y - sy)
            end
        end
    end

    -- 调整小节线的位置
    local barlineViewH = self._barlineViewH
    for i, y in ipairs(self._barlineList) do
        local curY = y - sy % barlineViewH
        if curY < 0 then
            curY = barlineViewH + curY
        end
        callback(i, event.kBarLineYChanged, curY)
    end
end

--[[
@brief 重新布局UI
--]]
function Waterfall:updateLayout()
    -- 遍历瀑布信息，根据高度和速度更新配置
    local midi = self._midi
    local ehp = self._eleHPerSec
    local sps = self._speedScale

    for _,info in ipairs(self._eleList) do
        local sy = tick2y(info.startTick, ehp, sps, midi)
        local ey = tick2y(info.endTick, ehp, sps, midi)
        info.y = sy
        info.h = ey - sy
    end
    -- 遍历正在显示的元素，调整他们的显示大小
    local callback = self._eventCB
    local et = Waterfall.Event.kEleSizeChanged
    for i, info in pairs(self._viewEleList) do
        -- 触发回调
        callback(i, et, info.w, info.h)
    end
    ------ 调整小节线的布局信息 --------
    -- 确定像是多少个小节线
    local bh = tick2y(self._ticksPerBar, ehp, sps, midi) -- 每小节多高
    local bn = math.floor(self._h / bh) + ((self._h % bh) > 0 and 1 or 0)
    local function updateBarLineY(curBn)
        -- 更新小节线的初始Y坐标位置
        if curBn == 0 then return end
        for i = 1, curBn do
            self._barlineList[i] = (i - 1) * bh
        end
    end
    -- 调整小节线的数量
    local curBn = #self._barlineList
    local offN  = bn - curBn
    if offN ~= 0 then
        if offN > 0 then
            et = Waterfall.Event.kBarLineShown
            for i = curBn + 1, curBn + offN do
                table.insert(self._barlineList, i, 0)
                callback(i, et)
            end
        else
            et = Waterfall.Event.kBarLineHide
            for i = curBn, curBn + offN + 1, -1 do
                table.remove(self._barlineList, i)
                callback(i, et)
            end
        end
        curBn = curBn + offN
    end
    updateBarLineY(curBn)
    -- 保存下小节线所在视图的高度
    self._barlineViewH = curBn * bh

    self:updateElements()
end

--[[
@brief 滚动到某个tick指定的位置
--]]
function Waterfall:scrollToTick(tick)
    if self._curTick == tick then return end
    self._curTick = tick
    self:updateElements()
end

--[[
@brief 设置瀑布流的滚动速率
@param s取值(0, 1]
--]]
function Waterfall:setFlowSpeedScale(s)
    if (s == self._speedScale) or (s <= 0) or (s > 1) then return end
    self._speedScale = s
    self:updateLayout()
end

--[[
@brief 设定每秒物理时间内，瀑布流将滚动多少像素的高度
@param h 取值最小为100
--]]
function Waterfall:setEleHeightPerSec(h)
    if h < 100 or h == self._eleHPerSec then return end
    self._eleHPerSec = h
    self:updateLayout()
end

return Waterfall
