local PlayerCore = class("PlayerCore")

local mu = require("MidiUtil")
local enableAutoPlay = false
local autoPlayDelayTime = 0
local schedule = cc.Director:getInstance():getScheduler()

function PlayerCore:ctor(midi, hitRadius, hitRank, hand, playMode)
    self.midi = midi
    self.hitRadius = hitRadius
    self.hitRank = hitRank
    self.hand = hand
    self.playMode = playMode

    self:initMidiPlayer()
    self:initPlayData()
    self:initPlayEngine()

    self.autoPlayEvents = {}
    -- 记录已经亮灯的pitch, 用于当关闭灯再打开的时候能正确显示
    self._lightOnEvents = {}
end

function PlayerCore:release()
    self.midiPlayer:release()
    self.playEngine:release()
end

-------------------- init --------------------\\
function PlayerCore:initMidiPlayer()
    local MIDI_PLAYER_EVENT = {
        EVENT_NOTE         = 0, -- arg: player pitchEvent
        EVENT_REST         = 1, -- arg: player restEvent
        EVENT_PEDAL        = 2, -- arg: player pedalEvent
        EVENT_LIGHT        = 3, -- arg: player lightEvent
        START              = 4, -- arg: player
        STOP               = 5, -- arg: player
        END                = 6, -- arg: player
        UPDATE             = 7, -- arg: player
        BEAT               = 8, -- arg: player -- WanakaMidiPlayer实现有问题，MultiPlayer里自己计算beat
        EVENT_CHANNEL      = 9, -- arg: player baseEvent
    }
    local midiPlayerCallback = {
        [MIDI_PLAYER_EVENT.EVENT_NOTE]    = function (midiPlayer, event)
            self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.EVENT_NOTE, event)
            -- Log.d("MIDI_PLAYER_EVENT.EVENT_NOTE")
            if enableAutoPlay then
                self:addAutoPlayEvent(event)
            end
            if self.controller.light then
                self:changeLight(event)
            end
        end,
        [MIDI_PLAYER_EVENT.EVENT_REST]    = function (midiPlayer, event)
            self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.EVENT_REST, event)
        end,
        -- [MIDI_PLAYER_EVENT.EVENT_REST]    = function (midiPlayer) end,
        -- [MIDI_PLAYER_EVENT.EVENT_PEDAL]   = function (midiPlayer) end,
        -- [MIDI_PLAYER_EVENT.EVENT_LIGHT]   = function (midiPlayer, lightEvent) end,
        -- [MIDI_PLAYER_EVENT.START]         = function (midiPlayer) end,
        -- [MIDI_PLAYER_EVENT.STOP]          = function (midiPlayer) end,
        -- [MIDI_PLAYER_EVENT.EVENT_CHANNEL] = function (midiPlayer) end,
        -- [MIDI_PLAYER_EVENT.BEAT]          = function (midiPlayer) self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.BEAT) end,
        [MIDI_PLAYER_EVENT.UPDATE]           = function (midiPlayer)
            self:onPlayUpdate()
        end,
        [MIDI_PLAYER_EVENT.END]              = function (midiPlayer)
            self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.MIDI_END)
        end,

    }
    self.midiPlayer = MidiPlayerForLua:create(self.midi, true)
    self.midiPlayer:retain()
    self.midiPlayer:addCallback(function(eventType, ...)
        if midiPlayerCallback[eventType] then
            midiPlayerCallback[eventType](...)
        end
    end)
end

