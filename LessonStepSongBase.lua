local LessonStepBase = require "LessonStepBase"
local PlayResultLayer = require "layers.PlayResultLayer"
local PkResultStudentLayer = require "layers.PkResultStudentLayer"
local PkResultTeacherLayer = require "layers.PkResultTeacherLayer"
local rating = require("controls.RatingSystem")
local mu = require "MidiUtil"

local LessonStepSongBase = class("LessonStepSongBase", LessonStepBase)

local statusBtnZorder = 100

local handleTable =
{
    [OPCODE_UPDATE_UI_MOUSE_CHECK] = "handleMouseCheck",
}

-------------------------------初始化模块-----------------------------
function LessonStepSongBase:ctor(lessonIndex, stepIndex)
    LessonStepSongBase.super.ctor(self, lessonIndex, stepIndex)
    -- table.print(self._stepConfig)

    --各个步骤的变量
    self._isNeedMetronome = self._stepConfig.isNeedMetronome
    self._playMode = self._stepConfig.playMode
    self._isPk = self._stepConfig.isPk
    self._supportView = self._stepConfig.supportView
    self._isHaveVideo = self._stepConfig.isShowVideo or false
    self._defaultPlaySpeed = self._stepConfig.defaultPlaySpeed / 100
    self._needRecord = self._stepConfig.needRecord
    --_isHaveMusic表示这个步骤是否有背景音乐
    self._isHaveMusic = self._stepConfig.isHaveMusic

    self._isWholeSong = self._stepConfig.wholeSong
    --当没有定义start的时候是全曲播放
    if not self._stepConfig.start then
        self._isWholeSong = true
    end

    self._playStatus = PLAY_STATE.READY

    --曲谱截图使用,需要还原当时的演奏状态
    self._playResultTable = {}

    --注意: 在图片正在保存时候，有可能会收到切场景的消息，如果此时切场景，
    --很可能会造成崩溃，这个变量目前用于在切下个场景前做一些延时处理,
    --回调完后注意置nil
    self._destroyCallback = nil
    self._isSavingPic = false     --是否正在保存图片图片

    -- 因为配置文件中的手的常量跟这里定义的不一样
    if self._stepConfig.hand == 0 then
        self._hand = PLAY_HAND.LEFT
    elseif self._stepConfig.hand == 1 then
        self._hand = PLAY_HAND.RIGHT
    else
        self._hand = PLAY_HAND.BOTH
    end

    if self._stepConfig.onePageMode then
        if self._stepConfig.layoutByTime then
            self._scoreMode = SCORE_MODE.PAGEEQUALWIDTHMODE
        else
            self._scoreMode = SCORE_MODE.PAGEMODE
        end
    else
        if self._stepConfig.layoutByTime then
            self._scoreMode = SCORE_MODE.LINEEQUALWIDTHMODE
        else
            self._scoreMode = SCORE_MODE.STACKMODE
        end
    end

    -- for test
    -- self._isNeedMetronome = true
    -- self._playMode = PLAY_MODE.WAIT

    self:initModules()
    OpcodeManager.registerUIOpcodeHandler(self, handleTable)
end

function LessonStepSongBase:onEnterTransitionFinish()
    LessonStepSongBase.super.onEnterTransitionFinish(self)
    cc.Director:getInstance():getTextureCache():addImage("star.png")
end

function LessonStepSongBase:getScoreConfig()
    local config = {}

    local keyboardHeight = KEYBOARD_HEIGHT
    local size = cc.Director:getInstance():getWinSize()
    if self._stepConfig.onePageMode then
        size.width = size.width * 0.9
        keyboardHeight = 350
    else
        size.height = size.height * 1.5
        if self._stepConfig.layoutByTime then
            size.width = size.width * 0.75
        else
            -- to do
        end
    end
    config.size = cc.size(size.width, size.height - keyboardHeight)
    config.staffMode = self._scoreMode

    -- if isWholeSong == false then config.showMetronome = false end
    return config
end

function LessonStepSongBase:getWaterfallConfig()
    local config = {
        rect = cc.rect(0, KEYBOARD_HEIGHT, DESIGN_SIZE_WIDTH, DESIGN_SIZE_HEIGHT - KEYBOARD_HEIGHT),
        rate = 3,
        hand = self._hand,
        startPitch = self._stepConfig.startPitch,
        endPitch = self._stepConfig.endPitch,
    }
    return config
end

function LessonStepSongBase:getPlayerConfig()
    local playerConfig ={
        useScore = true,
        scoreConfig = self:getScoreConfig(),
        useWaterfall = true,
        waterfallConfig = self:getWaterfallConfig(),
        useVirtualKeyboard = false,
        useVideo = false,
        xmlFile = self._stepConfig.staffPath,
        audioFile = self._stepConfig.musicPath,
        -- videoFile = APP.lessonManager.getLessonRes(self.lessonId, "guideVideo"),
        hitRadius = 300,
        hitRank = {0.60, 1.00},
        metronomeFile = "dang.mp3",
        playMode = self._playMode,
        hand = self._hand,
        light = self._stepConfig.isLightOn,
        needSeperatedMetronome = true,
    }
    playerConfig.useAudio = true
    if TERMINAL == 1 or self._playMode == PLAY_MODE.JUMP or self._playMode == PLAY_MODE.WAIT then
        playerConfig.useAudio = false
    end

    return playerConfig
