local mu = require("MidiUtil")

local MultiPlayer = class("MultiPlayer")

local schedule = cc.Director:getInstance():getScheduler()

function MultiPlayer:ctor(config, initFinishCallback)
    self.config = config

    -- default
    -- self.prepareTime     = 3                 -- 中途开始准备时间
    -- self.fadeInTime      = 3                 -- 淡入时间
    -- self.fadeOutTime     = 3                 -- 淡出时间
    self.hitRadius       = config.hitRadius or 200               -- 弹奏命中半径
    self.hitRank         = config.hitRank or {0.5, 1.0}          -- 弹奏命中分级(Perfect, Great ...)

    self.playMode        = config.playMode or PLAY_MODE.NORMAL  -- 默认演奏模式：普通
    self.hand            = config.hand or PLAY_HAND.BOTH    -- 默认分手：双手
    self.section         = nil
    self.playbackRate    = 1                 -- 默认速度：1
    self.metronome       = false             -- 默认节拍器：关
    self.metronomeFile   = config.metronomeFile                 -- 节拍器音频

    -- init
    self.playState       = PLAY_STATE.READY
    self.eventHandlers   = {}
    self.currentTime     = 0
    self.lastMeasure     = 0
    self.lastBeat        = 0
    self.lastPlayPoint   = nil  -- stop时记录这次弹奏的得分
    self.viewMode        = nil  -- 显示方式，曲谱还是瀑布

    self.musicXml        = nil
    self.midi            = nil
    self.playerCore      = nil
    self.scoreLayer      = nil
    self.waterfallLayer  = nil
    self.audioPlayer     = nil
    self.videoPlayer     = nil
    self.virtualKeyboard = nil
    self.light           = self.config.light

    self.isPressAKey     = false  --是否有按琴键，初始为否

    self.initFinishCallback = initFinishCallback or function ()
        print("MultiPlayer: init end")
    end
    self.initState       = {}

    self:initMidiData()
    self:initPlayerCore()
    self:initInputEventHandler()

    self.metronomeSeperated = false

    if device.platform ~= "mac" and device.platform ~= "android"
            and self.config.useVideo and self.config.videoFile then
        self.initState.video = false
        self:initVideoPlayer()
    end
    if self.config.useScore then
        self.viewMode = VIEW_MODE.STAFF
        self:initScore()
    end
    if self.config.useWaterfall then
        if not self.viewMode then
            self.viewMode = VIEW_MODE.WATERFALL
        end
        self:initWaterfall()
    end
    if self.playMode == PLAY_MODE.JUMP then
        self:initStepTimer()
    else
        if self.config.useAudio and self.config.audioFile then
            self.initState.audio = false
            self:initAudioPlayer()
        else
            self:initSystemTimer()
        end
    end

    if device.platform == "mac" and self.config.useVirtualKeyboard then
        self:initVirtualKeyboard()
    end

    local schedule = cc.Director:getInstance():getScheduler()
    self.initScheduleId = schedule:scheduleScriptFunc(function ()
        for k, v in pairs(self.initState) do
            if (not v) then
                -- print("check " .. k .. " failed")
                return false
            end
        end
        schedule:unscheduleScriptEntry(self.initScheduleId)
        self.initScheduleId = nil
        self.initFinishCallback()
    end, 0, false)

    if device.platform == "windows" then
        ccexp.AudioEngine:preload(self.metronomeFile)
    end
end

function MultiPlayer:release()
    self:stop()
    if self.initScheduleId then
        local schedule = cc.Director:getInstance():getScheduler()
        schedule:unscheduleScriptEntry(self.initScheduleId)
    end
    -- release virtualKeyboard (auto)
    -- release video (auto)
    -- release audio
    if self.audioPlayer then
        self.audioPlayer:release()
        self.audioPlayer = nil
    end
    -- release score
    if self.scoreLayer then
        self.scoreLayer:release()
        self.scoreLayer = nil
    end
    -- release playerCore
    self.playerCore:release()
    self.playerCore = nil
    -- release midi (auto)
    -- release xml
    self.musicXml:release()
    self.musicXml = nil
end

-------------------- init --------------------\\

