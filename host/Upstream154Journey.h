#pragma once
#include "SessionWindow.h"
#include <QAbstractButton>
#include <QApplication>
#include <QComboBox>
#include <QDialog>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QLineEdit>
#include <QMouseEvent>
#include <QPointingDevice>
#include <QTabletEvent>
#include <QPlainTextEdit>
#include <QPdfWriter>
#include <QPainter>
#include <QTemporaryDir>
#include <QThread>
#include <stdexcept>

extern "C" int64_t compositor_session_render(uint64_t, uint8_t *, size_t);

namespace upstream154journey {
inline void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
inline void settle(const std::function<bool()> &ready, const char *message) {
    QElapsedTimer timer; timer.start();
    while (!ready() && timer.elapsed() < 5000) { QApplication::processEvents(QEventLoop::AllEvents, 10); QThread::msleep(1); }
    require(ready(), message);
}
inline QByteArray pixels(SessionWindow &window) {
    const auto count = compositor_session_render(window.sessionHandle(), nullptr, 0);
    require(count > 0, "1.5.4: no document pixels");
    QByteArray result(qsizetype(count), Qt::Uninitialized);
    require(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(result.data()), result.size()) == count,
            "1.5.4: pixel read failed");
    return result;
}
inline void mouse(QWidget *widget, QEvent::Type type, QPointF point, Qt::MouseButton button, Qt::MouseButtons buttons) {
    QMouseEvent event(type, point, widget->mapToGlobal(point.toPoint()), button, buttons, Qt::NoModifier);
    QApplication::sendEvent(widget, &event); QApplication::processEvents();
}
inline void key(QWidget *widget, int code, const QString &text = {}) {
    require(widget, "1.5.4: key target missing");
    QKeyEvent event(QEvent::KeyPress, code, Qt::NoModifier, text);
    QApplication::sendEvent(widget, &event); QApplication::processEvents();
}
inline int run(QApplication &) {
    try {
        SessionWindow window;
        window.resize(1400, 900); window.show(); window.activateWindow(); QApplication::processEvents();
        window.createNewDocument(400, 200);
        require(window.sendCommand({{"action", "addLayer"}}), "1.5.4: no paint layer");
        const QJsonObject brush{{"diameter", 40}, {"hardness", 1}, {"opacity", 1}, {"red", 1}, {"green", 0}, {"blue", 0}};
        require(window.sendCommand({{"action", "setBrushSettings"}, {"parameters", brush}}), "1.5.4: brush setup failed");
        window.setTool(SessionWindow::Tool::Brush);
        auto *canvas = window.findChild<QWidget *>(QStringLiteral("editorCanvas"));
        require(canvas, "1.5.4: canvas missing");
        const auto button = [&](const QString &name) -> QAbstractButton * {
            for (auto *candidate : window.findChildren<QAbstractButton *>())
                if (candidate->isVisible() && candidate->accessibleName() == name) return candidate;
            return nullptr;
        };
        require(!button(QStringLiteral("Pressure for size")), "1.5.4: pressure shown before using a pen");
        static QPointingDevice pen(QStringLiteral("1.5.4 test pen"), 7154, QInputDevice::DeviceType::Stylus,
            QPointingDevice::PointerType::Pen, QInputDevice::Capability::Position | QInputDevice::Capability::Pressure, 1, 2);
        const auto tablet = [&](QEvent::Type type, QPointF document, qreal pressure) {
            const QPointF local = window.documentToCanvasPoint(document);
            const bool held = type == QEvent::TabletPress || type == QEvent::TabletMove;
            QTabletEvent event(type, &pen, local, canvas->mapToGlobal(local.toPoint()), pressure, 0, 0, 0, 0, 0,
                               Qt::NoModifier, type == QEvent::TabletMove ? Qt::NoButton : Qt::LeftButton,
                               held ? Qt::LeftButton : Qt::NoButton);
            QApplication::sendEvent(canvas, &event); QApplication::processEvents();
            require(event.isAccepted(), "1.5.4: canvas refused a tablet sample");
        };
        tablet(QEvent::TabletPress, QPointF(50, 100), 0.5);
        tablet(QEvent::TabletRelease, QPointF(50, 100), 0);
        settle([&] { return button(QStringLiteral("Pressure for size")) && button(QStringLiteral("Pressure for opacity")); },
               "1.5.4: pressure controls did not appear after pen use");
        require(window.sendCommand({{"action", "undo"}}), "1.5.4: first pen undo failed");
        const QByteArray baseline = pixels(window);
        for (const QString &name : {QStringLiteral("Pressure for size"), QStringLiteral("Pressure for opacity")}) {
            auto *control = button(name);
            require(control, "1.5.4: pressure control missing");
            const QPointF center = control->rect().center();
            mouse(control, QEvent::MouseButtonPress, center, Qt::LeftButton, Qt::LeftButton);
            control = button(name);
            require(control, "1.5.4: pressure control disappeared during click");
            mouse(control, QEvent::MouseButtonRelease, control->rect().center(), Qt::LeftButton, Qt::NoButton);
        }
        tablet(QEvent::TabletPress, QPointF(60, 100), 1);
        for (int step = 1; step <= 24; ++step)
            tablet(QEvent::TabletMove, QPointF(60 + step * 10, 100), 1 - 0.75 * step / 24);
        tablet(QEvent::TabletRelease, QPointF(300, 100), 0);
        const QByteArray painted = pixels(window);
        require(painted.size() == 400 * 200 * 4 && painted != baseline, "1.5.4: tablet painted no pixels");
        const auto thickness = [&](int x) {
            int count = 0;
            for (int y = 0; y < 200; ++y) if (painted.mid((y * 400 + x) * 4, 4) != baseline.mid((y * 400 + x) * 4, 4)) ++count;
            return count;
        };
        require(thickness(70) > thickness(290) * 2, "1.5.4: native pen stroke did not taper");
        require(window.sessionState().value("brushDiameter").toDouble() == 40, "1.5.4: tablet rewrote the configured diameter");
        require(window.sendCommand({{"action", "undo"}}) && pixels(window) == baseline, "1.5.4: tablet Undo did not restore pixels");
        require(window.sendCommand({{"action", "redo"}}) && pixels(window) == painted, "1.5.4: tablet Redo did not restore pixels");
        qInfo("Qt 1.5.4 pen pressure OK (native controls, raw samples, taper, settings isolation, Undo/Redo)");

        window.createNewDocument(400, 200);
        window.setTool(SessionWindow::Tool::Type);
        const auto start = window.documentToCanvasPoint(QPointF(50, 50)), end = window.documentToCanvasPoint(QPointF(350, 140));
        mouse(canvas, QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton);
        mouse(canvas, QEvent::MouseMove, end, Qt::NoButton, Qt::LeftButton);
        mouse(canvas, QEvent::MouseButtonRelease, end, Qt::LeftButton, Qt::NoButton);
        settle([&] {
            auto *text = window.findChild<QPlainTextEdit *>(QStringLiteral("canvas.textEditor"));
            return text && text->isVisible();
        }, "1.5.4: inline text editor did not appear after the native drag");
        auto *editor = window.findChild<QPlainTextEdit *>(QStringLiteral("canvas.textEditor"));
        require(editor && editor->isVisible(), "1.5.4: inline text editor missing");
        editor->setPlainText(QStringLiteral("Font preview")); editor->selectAll(); QApplication::processEvents();
        const auto fontName = [&] { return window.sessionState().value("textDraft").toObject().value("fontName").toString(); };
        const QString original = fontName();
        const auto popup = [&]() -> QDialog * {
            for (auto *dialog : window.findChildren<QDialog *>())
                if (dialog->isVisible() && dialog->objectName().startsWith(QLatin1String("floatingPanel.NativeWindow:"))) return dialog;
            return nullptr;
        };
        const auto search = [&]() -> QLineEdit * {
            if (auto *dialog = popup()) for (auto *field : dialog->findChildren<QLineEdit *>())
                if (field->isVisible() && field->placeholderText() == QLatin1String("Search Fonts")) return field;
            return nullptr;
        };
        const auto faces = [&]() -> QWidget * {
            if (auto *dialog = popup()) for (auto *view : dialog->findChildren<QWidget *>())
                if (view->isVisible() && view->property("appKitView").toBool()) return view;
            return nullptr;
        };
        const auto open = [&] {
            QComboBox *font = nullptr;
            for (auto *combo : window.findChildren<QComboBox *>())
                if (combo->isVisible() && combo->accessibleName() == QLatin1String("Font")) font = combo;
            require(font, "1.5.4: font pop-up control missing");
            font->showPopup();
            settle([&] { return search() != nullptr; }, "1.5.4: searchable font panel did not open");
        };
        const auto query = [&] {
            for (const QChar character : QStringLiteral("DejaVu bold")) {
                auto *field = search(); require(field, "1.5.4: search field lost while typing");
                field->setFocus(); key(field, 0, QString(character));
            }
        };
        open(); query();
        require(faces(), "1.5.4: native font rows missing");
        qInfo("Qt font panel geometry: panel %dx%d, rows %dx%d", popup()->width(), popup()->height(), faces()->width(), faces()->height());
        require(faces()->width() >= popup()->width() - 32, "1.5.4: font rows shrank after search refreshes");
        require(faces()->height() >= popup()->height() - 47, "1.5.4: font viewport did not grow with its panel");
        require(popup()->grab().save(QStringLiteral("/tmp/compositor-upstream154-font-panel.png")), "1.5.4: font panel capture failed");
        mouse(faces(), QEvent::MouseMove, QPointF(50, 12), Qt::NoButton, Qt::NoButton);
        settle([&] { return fontName().contains(QLatin1String("bold"), Qt::CaseInsensitive); }, "1.5.4: font hover did not preview");
        key(search(), Qt::Key_Down);
        settle([&] { return fontName().contains(QLatin1String("bold"), Qt::CaseInsensitive); }, "1.5.4: font highlight did not preview");
        require(popup()->grab().save(QStringLiteral("/tmp/compositor-upstream154-font-panel.png")), "1.5.4: font panel capture failed");
        key(search(), Qt::Key_Escape);
        settle([&] { return search() && search()->text().isEmpty(); }, "1.5.4: first Escape did not clear search");
        key(search(), Qt::Key_Escape);
        settle([&] { return !popup() && fontName() == original; }, "1.5.4: second Escape did not revert font preview");
        QThread::msleep(300);
        open(); query(); key(search(), Qt::Key_Return, QStringLiteral("\r"));
        settle([&] { return !popup() && fontName().contains(QLatin1String("bold"), Qt::CaseInsensitive); }, "1.5.4: Return did not keep the selected font");
        QThread::msleep(300);
        open(); query();
        require(faces(), "1.5.4: rows missing before pointer choice");
        mouse(faces(), QEvent::MouseButtonPress, QPointF(50, 12), Qt::LeftButton, Qt::LeftButton);
        settle([&] { return !popup() && fontName().contains(QLatin1String("bold"), Qt::CaseInsensitive); }, "1.5.4: pointer choice did not keep its font");
        const QString clicked = fontName();
        QThread::msleep(300);
        open(); query(); key(search(), Qt::Key_Down);
        popup()->hide();
        settle([&] { return !popup() && fontName() == clicked; }, "1.5.4: popup hide did not cancel its preview");
        window.grab().save(QStringLiteral("/tmp/compositor-upstream154-ui.png"));
        qInfo("Qt 1.5.4 font panel OK (search, hover preview, pointer choice, arrow keys, Escape twice, Return, hide cancellation)");

        require(window.sendCommand({{"action", "textFinish"}}), "1.5.4: text editing did not finish before PDF import");

        QTemporaryDir files;
        require(files.isValid(), "1.5.4: PDF test directory unavailable");
        const QString pdfPath = files.filePath(QStringLiteral("native-pages.pdf"));
        {
            // Qt writes the fixture independently of Compositor's PDF compatibility writer.
            QPdfWriter pdf(pdfPath);
            pdf.setResolution(72);
            pdf.setPageSize(QPageSize(QSizeF(48, 24), QPageSize::Point));
            pdf.setPageMargins(QMarginsF(0, 0, 0, 0), QPageLayout::Point);
            QPainter painter(&pdf);
            require(painter.isActive(), "1.5.4: native PDF writer failed");
            painter.fillRect(QRect(0, 0, 48, 24), Qt::red);
            require(pdf.newPage(), "1.5.4: second PDF page failed");
            painter.fillRect(QRect(0, 0, 48, 24), Qt::blue);
        }
        require(window.importWithUpstream({pdfPath}, true), "1.5.4: native PDF import failed");
        require(window.sessionState().value("layers").toArray().size() == 2, "1.5.4: PDF pages were not kept as separate layers");
        const QByteArray imported = pixels(window);
        require(imported.size() == 200 * 100 * 4, "1.5.4: PDF did not import at 300 DPI");
        const QString project = files.filePath(QStringLiteral("pdf-roundtrip.comp"));
        require(window.writeProjectPackage(project), "1.5.4: PDF project save failed");
        window.createNewDocument(32, 24);
        require(window.readProjectPackage(project), "1.5.4: PDF project reopen failed");
        require(pixels(window) == imported, "1.5.4: PDF project roundtrip changed pixels");
        qInfo("Qt 1.5.4 PDF import OK (independent native PDF, multiple pages, 300 DPI, project save/reopen)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt 1.5.4 acceptance failed: %s", error.what());
        return 1;
    }
}
}
