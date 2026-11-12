// mkdd-settings: the window the AppImage shows when it starts without arguments.
//
// It edits a small subset of settings and stores them in the launcher's own
// settings.ini, which AppRun.sh turns into per-run Dolphin overrides (-C). So
// Dolphin's own config, which an installed Dolphin shares, is never changed.
//
// Usage: mkdd-settings SETTINGS_FILE [NOTICE]
// Exit code: 0 = quit, 10 = play, 11 = open Dolphin.
//
// Built against Qt 6.4 headers and linked to the Qt 6 libraries Dolphin
// bundles; it runs through sharun like Dolphin. No moc: signals use lambdas.

#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDesktopServices>
#include <QDialogButtonBox>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFont>
#include <QFormLayout>
#include <QGuiApplication>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QIcon>
#include <QLabel>
#include <QLineEdit>
#include <QLocale>
#include <QMap>
#include <QProcess>
#include <QPushButton>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSlider>
#include <QTextStream>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>
#include <QVector>
#include <QWidget>

#include <algorithm>
#include <memory>

namespace {

enum ExitCode { Quit = 0, Play = 10, OpenDolphin = 11 };

const char *kDiscFilter =
    "GameCube disc images (*.iso *.gcm *.rvz *.gcz *.ciso *.wia *.wbfs *.nfs *.tgc "
    "*.ISO *.GCM *.RVZ *.GCZ *.CISO *.WIA);;All files (*)";

// settings.ini: plain "key=value" lines, read by AppRun.sh too.
using Settings = QMap<QString, QString>;

Settings load(const QString &path)
{
    Settings s;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return s;
    QTextStream in(&f);
    while (!in.atEnd()) {
        const QString line = in.readLine();
        const int eq = line.indexOf('=');
        if (eq > 0 && !line.startsWith('#'))
            s.insert(line.left(eq).trimmed(), line.mid(eq + 1).trimmed());
    }
    return s;
}

bool save(const QString &path, const Settings &s)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;
    QTextStream out(&f);
    out << "# Written by the Mario Kart: Double Dash!! AppImage settings window.\n";
    for (auto it = s.begin(); it != s.end(); ++it)
        out << it.key() << '=' << it.value() << '\n';
    out.flush();
    return f.commit();
}

QString get(const Settings &s, const char *key, const char *def)
{
    return s.value(key, def);
}

// A path field with a Browse button.
struct PathRow {
    QWidget *widget;
    QLineEdit *edit;
};

PathRow pathRow(QWidget *parent, const QString &value, const QString &title, const QString &filter)
{
    auto *w = new QWidget(parent);
    auto *row = new QHBoxLayout(w);
    row->setContentsMargins(0, 0, 0, 0);
    auto *edit = new QLineEdit(value, w);
    edit->setClearButtonEnabled(true);
    auto *browse = new QPushButton(QObject::tr("Browse…"), w);
    row->addWidget(edit, 1);
    row->addWidget(browse);
    QObject::connect(browse, &QPushButton::clicked, w, [=] {
        const QString start = edit->text().isEmpty() ? QDir::homePath() : QFileInfo(edit->text()).absolutePath();
        const QString file = QFileDialog::getOpenFileName(w, title, start, filter);
        if (!file.isEmpty())
            edit->setText(file);
    });
    return {w, edit};
}