function PlayerCore:initPlayEngine()
    local PLAY_ENGINE_RESULT = {
        HIT                = 0,
        MISS               = 1,
        NOMATCH            = 2,
        TIEDNOTE_HIT       = 3,
        TIEDNOTE_MISS      = 4,
        PASS_BASE_LINE     = 5,
    }
    local playEngineEventHandler = {
        [PLAY_ENGINE_RESULT.HIT] = function (pitchEvent, deltaTime, comboStep, tiedNoteIndex)
            -- Log.d("PLAY_ENGINE_RESULT.HIT")
            if comboStep == 1 then
                local hitDeviation = math.abs(deltaTime) / self.hitRadius
                local rank = self:getHitRank(hitDeviation)
                self.playData:handleHit(pitchEvent, "noteDeviation", hitDeviation, rank)
                self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_HIT, pitchEvent, self.playData:getPoint(), rank)
            else
                self.playData:handleHitLength(pitchEvent)
                self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_HIT_LONG, pitchEvent, self.playData:getPoint(), 1)
            end
        end,
        [PLAY_ENGINE_RESULT.MISS] = function (pitchEvent, deltaTime, comboStep, tiedNoteIndex)
            -- Log.d("PLAY_ENGINE_RESULT.MISS")
            self.playData:handleMiss(pitchEvent)
            self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_MISS, pitchEvent, self.playData:getPoint())
        end,
        [PLAY_ENGINE_RESULT.NOMATCH] = function (pitchEvent, missPitch, comboStep, tiedNoteIndex)
            -- Log.d("PLAY_ENGINE_RESULT.NOMATCH")
            self.playData:handleMiss(pitchEvent)
            self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_NOMATCH, pitchEvent, self.playData:getPoint(), missPitch)
        end,
        [PLAY_ENGINE_RESULT.TIEDNOTE_HIT] = function (pitchEvent, deltaTime, comboStep, tiedNoteIndex)
            -- Log.d("PLAY_ENGINE_RESULT.TIEDNOTE_HIT")
            self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_TIED_HIT, pitchEvent, self.playData:getPoint(), tiedNoteIndex)
        end,
        [PLAY_ENGINE_RESULT.TIEDNOTE_MISS] = function (pitchEvent, deltaTime, comboStep, tiedNoteIndex)
            -- Log.d("PLAY_ENGINE_RESULT.TIEDNOTE_MISS")
            self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_TIED_MISS, pitchEvent, self.playData:getPoint(), tiedNoteIndex)
        end,
        [PLAY_ENGINE_RESULT.PASS_BASE_LINE] = function (pitchEvent)
            -- Log.d("PLAY_ENGINE_RESULT.PASS_BASE_LINE, %s, %d", tostring(pitchEvent), pitchEvent:getPitch())
            self:sendEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_PASS, pitchEvent)
        end,
    }
    self.playEngine = StepPlayEngine:create(self.midi)
    self.playEngine:retain()
    self.playEngine:setCallback(function(pitchEvent, ret, deltaTime, comboStep, tiedNoteIndex)
        if playEngineEventHandler[ret] then
            -- print("<EngineEventHandler>", testGetKey(PLAY_ENGINE_RESULT, ret))
            playEngineEventHandler[ret](pitchEvent, deltaTime, comboStep, tiedNoteIndex)
        end
    end)
    self.playEngine:setHitTimeRadius(self.hitRadius)
    -- playEngine arg: 左手：0 右手：1 双手：2
    local engineHand
    if self.hand == PLAY_HAND.LEFT then engineHand = 0 elseif self.hand == PLAY_HAND.RIGHT then engineHand = 1 else engineHand = 2 end
    self.playEngine:setPlayHand(engineHand)
end

function PlayerCore:initPlayData()
    self.playData = require("PlayData").new(self.hitRank)
end

-------------------- init --------------------//

-------------------- input --------------------\\

function PlayerCore:setController(controller)
    local eventsHandle = {
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENABLE_MIDI] = function ( ... )
            self.midiPlayer:play()
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.DISABLE_MIDI] = function ( ... )
            self.midiPlayer:stop()
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.STOP] = function ( ... )
            self:reset()
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.SEEK] = function (to, from, prepareDuration, seekDuration)
            self:seek(to)
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.INPUT] = function (pitch, velocity)
            self:handleInput(pitch, velocity)
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.RESUME] = function( ... )
            self.midiPlayer:setNextUpdateIsSeeking()
        end
    }
    controller:addEventHandler(function (event, ...)
        if eventsHandle[event] then
            eventsHandle[event](...)
        end
    end)

    self.midiPlayer:setFollowTimeCallback(function ()
        return self.controller:getCurrentTime()
    end)
    self.controller = controller
end

-------------------- input --------------------//

-------------------- output --------------------\\

function PlayerCore:sendEvent(event, ...)
    -- print("<PlayerCore:sendEvent> " .. testGetKey(AUDIO_PLAYER_EVENT, event))
    if self.controller then
        self.controller:handleEvent(event, ...)
    end
end

-------------------- output --------------------//

function PlayerCore:reset()
    self.midiPlayer:setNextUpdateIsSeeking()
    self.midiPlayer:stop()

    self.playData:reset()
    self.playEngine:reset()

    self:unscheduleAutoPlaySchedule()
    self.autoPlayEvents = {}
    self:closeAllLight()
    self._lightOnEvents = {}
end

function PlayerCore:seek(time)
    local tick = mu.time2tick(self.midi, time)
    self.midiPlayer:setNextUpdateIsSeeking()
    self.playData:seek(tick)
    self.playEngine:reset()
end

function PlayerCore:onPlayEnd()
    self.midiPlayer:setNextUpdateIsSeeking()
end

-- 是否需要判定
function PlayerCore:needJudge()
    local tick = self.midiPlayer:getCurrentTick()
    local section = self.controller.section
    if section.prepareTime > 0 then
        -- 在准备阶段不判定
        local startTick = mu.time2tick(self.midi, section.startTime)
        if tick >= startTick then
            return true
        else
            return false
        end
    else
        return true
    end
