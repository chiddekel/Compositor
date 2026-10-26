#include "GridSettingsJourney.h"
#include <QApplication>
#include <QComboBox>
#include <QDebug>

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QWidget sheet;
    // Retired panels remain children until Qt delivers DeferredDelete. They cannot own a live picker.
    QWidget retired(&sheet);
    retired.setProperty("swiftUITree", QByteArray("retired"));
    retired.hide();
    QWidget active(&sheet);
    active.setProperty("swiftUITree", QByteArray("active"));
    QWidget wrapper(&active);
    QComboBox picker(&wrapper);
    if (gridsettingsjourney::renderedOwner(&picker, &sheet) != &active) {
        qCritical("Grid owner selection chose a retired or unrelated panel");
        return 1;
    }
    QWidget outside;
    outside.setProperty("swiftUITree", QByteArray("other sheet"));
    QComboBox foreignPicker(&outside);
    if (gridsettingsjourney::renderedOwner(&foreignPicker, &sheet) != nullptr) return 2;
    QWidget unowned(&sheet);
    if (gridsettingsjourney::renderedOwner(&unowned, &sheet) != nullptr) return 3;
    qInfo("Grid owner follows the live control ancestry and respects its sheet boundary");
    return 0;
}
