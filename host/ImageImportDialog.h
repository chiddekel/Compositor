#pragma once

#include <QDialog>
#include <QDialogButtonBox>
#include <QFileDialog>
#include <QFileInfo>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QPushButton>
#include <QSet>
#include <QStyle>
#include <QVBoxLayout>
#include <functional>

// Qt's native file and directory choosers have separate modes. Collect their selections in one import so files
// and folders can be mixed, while each chooser retains its platform/portal access grant.
class ImageImportDialog final : public QDialog {
public:
    using ImageChooser = std::function<QStringList()>;
    using FolderChooser = std::function<QString()>;

    explicit ImageImportDialog(const QString &filter, QWidget *parent = nullptr,
                               ImageChooser images = {}, FolderChooser folder = {}) : QDialog(parent) {
        setWindowTitle(tr("Import Images"));
        setObjectName("imageImportDialog");
        resize(560, 330);
        auto *layout = new QVBoxLayout(this);
        auto *description = new QLabel(tr("Choose images or folders. Images directly inside each folder are imported in name order."), this);
        description->setWordWrap(true);
        layout->addWidget(description);
        m_sources = new QListWidget(this);
        m_sources->setObjectName("import.sources");
        m_sources->setAccessibleName(tr("Images and folders to import"));
        m_sources->setSelectionMode(QAbstractItemView::ExtendedSelection);
        layout->addWidget(m_sources, 1);
        auto *row = new QHBoxLayout;
        auto *addImages = new QPushButton(tr("Add Images…"), this);
        addImages->setObjectName("import.addImages");
        auto *addFolder = new QPushButton(tr("Add Folder…"), this);
        addFolder->setObjectName("import.addFolder");
        auto *remove = new QPushButton(tr("Remove"), this);
        remove->setObjectName("import.remove");
        remove->setEnabled(false);
        row->addWidget(addImages); row->addWidget(addFolder); row->addStretch(); row->addWidget(remove);
        layout->addLayout(row);
        auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, this);
        m_import = buttons->button(QDialogButtonBox::Ok);
        m_import->setText(tr("Import"));
        m_import->setObjectName("import.confirm");
        m_import->setEnabled(false);
        layout->addWidget(buttons);
        connect(buttons, &QDialogButtonBox::accepted, this, &QDialog::accept);
        connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
        connect(addImages, &QPushButton::clicked, this, [this, filter, images] {
            addSources(images ? images() : QFileDialog::getOpenFileNames(this, tr("Add Images"), QString(), filter));
        });
        connect(addFolder, &QPushButton::clicked, this, [this, folder] {
            const QString path = folder ? folder() : QFileDialog::getExistingDirectory(this, tr("Add Folder"));
            if (!path.isEmpty()) addSources({path});
        });
        connect(m_sources, &QListWidget::itemSelectionChanged, remove, [this, remove] {
            remove->setEnabled(!m_sources->selectedItems().isEmpty());
        });
        connect(remove, &QPushButton::clicked, this, [this] {
            for (auto *item : m_sources->selectedItems()) delete item;
            m_import->setEnabled(m_sources->count() > 0);
        });
    }

    QStringList selectedPaths() const {
        QStringList paths;
        for (int i = 0; i < m_sources->count(); ++i) paths.append(m_sources->item(i)->data(Qt::UserRole).toString());
        return paths;
    }

private:
    void addSources(const QStringList &paths) {
        const QStringList current = selectedPaths();
        QSet<QString> existing(current.begin(), current.end());
        for (const QString &path : paths) {
            if (path.isEmpty()) continue;
            // Preserve portal aliases: resolving a canonical path could lose the selected access grant.
            const QFileInfo info(path);
            const QString absolute = info.absoluteFilePath();
            if (existing.contains(absolute)) continue;
            existing.insert(absolute);
            auto *item = new QListWidgetItem(style()->standardIcon(info.isDir() ? QStyle::SP_DirIcon : QStyle::SP_FileIcon),
                info.fileName(), m_sources);
            item->setData(Qt::UserRole, absolute);
            item->setToolTip(absolute);
        }
        m_import->setEnabled(m_sources->count() > 0);
    }
    QListWidget *m_sources;
    QPushButton *m_import;
};
