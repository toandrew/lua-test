#include <map>
#include "FollowGameEngine.h"
#include "FallElementSprite.h"
#include "Macros.h"

#include "WaterfallLayer.h"

#pragma execution_character_set("utf-8")

#define STANDARD_TEMPO 60
#define RATE_OF_TICK_LENGTH 6

static bool game_debug = false;

static const char *sDefaultFrameNames[] = {
    "perfect.png", "great.png", "miss.png",
};

void FollowGameEngine::setDebugEnabled(bool enabled) {
    game_debug = enabled;
}

using namespace std;

static vector<float> getLongPressComboY(FallElementSprite *sprite, int pressComboLength) {
    vector<float> result;
    if (sprite != nullptr) {
        //从2分音符开始算起
        for (int length = pressComboLength * 2; length < sprite->getLength(); length += pressComboLength) {
            result.push_back(sprite->getPositionY() + length);
        }
    }
    return result;
}

bool FollowGameEngine::init() {
    reset();
    _tempo = STANDARD_TEMPO;
    _perfectRange = 25;  //根据实际测试为了能同步瀑布流，放宽perfect区域 15 -》 25
    _greatRange = 30;
    _missRange = 50;
    _judgeBaselineOffset = 0;
    _perfectRangeLayer = nullptr;
    _greatRangeLayer = nullptr;
    _missRangeLayer = nullptr;
    _ratingCallback = nullptr;
    _isDisplayRatingResult = true;
    _scoreLabel = nullptr;

    _standardPerfectScore = 30;
    _standardGreatScore = 20;

    //_longPressComboLength = 30;
    //四分音符是480 tick, 6个tick1个像素，计算八分音符的显示长度
    _longPressComboLength = 480 / 2 / RATE_OF_TICK_LENGTH;

    _gameScoreStrategy = new GameScoreStrategy3();

    retainNeededObjects();

    return true;
}

FollowGameEngine::~FollowGameEngine() {
    if (_gameScoreStrategy != nullptr) {
        delete _gameScoreStrategy;
    }
    releaseNeededObjects();
}

void FollowGameEngine::setScoreMode(ScoreMode scoreMode) {
    _scoreMode = scoreMode;
}

void FollowGameEngine::setGameScoreStrategy(GameScoreStrategy *strategy) {
    if (_gameScoreStrategy != nullptr) {
        delete _gameScoreStrategy;
        _gameScoreStrategy = strategy;
    }
}

void FollowGameEngine::retainNeededObjects() {
    for (int i = 0; i < sizeof(sDefaultFrameNames) / sizeof(sDefaultFrameNames[0]); i++) {
        SpriteFrame *frame = SpriteFrameCache::getInstance()->getSpriteFrameByName(sDefaultFrameNames[i]);
        if (frame != nullptr) {
            frame->retain();
            _needRetainObjects.insert(frame);
        }
    }
}

void FollowGameEngine::releaseNeededObjects() {
    for (auto iter = _needRetainObjects.begin(); iter != _needRetainObjects.end(); iter++) {
        (*iter)->release();
    }
    _needRetainObjects.clear();
}

