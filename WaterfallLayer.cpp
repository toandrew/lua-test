#include "WaterfallLayer.h"
#include "WanakaMidi.h"
#include "FallElementSprite.h"
#include "FlowerElementSprite.h"
#include "MiniKeyboard.h"

#define RATE_OF_TICK_LENGTH 6
USING_NS_WANAKA;

static bool game_debug = false;

void WaterfallLayer::setDebugEnabled(bool enabled) {
    game_debug = enabled;
}

inline static int tickToY(int tick) {
    return tick / RATE_OF_TICK_LENGTH;
}

WaterfallLayer::WaterfallLayer() : _midi(nullptr), _scrollView(nullptr), _linesNode(nullptr), _keyboardLayer(nullptr), _mode(kWaterfallModeGame), _background(nullptr), _scrollCallback(nullptr), _baselineSprite(nullptr), _hitBaselineSprite(nullptr) {
}

bool WaterfallLayer::init(Wanaka::Midi *midi, MiniKeyboard *keyboard, FallElementSpriteBuilder builder, WaterfallMode mode) {
    Layer::init();
    _midi = midi;
    _keyboardLayer = keyboard;
    _mode = mode;

    // background image
//    Sprite *background = Sprite::create("background.png");
//    background->setAnchorPoint(Point::ANCHOR_BOTTOM_LEFT);
//    background->setPosition(Point::ZERO);
//    addChild(background);
//    _background = background;

    // advanced mode layout
    layoutSubNodes();

    // scroll view
    Size winSize = Director::getInstance()->getWinSize();
    _scrollView = extension::ScrollView::create();
    _scrollView->setPosition(Point::ZERO);
    _scrollView->setViewSize(winSize);
    _scrollView->setDirection(extension::ScrollView::Direction::VERTICAL);
    _scrollView->setBounceable(false);

    float maxY = 0;
    for (int i = 0; i < _midi->getTracks().size(); i++) {
        Track *track = _midi->getTracks()[i];
        CCLOG("track: %d events count: %lu", i, track->getEvents().size());
        if (!track->getEvents().empty()) {
            float y = tickToY(track->getEvents().back()->getTick());
            if (maxY < y) {
                maxY = y;
            }

        }
    }
    const float totalHeight = maxY + _scrollView->getViewSize().height;
    _scrollView->setContentSize(Size(_scrollView->getContentSize().width, totalHeight));
    addChild(_scrollView);

    // draw node
//    const Size &contentSize = _scrollView->getContentSize();
//    _linesNode = DrawNode::create();
//    _linesNode->setPosition(Point::ZERO);
//    _linesNode->setContentSize(contentSize);
//    _scrollView->addChild(_linesNode);
//    Color3B backgroundColor = {0x24, 0x24, 0x24};
//    Color3B lineColor = {0x41, 0x41, 0x41};
//    Point verts[] = {Point::ZERO, Point(contentSize.width, 0), Point(contentSize.width, contentSize.height), Point(0, contentSize.height)};
//    _linesNode->drawPolygon(verts, 4, Color4F(backgroundColor), 0, Color4F(backgroundColor));
//    // vertical lines
//    for (int i = 21; i <= 108; i++) {
//        const int key = i % 12;
//        if (key == 0 || key == 5) {
//            const float x = _keyboardLayer->getKeyRect(i).origin.x;
//            _linesNode->drawSegment(Point(x, 0), Point(x, contentSize.height), 1, Color4F(lineColor));
//        }
//    }
//    // last line
//    _linesNode->drawSegment(Point(0, maxY), Point(contentSize.width, maxY), 1, Color4F(lineColor));


    // color blocks
    vector<PitchEvent *> onEvents;
    for (int i = 0; i < _midi->getTracks().size(); i++) {
        Vector<BaseEvent *> &events = _midi->getTracks()[i]->getEvents();
        for(int j = 0; j < events.size(); j++) {
            BaseEvent *baseEvent = events.at(j);
            if(baseEvent->getType() == kEventTypePitch) {
                PitchEvent *pitchEvent = static_cast<PitchEvent *>(baseEvent);
                if (pitchEvent->isOn()) {
                    onEvents.push_back(pitchEvent);
                } else {
                    for (auto iter = onEvents.begin(); iter != onEvents.end(); iter++) {
                        PitchEvent *onEvent = *iter;
                        const int pitch = pitchEvent->getPitch();
                        if (onEvent->getPitch() == pitch) {
                            const int y = tickToY(onEvent->getTick());
                            int length = tickToY(pitchEvent->getTick()) - y - 2;
                            if (length < 5) {
                                length = 5;
                            }

                            FallType fallType = _keyboardLayer->isWhiteKey(pitch) ? kFallTypeWhite : kFallTypeBlack;
                            FallColor fallColor = pitchEvent->getTrack() % 2 == 0 ? kFallColorRight : kFallColorLeft;

                            Node *sprite = nullptr;
                            if (mode == kWaterfallModeAdvanced) {
                                sprite = FlowerElementSprite::create(fallType, fallColor, length, onEvent->getFinger(), pitch);
                            } else {
                                if (builder != nullptr) {
                                    sprite = builder(fallType, fallColor, length, onEvent->getFinger(), pitch);
                                } else {
                                    sprite = FallElementSprite::create(fallType, fallColor, length, onEvent->getFinger(), pitch);
                                }
                            }

                            Rect rect = _keyboardLayer->getKeyRect(pitch);
                            sprite->setAnchorPoint(Point::ANCHOR_MIDDLE_BOTTOM);
                            sprite->setPosition(rect.origin.x + rect.size.width / 2, y);
                            _scrollView->addChild(sprite);
                            _elements.pushBack(sprite);

                            onEvents.erase(iter);
                            break;
                        }
                    }
                }
            }
        }
    }

    // 非单轨的曲子需要再排一次序，用于之后对轮廓线的控制
    std::stable_sort(_elements.begin(), _elements.end(), [](Node *lhs, Node *rhs) -> bool {
        return lhs->getPositionY() < rhs->getPositionY();
    });

    if (game_debug) {
        Label *label = Label::createWithSystemFont("", "", 30);
        addChild(label);
        label->setAnchorPoint(Point::ANCHOR_BOTTOM_RIGHT);
        label->setPosition(Point(winSize.width-10, 100));
        char str[64] = {0};
        sprintf(str, "tempo=%d, tpq=%d", (int)midi->getFirstTempo(), midi->getTicksPerQuauter());
        label->setString(str);
    }

    return true;
}