function MultiPlayer:initMidiData()
    local isXml = self.config.xmlFile:find("xml$") and true or false -- TODO: (isXml = isXml and isDebug)
    self.musicXml = MusicXmlLoader:loadFromFile(self.config.xmlFile, isXml)
    self.musicXml:retain()
    self.midi = MidiLoader:loadFromXMLData(self.musicXml)

    self.section = {}
    self.section.startTime = 0
    self.section.endTime = mu.getDuration(self.midi)
    self.section.fadeInDuration = 0
    self.section.fadeOutDuration = 0
    self.section.prepareTime = 0

    -- calc play point
    self:resetNodeData()
end

function MultiPlayer:resetNodeData()
    local startTick = mu.time2tick(self.midi, self.section.startTime)
    local endTick = mu.time2tick(self.midi, self.section.endTime)
    self.midiNoteData = mu.calcNodeData(self.midi, self.hand, startTick, endTick)
end

function MultiPlayer:initPlayerCore()
    Log.d("MultiPlayer: initPlayerCore")
    self.playerCore = require("PlayerCore").new(self.midi, self.hitRadius, self.hitRank, self.hand, self.playMode)
    self.playerCore:setController(self)
end

function MultiPlayer:initScore()
    Log.d("MultiPlayer: initScore")
    self.scoreLayer = require("Score").new(self.midi, self.musicXml, self.config.scoreConfig)
    self.scoreLayer:setController(self)
end

function MultiPlayer:initWaterfall()
    Log.d("MultiPlayer: initWaterfall")
    self.waterfallLayer = require("layers.WaterfallLayer"):create(self.midi, self.config.waterfallConfig)
    self.waterfallLayer:setController(self)
    if self.viewMode ~= VIEW_MODE.WATERFALL then
        self.waterfallLayer:setVisible(false)
    end
end

function MultiPlayer:initAudioPlayer()
    Log.d("MultiPlayer: initAudioPlayer")
    self.audioPlayer = require("AudioPlayer").new(function ()
        print("AudioPlayer: init end")
        self.initState["audio"] = true
    end)
    self.audioPlayer:setController(self)
    self.audioPlayer:setConfig("filename", self.config.audioFile) -- TODO(yyj): move arg to creator
end

function MultiPlayer:initStepTimer()
    Log.d("MultiPlayer: initStepTimer")
    self.stepTime = require("StepTimer").new(self.midi)
    self.stepTime:setController(self)
end

function MultiPlayer:initSystemTimer()
    Log.d("MultiPlayer: initSystemTimer")
    self.systemTimer = require("SystemTimer").new()
    self.systemTimer:setController(self)
end

-- video must setContentSize
function MultiPlayer:initVideoPlayer()
    Log.d("MultiPlayer: initVideoPlayer")
    self.videoPlayer = require("VideoLayer").new(self.config.videoFile, self.config.videoSize.width, self.config.videoSize.height, function ()
        print("VideoLayer: init end")
        self.initState["video"] = true
    end)
    self.videoPlayer:setController(self)
end

function MultiPlayer:initVirtualKeyboard()
    Log.d("MultiPlayer: initVirtualKeyboard")
    local function onKeyboardPressOrRelease(pitch, velocity)
        self:handleEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.INPUT, pitch, velocity)
    end

    local keyboard = require("VirtualKeyboard").new(onKeyboardPressOrRelease, onKeyboardPressOrRelease)
    self.virtualKeyboard = keyboard
end

-------------------- init --------------------//


-------------------- config --------------------\\