void FollowGameEngine::setUILayer(Layer *ui) {
    _ui = ui;

    if (game_debug) {
        _scoreLabel = Label::createWithSystemFont("", "", 50);
        _scoreLabel->setPosition(300, 300);
        _scoreLabel->setColor(Color3B::RED);
        _ui->addChild(_scoreLabel);

        float width = ui->getContentSize().width;
        Color4B perfectColor = Color4B::GREEN;
        perfectColor.a = 100;
        Color4B greatColor = Color4B::ORANGE;
        greatColor.a = 100;
        Color4B missColor = Color4B::RED;
        missColor.a = 100;

        _perfectRangeLayer = LayerColor::create(perfectColor, width, _perfectRange * 2);
        _greatRangeLayer = LayerColor::create(greatColor, width, _greatRange * 2);
        //    _missRangeLayer = LayerColor::create(missColor, width, _missRange * 2);
        _judgeBaseLineLayer = LayerColor::create(Color4B::BLACK, width, 1);

        //    ui->addChild(_missRangeLayer);
        ui->addChild(_greatRangeLayer);
        ui->addChild(_perfectRangeLayer);
        ui->addChild(_judgeBaseLineLayer);

        //    _missRangeLayer->ignoreAnchorPointForPosition(false);
        _greatRangeLayer->ignoreAnchorPointForPosition(false);
        _perfectRangeLayer->ignoreAnchorPointForPosition(false);
        _judgeBaseLineLayer->ignoreAnchorPointForPosition(false);

        //    _missRangeLayer->setAnchorPoint(Point::ANCHOR_MIDDLE);
        _greatRangeLayer->setAnchorPoint(Point::ANCHOR_MIDDLE);
        _perfectRangeLayer->setAnchorPoint(Point::ANCHOR_MIDDLE);
        _judgeBaseLineLayer->setAnchorPoint(Point::ANCHOR_MIDDLE);

        layoutJudgeRange();

        //    addDebugMenu("Miss区域 ", [this](Ref*) {
        //        setMissRange(getMissRange()+1);
        //        Label *valueLabel = (Label*)_ui->getChildByTag(100);
        //        char valueStr[64] = {0};
        //        sprintf(valueStr, "%d", getMissRange());
        //        valueLabel->setString(valueStr);
        //    }, [this](Ref*) {
        //        setMissRange(getMissRange()-1);
        //        Label *valueLabel = (Label*)_ui->getChildByTag(100);
        //        char valueStr[64] = {0};
        //        sprintf(valueStr, "%d", getMissRange());
        //        valueLabel->setString(valueStr);
        //    }, Point(100,100), _missRange, 100);

        addDebugMenu("Great区域 ",
                     [this](Ref *) {
                         setGreatRange(getGreatRange() + 1);
                         Label *valueLabel = (Label *)_ui->getChildByTag(200);
                         char valueStr[64] = {0};
                         sprintf(valueStr, "%d", getGreatRange());
                         valueLabel->setString(valueStr);
                     },
                     [this](Ref *) {
                         setGreatRange(getGreatRange() - 1);
                         Label *valueLabel = (Label *)_ui->getChildByTag(200);
                         char valueStr[64] = {0};
                         sprintf(valueStr, "%d", getGreatRange());
                         valueLabel->setString(valueStr);
                     },
                     Point(100, 200), _greatRange, 200);

        addDebugMenu("Perfect区域 ",
                     [this](Ref *) {
                         setPerfectRange(getPerfectRange() + 1);
                         Label *valueLabel = (Label *)_ui->getChildByTag(300);
                         char valueStr[64] = {0};
                         sprintf(valueStr, "%d", getPerfectRange());
                         valueLabel->setString(valueStr);
                     },
                     [this](Ref *) {
                         setPerfectRange(getPerfectRange() - 1);
                         Label *valueLabel = (Label *)_ui->getChildByTag(300);
                         char valueStr[64] = {0};
                         sprintf(valueStr, "%d", getPerfectRange());
                         valueLabel->setString(valueStr);
                     },
                     Point(100, 300), _perfectRange, 300);
    }

    _maxLongComboPerfectCount = 0;
    Vector<Node *> &nodes = ((Wanaka::WaterfallLayer *)_ui)->getFallElements();
    for (int i = 0; i < nodes.size(); i++) {
        float len = ((FallElementSprite *)nodes.at(i))->getLength();
        len = len * RATE_OF_TICK_LENGTH;
        float ticksPerCombo = 240.0;
        if (len > ticksPerCombo * 2) {
            for (int ticksAtCombo = ticksPerCombo * 2; ticksAtCombo < len; ticksAtCombo += ticksPerCombo) {
                _maxLongComboPerfectCount += 1;
            }
        }
    }
}

void FollowGameEngine::addDebugMenu(const char *label, const ccMenuCallback &addCallback, const ccMenuCallback &subCallback, const Point &pos, int value, int tag) {
    Label *labelNode = Label::createWithSystemFont(label, "", 38);
    _ui->addChild(labelNode);

    Label *valueLabel = Label::createWithSystemFont("", "", 38);
    _ui->addChild(valueLabel);
    valueLabel->setTag(tag);

    Label *add = Label::createWithSystemFont("增加 ", "", 38);
    MenuItemLabel *menuAdd = MenuItemLabel::create(add, addCallback);

    Label *sub = Label::createWithSystemFont("减少 ", "", 38);
    MenuItemLabel *menuSub = MenuItemLabel::create(sub, subCallback);

    Menu *menu = Menu::create(menuAdd, menuSub, NULL);
    menuSub->setPosition(Point(100, 0));
    _ui->addChild(menu);
    labelNode->setPosition(pos);
    valueLabel->setPosition(pos + Point(labelNode->getContentSize().width, 0));
    menu->setPosition(pos + Point(labelNode->getContentSize().width + 100, 0));

    char valueStr[64] = {0};
    sprintf(valueStr, "%d", value);
    valueLabel->setString(valueStr);
}