WaterfallLayer* WaterfallLayer::create(Wanaka::Midi *midi, MiniKeyboard *keyboard, FallElementSpriteBuilder builder, WaterfallMode mode) {
    WaterfallLayer *layer = new WaterfallLayer();
    if (layer != nullptr && layer->init(midi, keyboard, builder, mode)) {
        layer->autorelease();
        return layer;
    } else {
        CC_SAFE_DELETE(layer);
        return nullptr;
    }
}

void WaterfallLayer::setMode(WaterfallMode mode) {
    // TODO: 此方法可能没有用啦，可以考虑删除
    if (_mode != mode) {
        _mode = mode;
        if (_linesNode != nullptr) {
            _linesNode->setVisible(mode == kWaterfallModeStudy);
        }
    }
}

void WaterfallLayer::layoutSubNodes() {
    if (_mode == kWaterfallModeAdvanced) {
        if (_baselineSprite != nullptr) {
            _baselineSprite->removeFromParentAndCleanup(true);
        }
        _baselineSprite = Sprite::create("baseline.png");
        _baselineSprite->setAnchorPoint(Point::ANCHOR_BOTTOM_LEFT);
        _baselineSprite->setPosition(Point::ZERO);
        _baselineSprite->setScaleX(getContentSize().width/_baselineSprite->getContentSize().width);
        _baselineSprite->setOpacity(0x40);
        addChild(_baselineSprite);
        auto sequence = Sequence::createWithTwoActions(FadeTo::create(0.5, 0x80), FadeTo::create(0.5, 0x40));
        _baselineSprite->runAction(RepeatForever::create(sequence));

        if (_hitBaselineSprite != nullptr) {
            _hitBaselineSprite->removeFromParentAndCleanup(true);
        }
        _hitBaselineSprite = Sprite::create("baseline.png");
        _hitBaselineSprite->setAnchorPoint(Point::ANCHOR_BOTTOM_LEFT);
        _hitBaselineSprite->setPosition(Point::ZERO);
        _hitBaselineSprite->setOpacity(0x00);
        addChild(_hitBaselineSprite);

        for (int i = _keyboardLayer->getStartPitch(); i <= _keyboardLayer->getEndPitch(); i++) {
            Rect rect = _keyboardLayer->getKeyRect(i);
            Point position = Point(rect.getMidX(), 0);

            Sprite *outline = Sprite::create("flower_outline.png");
            outline->setAnchorPoint(Point::ANCHOR_MIDDLE_BOTTOM);
            outline->setPosition(position);
            outline->setOpacity(0);
            _outlineSprites.insert(i, outline);
            addChild(outline);

            Sprite *bang = Sprite::create("flower_bang_light.png");
            bang->setAnchorPoint(Point::ANCHOR_MIDDLE_BOTTOM);
            bang->setPosition(position);
            bang->setOpacity(0);
            _bangSprites.insert(i, bang);
            addChild(bang, 1);
        }
    }
}

WaterfallLayer::WaterfallMode WaterfallLayer::getMode() const {
    return _mode;
}

const Wanaka::Midi *WaterfallLayer::getMidi() {
    return _midi;
}

void WaterfallLayer::setHidden(bool hidden) {
    setVisible(!hidden);
    _scrollView->setTouchEnabled(isVisible());
}

