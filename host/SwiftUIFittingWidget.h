#pragma once
#include <QWidget>
#include <QResizeEvent>

/// Size-dependent alternatives retain their widgets while the available space changes.
class SwiftUIFittingWidget final : public QWidget {
    QList<QWidget *> m_choices;
    bool m_horizontal, m_vertical;
    int m_selected = 0;
public:
    SwiftUIFittingWidget(QList<QWidget *> choices, bool horizontal, bool vertical, QSize proposed = QSize())
        : m_choices(std::move(choices)), m_horizontal(horizontal), m_vertical(vertical) {
        for (auto *choice : m_choices) { choice->setParent(this); choice->hide(); }
        if (!m_choices.isEmpty()) {
            m_selected = choiceFor(proposed.isValid() ? proposed : size());
            m_choices[m_selected]->show();
        }
        setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Expanding);
    }
    QSize sizeHint() const override { return m_choices.isEmpty() ? QSize(0, 0) : idealSize(m_choices[m_selected]); }
    QSize minimumSizeHint() const override {
        const QSize hint = sizeHint();
        return QSize(m_horizontal ? 0 : hint.width(), m_vertical ? 0 : hint.height());
    }
protected:
    void resizeEvent(QResizeEvent *event) override {
        QWidget::resizeEvent(event);
        if (m_choices.isEmpty()) return;
        const int selected = choiceFor(size());
        if (m_selected != selected) {
            m_choices[m_selected]->hide(); m_selected = selected; m_choices[m_selected]->show();
            updateGeometry();
        }
        m_choices[m_selected]->setGeometry(rect());
    }
private:
    int choiceFor(QSize available) const {
        for (int index = 0; index < m_choices.size(); ++index) {
            const QSize ideal = idealSize(m_choices[index]);
            if ((!m_horizontal || ideal.width() <= available.width()) && (!m_vertical || ideal.height() <= available.height()))
                return index;
        }
        return m_choices.size() - 1;
    }
    static QSize idealSize(QWidget *choice) {
        // Native scroll views may report a content hint narrower than their explicit SwiftUI frame.
        return choice->sizeHint().expandedTo(choice->minimumSize()).boundedTo(choice->maximumSize());
    }
};