void FollowGameEngine::layoutJudgeRange() {
    if (game_debug) {
        float width = _ui->getContentSize().width;
        if (_missRangeLayer != nullptr) {
            _missRangeLayer->setContentSize(Size(width, _missRange * 2));
            _missRangeLayer->setPosition(Point(width / 2, _judgeBaselineOffset));
        }

        if (_greatRangeLayer != nullptr) {
            _greatRangeLayer->setContentSize(Size(width, _greatRange * 2));
            _greatRangeLayer->setPosition(Point(width / 2, _judgeBaselineOffset));
        }

        if (_perfectRangeLayer != nullptr) {
            _perfectRangeLayer->setContentSize(Size(width, _perfectRange * 2));
            _perfectRangeLayer->setPosition(Point(width / 2, _judgeBaselineOffset));
        }

        _judgeBaseLineLayer->setPosition(Point(width / 2, _judgeBaselineOffset));
    }
}

void FollowGameEngine::reset() {
    _perfectElements.clear();
    _greatElements[0].clear();
    _greatElements[1].clear();
    _topMissElements.clear();
    _hitElementsLongPressComboPoint.clear();

    _ratingSprite = nullptr;
    _comboNode = nullptr;
    _combo = 0;
    _maxCombo = 0;
    _score = 0;
    _totalHits = 0;

    _longPressComboCount = 0;
    _greatCount = 0;
    _perfectCount = 0;
}

// TODO: 此函数名称难以准确说明其用处
static FallElementSprite *hasPitchAndMark(map<Node *, bool> &nodes, int pitch) {
    for (auto iter = nodes.begin(); iter != nodes.end(); iter++) {
        FallElementSprite *sprite = static_cast<FallElementSprite *>(iter->first);
        if (sprite != nullptr && sprite->getPitch() == pitch && iter->second == false) {
            iter->second = true;
            sprite->hit();
            return sprite;
        }
    }
    return nullptr;
}

// LOGIC: 音符起始点在perfect或great区域时对应琴键被按下，即算击中
std::pair<int, float> FollowGameEngine::getRatingAndDistance(int pitch, Point offset) {
    std::pair<int, float> result;
    FallElementSprite *sprite = hasPitchAndMark(_greatElements[1], pitch);
    if (sprite != nullptr) {
        result.first = kGreat;
        result.second = fabs(sprite->getPositionY() - fabs(offset.y));
        _hitElements[sprite] = kGreat;
    } else {
        sprite = hasPitchAndMark(_perfectElements, pitch);
        if (sprite != nullptr) {
            result.first = kPerfect;
            result.second = fabs(sprite->getPositionY() - fabs(offset.y));
            _hitElements[sprite] = kPerfect;
        } else {
            sprite = hasPitchAndMark(_greatElements[0], pitch);
            if (sprite != nullptr) {
                result.first = kGreat;
                result.second = fabs(sprite->getPositionY() - fabs(offset.y));
                _hitElements[sprite] = kGreat;
            } else {
                result.first = kNone;
                result.second = 0;
            }
        }
    }

    return result;
}

void FollowGameEngine::onWaterfallDidScroll(Wanaka::WaterfallLayer *layer) {
    onWaterfallDidScroll(layer->getFallElements(), layer->getScrollOffset());
}

