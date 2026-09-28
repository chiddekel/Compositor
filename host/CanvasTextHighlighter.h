#pragma once

#include "QtTextFont.h"
#include <QJsonArray>
#include <QJsonObject>
#include <QSyntaxHighlighter>
#include <QTextBlock>

// Layout-only font attributes keep native text undo independent of toolbar changes.
// QTextEdit extra selections paint colors but do not shape text in different faces.
class CanvasTextHighlighter final : public QSyntaxHighlighter {
public:
    explicit CanvasTextHighlighter(QTextDocument *document) : QSyntaxHighlighter(document) {}

    void setStyle(const QFont &base, const QJsonArray &runs, double size, double tracking) {
        if (base == m_base && runs == m_runs && size == m_size && tracking == m_tracking) return;
        m_base = base; m_runs = runs; m_size = size; m_tracking = tracking;
        rehighlight();
    }

protected:
    void highlightBlock(const QString &text) override {
        setFormat(0, int(text.size()), m_base);
        const int offset = currentBlock().position();
        for (const auto &value : m_runs) {
            const auto run = value.toObject();
            const int start = run.value("location").toInt();
            const int end = start + run.value("length").toInt();
            const int localStart = std::max(0, start - offset);
            const int localEnd = std::min(int(text.size()), end - offset);
            if (localEnd <= localStart) continue;
            auto font = fontFor(run.value("fontName").toString().toUtf8().constData(), m_size);
            font.setLetterSpacing(QFont::AbsoluteSpacing, m_tracking);
            setFormat(localStart, localEnd - localStart, font);
        }
    }

private:
    QFont m_base;
    QJsonArray m_runs;
    double m_size = 0, m_tracking = 0;
};