end

function LessonStepSongBase:initModules()
    if not self._stepConfig.onePageMode then
        if self._scoreMode == SCORE_MODE.STACKMODE then
            local staffBackground = display.newScale9Sprite("stack_mode_bg.png", 0, KEYBOARD_HEIGHT,
                cc.size(DESIGN_SIZE_WIDTH, DESIGN_SIZE_HEIGHT - KEYBOARD_HEIGHT), cc.rect(50, 50, 10, 10))
            staffBackground:setAnchorPoint(0, 0)
            self:addChild(staffBackground)
        else
            local staffBackground = CSLoaderUtil.createNodeAndPlay(self._stepConfig.backgroundCsb, true)
            self:addChild(staffBackground)
        end
    end

    if self._needRecord and self._isWholeSong and TERMINAL == 1 then
        self._midiRecorder = MidiRecorder:new()
        self._midiRecorder:setAutoRecord()
        self._midiRecorder:retain()
    end

    self:loadKeyboard()

    self:initDevice()
    self:initPlayer()
    self:initRatingSystem()

    if not self._isWholeSong then
        local start = {self._stepConfig.start, self._stepConfig.startBeat, self._stepConfig.startNote}
        local stop = {self._stepConfig.stop, self._stepConfig.stopBeat, self._stepConfig.stopNote}
        local startTime, endTime = mu.getSection(self._player.midi, start, stop)
        local fadeInDuration = mu.getMeasureDuration(self._player.midi) * 2
        -- Log.d("startTime:%f, endTime:%f, fadeInDuration:%f", startTime, endTime, fadeInDuration)
        local fadeOutDuration = 0
        local prepareTime = fadeInDuration
        self._player:setConfig("section", {startTime, endTime + 1, fadeInDuration, fadeOutDuration, prepareTime})
        -- endTime+1是为了防止最后一个chapter还没结算就结束播放
    end
    self._player:setConfig("rate", self._defaultPlaySpeed)
    self._player:setConfig("metronome", self._isNeedMetronome)
    local view = (self._supportView == SUPPORT_VIEW.WATERFALL) and VIEW_MODE.WATERFALL or VIEW_MODE.STAFF
    self._player:setConfig("viewMode", view)
    self._player:setConfig("light", 3)

    if not self._stepConfig.onePageMode and self._supportView ~= SUPPORT_VIEW.WATERFALL then
        self:createScorePanel()
    end
    self:initPlayBarStatus()

    -- if self._isHaveVideo then
    --     local KBHLPolygon = require(videoDataPath)
    --     self._KBHLNode = KBHLNode.new(self, 36, KBHLPolygon, cc.size(DESIGN_SIZE_WIDTH, videoHeight))
    --     self._KBHLNode:addTo(self)
    --     self:adjustFallElementPos(not self._isHaveVideo)
    --     self._keyboard:setVisible(false)
    -- end
end

function LessonStepSongBase:loadKeyboard()
    local function pressKeyCallback(pitch, velocity)
        if self._playStatus ~= PLAY_STATE.READY then
            self._player:handleEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.INPUT, pitch, velocity)
        end
    end

    local function releaseKeyCallback(pitch)
        if self._playStatus ~= PLAY_STATE.READY then
            self._player:handleEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.INPUT, pitch, 0)
        end
    end

    local startPitch = self._stepConfig.startPitch
    local endPitch = self._stepConfig.endPitch
    self._keyboard = MiniKeyboard:createEx(startPitch, endPitch)
    self._keyboard:setCallback(pressKeyCallback, releaseKeyCallback)
    self:addChild(self._keyboard)
end

function LessonStepSongBase:initScoreLayer()
    if self._scoreMode == SCORE_MODE.LINEEQUALWIDTHMODE then
        if self._midi:getTrackNumber() == 2 then
            self._scoreLayer:setPosition(400, 98)
        else
            self._scoreLayer:setPosition(400, 150)
        end
        -- self._scoreLayer:setScrollViewPosition(cc.p(210, 0))
    elseif self._scoreMode == SCORE_MODE.PAGEEQUALWIDTHMODE then
        if self._midi:getTrackNumber() == 2 then
            self._scoreLayer:setPosition(60, 130)
        else
            self._scoreLayer:setPosition(80, 150)
        end
    end
end

function LessonStepSongBase:initDevice()
    self.deviceCallbackId = MidiDevice:getInstance():addCallback(function(eventType, ...)
        if eventType == MIDI_DEVICE_EVENT.KEY_PRESS or eventType == MIDI_DEVICE_EVENT.KEY_RELEASE then
            if self._player then
                self._player:handleEvent(WANAKA_MULTI_PLAYER_INPUT_EVENT.INPUT, ...)
            end
        end
    end)
end