void FollowGameEngine::onWaterfallDidScroll(Vector<Node *> &elements, Point offset) {
    // 6 ticks is a pixel by default.
    const float bottomY = fabs(offset.y);

    for (int i = 0; i < elements.size(); i++) {
        FallElementSprite *sprite = static_cast<FallElementSprite *>(elements.at(i));
        if (sprite != nullptr) {
            const float y = sprite->getPositionY();
            //(150, 300] ticks
            if (y > bottomY + _greatRange + _judgeBaselineOffset && y <= bottomY + _missRange + _judgeBaselineOffset) {
                // MISS
                //                if (_topMissElements.find(sprite) == _topMissElements.end()) {
                //                    _topMissElements[sprite] = false;   //false代表还没有键盘事件
                //                }
            } else if (y >= bottomY + _perfectRange + _judgeBaselineOffset && y <= bottomY + _greatRange + _judgeBaselineOffset) {
                // GREAT
                if (_greatElements[0].find(sprite) == _greatElements[0].end()) {
                    auto iter = _topMissElements.find(sprite);
                    if (iter != _topMissElements.end()) {
                        _greatElements[0][sprite] = _topMissElements[sprite];
                        _topMissElements.erase(iter);
                    } else {
                        _greatElements[0][sprite] = false;
                    }
                }
            } else if (y > bottomY - _perfectRange + _judgeBaselineOffset && y < bottomY + _perfectRange + _judgeBaselineOffset) {
                // PERFECT
                if (_perfectElements.find(sprite) == _perfectElements.end()) {
                    auto iter = _greatElements[0].find(sprite);
                    if (iter != _greatElements[0].end()) {
                        _perfectElements[sprite] = _greatElements[0][sprite];
                        _greatElements[0].erase(iter);
                    } else {
                        _perfectElements[sprite] = false;
                    }
                }
            } else if (y >= bottomY - _greatRange + _judgeBaselineOffset && y <= bottomY - _perfectRange + _judgeBaselineOffset) {
                // GREAT
                if (_greatElements[1].find(sprite) == _greatElements[1].end()) {
                    auto iter = _perfectElements.find(sprite);
                    if (iter != _perfectElements.end()) {
                        _greatElements[1][sprite] = _perfectElements[sprite];
                        _perfectElements.erase(iter);
                    } else {
                        _greatElements[1][sprite] = false;
                    }
                }
            } else if (y < bottomY - _greatRange + _judgeBaselineOffset) {
                // MISS
                auto iter = _greatElements[1].find(sprite);
                if (iter != _greatElements[1].end()) {
                    // TODO: 最后几个音符可能移动不到可以发出miss的区域
                    if (_greatElements[1][sprite] == false) {
                        setRating(kMiss);
                    }
                    _greatElements[1].erase(iter);
                } else if (_perfectElements.find(sprite) != _perfectElements.end()) {
                    _perfectElements.erase(sprite);
                }
            }
        }
    }

    auto iter = _hitElements.begin();
    while (iter != _hitElements.end()) {
        FallElementSprite *sprite = static_cast<FallElementSprite *>(iter->first);
        const float y = sprite->getPositionY();

        vector<float> &&longPressComboYs = getLongPressComboY(sprite, _longPressComboLength);
        for (int i = 0; i < longPressComboYs.size(); i++) {
            //只要当前的长连击大于bottomY，就满足条件，防止miss
            // if (fabs(longPressComboYs[i] - bottomY) <= 1){
            if (longPressComboYs[i] <= bottomY) {
                // 计算分数
                if (_hitElementsLongPressComboPoint[sprite].count(longPressComboYs[i]) == 0) {
                    _hitElementsLongPressComboPoint[sprite].insert(longPressComboYs[i]);
                    setRating(kPerfect);
                    GameScoreStrategyContext context;
                    context.combo = _combo;
                    context.comboInNote = 0;  // TODO: 这个值什么意思？
                    context.rateing = kPerfect;
                    context.toleranceRadius = (_perfectRange + _greatRange) * RATE_OF_TICK_LENGTH;
                    context.deltaDistance = 0;

                    _score += _gameScoreStrategy->compute(&context);
                    if (_scoreLabel != nullptr) {
                        char scoreLabel[50] = {0};
                        sprintf(scoreLabel, "%d", (int)_score);
                        _scoreLabel->setString(scoreLabel);
                    }
                    _longPressComboCount++;
                }
            }
        }

        // 已击中音符时值全部过去后，移出_hitElements
        if (sprite != nullptr && y + sprite->getLength() < bottomY) {
            iter = _hitElements.erase(iter);
        } else {
            iter++;
        }
    }
}