// A texture file the way Dolphin finds one: tex1_..., PNG or DDS. The _mipN
// files are levels of another texture, so they do not count.
bool isTexture(const QString &fileName)
{
    static const QRegularExpression name("^tex1_.*\\.(png|dds)$", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression mip("_mip\\d", QRegularExpression::CaseInsensitiveOption);
    return name.match(fileName).hasMatch() && !mip.match(fileName).hasMatch();
}

struct TexturePack {
    QString name;
    int textures;
};

// Each folder in root is a pack. Links to folders below a pack are not
// followed, like Dolphin's own walk.
QVector<TexturePack> scanPacks(const QString &root)
{
    QVector<TexturePack> packs;
    const QDir dir(root);
    if (root.isEmpty() || !dir.exists())
        return packs;
    // Dolphin's order: byte order of the path, which is what decides between two packs.
    QStringList folders = dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    std::sort(folders.begin(), folders.end(), [](const QString &a, const QString &b) {
        return a.toUtf8() < b.toUtf8();
    });
    for (const QString &folder : folders) {
        int n = 0;
        QDirIterator it(dir.filePath(folder), QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            it.next();
            if (isTexture(it.fileName()))
                ++n;
        }
        if (n > 0)
            packs.push_back({folder, n});
    }
    return packs;
}

void openFolder(const QString &path)
{
    QDir().mkpath(path);
    QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

void setCombo(QComboBox *combo, const QString &value)
{
    const int i = combo->findData(value);
    combo->setCurrentIndex(i >= 0 ? i : 0);
}

} // namespace

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    QApplication::setApplicationName("Mario Kart: Double Dash!!");
    QApplication::setDesktopFileName("mkdd");
    if (argc < 2) {
        fprintf(stderr, "usage: mkdd-settings SETTINGS_FILE [NOTICE]\n");
        return 2;
    }
    const QString settingsPath = QString::fromLocal8Bit(argv[1]);
    const QString notice = argc > 2 ? QString::fromLocal8Bit(argv[2]) : QString();
    const QString appdir = qEnvironmentVariable("APPDIR");
    Settings s = load(settingsPath);

    QWidget window;
    window.setWindowTitle("Mario Kart: Double Dash!!");
    const QString icon = appdir + "/mkdd.png";
    if (QFile::exists(icon))
        window.setWindowIcon(QIcon(icon));
    auto *layout = new QVBoxLayout(&window);

    auto *title = new QLabel("Mario Kart: Double Dash!!", &window);
    QFont big = title->font();
    big.setPointSizeF(big.pointSizeF() * 1.5);
    big.setBold(true);
    title->setFont(big);
    layout->addWidget(title);
    auto *sub = new QLabel(QObject::tr("Version %1, runs on Dolphin %2. You need your own disc image.")
                               .arg(qEnvironmentVariable("MKDD_APPIMAGE_VERSION", "?"),
                                    qEnvironmentVariable("MKDD_DOLPHIN_VERSION", "?")), &window);
    sub->setEnabled(false);
    layout->addWidget(sub);
    if (!notice.isEmpty()) {
        auto *n = new QLabel(notice, &window);
        n->setWordWrap(true);
        n->setStyleSheet("font-weight: bold;");
        layout->addWidget(n);
    }

    // --- Game
    auto *gameBox = new QGroupBox(QObject::tr("Game"), &window);
    auto *game = new QFormLayout(gameBox);
    PathRow disc = pathRow(gameBox, get(s, "disc", ""), QObject::tr("Disc image"), kDiscFilter);
    game->addRow(QObject::tr("Disc image"), disc.widget);
    auto *useDol = new QCheckBox(QObject::tr("Boot my decomp build instead of the disc's main.dol"), gameBox);
    useDol->setChecked(get(s, "use_dol", "0") == "1");
    game->addRow(useDol);
    PathRow dol = pathRow(gameBox, get(s, "dol", ""), QObject::tr("Decomp build"),
                          "GameCube executables (*.dol);;All files (*)");
    dol.edit->setPlaceholderText("build/MarioClub_us/main.dol");
    game->addRow(QObject::tr("main.dol"), dol.widget);
    dol.widget->setEnabled(useDol->isChecked());
    QObject::connect(useDol, &QCheckBox::toggled, dol.widget, &QWidget::setEnabled);
    layout->addWidget(gameBox);

    // --- Display
    auto *displayBox = new QGroupBox(QObject::tr("Display"), &window);
    auto *display = new QFormLayout(displayBox);
    auto *fullscreen = new QCheckBox(QObject::tr("Fullscreen"), displayBox);
    fullscreen->setChecked(get(s, "fullscreen", "1") == "1");
    display->addRow(fullscreen);
    auto *resolution = new QComboBox(displayBox);
    resolution->addItem(QObject::tr("Auto (follows the window size)"), "0");
    resolution->addItem(QObject::tr("Native (480p)"), "1");
    resolution->addItem(QObject::tr("2× (720p)"), "2");
    resolution->addItem(QObject::tr("3× (1080p)"), "3");
    resolution->addItem(QObject::tr("4× (1440p)"), "4");
    resolution->addItem(QObject::tr("6× (4K)"), "6");
    setCombo(resolution, get(s, "resolution", "0"));
    display->addRow(QObject::tr("Resolution"), resolution);
    auto *backend = new QComboBox(displayBox);
    backend->addItem(QObject::tr("Dolphin's choice"), "");
    backend->addItem("Vulkan", "Vulkan");
    backend->addItem("OpenGL", "OGL");
    setCombo(backend, get(s, "backend", ""));
    display->addRow(QObject::tr("Renderer"), backend);
    auto *vsync = new QCheckBox(QObject::tr("VSync (no tearing)"), displayBox);
    vsync->setChecked(get(s, "vsync", "1") == "1");
    display->addRow(vsync);
    auto *wide = new QCheckBox(QObject::tr("Widescreen (16:9 hack; the screen edges can show glitches)"), displayBox);
    wide->setChecked(get(s, "widescreen", "0") == "1");
    display->addRow(wide);
    layout->addWidget(displayBox);

    // --- Audio
    auto *audioBox = new QGroupBox(QObject::tr("Audio"), &window);
    auto *audio = new QFormLayout(audioBox);
    auto *volumeRow = new QWidget(audioBox);
    auto *volumeLayout = new QHBoxLayout(volumeRow);
    volumeLayout->setContentsMargins(0, 0, 0, 0);
    auto *volume = new QSlider(Qt::Horizontal, volumeRow);
    volume->setRange(0, 100);
    volume->setValue(get(s, "volume", "100").toInt());
    auto *volumeLabel = new QLabel(QString("%1%").arg(volume->value()), volumeRow);
    volumeLabel->setMinimumWidth(volumeLabel->fontMetrics().horizontalAdvance("100%"));
    QObject::connect(volume, &QSlider::valueChanged, volumeLabel,
                     [=](int v) { volumeLabel->setText(QString("%1%").arg(v)); });
    volumeLayout->addWidget(volume, 1);
    volumeLayout->addWidget(volumeLabel);
    audio->addRow(QObject::tr("Volume"), volumeRow);
    layout->addWidget(audioBox);

    // --- Texture packs
    const QString packsDir = qEnvironmentVariable("MKDD_TEXTURE_PACKS");
    const QString dumpsDir = qEnvironmentVariable("MKDD_TEXTURE_DUMPS");
    auto *texBox = new QGroupBox(QObject::tr("Texture packs"), &window);
    auto *tex = new QFormLayout(texBox);
    auto *texRow = new QWidget(texBox);
    auto *texRowLayout = new QHBoxLayout(texRow);
    texRowLayout->setContentsMargins(0, 0, 0, 0);
    auto *textures = new QCheckBox(QObject::tr("Use texture packs"), texRow);
    textures->setChecked(get(s, "textures", "1") == "1");
    auto *openPacks = new QPushButton(QObject::tr("Open packs folder"), texRow);
    openPacks->setEnabled(!packsDir.isEmpty());
    texRowLayout->addWidget(textures, 1);
    texRowLayout->addWidget(openPacks);
    tex->addRow(texRow);
    auto *pack = new QComboBox(texBox);
    pack->setSizeAdjustPolicy(QComboBox::AdjustToContents);
    tex->addRow(QObject::tr("Pack"), pack);
    auto *packNote = new QLabel(texBox);
    packNote->setWordWrap(true);
    packNote->setEnabled(false);
    tex->addRow(packNote);
    auto *preload = new QCheckBox(QObject::tr("Load all pack textures at the start (no stutter, needs more memory)"), texBox);
    preload->setChecked(get(s, "texture_preload", "0") == "1");
    tex->addRow(preload);
    auto *dumpRow = new QWidget(texBox);
    auto *dumpRowLayout = new QHBoxLayout(dumpRow);
    dumpRowLayout->setContentsMargins(0, 0, 0, 0);
    auto *dump = new QCheckBox(QObject::tr("Save the game's textures as PNG files, to make a pack"), dumpRow);
    dump->setChecked(get(s, "texture_dump", "0") == "1");
    auto *openDumps = new QPushButton(QObject::tr("Open dumps folder"), dumpRow);
    openDumps->setEnabled(!dumpsDir.isEmpty());
    dumpRowLayout->addWidget(dump, 1);
    dumpRowLayout->addWidget(openDumps);
    tex->addRow(dumpRow);
    layout->addWidget(texBox);
    QObject::connect(openPacks, &QPushButton::clicked, texBox, [=] { openFolder(packsDir); });
    QObject::connect(openDumps, &QPushButton::clicked, texBox, [=] { openFolder(dumpsDir); });

    // The pack the player chose, kept while the list is filled again.
    auto packWanted = std::make_shared<QString>(get(s, "texture_pack", ""));
    auto filling = std::make_shared<bool>(false);
    auto updatePacks = [=] {
        const QVector<TexturePack> packs = scanPacks(packsDir);
        const QLocale locale;
        *filling = true;
        pack->clear();
        pack->addItem(QObject::tr("All packs"), QString());
        for (const TexturePack &p : packs)
            pack->addItem(p.textures == 1 ? QObject::tr("%1 (1 texture)").arg(p.name)
                                          : QObject::tr("%1 (%2 textures)").arg(p.name, locale.toString(p.textures)),
                          p.name);
        if (!packWanted->isEmpty() && pack->findData(*packWanted) < 0)
            pack->addItem(QObject::tr("%1 (not found, all packs load)").arg(*packWanted), *packWanted);
        setCombo(pack, *packWanted);
        *filling = false;
        if (packs.isEmpty())
            packNote->setText(QObject::tr("No packs yet. Put each pack in its own folder in the packs folder. "
                                          "Until then, Dolphin's own Load/Textures folder is used."));
        else if (packs.size() > 1)
            packNote->setText(QObject::tr("With all packs, the first by name wins where two replace the same texture."));
        else
            packNote->clear();
        packNote->setVisible(!packNote->text().isEmpty());
        const bool on = textures->isChecked();
        pack->setEnabled(on && !packs.isEmpty());
        preload->setEnabled(on);
    };
    QObject::connect(pack, &QComboBox::currentIndexChanged, texBox, [=] {
        if (!*filling)
            *packWanted = pack->currentData().toString();
    });
    QObject::connect(textures, &QCheckBox::toggled, texBox, updatePacks);
    // Packs copied in from the file manager show up when the window is back in front.
    QObject::connect(qApp, &QGuiApplication::applicationStateChanged, texBox, [=](Qt::ApplicationState st) {
        if (st == Qt::ApplicationActive)
            updatePacks();
    });
    updatePacks();

    // --- Controllers
    auto *padBox = new QGroupBox(QObject::tr("Controllers"), &window);
    auto *pads = new QVBoxLayout(padBox);
    auto *automap = new QCheckBox(QObject::tr("Map gamepads to GameCube ports automatically"), padBox);
    automap->setChecked(get(s, "automap", "1") == "1");
    pads->addWidget(automap);
    auto *padList = new QLabel(padBox);
    padList->setTextInteractionFlags(Qt::TextSelectableByMouse);
    padList->setWordWrap(true);
    pads->addWidget(padList);
    auto *padButtons = new QHBoxLayout;
    auto *refresh = new QPushButton(QObject::tr("Refresh"), padBox);
    auto *mapHint = new QLabel(QObject::tr("To change buttons: Open Dolphin, then Controllers."), padBox);
    mapHint->setEnabled(false);
    padButtons->addWidget(refresh);
    padButtons->addWidget(mapHint, 1);
    pads->addLayout(padButtons);
    layout->addWidget(padBox);

    // The launcher knows how controllers are detected and mapped; ask it.
    auto *probe = new QProcess(&window);
    auto listPads = [=] {
        if (appdir.isEmpty() || probe->state() != QProcess::NotRunning) {
            if (appdir.isEmpty())
                padList->setText(QObject::tr("Controller list needs the AppImage."));
            return;
        }
        padList->setText(QObject::tr("Looking for controllers…"));
        probe->start(appdir + "/AppRun", {"--pads"});
    };
    QObject::connect(probe, &QProcess::finished, padList, [=] {
        const QString out = QString::fromLocal8Bit(probe->readAllStandardOutput()).trimmed();
        padList->setText(out.isEmpty() ? QObject::tr("Controller detection failed.") : out);
    });
    QObject::connect(refresh, &QPushButton::clicked, padList, listPads);

    // --- Buttons
    auto *buttons = new QDialogButtonBox(&window);
    auto *play = buttons->addButton(QObject::tr("Play"), QDialogButtonBox::AcceptRole);
    auto *dolphin = buttons->addButton(QObject::tr("Open Dolphin"), QDialogButtonBox::ActionRole);
    auto *quit = buttons->addButton(QObject::tr("Quit"), QDialogButtonBox::RejectRole);
    play->setDefault(true);
    layout->addWidget(buttons);

    auto *problem = new QLabel(&window);
    problem->setStyleSheet("color: palette(link);");
    layout->addWidget(problem);

    auto validate = [=] {
        QString why;
        if (disc.edit->text().isEmpty())
            why = QObject::tr("Pick your disc image to play.");
        else if (!QFileInfo(disc.edit->text()).isFile())
            why = QObject::tr("The disc image does not exist.");
        else if (useDol->isChecked() && !dol.edit->text().isEmpty() && !QFileInfo(dol.edit->text()).isFile())
            why = QObject::tr("The main.dol does not exist.");
        problem->setText(why);
        problem->setVisible(!why.isEmpty());
        play->setEnabled(why.isEmpty());
    };
    QObject::connect(disc.edit, &QLineEdit::textChanged, &window, validate);
    QObject::connect(dol.edit, &QLineEdit::textChanged, &window, validate);
    QObject::connect(useDol, &QCheckBox::toggled, &window, validate);

    auto store = [=, &s] {
        s["disc"] = disc.edit->text();
        s["use_dol"] = useDol->isChecked() ? "1" : "0";
        s["dol"] = dol.edit->text();
        s["fullscreen"] = fullscreen->isChecked() ? "1" : "0";
        s["resolution"] = resolution->currentData().toString();
        s["backend"] = backend->currentData().toString();
        s["vsync"] = vsync->isChecked() ? "1" : "0";
        s["widescreen"] = wide->isChecked() ? "1" : "0";
        s["volume"] = QString::number(volume->value());
        s["automap"] = automap->isChecked() ? "1" : "0";
        s["textures"] = textures->isChecked() ? "1" : "0";
        s["texture_pack"] = *packWanted;
        s["texture_preload"] = preload->isChecked() ? "1" : "0";
        s["texture_dump"] = dump->isChecked() ? "1" : "0";
        if (!save(settingsPath, s))
            fprintf(stderr, "mkdd-settings: cannot write %s\n", qPrintable(settingsPath));
    };
    int result = Quit;
    QObject::connect(play, &QPushButton::clicked, &window, [&] { result = Play; window.close(); });
    QObject::connect(dolphin, &QPushButton::clicked, &window, [&] { result = OpenDolphin; window.close(); });
    QObject::connect(quit, &QPushButton::clicked, &window, &QWidget::close);

    validate();
    window.show();
    listPads();
    // MKDD_SETTINGS_SCREENSHOT=FILE: save a picture of the window and close
    // without saving (for docs and for checking it on a machine without a screen).
    const QString shot = qEnvironmentVariable("MKDD_SETTINGS_SCREENSHOT");
    if (!shot.isEmpty()) {
        QTimer::singleShot(1500, &window, [&] {
            window.grab().save(shot);
            app.exit(0);
        });
        app.exec();
        return Quit;
    }
    app.exec();
    // Saved however the window closed, its close button included.
    store();
    return result;
}
