#pragma once

#include "CanvasSizeJourney.h"
#include <QAbstractButton>
#include <QAccessible>
#include <QJsonObject>

namespace layersearchjourney {
inline int run(QApplication &) {
    using canvassizejourney::require;
    using canvassizejourney::pump;
    using canvassizejourney::click;
    using canvassizejourney::key;
    try {
        SessionWindow window;
        window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window);
        const auto command = [&](QJsonObject value) {
            require(window.sendCommand(value), "layer search fixture command failed");
            QApplication::processEvents();
        };
        command({{"action", "new"}, {"width", 64}, {"height", 48}, {"emptyLayer", true}});
        command({{"action", "renameLayer"}, {"name", "Portrait"}});
        for (const auto &name : {QString("Sky"), QString("Sky foreground")}) {
            command({{"action", "addLayer"}});
            command({{"action", "renameLayer"}, {"name", name}});
        }
        const auto original = window.sessionState();
        const auto rows = [&] {
            QStringList names;
            QPointer<QWidget> table;
            for (auto *widget : window.findChildren<QWidget *>()) {
                if (!widget->isVisible() || !widget->property("appKitView").toBool()
                    || !widget->property("appKitNode").toString().startsWith("LayersPanel|")) continue;
                table=widget; break;
            }
            // Reading accessibility refreshes the table's proxy children. Finish the widget search first so
            // no snapshot of those children is traversed after the refresh replaces them.
            auto *list=table ? QAccessible::queryAccessibleInterface(table) : nullptr;
            if (list) for (int i=0; i<list->childCount(); ++i) {
                auto *child=list->child(i);
                if (child && child->role()==QAccessible::ListItem) names.append(child->text(QAccessible::Name));
            }
            return names;
        };
        const auto search = [&]() -> QLineEdit * {
            for (auto *field : window.findChildren<QLineEdit *>())
                if (field->isVisible() && field->placeholderText()=="Search Layers") return field;
            return nullptr;
        };
        const auto button = [&](const QString &name) -> QAbstractButton * {
            for (auto *candidate : window.findChildren<QAbstractButton *>())
                if (candidate->isVisible() && (candidate->objectName()==name || candidate->accessibleName()==name)) return candidate;
            return nullptr;
        };
        pump([&] { return rows().size()==3 && button("layerSearchButton"); }, "layer search header/table missing");
        click(button("layerSearchButton"));
        pump([&] { return search()!=nullptr; }, "layer search field did not appear");
        pump([&] { return search() && search()->hasFocus(); }, "layer search did not automatically take keyboard focus");
        qInfo("Qt layer search field style (frame=%d pixels=%d points=%.2f)", search()->hasFrame(), search()->font().pixelSize(), search()->font().pointSizeF());
        require(!search()->hasFrame(), "layer search field regained a native frame");
        require(search()->font().pixelSize()==13, "layer search field lost its 13-point font");
        for (const QChar character : QString("sKy")) {
            require(search(), "layer search field retired while typing");
            key(search(), 0, Qt::NoModifier, QString(character));
        }
        pump([&] { return rows().size()==2; }, "case-insensitive layer search did not filter native rows");
        require(search() && search()->text()=="sKy" && search()->hasFocus(), "layer search lost text or focus");
        key(search(), Qt::Key_Escape);
        pump([&] { return search() && search()->text().isEmpty() && rows().size()==3; }, "first Escape did not clear layer search");
        key(search(), Qt::Key_Escape);
        pump([&] { return search()==nullptr; }, "second Escape did not close layer search");
        click(button("Filter the layer list"));
        const auto toggle = [&](const QString &name) -> QCheckBox * {
            for (auto *widget : QApplication::allWidgets())
                if (auto *box=qobject_cast<QCheckBox *>(widget); box && box->isVisible() && box->objectName()==name) return box;
            return nullptr;
        };
        pump([&] { return toggle("layerFilterSelected")!=nullptr; }, "layer type filter popover missing");
        for (const auto &name : {"All", "Image", "Shape", "Text", "Folder", "Adjustment", "Selected"}) {
            auto *box=toggle(QString("layerFilter")+name);
            require(box && !box->icon().isNull() && !box->text().isEmpty(), "layer type toggle label/icon missing");
        }
        click(toggle("layerFilterSelected"));
        pump([&] { return rows().size()==1; }, "Selected filter did not narrow native rows");
        click(toggle("layerFilterAll"));
        pump([&] { return rows().size()==3; }, "All Layers did not restore native rows");
        const auto after=window.sessionState();
        for (const auto &name : {"layers", "activeLayerID", "undoName", "redoName", "modified"})
            require(after.value(name)==original.value(name), "layer search/filter changed the document or history");
        qInfo("Qt layer search OK (native typing/focus, case-insensitive rows, two Escape actions, symbol toggles, Selected/All and history isolation)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt layer search failed: %s", error.what()); return 1;
    }
}
}