function MultiPlayer:setConfig(key, data)
    local configTable = {
        section = {needReset = true, default = {startTime = 0, endTime = -1,
                fadeInDuration = 0, fadeOutDuration = 0, prepareTime = 0}, handleFunc = function (data)
            -- 让时间错过当前整拍时间，从下一拍开始，修正时间跟audioPlayer支持的seek精度有关
            -- 0.0001是superpowered的最小值
            self.section.startTime = data[1] + 0.0001
            self.section.endTime = data[2]
            self.section.fadeInDuration = data[3]
            self.section.fadeOutDuration = data[4]
            self.section.prepareTime = data[5] or 0
            self:resetNodeData()
            self:setCurrentTime(self.section.startTime - self.section.prepareTime)
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.CONFIG_CHANGED_SECTION, self.section)
        end},

        -- mode = {needReset = true, default = 1, handleFunc = function (data)
        --     self.playMode = data
        --     self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.CONFIG_CHANGED_MODE, self.playMode)
        -- end},

        -- hand = {needReset = true, default = -1, handleFunc = function (data)
        --     self.hand = data
        --     self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.CONFIG_CHANGED_HAND, self.hand)
        -- end},

        rate = {needReset = false, default = 1, handleFunc = function (data)
            if data == self.rate then return end
            self.rate = data
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.CONFIG_CHANGED_RATE, self.rate)
        end},

        metronome = {needReset = false, default = false, handleFunc = function (data)
            if data == self.metronome then return end
            self.metronome = data
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.CONFIG_CHANGED_METRONOME, self.metronome)
        end},

        mute = {needReset = false, default = false, handleFunc = function (data)
            if data == self.mute then return end
            self.mute = data
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.CONFIG_CHANGED_MUTE, self.mute)
        end},

        viewMode = {needReset = false, default = VIEW_MODE.STAFF, handleFunc = function (data)
            if data == self.viewMode then return end
            if data == VIEW_MODE.STAFF then
                if self.scoreLayer then self.scoreLayer:setVisible(true) end
                if self.waterfallLayer then self.waterfallLayer:setVisible(false) end
            elseif data == VIEW_MODE.WATERFALL then
                if self.scoreLayer then self.scoreLayer:setVisible(false) end
                if self.waterfallLayer then self.waterfallLayer:setVisible(true) end
            end
            self.viewMode = data
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.CONFIG_CHANGED_VIEW, self.viewMode)
        end},
        light = {needReset = false, default = true, handleFunc = function (data)
            self.light = data
            if data then
                self.playerCore:openLight()
            else
                self.playerCore:closeAllLight()
            end
        end},
    }

    if not configTable[key] then return end
    if configTable[key].needReset and self.playState ~= PLAY_STATE.READY then return end
    data = data or clone(configTable[key].default)
    configTable[key].handleFunc(data)
end

function MultiPlayer:getConfig(key)
    return self[key]
end

-------------------- config --------------------//


-------------------- input --------------------\\