function LessonStepSongBase:addPlayerEvents()
    local eventsHandler = {
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.PLAY] = function ()
            Log.d("WANAKA_MULTI_PLAYER_OUTPUT_EVENT.PLAY")
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_END] = function (point)
            Log.d("ON_END")
            self:onPlayFinish()
            local result = rating.getScoreFromPoint(point, self._player.midiNoteData)
            self:resetFinish(result)
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.SEEK] = function (prepareDuration, seekDuration, from)
            -- if TERMINAL == 0 and self._midiPlayer then
            --     --midiplayer比背景音乐有延时，所以这里要减掉延时
            --     currentTime = currentTime - LessonStepSongUtils.getMidiPlayerDelayTime()
            -- end
            self._playerBarLayer:setLoadingBarPercent(self._player:getCurrentPercent())
            self._playerBarLayer:setProgressTime(self._player:getCurrentTime())
        end,
        [WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ON_PROGRESS] = function ()
            self._playerBarLayer:setLoadingBarPercent(self._player:getCurrentPercent())
            self._playerBarLayer:setProgressTime(self._player:getCurrentTime())
        end,
    }
    self._player:addEventHandler(function(event, ...)
        if eventsHandler[event] then
            eventsHandler[event](...)
        end
    end)
end

function LessonStepSongBase:initPlayer()
    local player = require("MultiPlayer").new(self:getPlayerConfig())
    self._player = player

    self._midi = player.midi
    self._midi:retain()

    self._scoreLayer = player.scoreLayer
    self:initScoreLayer()
    self:addChild(player.scoreLayer)

    self._waterfallLayer = player.waterfallLayer
    player.waterfallLayer:setPosition(0, 0)
    self:addChild(player.waterfallLayer)

    self:addPlayerEvents()

    self._playEngine = player:getPlayEngine()
    self._playerCore = player:getPlayerCore()

    self._playerCore:setAutoPlay(true)
    if self._playMode == PLAY_MODE.JUMP or self._playMode == PLAY_MODE.WAIT then
        self._playerCore:setAutoPlayDelayTime(1)
    end

    -- local videoBg = display.newSprite("unpack/keyboard.png")
    -- videoBg:setScale(videoSize.width / videoBg:getContentSize().width)
    -- videoBg:setAnchorPoint(0, 0)
    -- videoBg:setPosition(0, 0 - 1)
    -- self:addChild(videoBg, VIDEO_ZORDER - 1)
    -- bottom_center(videoBg)
    -- if player.videoPlayer then
    --     player.videoPlayer:setContentSize(videoSize.width, videoSize.height)
    --     player.videoPlayer:setAnchorPoint(0, 0)
    --     player.videoPlayer:setPosition(0, 0 - 1)
    --     self:addChild(player.videoPlayer, VIDEO_ZORDER)
    -- end
end

function LessonStepSongBase:initRatingSystem()
    self._player:addEventHandler(function (event, pitchEvent, point, ...)
        local args = {...}
        if event == WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_HIT
            or event == WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_HIT_LONG
            or event == WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_TIED_HIT then

            self:updateScore(point)
            self:showStar(pitchEvent, 3 - args[1])
        elseif event == WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_TIED_HIT then
            self:updateScore(point)
         elseif event == WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_TIED_MISS
            or event == WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_MISS then

            -- todo
        elseif event == WANAKA_MULTI_PLAYER_OUTPUT_EVENT.ENGINE_RESULT_NOMATCH then
            self:playNoMatchOperation(pitchEvent, args[1])
        end
    end)
end

function LessonStepSongBase:playNoMatchOperation(pitchEvent, missPitch)
end

function LessonStepSongBase:createScorePanel()
    local scorePanel = cc.Sprite:create("real_time_score_bg.png")
    scorePanel:setPosition(cc.p(scorePanel:getContentSize().width / 2 + 70, KEYBOARD_HEIGHT + 50))
    self:addChild(scorePanel, 10)

    self._star = cc.Sprite:create("real_time_score_star.png")
    self._star:setPosition(cc.p(70 + 37, KEYBOARD_HEIGHT + 50))
    self:addChild(self._star, 11)

    self._scoreLabel = display.newTTFLabel({
        text = "0",
        font = "jiancuyuan.ttf",
        size = 40,
        align = cc.TEXT_ALIGNMENT_CENTER, -- 文字内部居中对齐
        x = 150,
    })
    self._scoreLabel:setPosition(cc.p(scorePanel:getPositionX() + 30, scorePanel:getPositionY()))
    self:addChild(self._scoreLabel, 11)
end

function LessonStepSongBase:initPlayBarStatus()
    -- 指法
    self._playerBarLayer:enableFinger(true)
    self:enableFinger(true)

    -- 背景音乐
    self._playerBarLayer:enableBackgroundMusic(self._isHaveMusic)
    if TERMINAL == 1 or self._playMode ~= PLAY_MODE.NORMAL then
        self._playerBarLayer:touchEnableMetronmeButton(false)
        self._playerBarLayer:disableBackgroundMusicButton()
    end

    -- 节拍器
    self._playerBarLayer:enableMetronome(self._isNeedMetronome)
    if TERMINAL == 1 or self._playMode == PLAY_MODE.JUMP then
        self._playerBarLayer:touchEnableMetronmeButton(false)
    end

    self._playerBarLayer:enableLightOn(self._stepConfig.isLightOn)
    self._playerBarLayer:adjustUIByMapIndex(self._stepConfig.mapIndex)

    if TERMINAL == 1 then
        self._playerBarLayer:hideSettingButton()
        self._playerBarLayer:setShowForStudent()
    end
    if not self._stepConfig.canAjustSpeed then
        self._playerBarLayer:disableAdjustButton()
    end
    self._playerBarLayer:setSpeedValue(self._defaultPlaySpeed * 100)

    if self._supportView ~= SUPPORT_VIEW.BOTH then
        self._playerBarLayer:disableKalaButton()
    else
        self:enableKalaMode(false)
    end
    self:enablePitchVisible(false)

    if self._isPk or self._playMode == PLAY_MODE.WAIT or self._stepConfig.onePageMode then
        self._playerBarLayer:disablePauseButton()
    end
