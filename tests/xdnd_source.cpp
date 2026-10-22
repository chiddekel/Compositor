// A separate X client that drags files (scripts/test-desktop-dnd.sh): as a file manager does, it offers the files as
// text/uri-list over XDND when the pointer is pressed in its window. `xdnd_source X Y FILE...`; prints the drop's
// result (copy / ignored) when the drag ends, then exits.
#include <QApplication>
#include <QDrag>
#include <QMimeData>
#include <QMouseEvent>
#include <QUrl>
#include <QWidget>
#include <cstdio>

class Source : public QWidget {
public:
    QList<QUrl> urls;
protected:
    void mousePressEvent(QMouseEvent *) override {
        auto *drag = new QDrag(this);
        auto *mime = new QMimeData;
        mime->setUrls(urls);
        drag->setMimeData(mime);
        const Qt::DropAction result = drag->exec(Qt::CopyAction);
        std::printf("drop result: %s\n", result == Qt::CopyAction ? "copy" : result == Qt::IgnoreAction ? "ignored" : "other");
        std::fflush(stdout);
        QApplication::quit();
    }
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    if (argc < 4) { std::fprintf(stderr, "usage: xdnd_source X Y FILE...\n"); return 2; }
    Source source;
    for (int i = 3; i < argc; ++i) source.urls << QUrl::fromLocalFile(QString::fromLocal8Bit(argv[i]));
    source.setWindowTitle(QStringLiteral("xdnd source"));
    source.setGeometry(std::atoi(argv[1]), std::atoi(argv[2]), 160, 160);
    source.show();
    std::printf("source ready\n");
    std::fflush(stdout);
    return app.exec();
}
