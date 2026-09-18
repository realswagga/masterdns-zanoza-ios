<div align="right">

**🇷🇺 Русский** · [🇬🇧 English](README.en.md)

</div>

# Zanoza

iOS-клиент для [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN) — VPN на основе туннелирования через DNS для сетей с жёсткой цензурой.

Приложение использует оригинальное ядро Go-клиента MasterDnsVPN и поднимает локальный SOCKS5-прокси на `127.0.0.1:41080` для сторонних VPN-приложений (Happ, Hiddify, Streisand, Shadowrocket и т.п.). Zanoza не создаёт собственный iOS VPN-профиль; весь системный трафик направляет выбранное приложение-потребитель.

В этой ветке добавлены пресет Andron Industries, полная типизированная конфигурация MasterDNS, импорт/экспорт, иерархические списки резолверов, нативная проверка MTU, ограниченный тест пропускной способности каждого резолвера и speed test, который явно использует локальный SOCKS и не может незаметно перейти на мобильный интернет.

## Настройка сервера

Клиент поддерживает ключи и конфигурации серверов [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN). Вы можете найти рабочий сервер в различных телеграм-каналах, или настроить самостоятельно:

**Требования:** 
VPS (Ubuntu 22.04+ / Debian 11+) >500MB RAM<br>
Домен с любым TLD (не обязательно .ru), без кириллицы! Чем меньше символов в домене, тем лучше.

1. В панели управления DNS-записями домена создайте: 

A-запись **`ns`**, указывающую на Ваш VPS:<br>
`ns.domain.ru` -> `12.34.56.78`

NS-запись **`v`** (обязательно в одну букву!), указывающую на A-запись:<br>
`v.domain.ru` -> `ns.domain.ru`

Если Ваш домен делегирован / создан в Cloudflare, **Proxy status** этих записей должен быть **DNS only** (серое облако).<br>
Если Вы купили домен в другом месте (reg.ru и т.п.), рекомендуется делегировать его на Cloudflare - обновление записей будет происходить намного быстрее.

2. Подключитесь по `ssh` к Вашему VPS и введите:

```
sudo bash && cd
```

```
sudo apt update -y && sudo apt full-upgrade -y && sudo apt install curl -y
```

```
sudo tee /etc/sysctl.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
EOF
sudo sysctl -p > /dev/null 2>&1
```

```
bash <(curl -Ls https://raw.githubusercontent.com/masterking32/MasterDnsVPN/main/server_linux_install.sh)
```

По итогу запуска последней команды Вы получите ключ шифрования. Сохраните его, чтобы не возвращаться к серверу.

## Настройка Zanoza

1. Запустите Zanoza и нажмите **Импорт**.
2. Введите делегированный домен с вашего сервера MasterDnsVPN (то же значение, что в NS-записи, `v.domain.ru`).
3. Введите ключ шифрования, полученный при настройке сервера.
4. Нажмите **Импорт**, затем кнопку «питания». Метод шифрования и сжатие должны совпадать с сервером. Пресет Andron использует AES-256-GCM (`DATA_ENCRYPTION_METHOD = 5`) и отключённое сжатие.
5. Дождитесь статуса **Ready**: теперь он выставляется только после проверки MTU, создания сессии и запуска локального listener.
6. Добавьте в Happ/Hiddify/Streisand SOCKS5 без авторизации: `socks://127.0.0.1:41080#Andron%20Industries`. Не добавляйте пустое `:@`. Для ручного fallback доступен HTTP CONNECT на `127.0.0.1:41081`.

Совместимость со Streisand зависит и от версии самого Streisand: она должна разрешать loopback-прокси внутри Network Extension. Zanoza обрабатывает короткий timeout рукопожатия, пустую SOCKS-auth форму и ранние TLS-байты, но не может изменить политику маршрутизации стороннего приложения из другого sandbox.

## Структура репозитория

```
Zanoza/
├── apple/                            # Проект Xcode / SwiftPM
│   ├── Package.swift                 # Общая библиотека ZanozaKit
│   ├── project.yml                   # Описание проекта для XcodeGen
│   ├── Frameworks/                   # Сюда падает Mobile.xcframework
│   ├── Scripts/
│   │   ├── build-xcframework.sh         # gomobile bind → Mobile.xcframework
│   │   ├── build-ios-unsigned-local-ipa.sh
│   │   ├── prepare-xcode.sh             # обёртка над xcodegen
│   │   └── generate-icon.py             # генератор AppIcon (Pillow)
│   ├── Sources/
│   │   ├── ZanozaApp/                # таргет iOS-приложения
│   │   │   ├── Assets.xcassets/AppIcon.appiconset/
│   │   │   ├── Info.plist            # UIBackgroundModes=[audio]
│   │   │   └── ZanozaApp.swift
│   │   └── ZanozaKit/                # Общая SwiftPM-библиотека
│   │       ├── Models/               # ConnectionProfile, ClientStatus
│   │       ├── Services/             # MasterDnsEngine, BackgroundRuntimeKeeper, …
│   │       ├── ViewModels/           # ClientViewModel
│   │       ├── Views/                # ContentView, ImportProfileSheet, …
│   │       └── Resources/{en,ru}.lproj/Localizable.strings
│   └── Tests/ZanozaKitTests/
└── masterdns/                        # Vendored-форк MasterDnsVPN
    ├── go.mod                        # добавлена зависимость golang.org/x/mobile
    └── mobile/                       # gomobile-обёртка
        ├── mobile.go                 #   Start/Stop/IsRunning/SetLogWriter
        └── stdout_pump.go            #   перенаправляет stdout → LogWriter
```

## Для сборки

- macOS 14 + Xcode 16 (iOS-инструментарий идёт в составе Xcode)
- [Homebrew](https://brew.sh)
- `brew install go xcodegen`
- `go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`
- Python 3 с Pillow (`python3 -m pip install --user pillow`) — только если хотите пересобрать иконку приложения

## Сборка

```bash
# 1. Собираем Go-xcframework
apple/Scripts/build-xcframework.sh

# 2. Генерируем проект Xcode
apple/Scripts/prepare-xcode.sh

# 3. Собираем неподписанный IPA
apple/Scripts/build-ios-unsigned-local-ipa.sh
#   → apple/.build/ios-unsigned-local/Zanoza-unsigned.ipa
```

IPA-файл не подписан. Подпишите и установите его на устройство одним из способов:

- **[Sideloadly](https://sideloadly.io)** — перетащите IPA в окно, подпишите своим Apple ID и установите через USB.
- **AltStore / SideStore** — установка прямо на устройстве, после первой настройки Mac уже не нужен.

Перед первой установкой включите на iPhone **Настройки → Конфиденциальность и безопасность → Режим разработчика**.

## Благодарности

- Протокол и ядро Go-клиента: [MasterDnsVPN от MasterkinG32](https://github.com/masterking32/MasterDnsVPN)
- UI iOS-приложения построен по структуре [Godwit](https://github.com/plumbicon/godwit) (MIT)