end

function LessonStepSongBase:createMediaPlayer()
    local mediaFinishCallback = function()
        self._video:removeFromParent()
        self:createMediaPlayer()
    end
    local videoHeight = self._keyboard:getKeyboardHeight()
    local videoPath = string.format("lesson_keyboard_%d.mp4", LessonStepManager.getStepLessonIndex())
    self._video = MediaPlayer:create(videoPath, DESIGN_SIZE_WIDTH, videoHeight, false)
    self._media:setCallback(mediaFinishCallback, mediaUpdateCallBack)
    self._video:setAnchorPoint(cc.p(0, 0))
    self._video:setPosition(cc.p(0, 0))
    self._video:addTo(self)
end
-------------------------------初始化模块  结束-----------------------------


function LessonStepSongBase:changePlayStatus(model)
    if TERMINAL == 1 then return end

    if not self._handsStatusIcon then
        self._handsStatusIcon = display.newSprite("status_righthand.png", DESIGN_SIZE_WIDTH - 70, DESIGN_SIZE_HEIGHT / 2 - 135 + 60)
        self:addChild(self._handsStatusIcon, statusBtnZorder)
    end
    if model == PLAY_HAND.LIFT then
        self._handsStatusIcon:setTexture("status_lefthand.png")
    elseif model == PLAY_HAND.RIGHT then
        self._handsStatusIcon:setTexture("status_righthand.png")
    elseif model == PLAY_HAND.BOTH then
        self._handsStatusIcon:setTexture("status_hands.png")
    end
end

function LessonStepSongBase:showStar(pitchEvent, starNumber)
    if self._player:getViewMode() == VIEW_MODE.WATERFALL then return end

    local pos = UtilsMusicCore:getNotePos(pitchEvent:getNote())
    local positionX = 440
    local positionY = 150
    if self._scoreMode == SCORE_MODE.STACKMODE then
        positionX = pos.x
    elseif self._midi:getTrackNumber() == 2 then
        positionX = positionX + 20
        positionY = 150 - 52
    end

    local startPos = cc.p(positionX, pos.y + positionY)
    local jumpHeight = 230
    local jumps = 1
    local jumpDuration = 1.2
    local jumpTargetPostion = cc.p(220, 440)

    for i = 1, starNumber do
        local texture = cc.Director:getInstance():getTextureCache():getTextureForKey("star.png")
        local star = cc.Sprite:createWithTexture(texture)
        star:setPosition(startPos)
        star:setVisible(false)
        self:addChild(star, 12)

        local delay = cc.DelayTime:create(0.08 * i - 0.08)
        local show = cc.Show:create()
        local jumpTo = cc.JumpTo:create(jumpDuration, jumpTargetPostion, jumpHeight, jumps)
        local callFunc = cc.CallFunc:create(function()
            star:removeSelf()
        end)
        star:runAction(cc.Sequence:create(delay, show, jumpTo, callFunc))
        star:runAction(cc.RotateTo:create(3, 2400))
        if self._star then
            local delayAction = cc.DelayTime:create(1.1)
            self._star:runAction(cc.Sequence:create(delayAction, cc.Repeat:create(cc.Sequence:create(cc.ScaleTo:create(0.15 / starNumber, 1.2),
                cc.ScaleTo:create(0.15 / starNumber, 1.0)), starNumber)))
        end
    end
end

function LessonStepSongBase:updateScore(point)
    if self._scoreLabel then
        local result = rating.getScoreFromPoint(point, self._player.midiNoteData)
        self._scoreLabel:setString(tostring(result.score))
    end
end

-- TODO 子类重写，Step内部步骤下一步
function LessonStepSongBase:onSubStepNext()
    self:dismissResultLayer()
    Statistics.trackEventTeacher(Statistics.staffPlay, {["速度"] = self._defaultPlaySpeed})
    if self._pkResultLayer then self._pkResultLayer:dismiss(false) end

    Log.d("currentStep:".. self.TeaStuSynchData._currentSubStepIndex)
    LessonStepSongBase.super.onSubStepNext(self)
    if TERMINAL == 0 then
        self:performWithDelay(function()
            self._playerBarLayer:settingButtonVisibleControl(true)
            if self._scoreMode == SCORE_MODE.STACKMODE then
                self._playerBarLayer:setVisible(false)
            end
        end, 2)
    end
    self._player:play()
    self:play()

    --初始化隐藏瀑布流，播放才会显示出来
    if self._isKalaMode then
        -- if self._playMode ~= PLAY_MODE.JUMP then self._waterfallLayer:setOutLineSpritesVisible(true) end
    end
    --播放时候控制学生钢琴声音开启
    self:setSwitchPianoSound(true)
    self._playStatus = PLAY_STATE.PLAYING

    --老师清空该步骤成绩
    if TERMINAL == 0 then
        PlayResultManager.resetCurResult(self._lessonIndex, self._stepIndex)
    end
    if self._video then
        self._video:play()
    end
