#pragma once

#include <QCryptographicHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <optional>

// Qt owns text, caret movement and typing groups. Keep only style metadata and a
// digest at each Qt undo position, so undo never infers deleted letters' styles.
class NativeTextHistory {
public:
    static QJsonObject attributes(const QJsonObject &draft) {
        QJsonObject result;
        for (const auto *key : {"fontName", "fontSize", "tracking", "leading", "alignment", "boxSize", "fontRuns", "colorRuns"})
            if (draft.contains(key)) result.insert(key, draft.value(key));
        const auto color = draft.value("color").toArray();
        result.insert("red", color.at(0)); result.insert("green", color.at(1)); result.insert("blue", color.at(2));
        return result;
    }

    void reset(int position, const QJsonObject &draft) {
        m_snapshots.clear(); remember(position, draft);
    }

    void remember(int position, const QJsonObject &draft) {
        discardAfter(position);
        m_snapshots.insert(position, {digest(draft.value("content").toString()), attributes(draft)});
    }

    void discardAfter(int position) {
        auto it = m_snapshots.upperBound(position);
        while (it != m_snapshots.end()) it = m_snapshots.erase(it);
    }

    std::optional<QJsonObject> restore(int position, const QString &content) const {
        const auto it = m_snapshots.constFind(position);
        if (it == m_snapshots.cend() || it->digest != digest(content)) return std::nullopt;
        auto style = it->attributes;
        style.insert("content", content);
        return style;
    }

    bool matches(int position, const QJsonObject &draft) const {
        const auto it = m_snapshots.constFind(position);
        return it != m_snapshots.cend() && it->attributes == attributes(draft);
    }

private:
    static QByteArray digest(const QString &text) { return QCryptographicHash::hash(text.toUtf8(), QCryptographicHash::Sha256); }
    struct Snapshot { QByteArray digest; QJsonObject attributes; };
    QMap<int, Snapshot> m_snapshots;
};