-- 处理其他组件发来的消息
function MultiPlayer:initInputEventHandler()
    self.inputEventsHandler = {
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.PLAY] = function ()
            self:play()
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.PAUSE] = function ( ... )
            self:pause()
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.RESUME] = function ()
            self:resume()
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.STOP] = function ( ... )
            self:stop()
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.END] = function ( ... )
            self:onEnd()
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.SEEK_END] = function ( ... )
            if self.seekCallback then
                self.seekCallback()
                self.seekCallback = nil
            end
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.SEEK] = function ( ... )
            -- self:seek(60, 0, 0, function() end) -- test
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.PROGRESS] = function (time)
            -- Log.d("INPUT_EVENT.PROGRESS:%f", time)
            self:setCurrentTime(time)
            local measure = mu.time2Measure(self.midi, self:getCurrentTime())
            if self.lastMeasure ~= measure then
                self.lastMeasure = measure
                self:onMeasure()
            end
            if not self.metronomeSeperated then
                self:updateBeat(self:getCurrentTime())
            end
            self:onProgress()
            if self.playState == PLAY_STATE.PLAYING and self.prepareEndTime and time > self.prepareEndTime then
                self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENABLE_MIDI)
                self.prepareEndTime = nil
            end
        end,

        [WANAKA_MULTI_PLAYER_INPUT_EVENT.INPUT] = function (pitch, velocity)
            if not self.isPressAKey then self.isPressAKey = true end
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.INPUT, pitch, velocity)
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_HIT] = function (...)
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_HIT, ...)
            if self.playMode == PLAY_MODE.WAIT and self.playState == PLAY_STATE.PAUSED then
                self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.HIT_IN_WAIT)
                if self.videoPlayer then
                    self.videoPlayer:seek(self:getCurrentTime())
                end
                self:resume()
            end
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_HIT_LONG] = function (...)
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_HIT_LONG, ...)
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_MISS] = function (pitchEvent, currentPoint)
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_MISS, pitchEvent, currentPoint)
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_TIED_HIT] = function (pitchEvent, currentPoint, tiedIndex)
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_TIED_HIT, pitchEvent, currentPoint, tiedIndex)
            if self.playMode == PLAY_MODE.WAIT and self.playState == PLAY_STATE.PAUSED then
                self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.HIT_IN_WAIT)
                if self.videoPlayer then
                    self.videoPlayer:seek(self:getCurrentTime())
                end
                self:resume()
            end
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_TIED_MISS] = function (pitchEvent, currentPoint, tiedIndex)
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_TIED_MISS, pitchEvent, currentPoint, tiedIndex)
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_NOMATCH] = function (pitchEvent, currentPoint, missPitch)
            if self.playMode == PLAY_MODE.WAIT and self.playState == PLAY_STATE.PAUSED then
                self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.NOMATCH_IN_WAIT)
            end
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_NOMATCH, pitchEvent, currentPoint, missPitch)
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.ENGINE_RESULT_PASS] = function (pitchEvent, currentPoint)
            -- TODO yyj: PLAY_MODE.WAIT, pause and resume will send ENGINE_RESULT_PASS again
            if self.playMode == PLAY_MODE.WAIT then
                self:pause()
                if self.config.needSeperatedMetronome then
                    self:seperateMetronome()
                end
            end
        end,

        [WANAKA_MULTI_PLAYER_INPUT_EVENT.SET_CONFIG] = function (configKey, value)
            self:setConfig(configKey, value)
        end,

        [WANAKA_MULTI_PLAYER_INPUT_EVENT.TOGGLE_AUTO_PLAY] = function ()
            self.playerCore:setAutoPlay(not self.playerCore:getAutoPlay())
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.AUTO_PLAY, self.playerCore:getAutoPlay())
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.EVENT_NOTE] = function (event)
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.EVENT_NOTE, event)
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.EVENT_REST] = function (event)
            self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.EVENT_REST, event)
        end,
        [WANAKA_MULTI_PLAYER_INPUT_EVENT.MIDI_END] = function ()
            if self.audioPlayer then self.audioPlayer:stop() end
            self:onEnd()
        end,
    }
end

function MultiPlayer:handleEvent(event, ...)
    if self.inputEventsHandler[event] then
        self.inputEventsHandler[event](...)
    end
end

-------------------- input --------------------//


-------------------- output --------------------\\

-- 向所有组件广播消息，具体处理哪些消息由组件自己过滤
function MultiPlayer:addEventHandler(handler)
    table.insert(self.eventHandlers, handler)
    local handlerId = #self.eventHandlers
    return handlerId
end

function MultiPlayer:removeEventHandler(handlerId)
    table.remove(self.eventHandlers, handlerId)
end

function MultiPlayer:sendEvent(event, ...)
    if event ~= WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_PROGRESS
        and event ~= WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_BEAT
        and event ~= WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_MEASURE then
        -- print("<MultiPlayer> broadcast " .. testGetKey(WANAKA_MULTI_PLAYER_OUTPUT_EVENT, event))
    end
    for _, handler in ipairs(self.eventHandlers) do
        handler(event, ...)
    end
end

-------------------- output --------------------//


-------------------- operation --------------------\\

function MultiPlayer:play()
    if self.playState ~= PLAY_STATE.READY then return end
    self.playState = PLAY_STATE.PLAYING
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENABLE_MIDI)
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.PLAY)
end

function MultiPlayer:pause()
    if self.playState ~= PLAY_STATE.PLAYING then return end
    self.playState = PLAY_STATE.PAUSED
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.DISABLE_MIDI)
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.PAUSE)
end

function MultiPlayer:resume()
    if self.playState ~= PLAY_STATE.PAUSED then return end
    self.playState = PLAY_STATE.PLAYING
    if not self.prepareEndTime then
        self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENABLE_MIDI)
    end
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.RESUME)
end

function MultiPlayer:stop()
    if self.playState ~= PLAY_STATE.PLAYING and self.playState ~= PLAY_STATE.PAUSED then return end
    self.playState = PLAY_STATE.READY
    self.lastPlayPoint = self:getPoint()
    self:setCurrentTime(0)
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.DISABLE_MIDI)
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.STOP)
    self:stopSeperatedMetronome()