end

function LessonStepSongBase:onSubStepBack()
    LessonStepSongBase.super.onSubStepBack(self)
    LessonStepManager.goToStep(self._stepIndex)
end

function LessonStepSongBase:play()
    --为了防止跟停同步老师端，做以下判断
    -- if not self._stopSynch and self._midiPlayer then
    --     self._player:sendOwnerTime()
    -- end
    -- self._stopSynch = false

    -- self:scheduleUpdate()
    if not self._isHaveMusic then
        WanakaAudioPlayer:getInstance():setVolume(0)
    end

    --[[
    _midiPlayDelayTime起作用有以下两种情况：
    1.在有背景音乐的情况下，学生端和老师端同时延时播放MidiPlayer,给加载背景音乐充足的时间，保证曲谱和背景音乐对应
    2.在无背景音乐的跟停模式下，保证节拍器正常。
    ]]

    -- local function startPlayMidi()
    --     if TERMINAL == 1 then
    --         self._player:setSpeed(self._defaultPlaySpeed)
    --         if self._startTime then
    --             local tick = LessonStepSongUtils.secondsToTicks(self._startTime, self._midi)
    --             self._player:setTick(tick)
    --         end
    --     end
    --     self._player:play(self._midiPlayer:getTick())
    -- end
    -- if self._midiPlayDelayTime then
    --     self:performWithDelay(function()
    --         startPlayMidi()
    --     end, self._midiPlayDelayTime)
    -- else
    --     startPlayMidi()
    -- end

    self._playerBarLayer:setTotalTime(self._player:getTotalTime())
    self._playerBarLayer:onPlay()
end

function LessonStepSongBase:onPlay()
    if self:canResume() then
        self:onResume()
    else
        if self.TeaStuSynchData._currentSubStepIndex == self._currentStepSubAmount then
            self.TeaStuSynchData._currentSubStepIndex = self.TeaStuSynchData._currentSubStepIndex - self:subStepBackJump()
        end
        self:onGoNext()
    end
end

function LessonStepSongBase:onPause()
    if not self._player:isPlaying() then return end
    if self._video then self._video:pause() end
    LessonStepSongBase.super.onPause(self)
    Statistics.trackEventTeacher(Statistics.staffPause)
    self._playStatus = PLAY_STATE.PAUSED
    self._player:pause()
    WanakaAudioPlayer:getInstance():pause()
    self._playerBarLayer:onPause()
end

function LessonStepSongBase:onReplay()
    Statistics.trackEventTeacher(Statistics.staffReplay, {["速度"] = self._defaultPlaySpeed})
    self:resetPlayer()

    if self.TeaStuSynchData._currentSubStepIndex == 1 then
        self.TeaStuSynchData._currentSubStepIndex = self.TeaStuSynchData._currentSubStepIndex + self:subStepNextJump()
    end
    self:onSubStepNext()
end

function LessonStepSongBase:onResume()
    self:onSubStepNext()
end

function LessonStepSongBase:enableKalaMode(isEnable)
    if isEnable then
        if self._waterfallLayer then
            -- self._waterfallLayer:setOutLineSpritesVisible(true)
        end
        self._playerBarLayer:setPitchButtonEnable(false)
        self._player:setConfig("viewMode", VIEW_MODE.WATERFALL)
    else
        self._player:setConfig("viewMode", VIEW_MODE.STAFF)
        self._playerBarLayer:setPitchButtonEnable(true)
    end
end

function LessonStepSongBase:enableLightOn(isEnable)
    self._player:setConfig("light", isEnable)
end

function LessonStepSongBase:enableFinger(isEnable)
    if self._scoreLayer then self._scoreLayer:setFingerVisible(isEnable) end
    -- if self._waterfallLayer then self._waterfallLayer:setFingerVisible(isEnable) end
    self._keyboard:setKeyFingerLabelVisible(isEnable)
end

function LessonStepSongBase:enableMetronome(isEnable)
    if TERMINAL == 1 then return end
    self._player:setConfig("metronome", isEnable)
end

function LessonStepSongBase:enableBackgroundMusic(isEnable)
    if TERMINAL == 1 then return end
    self._player:setConfig("mute", not isEnable)
end

function LessonStepSongBase:enablePitchVisible(isEnable)
    if self._scoreLayer then self._scoreLayer:setStepLabelVisible(isEnable) end
end