void FollowGameEngine::setRating(Rating rating) {
    // rating
    if (rating != kNone && _ratingSprite != nullptr) {
        _ui->removeChild(_ratingSprite, true);
        _ratingSprite = nullptr;
    }

    switch (rating) {
        case kPerfect:
            _ratingSprite = Sprite::createWithSpriteFrameName("perfect.png");
            _combo++;
            break;
        case kGreat:
            _ratingSprite = Sprite::createWithSpriteFrameName("great.png");
            _combo++;
            break;
        case kMiss:
            _ratingSprite = Sprite::createWithSpriteFrameName("miss.png");
            _combo = 0;
            break;
        case kNone:
            _combo = 0;
            break;
        default:
            break;
    }

    if (_combo > _maxCombo) {
        _maxCombo = _combo;
    }

    if (!_isDisplayRatingResult) {
        return;
    }

    Size uiSize = _ui->getContentSize();
    if (_ratingSprite != nullptr && rating != kNone) {
        _ratingSprite->setPosition(uiSize.width / 2, uiSize.height * 400 / 640);
        _ui->addChild(_ratingSprite);

        _ratingSprite->setScale(0.6f);

        _ratingSprite->runAction(Sequence::create(ScaleTo::create(0.1f, 1.0f), DelayTime::create(0.2f), FadeOut::create(0.2f), nullptr));
    }

    if (!_isDisplayRatingResult) {
        return;
    }

    if (_comboNode != nullptr) {
        _ui->removeChild(_comboNode, true);
        _comboNode = nullptr;
    }

    if (_combo > 0) {
        _comboNode = Node::create();
        _comboNode->setContentSize(uiSize);

        std::stringstream ss;
        ss << _combo;
        Label *comboLabel = Label::createWithSystemFont(ss.str().c_str(), COMBO_NUMBER_FONT, 80);
        comboLabel->setAnchorPoint(Point::ANCHOR_MIDDLE);
        comboLabel->setWidth(comboLabel->getContentSize().width + 30);  // 避免斜体字右侧字符有部分被裁减掉
        comboLabel->setPosition(uiSize.width / 2, _ratingSprite->getBoundingBox().getMinY() - comboLabel->getBoundingBox().size.height - 10);
        _comboNode->addChild(comboLabel);

        _ui->addChild(_comboNode);

        _comboNode->setOpacity(0x80);  // TODO: not works?
        _comboNode->runAction(
            Sequence::create(Spawn::create(MoveBy::create(0.1f, Point(0, 20)), FadeIn::create(0.1f), nullptr), FadeOut::create(0.3f), Hide::create(), nullptr));  // TODO: fade not works
    }
}

void FollowGameEngine::setIsDisplayRatingResult(bool display) {
    _isDisplayRatingResult = display;
}

bool FollowGameEngine::getIsDisplayRatingResult() {
    return _isDisplayRatingResult;
}

void FollowGameEngine::computeScore(double distance, Rating rating) {
    if (fabs(distance) <= 30 && rating != kMiss && rating != kNone) {
        GameScoreStrategyContext context;
        context.combo = _combo;
        context.comboInNote = 0;
        context.rateing = rating;
        //这个都转换为对应的tick
        context.toleranceRadius = (_greatRange + _perfectRange) * RATE_OF_TICK_LENGTH;
        context.deltaDistance = distance * RATE_OF_TICK_LENGTH;

        _score += _gameScoreStrategy->compute(&context);
        if (_scoreLabel != nullptr) {
            char scoreLabel[50] = {0};
            sprintf(scoreLabel, "%d", (int)_score);
            _scoreLabel->setString(scoreLabel);
        }
    }
}

void FollowGameEngine::onKeyDown(int pitch, Point waterfallOffset) {
    std::pair<int, float> &&result = getRatingAndDistance(pitch, waterfallOffset);
    Rating rating = (Rating)result.first;
    setRating(rating);
    computeScore(result.second, rating);

    if (rating == kGreat || rating == kPerfect) {
        Wanaka::WaterfallLayer *waterfall = dynamic_cast<Wanaka::WaterfallLayer *>(_ui);
        if (waterfall != nullptr) {
            waterfall->hitPitch(pitch);
        }
        _totalHits++;
        if (rating == kGreat) {
            _greatCount++;
        } else if (rating == kPerfect) {
            _perfectCount++;
        }
    }

    if (_ratingCallback != nullptr) {
        _ratingCallback(pitch, result.first, _score);
    }
}