end

function MultiPlayer:replay()
    self:stop()
    self:play()
end

function MultiPlayer:reset()
    self.metronomeSeperated = false
end

function MultiPlayer:isPlaying()
    return self.playState == PLAY_STATE.PLAYING
end

function MultiPlayer:seek(time, prepareDuration, seekDuration, callback)
    prepareDuration = prepareDuration or 0
    seekDuration = seekDuration or 0
    self.prepareEndTime = time
    self:pause()
    if callback then
        self.seekCallback = callback
    end
    local from = self:getCurrentTime()
    self:setCurrentTime(time - prepareDuration)
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.SEEK, time, from, prepareDuration, seekDuration)
end

-------------------- operation --------------------//

-------------------- score view --------------------\\

function MultiPlayer:setNoteDisable(startTime, endTime)
    if self.scoreLayer then
        self.scoreLayer:setNoteDisable(startTime, endTime, self.hand)
    end
    if self.waterfallLayer then
    end
end

function MultiPlayer:resetNoteColor(startTime, endTime)
    if self.scoreLayer then
        self.scoreLayer:resetNoteColor(startTime, endTime, self.hand)
    end
    if self.waterfallLayer then
    end
end

-------------------- score view --------------------//

function MultiPlayer:onProgress()
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_PROGRESS, self.currentTime)
end

function MultiPlayer:onBeat()
    if self.metronome then
        if device.platform == "windows" then
            ccexp.AudioEngine:play2d(self.metronomeFile)
        else
            cc.SimpleAudioEngine:getInstance():playEffect(self.metronomeFile)
        end
    end
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_BEAT, self.lastBeat)
end

function MultiPlayer:updateBeat(passedTime)
    local beat = mu.time2Beat(self.midi, passedTime)
    if self.lastBeat ~= beat and beat > 0 then
        self.lastBeat = beat
        self:onBeat()
    end
end

-- 跟停模式下还需要节拍器的话分离节拍器
function MultiPlayer:seperateMetronome()
    if self.metronomeSeperated then return end
    self.metronomeSeperated = true
    self.metronomePassedTime = self.currentTime

    self.seperateMetronomeScheduleID = schedule:scheduleScriptFunc(function(dt)
        self.metronomePassedTime = self.metronomePassedTime + dt * self.rate
        self:updateBeat(self.metronomePassedTime)
    end, 0, false)
end

function MultiPlayer:stopSeperatedMetronome()
    if self.seperateMetronomeScheduleID then
        schedule:unscheduleScriptEntry(self.seperateMetronomeScheduleID)
        self.seperateMetronomeScheduleID = nil
    end
end

function MultiPlayer:onMeasure()
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_MEASURE, self.lastMeasure)
end

function MultiPlayer:onEnd()
    self:sendEvent(WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_END, self:getPoint())
end

function MultiPlayer:getPoint()
    return self.playerCore:getPoint()
end

function MultiPlayer:getPlayMode()
    return self.playMode
end

function MultiPlayer:getPlayState()
    return self.playState
end

function MultiPlayer:getViewMode()
    return self.viewMode
end

function MultiPlayer:setCurrentTime(t)
    self.currentTime = t
end

function MultiPlayer:getCurrentTime()
    return self.currentTime
end

function MultiPlayer:getCurrentPercent()
    local totalTime = self.section.endTime - self.section.startTime
    local currentTime = self.currentTime - self.section.startTime
    return currentTime / totalTime * 100
end

function MultiPlayer:getPercent(time)
    local totalTime = self.section.endTime - self.section.startTime
    local currentTime = time - self.section.startTime
    return currentTime / totalTime * 100
end

function MultiPlayer:getPlayEngine()
    return self.playerCore.playEngine
end

function MultiPlayer:getTotalTime()
    return self.section.endTime - self.section.startTime
end

function MultiPlayer:getPlayerCore()
    return self.playerCore
end

function MultiPlayer:getMidiPlayer()
    return self.playerCore.midiPlayer
end

return MultiPlayer


