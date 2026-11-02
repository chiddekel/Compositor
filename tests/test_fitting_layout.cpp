#include "SwiftUIFittingWidget.h"
#include <QApplication>
#include <QMainWindow>
#include <QToolBar>
#include <QVBoxLayout>
#include <QDebug>
#include <stdexcept>

namespace {
class Content final : public QWidget {
    QSize m_hint;
public:
    Content(QSize hint, int fixedWidth) : m_hint(hint) { setFixedWidth(fixedWidth); }
    QSize sizeHint() const override { return m_hint; }
};
class ResizeProbe final : public QWidget {
public:
    QList<QSize> changes;
protected:
    void resizeEvent(QResizeEvent *event) override { changes.append(event->size()); QWidget::resizeEvent(event); }
};
void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void settle(QApplication &app) { for (int index = 0; index < 30; ++index) app.processEvents(); }
}

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        QMainWindow window;
        auto *canvas = new ResizeProbe;
        window.setCentralWidget(canvas);
        window.resize(1200, 1100);
        auto *rail = new QToolBar;
        rail->setOrientation(Qt::Vertical);
        window.addToolBar(Qt::LeftToolBarArea, rail);
        auto *container = new QWidget;
        auto *layout = new QVBoxLayout(container);
        layout->setContentsMargins(0, 0, 0, 0);
        // As with a native scroll view, a content hint can be narrower than the explicit frame.
        auto *one = new Content(QSize(36, 754), 56);
        auto *two = new Content(QSize(80, 432), 92);
        auto *fits = new SwiftUIFittingWidget({one, two}, false, true);
        layout->addWidget(fits);
        rail->addWidget(container);
        window.show(); settle(app);
        require(one->isVisible() && !two->isVisible(), "tall layout did not choose the first fitting alternative");
        require(fits->sizeHint().width() == 56, "first alternative lost its explicit width");
        const auto replace = [&](int expectedWidth) {
            auto *nextOne = new Content(QSize(36, 754), 56);
            auto *nextTwo = new Content(QSize(80, 432), 92);
            auto *replacement = new SwiftUIFittingWidget(
                {nextOne, nextTwo}, false, true, fits->size());
            require(replacement->sizeHint().width() == expectedWidth, "replacement negotiated the wrong initial column width");
            canvas->changes.clear();
            delete layout->replaceWidget(fits, replacement);
            delete fits;
            fits = replacement;
            one = nextOne; two = nextTwo;
            fits->show(); settle(app);
            require(canvas->changes.isEmpty(), "replacing a fitting layout transiently resized the canvas");
        };
        replace(56);
        window.resize(1200, 600); settle(app);
        require(!one->isVisible() && two->isVisible(), "short layout did not choose the fallback");
        require(fits->sizeHint().width() == 92 && fits->width() >= 92 && rail->width() >= 92,
                "fallback frame was clipped by an undersized hint");
        replace(92);
        window.resize(1200, 1100); settle(app);
        require(one->isVisible() && !two->isVisible(), "growing the window did not restore the first alternative");
        require(rail->width() < 92, "restoring the first alternative did not shrink the toolbar");
        qInfo("ViewThatFits Qt layout OK (first fit, explicit frames, fallback width and resize restoration)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("ViewThatFits Qt layout failed: %s", error.what());
        return 1;
    }
}
