local function getRes(fileName)
    return "waterfall_test_" .. fileName
end

-- 创建瀑布流的数据模型
local sDataModel = require("Waterfall")
local function isWhiteKey(pitch)
    local normalPitch = pitch % 12
    if normalPitch < 5 then
        return (normalPitch % 2) == 0
    else
        return (normalPitch % 2) == 1
    end
end
------------------------| 瀑布流元素 |------------------------
local Ele = class("WaterfallEle", cc.Node)

function Ele:ctor(pitch, hand, finger, tick)
    -- 创建显示的条条
    local keyColorName = isWhiteKey(pitch) and "white" or "black"
    local handName = (hand == PLAY_HAND.RIGHT) and "right" or "left"
    local sp = display.newNode()
    local icon = display.newSprite(string.format("ui_waterfall_note_%s_key.png", keyColorName))
    icon:setPositionY(icon:getContentSize().width / 2)
    local tail = display.newSprite(string.format("ui_waterfall_note_tail_%s.png", handName),
        {scale9 = true, size = cc.size(16, 20), capInsets = cc.size(0, 0, 16, 5)})
    tail:setPositionY(icon:getContentSize().width / 2)
    tail:setAnchorPoint(0.5, 0)
    sp:addChild(tail)
    sp:addChild(icon)
    self.pitch = pitch
    self.tick = tick
    self:addChild(sp)

    local fingerLabel = nil
    -- 创建指法显示label
    if finger and finger > 0 and finger < 6 then
        fingerLabel = display.newTTFLabel({text = tostring(finger), size = 15})
        fingerLabel:setAnchorPoint(display.CENTER_BOTTOM)
        fingerLabel:setPositionY(3)
        self:addChild(fingerLabel)
    end

    -- 设置大小
    function self.setSize(w, h)
        local preSize = self:getContentSize()
        if not w then
            w = preSize.width
        end
        if not h then
            h = preSize.height
        end
        -- NOTE(zhangyufei): 留出一个间隙
        -- h = h - 4
        local newSize = cc.size(w, h)

        tail:setContentSize(tail:getContentSize().width, h)
        self:setContentSize(newSize)

        -- 调整显示指法的label大小
        if fingerLabel then
            local labelW = fingerLabel:getContentSize().width
            if labelW > w then
                fingerLabel:setScale(w / labelW * 0.8)
            end
        end
    end

    -- 设置指法
    function self.enableFingering(b)
        if fingerLabel then
            fingerLabel:setVisible(b)
        end
    end
end
------------------------| 瀑布流按下特效 |------------------------
local EleOnLineEffectNode = class("EleOnLineEffectNode", cc.Node)

function EleOnLineEffectNode:ctor()
    ------------------------| 构造函数 |------------------------
    local viewEffs = {}
    local freeEffs = {}
    local frameCache = cc.SpriteFrameCache:getInstance()

    -- 缓冲资源
    frameCache:addSpriteFrames(getRes("kala_eff.plist"))
    local frames = {}
    for i = 1, 4 do
        local m =
        table.insert(frames, m)
    end
    ------------------------| 外部接口 |------------------------
    function self.show(pitch, w, x)
        local eff = viewEffs[pitch]
        if eff then return end

        eff = table.remove(freeEffs)
        if not eff then
            -- 创建一个新的特效
            local ac = nil
            ac, eff = display.newSprite("ui_waterfall_hit_light.png")
            eff:runAction(cc.RepeatForever:create(cc.Animate:create(ac)))
            eff:setAnchorPoint(display.CENTER_BOTTOM)
            eff:retain()
        end

        viewEffs[pitch] = eff
        self:addChild(eff)
        eff:setPositionX(x)
    end

    --[[
    @brief 如果不指定pitch，那么将隐藏全部的特效
    --]]
    function self.dismiss(pitch)
        if not pitch then
            self:removeAllChildren(false)
            for _, v in pairs(viewEffs) do
                table.insert(freeEffs, v)
            end
            viewEffs = {}
            return
        end

        local eff = viewEffs[pitch]
        if eff then
            self:removeChild(eff, false)
            table.insert(freeEffs, eff)
            viewEffs[pitch] = nil
        end
    end

    function self.onClean()
        for _, v in ipairs(freeEffs) do
            v:release()
        end
        for _, v in pairs(viewEffs) do
            v:release()
        end
    end
end

------------------------| 用于显示的层 |------------------------
local WaterfallNode = class("WaterfallNode", cc.ClippingRectangleNode)