function LessonStepSongBase:adjustPlaySpeed(speedValue, isPlus, data)
    Statistics.trackEventTeacher(Statistics.setSpeed, {["速度"] = speedValue})
    self._defaultPlaySpeed = speedValue
    if self._playStatus ~= PLAY_STATE.READY then
        --如果学生端和老师端的播放状态不一致，那么_currentSubStepIndex会不同步，所以通过opcode控制
        if TERMINAL == 0 then
            self.TeaStuSynchData._currentSubStepIndex = self.TeaStuSynchData._currentSubStepIndex - self:subStepBackJump()
        end
        self:resetPlayer()
    end
    if TERMINAL == 0 then
        local opcode = isPlus and OPCODE_PLUS_SPEED or OPCODE_MINUS_SPEED
        OpcodeManager.teacherBoardcastData(opcode, self.TeaStuSynchData._currentSubStepIndex)
    else
        if data then
            local index = string.tonumber(data)
            self.TeaStuSynchData._currentSubStepIndex = index
        end
    end
end

function LessonStepSongBase:showResultLayer(result)
    if self._resultLayer then return end
    Log.d("showResultLayer")
    self._resultLayer = PlayResultLayer.new(result)

    self._resultLayer:addCallback(function(type)
        if type == PopupLayerEvent.kPopupLayerDismiss then
            self._resultLayer = nil
        end
    end)
    self._resultLayer:show()
end

function LessonStepSongBase:dismissResultLayer()
    if self._resultLayer then
        self._resultLayer:dismiss()
        self._resultLayer = nil
    end
end

--根据参数调整下落精灵的坐标
function LessonStepSongBase:adjustFallElementPos(isShowKeyboard)
    local eleList = self._waterfallLayer:getFallElements()
    if self._isHaveVideo and not isShowKeyboard then
        local lessonIndex = LessonStepManager.getStepLessonIndex()
        local videoDataPath = LessonManager.getLessonVideoDataConfigByIndex(lessonIndex)
        WanakaUtils.safeAssert(videoDataPath, "videoDataPath can not be nil")
        local KBHLPolygon = require(videoDataPath)
        -- local KBHLPolygon = self._KBHLNode:getHighLightPolygonInfo()
        if KBHLPolygon then
            local scale = DESIGN_SIZE_WIDTH / KBHLPolygon.width
            local startPitch = self._KBHLNode._startPitch - 1
            for k, v in ipairs(eleList) do
                local p = KBHLPolygon[v:getPitch() - startPitch]
                local realX = (p[1].x + (p[4].x - p[1].x) / 2) * scale
                v:setPositionX(realX)
            end
        end
    else
        for k, v in ipairs(eleList) do
            local rect = self._keyboard:getKeyRect(v:getPitch())
            v:setPositionX(rect.x + rect.width / 2)
        end
    end
end

function LessonStepSongBase:resetPlayer()
    Log.d("resetPlayer")
    if self._scoreLabel then self._scoreLabel:setString("0") end
    if self._scoreLayer then self._scoreLayer:reset() end

    if self._isKalaMode then
        --隐藏小花轮廓
        -- self._waterfallLayer:setOutLineSpritesVisible(false)
        --隐藏小花上面的光圈
        -- self._waterfallLayer:reset()
    end
    self._playerBarLayer:setLoadingBarPercent(0)
    self._playerBarLayer:setProgressTime(0)
    self._playerBarLayer:onPause()
    if self._keyboard then self._keyboard:clearAllKeys() end
    MidiDevice:getInstance():turnOffAllLights()

    self._playStatus = PLAY_STATE.READY

    self._player:stop()
    self._player:reset()
    self._waterfallLayer:scrollOutOfWindow()

    self._playResultTable = {} --重置event,防止重播时用到过期的数据
end

--[[
功能: 演奏完后的处理，需要子类重写
注意: 该函数的调用有以下两种情况:
1.在有背景音乐的情况下，在update方法中，当音乐播放完毕时调用
2.在无背景音乐的情况下，在midi播放完毕后调用
]]
function LessonStepSongBase:onPlayFinish()
    Log.d("LessonStepSongBase:onPlayFinish()")
    Statistics.trackEventTeacher(Statistics.staffEnd)
    if self._midiRecorder then
        local curStep = LessonStepManager.getStepIndex()
        local curLessonId = LessonManager.getLessonIDByIndex(self._lessonIndex)
        local midPath = PlayResultManager.getMidPath(curLessonId, curStep)
        ccFileUtils:removeDirectory(midPath)
        ccFileUtils:createDirectory(midPath)
        self._midiRecorder:stop(midPath .. "result.mid")
    end
    --记录当前弹奏完成的时间戳，用于学生端进行本次pk成绩，与名次校验
    if TERMINAL == 1 and self._isPk then
        self._completeTick = os.time()
    end
    --老师开启成绩计算
    if TERMINAL == 0 then
        if self._isPk then
            PlayResultManager.startScheduleForCheckPlayResult()
        end
    end
end

function LessonStepSongBase:resetFinish(result)
    Log.d("resetWhenHaveMusic")

    --学生端弹琴完成上传数据
    if self._isPk then
        if TERMINAL == 0 then
            self:addPkResultTeacherLayer()
        else
            self:setSwitchPianoSound(false)
            self._pkResultLayer = PkResultStudentLayer.new(point, function()
                self._pkResultLayer = nil
            end)
            self._pkResultLayer:show()
            self:sendPlayData()
        end
    else
        if self._stepConfig.hasPlayResult then
            self:showResultLayer(result)
        end
    end
    self:resetPlayer()