end

function PlayerCore:onPlayUpdate()
    if self:needJudge() then
        self.playEngine:midiUpdate(self.midiPlayer:getCurrentTick())
    end
end

function PlayerCore:handleInput(pitch, velocity)
    if self:needJudge() then
        self.playEngine:onMidiNoteReceived(pitch, velocity)
    end
end

function PlayerCore:getPoint()
    return self.playData:getPoint()
end

function PlayerCore:getHitRank(hitDeviation)
    if hitDeviation <= 0 then return 1 end
    if hitDeviation >= 1 then return #self.hitRank end
    for i, v in ipairs(self.hitRank) do
        if hitDeviation <= v then return i end
    end
end

function PlayerCore:autoPlay()
    for i = 1, #self.autoPlayEvents do
        local event = self.autoPlayEvents[i]
        if UtilsWanakaFramework:getUnixTimestamp() > event.currentTime + event.delayTime then
            local pitchEvent = event.event
            -- Log.d("start autoPlay, pitch:%d", pitchEvent:getPitch())
            if pitchEvent:isOn() then
                self.controller:handleEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.INPUT, pitchEvent:getPitch(), 90)
            else
                self.controller:handleEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.INPUT, pitchEvent:getPitch(), 0)
            end
            table.remove(self.autoPlayEvents, i)
            return
        end
    end
end

function PlayerCore:setAutoPlay(enable)
    enableAutoPlay = enable
    if enable then
        self.autoPlayScheduleID = schedule:scheduleScriptFunc(function(dt)
            self:autoPlay()
        end, 0, false)
    else
        self:unscheduleAutoPlaySchedule()
    end
end

function PlayerCore:getAutoPlay()
    return enableAutoPlay
end

function PlayerCore:setAutoPlayDelayTime(time)
    autoPlayDelayTime = time
end

function PlayerCore:addAutoPlayEvent(pitchEvent, delayTime)
    if not self.controller then return end

    local event = {}
    event.event = pitchEvent
    event.currentTime = UtilsWanakaFramework:getUnixTimestamp()
    event.delayTime = delayTime or autoPlayDelayTime
    table.insert(self.autoPlayEvents, event)
end

function PlayerCore:unscheduleAutoPlaySchedule()
    if self.autoPlayScheduleID then
        schedule:unscheduleScriptEntry(self.autoPlayScheduleID)
        self.autoPlayScheduleID = nil
    end
end

function PlayerCore:changeLight(pitchEvent)
    local pitch = pitchEvent:getPitch()
    if pitchEvent:isOn() then
        MidiDevice:getInstance():turnOnLight(pitch, self:getIndicatorType(pitchEvent:getTrack()))
        local indicatorType = self:getKeyBoardIndicatorType(pitchEvent:getTrack())
        -- self._keyboard:setKeyIndicator(pitch, indicatorType, pitchEvent:getFinger())
        table.insert(self._lightOnEvents, {pitchEvent = pitchEvent, indicatorType = indicatorType})
    else
        MidiDevice:getInstance():turnOffLight(pitch)
        -- self._keyboard:setKeyIndicator(pitch, KeyIndicatorType.kKeyIndicatorNone, 0)
        table.remove(self._lightOnEvents, 1)
    end
end

function PlayerCore:openLight()
    for i,v in ipairs(self._lightOnEvents) do
        -- self._keyboard:setKeyIndicator(v.pitchEvent:getPitch(), v.indicatorType, v.pitchEvent:getFinger())
        local indicatorType = self:getIndicatorType(v.pitchEvent:getTrack())
        MidiDevice:getInstance():turnOnLight(v.pitchEvent:getPitch(), indicatorType)
    end
end

function PlayerCore:closeAllLight()
    MidiDevice:getInstance():turnOffAllLights()
    -- self._keyboard:clearAllKeys()
end

function PlayerCore:getIndicatorType(track)
    local clefType = self.midi:getClefType()
    if clefType == CLEF_TYPE.BASS then
        return 2
    elseif clefType == CLEF_TYPE.TREBLE then
        return 1
    else
        if track % 2 == 0 then
            return 1
        else
            return 2
        end
    end
end

-- todo：虚拟键盘
function PlayerCore:getKeyBoardIndicatorType(track)
    local indicatorType = 0
    if track % 2 == 0 then
        indicatorType =  KeyIndicatorType.kKeyIndicatorRight
    else
        indicatorType = KeyIndicatorType.kKeyIndicatorLeft
    end
    local clefType = self.midi:getClefType()
    if clefType == CLEF_TYPE.BASS then
        indicatorType = KeyIndicatorType.kKeyIndicatorLeft
    end
end

return PlayerCore