--[[
@brief 创建一个瀑布流UI。 参数意义参考Waterfall.lua中的init函数
@param viewRect cc.Rect
--]]
function WaterfallNode:ctor(viewRect, midi, elePosInfo, speed, hand)
    -- 这是裁剪区域
    self:setClippingRegion(viewRect)
    -- NOTE(zhangyufei): 调试使用，用于显示裁剪区域范围
    -- self:addChild(cc.LayerColor:create(cc.c4b(40, 5, 51, 80)))

    -- 一些控制量
    self._showFingering = true
    -- self._autoShowEff   = true
    self._elePosInfo    = elePosInfo
    self._prepareHeight = 50
    self._sy = viewRect.y

    self.preSprID = {}

    local eleList     = {}
    local barlineList = {}
    local eventType = sDataModel.Event
    local sx = viewRect.x
    local sy = viewRect.y

    -- baseline effect
    local prepareEffectSpriteSize = cc.size(24, 24)
    local prepareEffectNode = display.newNode()
    prepareEffectNode:setPosition(sx, sy + prepareEffectSpriteSize.height / 2)
    self:addChild(prepareEffectNode)

    self._prepareEffectSprite = {}
    for pitch, info in pairs(elePosInfo) do
        local sp = display.newSprite("ui_waterfall_note_outline.png")
        local posX = info[2]
        sp:setPosition(posX, 0)
        sp:setOpacity(0)
        prepareEffectNode:addChild(sp)
        self._prepareEffectSprite[pitch] = sp
    end

    sDataModel:init(viewRect.width, viewRect.height, midi, elePosInfo, function(id, event, ...)
        local ele = eleList[id]

        -- 创建一个新的瀑布流元素
        local function newEle(info)
            ele = Ele:create(info.pitch, info.hand, info.finger, info.startTick)
            eleList[id] = ele
            ele.setSize(info.w, info.h)
            self:addChild(ele, 1)
        end

        if event == eventType.kElePosChanged then
            -- 只要改变y位置就好了
            local x, y = ...
            ele:setPositionX(x + sx)
            ele:setPositionY(y + sy + 2)
            if self._initEnd then
                self:updatePrepareEffect(ele.pitch, y, id)
            end
        elseif event == eventType.kEleShownFromOnLine then
            -- self:dismissEff(ele.pitch)
        elseif event == eventType.kEleShownFromHide then
            -- 需要创建一个新的元素
            newEle(...)
        elseif event == eventType.kEleOnLine then
            -- 首先判定这个元素是否存在，如果不存在，那么就要创建一个
            if nil == ele then newEle(...) end
            -- if self._autoShowEff then
            --     self:showEff(ele.pitch)
            -- end
        elseif event == eventType.kEleHide then
            -- self:dismissEff(ele.pitch)
            -- 需要释放掉这个元素
            self:removeChild(ele)
            eleList[id] = nil
        elseif event == eventType.kEleSizeChanged then
            ele.setSize(...)
        elseif event == eventType.kBarLineShown then
            -- 生成一个小节线
        elseif event == eventType.kBarLineHide then
            -- 删除一个小节线
        elseif event == eventType.kBarLineYChanged then
            -- 调整小节线的位置
        end
    end, speed, hand)

    self._eleList = eleList
    self._initEnd = true
end

function WaterfallNode:getDataModel()
    return sDataModel
end

function WaterfallNode:onCleanup()
    sDataModel = nil
end

function WaterfallNode:enableFingering(b)
    if self._showFingering == b then return end
    self._showFingering = b
    -- 关闭组件的指法
    for _,ele in pairs(self._eleList) do
        ele.enableFingering(b)
    end
end

function WaterfallNode:updatePrepareEffect(pitch, y, id)
    local yy = y
    local effectSp = self._prepareEffectSprite[pitch]
    if id == effectSp.lastId then return end
    if yy > 0 then
        if yy < self._prepareHeight then
            self.preSprID[pitch] = self.preSprID[pitch] or nil or id
            if self.preSprID[pitch] == id then
                local op = (self._prepareHeight - yy) / self._prepareHeight * 255
                effectSp:setOpacity(op)
            end
        end
    else
        self.preSprID[pitch] = nil
        transition.fadeOut(effectSp, {time = 0.3})
        effectSp.lastId = id
    end
end

function WaterfallNode:showHitEffect(pitch)
    -- TODO:yangyijie
end

return WaterfallNode