end

--[[将destoryScene函数中传入的回调函数，在这里封装一下，
统一调用，保证学生端在图片保存完成后才能销毁当前场景
]]
function LessonStepSongBase:delayDestroyCallbackHandle()
    if TERMINAL == 1 then
        if self._isSavingPic then return end --学生
    end
    if self._destroyCallback then
        self._destroyCallback()
        self._destroyCallback = nil
    end
end

function LessonStepSongBase:upLoadPlayResult(isHavePicture)
    if (self._stepStatus ~= kLessonStatusNormal) or (not self._stepConfig.staffPath) then
        return
    end

    --老师端不执行截屏并且上传的操作
    if TERMINAL == 0 then return end
    --统计分数上传到后台
    self._isSavingPic = isHavePicture
    self._isHavePicture = isHavePicture
    local needUploadRecorde = self._midiRecorder and true or false
    local score = self:getScoreEngine():getDefaultFinalScore()
    local maxCombo = self:getScoreEngine():getMaxCombo()
    local wholeCombo = self:getScoreEngine():getTotalCombo()
    local rightRate = self:getScoreEngine():getRightRate()
    local duration = self:getScoreEngine():getDurationScore()
    local rhythm = self:getScoreEngine():getRhythmScore(0.5)
    local scoreData = {["score"]=score, ["max_combo"]=maxCombo, ["full_combo"]=wholeCombo,["accurate"]=rightRate,
        ["rhythm"] = rhythm, ["duration"] = duration}
    local curStep = LessonStepManager.getStepIndex()
    local curLessonId = LessonManager.getLessonIDByIndex(self._lessonIndex)
    WanakaUtils.safeAssert(curLessonId, "curLessonId can not be nil")
    Log.d("LessonStepSongBase upLoadPlayResult score = %s, isHavePicture = %s, step = %d, curLessonId = %s", tostring(score),
        tostring(isHavePicture), curStep, tostring(curLessonId))

    if isHavePicture then
        --创建页曲谱
        local scoreXML = MusicXmlLoader:loadFromFile(self._stepConfig.staffPath)
        local staffLayerCut = ScoreLayer:createEx(scoreXML, 1, STAFF_MODE.ONEPAGEMODE, 0)
        staffLayerCut:setLaserlineVisibility(false)
        staffLayerCut:setPageNumberLabelVisible(false)
        staffLayerCut:setPageHeaderLabelVisible(false)
        staffLayerCut:setVisible(false)
        self:resetNoteColor(staffLayerCut, midi)
        self:addChild(staffLayerCut:getParentLayer(), 10000)
        --上传数据用临时变量
        local midi = Midi:new()
        midi:retain()
        midi:loadFromXMLData(scoreXML)
        --还原弹奏结束现场
        local eventCount = midi:getEventCount()
        for i = 1, eventCount do
            local baseEvent = midi:getEventAtIndex(i - 1)
            if MIDI_EVENT_TYPE.PITCH == baseEvent:getType() then
                local pitchEvent = tolua.cast(baseEvent, "Wanaka.PitchEvent")
                if pitchEvent and pitchEvent:isOn() then
                    local tick = pitchEvent:getTick()
                    local pitchValue = pitchEvent:getPitch()
                    if self._playResultTable[tick] and self._playResultTable[tick][pitchValue] then
                        for _, result in pairs(self._playResultTable[tick][pitchValue]) do
                            staffLayerCut:updateLaserLine(result._lastTick, self._midi:getTicksPerQuauter(), false)
                            local ret = result._result
                            if ret == StepPlayEngineResult.kMiss then
                                staffLayerCut:setNoteColor(pitchEvent:getNote(), cc.c4f(1.0, 0, 0, 1.0))
                            elseif ret == StepPlayEngineResult.kNoMatch then
                                local trackIndex = pitchEvent:getTrack()
                                local minPitch, maxPitch = LessonStepSongUtils.computerPitchRange(midi, trackIndex)
                                if result._missPitch >= minPitch and result._missPitch <= maxPitch then
                                    staffLayerCut:AddNoteOfMistake(pitchEvent:getNote(), result._missPitch, result._lastTick, midi:getTicksPerQuauter())
                                else
                                    staffLayerCut:setNoteColor(pitchEvent:getNote(), cc.c4f(1.0, 0, 0, 1.0))
                                end
                            elseif ret == StepPlayEngineResult.kGreat or ret == StepPlayEngineResult.kPerfect then
                                staffLayerCut:setNoteColor(pitchEvent:getNote(), cc.c4f(0, 1.0, 0, 1.0))
                            end
                        end
                    end
                end
            end
        end

        --用完midi释放掉
        midi:release()

        --清除上次图片缓存，将图片保存到本地，在保存结束后将分数和图片上传到后台
        local path = PlayResultManager.getImagePath(tostring(curLessonId), curStep)
        ccFileUtils:removeDirectory(path)

        local finishSaveCallBack = function(savedPicCount)
            Log.d("save pic success and savedPicCount = %d", savedPicCount)
            staffLayerCut:removeSelf()
            staffLayerCut = nil
            self._isSavingPic = false
            PlayResultManager.pushScore(scoreData, self._lessonIndex, curStep,
                isHavePicture, needUploadRecorde, self._completeTick)
            self:delayDestroyCallbackHandle()
        end
        self:performWithDelay(function()
            Log.d("LessonStepSongBaseSaveToFile")
            staffLayerCut:saveToFile(path, finishSaveCallBack)
        end, 0.1)
    else
        PlayResultManager.pushScore(scoreData, self._lessonIndex, curStep,
            isHavePicture, needUploadRecorde, self._completeTick)
    end
