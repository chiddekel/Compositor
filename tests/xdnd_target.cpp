// The control drop target for scripts/test-desktop-dnd.sh: a plain Qt window that prints what an XDND drop carries.
// When even it receives no data, the environment (a headless X server, synthetic input) cannot carry drop data.
#include <QApplication>
#include <QDropEvent>
#include <QMimeData>
#include <QWidget>
#include <cstdio>
class T : public QWidget { protected:
  void dragEnterEvent(QDragEnterEvent *e) override { e->acceptProposedAction(); }
  void dropEvent(QDropEvent *e) override { std::printf("target got formats %d urls %d data '%s'\n", int(e->mimeData()->formats().size()), int(e->mimeData()->urls().size()), e->mimeData()->data("text/uri-list").constData()); std::fflush(stdout); e->acceptProposedAction(); }
};
int main(int c, char **v) { QApplication a(c, v); T t; t.setAcceptDrops(true); t.setGeometry(100, 100, 400, 300); t.show(); std::printf("target ready\n"); std::fflush(stdout); return a.exec(); }
