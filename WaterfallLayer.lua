-- WaterfallLayer.lua
local WaterfallLayer = class("WaterfallLayer", function()
    return display.newNode()
end)

local mu = require("MidiUtil")

function WaterfallLayer:ctor(midi, config)
    self.midi = midi
    self.musicXml = musicXml
    self.config = config

    self.setProgressScheduleId = nil

    self:init()
end

function WaterfallLayer:release()
    if self.setProgressScheduleId then
        schedule:unscheduleScriptEntry(self.setProgressScheduleId)
        self.setProgressScheduleId = nil
    end
end

function WaterfallLayer:init()
    local startPitch, endPitch = self.config.startPitch, self.config.endPitch
    local keyWidth = self.config.rect.width / (endPitch - startPitch + 1)
    self.elePosInfo = {}
    for i = startPitch, endPitch, 1 do
        self.elePosInfo[i] = {keyWidth, (i - startPitch) * keyWidth}
    end

    local baseLine = display.newSprite("ui_waterfallbaseline.png", {scale9 = true, size = cc.size(1960, 14), capInsets = cc.size(0, 0, 4, 14)})
    baseLine:setAnchorPoint(0, 0)
    baseLine:setPosition(self.config.rect.x, self.config.rect.y)
    self:addChild(baseLine)

    baseLine:runAction(cc.RepeatForever:create(cc.Sequence:create(
        cc.FadeTo:create(0.8, 0x80),
        cc.FadeTo:create(0.5, 0x40)
    )))

    local waterfallNode = require("layers.WaterfallNode"):create(self.config.rect, self.midi, self.elePosInfo, self.config.rate, self.config.hand)
    waterfallNode:setPosition(0, 0)
    self:addChild(waterfallNode)
    self.waterfallNode = waterfallNode
    self:scrollOutOfWindow()
end

function WaterfallLayer:addMask(startTick, endTick)
end

function WaterfallLayer:addLabel(tick, text)
end

function WaterfallLayer:setController(controller)
    local eventsHandler = {
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_PROGRESS] = function (time)
            self:updateProgress(time)
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.SEEK] = function (to, from, prepareDuration, seekDuration)
            local seekTime = to - prepareDuration
            if seekDuration == 0 then
                self:updateProgress(seekTime)
            else
                self:setProgress(from, seekTime, seekDuration)
            end
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.CONFIG_CHANGED_SECTION] = function (section)
            self:updateProgress(section.startTime)
        end,

        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_HIT] = function (pitchEvent, currentPoint)
            self.waterfallNode:showHitEffect(pitchEvent:getPitch())
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_HIT_LONG] = function (pitchEvent, currentPoint)
            self.waterfallNode:showHitEffect(pitchEvent:getPitch())
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_MISS] = function (pitchEvent, currentPoint)
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_TIED_HIT] = function (pitchEvent, currentPoint, tiedIndex)
            self.waterfallNode:showHitEffect(pitchEvent:getPitch())
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_TIED_MISS] = function (pitchEvent, currentPoint, tiedIndex)
            -- end
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_NOMATCH] = function (pitchEvent, currentPoint, missPitch)
        end,
    }
    controller:addEventHandler(function (event, ...)
        if eventsHandler[event] then
            eventsHandler[event](...)
        end
    end)
    self.controller = controller
end

function WaterfallLayer:sendEvent(eventType, ...)
    -- print("<WaterfallLayer:sendEvent> " .. testGetKey(AUDIO_PLAYER_EVENT, eventType))
    if self.controller then
        self.controller:handleEvent(eventType, ...)
    end
end

function WaterfallLayer:updateProgress(time)
    local tick = mu.time2tick(self.midi, time)
    self:scrollToTick(tick)
end

function WaterfallLayer:setProgress(from, to, duration)
    -- local schedule = cc.Director:getInstance():getScheduler() -- TODO:try scheduleUpdateWithPriorityLua
    -- local delta = to - from
    -- local setProgressTimer = 0
    -- self.setProgressScheduleId = schedule:scheduleScriptFunc(function (dt)
    --     setProgressTimer = setProgressTimer + dt
    --     if setProgressTimer < duration then
    --         local percent = setProgressTimer / duration
    --         self:updateProgress(from + delta * percent)
    --     else
    --         self:updateProgress(from + delta)
    --         schedule:unscheduleScriptEntry(self.setProgressScheduleId)
    --         self.setProgressScheduleId = nil
    --         self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.SEEK_END)
    --     end
    -- end, 0, false)
    self:updateProgress(to)
end

function WaterfallLayer:setHand(hand)
    if self.config.hand == hand then return end

    self.config.hand = hand
    self.waterfallNode:removeFromParent()

    local waterfallNode = require("layers.WaterfallNode"):create(self.config.rect, self.midi, self.elePosInfo, self.config.rate, self.config.hand)
    waterfallNode:setPosition(-10, 0)
    self:addChild(waterfallNode)
    self.waterfallNode = waterfallNode
    self:scrollOutOfWindow()
end

function WaterfallLayer:scrollToTick(tick)
    self.waterfallNode:getDataModel():scrollToTick(tick)
end

-- 移出窗口之外
function WaterfallLayer:scrollOutOfWindow()
    self:scrollToTick(-1000)
end

return WaterfallLayer