end

function LessonStepSongBase:addPkResultTeacherLayer()
    self._pkResultLayer = PkResultTeacherLayer.new(function()
        self._pkResultLayer = nil
    end)
    self._pkResultLayer:show()
    SynchNodeManager.setSynchEnable(true)
end

function LessonStepSongBase:hidePkResultLayer()
    self._resultsData = {}
    if self._pkResultLayer then
        self._pkResultLayer:dismiss()
        self._pkResultLayer = nil
    end
end

function LessonStepSongBase:sendPlayData()
    local scoreEngine = self:getScoreEngine()
    local rightRate = scoreEngine:getRightRate()
    local durationScore = scoreEngine:getDurationScore()
    --TODO:great分数相当于perfect分数的一半，故用0.5？
    local rhythmScore = scoreEngine:getRhythmScore(0.5)
    local finalScore = scoreEngine:getDefaultFinalScore()

    local resultTab = {rightRate = rightRate, durationScore = durationScore, rhythmScore = rhythmScore,
        finalScore = finalScore, midiData = midiData, tick = self._completeTick}
    local data = {result = resultTab}
    self:addOpcodeCheckData(data)
    OpcodeManager.studentSendStringData(OPCODE_STUDENT_PLAY_DATA, data)
end

function LessonStepSongBase:destoryScene(callback)
    self._destroyCallback = callback   --保存销毁后的回调，做延时处理
    if self._destoryed then
        self:delayDestroyCallbackHandle()
        return
    end
    self._destoryed = true

    self._keyboard:setCallbackAvailable(false)

    if self._video then self._video:stop() end
    self:setSwitchPianoSound(false)

    -- if self._midi then self._midi:release() end
    if self._midiRecorder then self._midiRecorder:release() end

    MidiDevice:getInstance():turnOffAllLights()
    self:removeAllEventListener()

    -- device
    if self.deviceCallbackId then
        MidiDevice:getInstance():removeCallback(self.deviceCallbackId)
    end

    -- player
    self._player:release()

    self:delayDestroyCallbackHandle()
end

function LessonStepSongBase:synchData()
    Log.d("LessonStepSongBase:synchData")
    table.print(self.TeaStuSynchData)
    local data = self.TeaStuSynchData

    self._playerBarLayer:enableKalaMode(data.isKalaMode)
    self:enableKalaMode(data.isKalaMode)
    self._playerBarLayer:enablePitchVisible(data.isPitchVisible)
    self:enablePitchVisible(data.isPitchVisible)
    self._playerBarLayer:enableFinger(data.isShowFinger)
    self:enableFinger(data.isShowFinger)
    self._playerBarLayer:enableLightOn(data.isLightOn)
    self:enableLightOn(data.isLightOn)
    self._playerBarLayer:synchPlaySpeed(data.defaultPlaySpeed * 100)

    if data.playStatus ~= PLAY_STATE.READY and data.tick > 0 then
        if data.playStatus == PLAY_STATE.PLAYING or self._playMode == PLAY_MODE.WAIT then
            self:onSubStepNext()
            if self._playMode == PLAY_MODE.WAIT and self._midiPlayer then
                self._stopSynch = true
            end
        elseif data.playStatus == PLAY_STATE.PAUSED then
            self:onSubStepNext()
            self:onPause()
            self._player:setTick(data.tick)
            self:setPlayBar(data.tick)
            if self._scoreLayer then self._scoreLayer:horizontalScroll(data.tick) end
            if self._waterfallLayer then self._waterfallLayer:scrollTo(data.tick) end
        end
    end

    if data.showResult then
        --需要延迟才能显示
        self:performWithDelay(function()
            local result = {score = 0, intonation = 0, notevalue = 0, rhythm = 0}
            self:showResultLayer(result)
        end, 0.1)
    end
end

function LessonStepSongBase:updateSynchData(data)
    data.tick = self._player:getTick()
    data.showResult = self._resultLayer and true or false
    data.playStatus = self._playStatus
    if self._scoreLayer then
        data.currentSystemId = self._scoreLayer:getCurrentSystemId()
    end

    data.isLightOn = self._player:getConfig("light")
    data.view = self._player:getConfig("viewMode")
    data.isPitchVisible = self._scoreLayer:isStepLabelVisible()
    data.isShowFinger = self._scoreLayer:isFingerVisible()
    data.defaultPlaySpeed = self._defaultPlaySpeed
end

function LessonStepSongBase:handleMouseCheck(opcode, data, studentID)
    if self._scoreMode == SCORE_MODE.STACKMODE then
        if data then
            self._playerBarLayer:setVisible(true)
        elseif self._player:isPlaying() then
            self._playerBarLayer:setVisible(false)
        end
    end
end

return LessonStepSongBase