bool WaterfallLayer::isHidden() {
    return !isVisible();
}

void WaterfallLayer::scrollTo(int tick) {
    Point offset = Point(0, -tickToY(tick));
    if (_scrollView->getContentOffset().y != offset.y) {
        _scrollView->setContentOffset(offset);

        // update flower outline
        // TODO: 放到FollowGameEngine::onWaterfallDidScroll里面一个循环搞定？
        if (_mode == kWaterfallModeAdvanced) {
            const float regionBottomY = -offset.y;
            const float regionHeight = _outlineSprites.at(64)->getContentSize().height * 3; // 3个小花的高度
            const float regionTopY = regionBottomY + regionHeight;

            // LOGIC: 从前往后遍历每个小花，找到已经显示出来的小花对应的outline，再修改其alpha值
            for (int i = 0; i < _elements.size(); i++) {
                FallElementSprite *sprite = dynamic_cast<FallElementSprite *>(_elements.at(i));
                if (sprite != nullptr) {
                    const float positionY = sprite->getPositionY();
                    if (positionY > regionTopY) {
                        break;
                    } else if (positionY >= regionBottomY) {
                        const int pitch = sprite->getPitch();
                        const GLbyte opacity = 0xFF * ((regionTopY - positionY)/ regionHeight);
                        auto iter = _processedElements.find(pitch);
                        if (iter != _processedElements.end()) {
                            // 有相同pitch的node
                            if (iter->second == sprite) {
                                _outlineSprites.at(pitch)->setOpacity(opacity);
                            }
                        } else {
                            _processedElements.insert(pitch, sprite);
                            _outlineSprites.at(pitch)->setOpacity(opacity);
                        }
                    }
                }
            }

            auto iter = _processedElements.begin();
            while (iter != _processedElements.end()) {
                if (iter->second->getPositionY() < regionBottomY) {
                    _outlineSprites.at(iter->first)->setOpacity(0);
                    iter = _processedElements.erase(iter);
                } else {
                    iter++;
                }
            }
        }

        if (_scrollCallback != nullptr) {
            _scrollCallback();
        }
    }
}

Vector<Node *> &WaterfallLayer::getFallElements() {
    return _elements;
}

void WaterfallLayer::setScrollCallback(const WaterfallScrollCallback &cb) {
    _scrollCallback = cb;
}

Point WaterfallLayer::getScrollOffset() {
    return _scrollView->getContentOffset();
}

unsigned int WaterfallLayer::getNoteCount() const {
    return (unsigned int)_elements.size();
}

void WaterfallLayer::setTouchScrollEnabled(bool enabled) {
    _scrollView->setTouchEnabled(enabled);
}

void WaterfallLayer::setScollViewContent(Size size, int navigationHeight) {
    this->setContentSize(size);
    _scrollView->setViewSize(Size(size.width, size.height - navigationHeight));
    _scrollView->setPosition(Point::ZERO);
    if (_background != nullptr) {
        _background->setTextureRect(Rect(0, 0, size.width, size.height - navigationHeight));
    }
}

void WaterfallLayer::reset() {
    for (auto element : _elements) {
        auto fallElement = dynamic_cast<FlowerElementSprite *>(element);
        fallElement->reset();
    }
    _processedElements.clear();
}

void WaterfallLayer::setBackgroundVisiable(bool visible) {
    if (_background != nullptr) {
        _background->setVisible(visible);
    }
}

void WaterfallLayer::setOutLineSpritesVisible(bool visible) {
    for (auto iter :_outlineSprites) {
        if (visible) {
            iter.second->setVisible(true);
            iter.second->setOpacity(0);
        } else {
            iter.second->setVisible(false);
        }
    }
}

void WaterfallLayer::setFingerVisible(bool visible) {
    for (auto element: _elements) {
        auto fallElementSprite = static_cast<FallElementSprite *>(element);
        fallElementSprite->setFingerVisible(visible);
    }
}

void WaterfallLayer::hitPitch(int pitch) {
    if (_mode == kWaterfallModeAdvanced) {
        if (_hitBaselineSprite != nullptr) {
            Sequence *sequence = Sequence::createWithTwoActions(FadeTo::create(0.1f, 0x80), FadeTo::create(0.1f, 0x00));
            _hitBaselineSprite->runAction(sequence);
        }
        Sprite *bang = _bangSprites.at(pitch);
        if (bang != nullptr) {
            bang->runAction(Sequence::createWithTwoActions(FadeIn::create(0.2f), FadeOut::create(0.3f)));
        }
    }
}

void WaterfallLayer::hideElementsByFallColor(FallColor color) {
    for (auto element : _elements){
        auto fallElementSprite = static_cast<FallElementSprite *>(element);
        if (fallElementSprite->getFallColor() == color) {
            fallElementSprite->setVisible(false);
        } else {
            fallElementSprite->setVisible(true);
        }
    }
}
