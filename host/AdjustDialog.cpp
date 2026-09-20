#include "EditorDialogs.h"

#include <QCheckBox>
#include <QColor>
#include <QColorDialog>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QPushButton>
#include <QTableWidget>
#include <QTimer>
#include <QVBoxLayout>
#include <memory>
#include <vector>

// The Swift LayerAdjustment model decodes hue/saturation/lightness/colorize,
// levels, and curves unconditionally (synthesized Codable, non-optional fields);
// the per-kind settings objects that follow are optional and only sent when set.
static QJsonObject levelRange(double black, double gamma, double white,
                              double outputBlack, double outputWhite) {
    return {{"black", black}, {"gamma", gamma}, {"white", white},
            {"outputBlack", outputBlack}, {"outputWhite", outputWhite}};
}

static QJsonArray levelRangesIdentity() {
    QJsonArray ranges;
    for (int i = 0; i < 4; ++i) ranges.append(levelRange(0, 1, 255, 0, 255));
    return ranges;
}

static QJsonArray curvePointsIdentity() {
    QJsonArray points;
    points.append(QJsonObject{{"x", 0}, {"y", 0}});
    points.append(QJsonObject{{"x", 255}, {"y", 255}});
    return points;
}

static QJsonArray curveChannelsIdentity() {
    QJsonArray channels;
    for (int i = 0; i < 4; ++i) channels.append(curvePointsIdentity());
    return channels;
}

static QString hueBandKey(int index) {
    static const QStringList keys = {"Master", "Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"};
    return keys[index];
}

static QJsonObject hueBandDefault(int index) {
    // Photoshop's starting hue bands for the seven ColorRange presets.
    static const QList<QList<double>> bands = {
        {0, 0, 360, 360}, {315, 345, 15, 45}, {15, 45, 75, 105}, {75, 105, 135, 165},
        {135, 165, 195, 225}, {195, 225, 255, 285}, {255, 285, 315, 345}};
    const QList<double> &b = bands[index];
    return {{"falloffStart", b[0]}, {"rangeStart", b[1]}, {"rangeEnd", b[2]}, {"falloffEnd", b[3]}};
}