void FollowGameEngine::onKeyUp(int pitch, Point waterfallOffset) {
    // 在连击计分点出基准线之前松开已击中音符对应琴键，移出_hitElements
    auto iter = _hitElements.begin();
    while (iter != _hitElements.end()) {
        FallElementSprite *sprite = static_cast<FallElementSprite *>(iter->first);
        vector<float> &&lpcys = getLongPressComboY(sprite, _longPressComboLength);

        float y = 0.0f;
        if (lpcys.size() > 0) {
            y = lpcys.back();
        }

        if (sprite != nullptr && sprite->getPitch() == pitch && sprite->getPositionY() + sprite->getLength() > fabs(waterfallOffset.y)) {
            iter = _hitElements.erase(iter);
        } else {
            iter++;
        }
    }
}

void FollowGameEngine::setRatingCallback(RatingCallback ratingCallback) {
    _ratingCallback = ratingCallback;
}

int FollowGameEngine::getScore() {
    return _score;
}

unsigned int FollowGameEngine::getTotalScore() {
    int maxScore = 0;

    //全部的perfect数目
    for (int i = 0; i < _totalNotes + _maxLongComboPerfectCount; i++) {
        GameScoreStrategyContext context;
        context.combo = i + 1;
        context.comboInNote = 0;
        context.rateing = kPerfect;
        context.toleranceRadius = (_greatRange + _perfectRange) * RATE_OF_TICK_LENGTH;
        context.deltaDistance = 0;

        maxScore += _gameScoreStrategy->compute(&context);
    }

    return maxScore;
}

int FollowGameEngine::getMaxCombo() {
    return _maxCombo;
}

int FollowGameEngine::getRightRate() {
    return (_totalHits * 100 / _totalNotes);
}

void FollowGameEngine::setTempo(int tempo) {
    _tempo = tempo;
}

void FollowGameEngine::setPerfectRange(int range) {
    _perfectRange = range;
    _perfectRange *= (float)_tempo / (float)STANDARD_TEMPO;
    layoutJudgeRange();
}

void FollowGameEngine::setGreatRange(int range) {
    _greatRange = range;
    _greatRange *= (float)_tempo / (float)STANDARD_TEMPO;
    layoutJudgeRange();
}

void FollowGameEngine::setMissRange(int range) {
    _missRange = range;
    _missRange *= (float)_tempo / (float)STANDARD_TEMPO;
    layoutJudgeRange();
}

void FollowGameEngine::setJudgeLineOffset(int offset) {
    _judgeBaselineOffset = offset;
    layoutJudgeRange();
}

int FollowGameEngine::getTempo() {
    return _tempo;
}

int FollowGameEngine::getPerfectRange() {
    return _perfectRange;
}

int FollowGameEngine::getGreatRange() {
    return _greatRange;
}

int FollowGameEngine::getMissRange() {
    return _missRange;
}

int FollowGameEngine::getJudgeLineOffset() {
    return _judgeBaselineOffset;
}

//计算时值得分
int FollowGameEngine::getDurationScore() {
    int allLongComboPoints = _perfectCount + _greatCount + _longPressComboCount;
    int maxLongComboPoints = _maxLongComboPerfectCount + _totalNotes;
    return allLongComboPoints * 100 / maxLongComboPoints;
}

//计算节奏得分,getGreatRate() * weight +getPerfectRate() * (1 - weight)
int FollowGameEngine::getRhythmScore(float weight) {
    int greatScore = _greatCount * 100 / _totalNotes;
    int perfectScore = _perfectCount * 100 / _totalNotes;
    return greatScore * weight + perfectScore;
}

//计算最大连击数
unsigned int FollowGameEngine::getTotalCombo() {
    return _maxLongComboPerfectCount + _totalNotes;
}

float FollowGameEngine::getFinalScore(float rightRatePercent, float durationPercent, float rhythmPercent) {
    return getRightRate() * rightRatePercent + getDurationScore() * durationPercent + getRhythmScore(0.5f) * rhythmPercent;
}
