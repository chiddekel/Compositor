#pragma once

#include <algorithm>
#include <QHash>
#include <QKeyEvent>
#include <private/qkeymapper_p.h>
#include "NativeKeyboardLayout.h"

extern "C" void compositor_keyboard_set_latin_character(int32_t keyCode, int32_t shifted, const char *characters);

// Keep physical-key metadata separate from the user's Latin layout. Raw typed text remains untouched.
inline int appKitPrintableKeyCode(const QKeyEvent *event) {
    static const QHash<int, int> codes{
        {'A',0},{'S',1},{'D',2},{'F',3},{'H',4},{'G',5},{'Z',6},{'X',7},{'C',8},{'V',9},{'B',11},
        {'Q',12},{'W',13},{'E',14},{'R',15},{'Y',16},{'T',17},{'1',18},{'2',19},{'3',20},{'4',21},
        {'6',22},{'5',23},{'=',24},{'9',25},{'7',26},{'-',27},{'8',28},{'0',29},{']',30},{'O',31},
        {'U',32},{'[',33},{'I',34},{'P',35},{'L',37},{'J',38},{'\'',39},{'K',40},{';',41},{'\\',42},
        {',',43},{'/',44},{'N',45},{'M',46},{'.',47},{' ',49},{'`',50},
        {'!',18},{'@',19},{'#',20},{'$',21},{'^',22},{'%',23},{'+',24},{'(',25},{'&',26},{'_',27},
        {'*',28},{')',29},{'}',30},{'{',33},{'"',39},{':',41},{'|',42},{'<',43},{'?',44},{'>',47},{'~',50}};
    const bool shift = event->modifiers().testFlag(Qt::ShiftModifier);
    const QString typed = event->text();
    if (event->nativeScanCode()) {
        static const QHash<QByteArray, int> physicalCodes{
            {"TLDE",50},{"AE01",18},{"AE02",19},{"AE03",20},{"AE04",21},{"AE05",23},{"AE06",22},
            {"AE07",26},{"AE08",28},{"AE09",25},{"AE10",29},{"AE11",27},{"AE12",24},
            {"AD01",12},{"AD02",13},{"AD03",14},{"AD04",15},{"AD05",17},{"AD06",16},
            {"AD07",32},{"AD08",34},{"AD09",31},{"AD10",35},{"AD11",33},{"AD12",30},
            {"AC01",0},{"AC02",1},{"AC03",2},{"AC04",3},{"AC05",5},{"AC06",4},
            {"AC07",38},{"AC08",40},{"AC09",37},{"AC10",41},{"AC11",39},{"BKSL",42},
            {"AB01",6},{"AB02",7},{"AB03",8},{"AB04",9},{"AB05",11},{"AB06",45},
            {"AB07",46},{"AB08",43},{"AB09",47},{"AB10",44},{"LSGT",10},{"SPCE",49}};
        const auto key = nativekeyboard::lookupLatinKey(event->nativeScanCode());
        const QString latin = shift ? key.shifted : key.normal;
        const bool ascii = !latin.isEmpty() && std::all_of(latin.begin(), latin.end(), [](QChar c) { return c.unicode() < 0x80; });
        const bool nonLatinInput = std::any_of(typed.begin(), typed.end(), [](QChar c) { return c.unicode() >= 0x80; });
        if (nonLatinInput && !ascii) return 0xffff;
        if (physicalCodes.contains(key.physicalName)) {
            const int code = physicalCodes.value(key.physicalName);
            if (ascii) {
                const QByteArray text = latin.toUtf8();
                compositor_keyboard_set_latin_character(code, shift, text.constData());
            }
            return code;
        }
    }
    QList<QKeyCombination> candidates = QKeyMapper::possibleKeys(event);
    if (event->key() >= 0x20 && event->key() < 0x7f)
        candidates.prepend(QKeyCombination(event->modifiers(), Qt::Key(event->key())));
    for (const auto &candidate : candidates) {
        const int key = int(candidate.key());
        if (key < 0x20 || key >= 0x7f || !codes.contains(key)) continue;
        const QChar label{ushort(key)};
        const QByteArray text = QString(shift ? label.toUpper() : label.toLower()).toUtf8();
        compositor_keyboard_set_latin_character(codes.value(key), shift, text.constData());
        return codes.value(key);
    }
    return 0xffff;
}