AdjustDialog::AdjustDialog(const QString &kind, Submit submit, QWidget *parent) : QDialog(parent) {
    setObjectName("adjustDialog"); setWindowTitle(kind);
    auto *layout = new QVBoxLayout(this);
    auto *form = new QFormLayout;
    layout->addLayout(form);

    auto adjustment = std::make_shared<QJsonObject>();
    adjustment->insert("kind", kind);

    // Required non-optional LayerAdjustment fields (identity by default).
    adjustment->insert("hue", 0); adjustment->insert("saturation", 0);
    adjustment->insert("lightness", 0); adjustment->insert("colorize", false);
    adjustment->insert("levels", QJsonObject{{"channel", "RGB"}, {"ranges", levelRangesIdentity()}});

    auto *debounce = new QTimer(this);
    debounce->setSingleShot(true); debounce->setInterval(120);
    auto changed = [=] {
        QJsonObject command{{"action", "adjustmentPreview"}, {"adjustment", *adjustment}};
        const bool ok = submit(command);
        if (ok) setProperty("previewFailed", false);
        return ok;
    };
    auto *preview = new QCheckBox(tr("Preview"), this);
    preview->setObjectName("preview"); preview->setChecked(true); layout->addWidget(preview);
    auto *error = new QLabel(this); error->setWordWrap(true); layout->addWidget(error);
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, this);
    layout->addWidget(buttons);

    if (kind == "Levels") {
        auto *channel = new QComboBox(this);
        channel->setObjectName("channel"); channel->setAccessibleName("Channel");
        channel->addItems({"RGB", "Red", "Green", "Blue"});
        form->addRow(tr("&Channel"), channel);
        const QStringList names = {"Black", "Gamma", "White", "Output Black", "Output White"};
        const double defaults[5] = {0, 1, 255, 0, 255};
        auto ranges = std::make_shared<QJsonArray>(levelRangesIdentity());
        auto *fields = new QDoubleSpinBox *[5];
        for (int i = 0; i < 5; ++i) {
            fields[i] = new QDoubleSpinBox(this);
            QString name = names[i];
            fields[i]->setObjectName(name.replace(' ', "")); fields[i]->setAccessibleName(names[i]);
            fields[i]->setRange(i == 1 ? 0.01 : -255, i == 1 ? 9.99 : 255);
            fields[i]->setDecimals(i == 1 ? 2 : 0); fields[i]->setValue(defaults[i]);
            fields[i]->setKeyboardTracking(false);
            form->addRow(tr("&%1").arg(names[i]), fields[i]);
            connect(fields[i], qOverload<double>(&QDoubleSpinBox::valueChanged), this,
                    [=](double v) {
                        static const char *const keys[5] = {"black", "gamma", "white", "outputBlack", "outputWhite"};
                        QJsonObject range = ranges->at(channel->currentIndex()).toObject();
                        range.insert(keys[i], v);
                        ranges->replace(channel->currentIndex(), range);
                        adjustment->insert("levels", QJsonObject{{"channel", channel->currentText()}, {"ranges", *ranges}});
                        debounce->start();
                    });
        }
        connect(channel, qOverload<int>(&QComboBox::currentIndexChanged), this, [=](int index) {
            const QJsonObject range = ranges->at(index).toObject();
            fields[0]->setValue(range.value("black").toDouble());
            fields[1]->setValue(range.value("gamma").toDouble());
            fields[2]->setValue(range.value("white").toDouble());
            fields[3]->setValue(range.value("outputBlack").toDouble());
            fields[4]->setValue(range.value("outputWhite").toDouble());
        });
    }
    if (kind == "Hue/Saturation") {
        auto *range = new QComboBox(this);
        range->setObjectName("range"); range->setAccessibleName("Range");
        for (int i = 0; i < 7; ++i) range->addItem(hueBandKey(i));
        form->addRow(tr("&Range"), range);
        auto *hue = new QDoubleSpinBox(this), *sat = new QDoubleSpinBox(this), *light = new QDoubleSpinBox(this);
        auto addHsv = [=](QDoubleSpinBox *box, const QString &label, double min, double max) {
            box->setObjectName(label); box->setAccessibleName(label);
            box->setRange(min, max); box->setDecimals(0); box->setKeyboardTracking(false);
            form->addRow(tr("&%1").arg(label), box);
        };
        addHsv(hue, "Hue", -180, 180); addHsv(sat, "Saturation", -100, 100); addHsv(light, "Lightness", -100, 100);
        auto *colorize = new QCheckBox(tr("Colorize"), this), *invert = new QCheckBox(tr("Invert range"), this);
        layout->addWidget(colorize); layout->addWidget(invert);
        auto build = [=] {
            // Swift dicts keyed by enums encode as arrays of alternating key/value.
            QJsonArray adjustments;
            QJsonObject master{{"hue", hue->value()}, {"saturation", sat->value()}, {"lightness", light->value()}};
            adjustments.append("Master"); adjustments.append(master);
            if (range->currentIndex() != 0) {
                QJsonObject band = master;
                band.insert("hue", 0.0);
                adjustments.append(hueBandKey(range->currentIndex())); adjustments.append(band);
            }
            QJsonArray bands;
            for (int i = 0; i < 7; ++i) { bands.append(hueBandKey(i)); bands.append(hueBandDefault(i)); }
            adjustment->insert("hsvSettings", QJsonObject{
                {"range", range->currentText()}, {"colorize", colorize->isChecked()},
                {"invertRange", invert->isChecked()}, {"adjustments", adjustments}, {"bands", bands}});
        };
        auto connectAll = [=](auto *box) { connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [=](double) { build(); debounce->start(); }); };
        connectAll(hue); connectAll(sat); connectAll(light);
        connect(colorize, &QCheckBox::toggled, this, [=](bool) { build(); debounce->start(); });
        connect(invert, &QCheckBox::toggled, this, [=](bool) { build(); debounce->start(); });
        connect(range, qOverload<int>(&QComboBox::currentIndexChanged), this, [=](int) { build(); debounce->start(); });
        build();
    }
    if (kind == "Curves") {
        auto *channel = new QComboBox(this);
        channel->setObjectName("channel"); channel->setAccessibleName("Channel");
        channel->addItems({"RGB", "Red", "Green", "Blue"});
        form->addRow(tr("&Channel"), channel);
        auto *table = new QTableWidget(2, 2, this);
        table->setObjectName("points"); table->setAccessibleName("Points");
        table->setHorizontalHeaderLabels({tr("Input"), tr("Output")});
        table->setAcceptDrops(false);
        layout->addWidget(table);
        auto *rowButtons = new QHBoxLayout;
        auto *addBtn = new QPushButton(tr("Add"), this), *delBtn = new QPushButton(tr("Delete"), this),
             *resetBtn = new QPushButton(tr("Reset channel"), this);
        rowButtons->addWidget(addBtn); rowButtons->addWidget(delBtn); rowButtons->addWidget(resetBtn);
        layout->addLayout(rowButtons);
        auto channels = std::make_shared<QJsonArray>(curveChannelsIdentity());
        auto reload = [=](int index) {
            const QJsonArray points = channels->at(index).toArray();
            table->setRowCount(points.size());
            for (int i = 0; i < points.size(); ++i) {
                auto *x = new QDoubleSpinBox(table), *y = new QDoubleSpinBox(table);
                x->setRange(0, 255); y->setRange(0, 255); x->setDecimals(1); y->setDecimals(1); x->setKeyboardTracking(false); y->setKeyboardTracking(false);
                x->setValue(points.at(i).toObject().value("x").toDouble());
                y->setValue(points.at(i).toObject().value("y").toDouble());
                table->setCellWidget(i, 0, x); table->setCellWidget(i, 1, y);
            }
        };
        auto sync = [=] {
            QJsonArray points;
            for (int i = 0; i < table->rowCount(); ++i) {
                auto *x = qobject_cast<QDoubleSpinBox *>(table->cellWidget(i, 0));
                auto *y = qobject_cast<QDoubleSpinBox *>(table->cellWidget(i, 1));
                points.append(QJsonObject{{"x", x->value()}, {"y", y->value()}});
            }
            channels->replace(channel->currentIndex(), points);
            adjustment->insert("curves", QJsonObject{{"channel", channel->currentText()}, {"channels", *channels}});
            debounce->start();
        };
        reload(channel->currentIndex());
        auto anyChanged = [=] { for (int i = 0; i < table->rowCount(); ++i) {
            auto *x = qobject_cast<QDoubleSpinBox *>(table->cellWidget(i, 0));
            auto *y = qobject_cast<QDoubleSpinBox *>(table->cellWidget(i, 1));
            connect(x, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [=](double) { sync(); });
            connect(y, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [=](double) { sync(); });
        } };
        anyChanged();
        connect(channel, qOverload<int>(&QComboBox::currentIndexChanged), this, [=](int index) { reload(index); anyChanged(); });
        connect(addBtn, &QPushButton::clicked, this, [=] {
            int row = table->rowCount();
            table->setRowCount(row + 1);
            auto *x = new QDoubleSpinBox(table), *y = new QDoubleSpinBox(table);
            x->setRange(0, 255); y->setRange(0, 255); x->setDecimals(1); y->setDecimals(1); x->setKeyboardTracking(false); y->setKeyboardTracking(false);
            x->setValue(255); y->setValue(255);
            table->setCellWidget(row, 0, x); table->setCellWidget(row, 1, y);
            connect(x, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [=](double) { sync(); });
            connect(y, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [=](double) { sync(); });
            sync();
        });
        connect(delBtn, &QPushButton::clicked, this, [=] {
            if (table->rowCount() <= 2) return;
            table->removeRow(table->currentRow() < 0 ? table->rowCount() - 1 : table->currentRow());
            sync();
        });
        connect(resetBtn, &QPushButton::clicked, this, [=] { reload(channel->currentIndex()); sync(); });
    }
    if (kind == "Exposure") {
        auto *exposure = new QDoubleSpinBox(this), *offset = new QDoubleSpinBox(this), *gamma = new QDoubleSpinBox(this);
        auto addNum = [=](QDoubleSpinBox *box, const QString &label, double min, double max, double value, int decimals) {
            box->setObjectName(label); box->setAccessibleName(label);
            box->setRange(min, max); box->setDecimals(decimals); box->setValue(value); box->setKeyboardTracking(false);
            form->addRow(tr("&%1").arg(label), box);
            connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [=](double) {
                adjustment->insert("exposureSettings", QJsonObject{{"exposure", exposure->value()}, {"offset", offset->value()}, {"gamma", gamma->value()}});
                debounce->start();
            });
        };
        addNum(exposure, "Exposure", -20, 20, 0, 2);
        addNum(offset, "Offset", -0.5, 0.5, 0, 4);
        addNum(gamma, "Gamma", 0.01, 9.99, 1, 2);
    }
    if (kind == "Gradient Map") {
        auto *shadows = new QPushButton(this), *highlights = new QPushButton(this);
        auto *reversed = new QCheckBox(tr("Reversed"), this); layout->addWidget(reversed);
        QColor shadowColor(0, 0, 0), highlightColor(255, 255, 255);
        auto paint = [=](QPushButton *btn, const QColor &c) {
            btn->setStyleSheet(QString("background-color: %1; border: 1px solid #555555;").arg(c.name()));
            btn->setMinimumHeight(24);
        };
        paint(shadows, shadowColor); paint(highlights, highlightColor);
        form->addRow(tr("&Shadows"), shadows); form->addRow(tr("&Highlights"), highlights);
        auto emitSettings = [=] {
            auto colorJson = [](const QColor &c) -> QJsonObject {
                return {{"red", c.redF()}, {"green", c.greenF()}, {"blue", c.blueF()}};
            };
            adjustment->insert("gradientMapSettings", QJsonObject{
                {"shadows", colorJson(shadowColor)}, {"highlights", colorJson(highlightColor)},
                {"reversed", reversed->isChecked()}});
            debounce->start();
        };
        auto pick = [=](QPushButton *btn, QColor *target) {
            connect(btn, &QPushButton::clicked, this, [=] {
                const QColor chosen = QColorDialog::getColor(*target, this, btn->text());
                if (chosen.isValid()) { *target = chosen; paint(btn, chosen); emitSettings(); }
            });
        };
        pick(shadows, &shadowColor); pick(highlights, &highlightColor);
        connect(reversed, &QCheckBox::toggled, this, [=](bool) { emitSettings(); });
        emitSettings();
    }
    if (kind == "Grain") {
        auto *amount = new QDoubleSpinBox(this), *size = new QDoubleSpinBox(this), *roughness = new QDoubleSpinBox(this);
        auto addNum = [=](QDoubleSpinBox *box, const QString &label, double min, double max, double value, int decimals) {
            box->setObjectName(label); box->setAccessibleName(label);
            box->setRange(min, max); box->setDecimals(decimals); box->setValue(value); box->setKeyboardTracking(false);
            form->addRow(tr("&%1").arg(label), box);
            connect(box, qOverload<double>(&QDoubleSpinBox::valueChanged), this, [=](double) {
                adjustment->insert("grainSettings", QJsonObject{{"amount", amount->value()}, {"size", size->value()}, {"roughness", roughness->value()}, {"seed", 0}});
                debounce->start();
            });
        };
        addNum(amount, "Amount", 0, 100, 25, 0);
        addNum(size, "Size (px)", 0.5, 20, 2, 1);
        addNum(roughness, "Roughness", 0, 100, 50, 0);
    }

    auto update = [=] {
        const bool ok = submit({{"action", "adjustmentPreview"}, {"adjustment", *adjustment}});
        error->setText(ok ? QString() : tr("Preview failed. Adjust the settings or cancel."));
        buttons->button(QDialogButtonBox::Ok)->setEnabled(ok);
        return ok;
    };
    connect(debounce, &QTimer::timeout, this, [=] { update(); });
    connect(preview, &QCheckBox::toggled, this, [=](bool enabled) {
        if (enabled) debounce->start(); else debounce->stop();
    });
    connect(buttons, &QDialogButtonBox::accepted, this, [=] {
        debounce->stop();
        if (update() && submit({{"action", "adjustmentCommit"}, {"adjustment", *adjustment}})) accept();
        else error->setText(tr("Could not apply the adjustment. Adjust the settings or cancel."));
    });
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
    connect(this, &QDialog::rejected, this, [=] { debounce->stop(); submit({{"action", "adjustmentCancel"}}); });
    debounce->start(0);
}