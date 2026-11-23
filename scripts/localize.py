#!/usr/bin/env python3
"""Builds the .lproj language packs from the Russian UI strings.

Run after any UI change:  make localize

The Russian literal is the localization key, so an untranslated string simply
falls back to Russian. Translations are cached in Scripts/translations.json,
which makes reruns fast and keeps manual corrections.
"""

import json
import re
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "Scripts" / "translations.json"
RESOURCES = ROOT / "Resources"

# code -> Google Translate code. `ru` is the source and `uk` deliberately
# reuses the Russian texts for now.
LANGS = {
    "en": "en", "es": "es", "pt": "pt", "fr": "fr", "de": "de", "it": "it",
    "nl": "nl", "pl": "pl", "tr": "tr", "ru": "ru", "uk": "uk",
    "ar": "ar", "hi": "hi", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
    "ja": "ja", "ko": "ko", "id": "id", "vi": "vi", "th": "th",
    "sv": "sv", "cs": "cs",
}

# Machine translation often picks the wrong sense for short UI words. These
# keys are translated from an explicit English phrase instead, which gives
# consistent database terminology in every language.
EN_OVERRIDES = {
    "Значение": "Field value",
    "Новый скрипт": "New SQL script",
    "Новый запрос": "New query",
    "Новый запрос (⌘T)": "New query (⌘T)",
    "Запрос": "Query",
    "Запросы": "Queries",
    "Выполнить всё": "Run all",
    "Выполнить выделение / всё": "Run selection / all",
    "Выполнить запрос под курсором": "Run the query under the cursor",
    "Отменить запрос": "Cancel query",
    "По умолчанию": "Defaults",
    "Нажмите сочетание…": "Press a shortcut…",
    "Сочетание уже используется: %@": "Shortcut already in use: %@",
    "Нажмите на сочетание, чтобы изменить его.": "Click a shortcut to change it.",
    "Вернуть по умолчанию": "Reset to default",
    "Изменить сочетание": "Change shortcut",
    "Пробел": "Space",
    "Найти запрос (⌘E)": "Find query (⌘E)",
    "Найти запрос…": "Find query…",
    "Найти": "Find",
    "Найти в результате (⌘F при фокусе в таблице)": "Find in result (⌘F when the table has focus)",
    "Строк за одну загрузку:": "Rows per fetch:",
    "Вставлять несколько строк": "Insert multiple rows",
    "Удалить всю историю запросов": "Clear all query history",
    "Очистить историю": "Clear history",
    "История запросов": "Query history",
    "История запросов очищена": "Query history cleared",
    "Подключение": "Connection",
    "Подключение для текущего скрипта": "Connection for the current script",
    "Подключение: %@…": "Connecting: %@…",
    "Подключено: %@": "Connected: %@",
    "Отключено": "Disconnected",
    "Выполняется…": "Running…",
    "Ошибка": "Error",
    "Готово": "Ready",
    "Загружено %@ строк": "%@ rows loaded",
    "Скопировано: %@ строк": "Copied: %@ rows",
    "Вставлено: %@ строк": "Inserted: %@ rows",
    "Выполните запрос: ⌘↩ (выделение или весь скрипт)": "Run the query: ⌘↩ (selection or the whole script)",
    "Для этого скрипта не выбрано подключение.\nВыберите подключение в строке вкладок или добавьте новое (⇧⌘N).": "No connection is selected for this script.\nChoose one in the tab bar or add a new one (⇧⌘N).",
    "Имя или текст запроса — раскладка не важна": "Query name or text — keyboard layout does not matter",
    "Автосохранение открытых запросов между сессиями": "Autosave open queries between sessions",
    "Выберите ячейку и нажмите «Значение»": "Select a cell and open the panel",
    "Положение курсора в скрипте: строка : позиция в строке : общая позиция": "Caret position in the script: line : column : offset",
    "Ширина запоминается по имени запроса; новые столбцы подстраиваются под данные. Ширину, заданную вручную, программа не меняет.": "Width is remembered per query name; new columns fit their data. Widths set by hand are never changed.",

    # Value inspector and tooltips.
    "Двоичные данные": "Binary",
    "Текст": "Text",
    "Авто": "Auto",
    "Перенос строк": "Word wrap",
    "Автоформат": "Auto format",
    "Сохранять сжатое значение": "Save minified value",
    "Кодировка…": "Encoding…",
    "Строка": "Row",
    "Пусто": "Empty",
    "Скрипт: %@": "Script: %@",
    "Папка: %@": "Folder: %@",
    "Подключение: %@": "Connection: %@",
    "Тип: %@": "Type: %@",
    "База данных: %@": "Database: %@",
    "Схема: %@": "Schema: %@",
    "Имя: %@": "Name: %@",
    "Пользователь: %@": "User: %@",
    "Подключение: по выбору в дереве": "Connection: choose one in the tree",
    "Столбец: %@ %@": "Column: %@ %@",
    "Уникальный ключ: %@(%@)": "Unique key: %@(%@)",
    "Часть ключа: %@": "Part of key: %@",
    "Часть ключа:": "Part of key:",
    "Таблица: %@": "Table: %@",

    # Status lines.
    "Готово: %@%@ строк · %@ мс": "Done: %@%@ rows · %@ ms",
    "(всего %@ строк)": "(of %@ rows)",
    "%@%@ строк · %@ мс": "%@%@ rows · %@ ms",
    "· выделено %@×%@": "· selected %@×%@",
    "%@ стр · %@ мс": "%@ rows · %@ ms",

    "(копия)": "(copy)",
    "Запрос %@": "SQL query %@",
    "Записей в истории: %@": "History entries: %@",
    "Размер шрифта: %@ pt": "Font size: %@ pt",
    "Размер: %@ pt": "Size: %@ pt",
    "Проверка подключения…": "Testing connection…",
    "Подключение успешно": "Connection successful",
    "Подключение успешно — %@": "Connection successful — %@",
    "ldap.ora не найден": "ldap.ora not found",
    "sqlnet.ora не найден": "sqlnet.ora not found",
    "tnsnames.ora есть": "tnsnames.ora found",
    "сервер не указан": "server not set",
    "путь: %@": "path: %@",
    "ldap.ora: %@": "ldap.ora: %@",
    "не найден": "not found",

    # Common UI terms where machine translation picks the wrong sense.
    "Sidecar не запущен": "The Java process is not running",
    "sidecar не запущен": "The Java process is not running",
    "tnsnames.ora есть": "tnsnames.ora found",
    "SELECT таблицы": "SELECT * FROM table",
    "Вид и справка": "View and Help",
    "Всегда заключать в кавычки": "Always quote",
    "Вставлять несколько строк": "Insert multiple rows",
    "Выбрать папку network/admin": "Choose the network/admin folder",
    "Выбрать…": "Choose…",
    "Вырезать": "Cut",
    "Добавить (⌘N)": "Add (⌘N)",
    "Дополнительная вставка": "Advanced paste",
    "Дополнительная вставка…": "Advanced paste…",
    "Другое приложение…": "Other application…",
    "Дублировать подключение": "Duplicate connection",
    "Завершить DBooyvol": "Quit DBooyvol",
    "Завершить и закрыть все окна": "Quit and close all windows",
    "Заключать значения в кавычки": "Quote values",
    "Закрыть все вкладки": "Close all tabs",
    "Закрыть все окна": "Close all windows",
    "Закрыть остальные": "Close others",
    "Закрыть остальные вкладки": "Close other tabs",
    "История": "History",
    "История пуста": "History is empty",
    "История: %@ дней": "History: %@ days",
    "Использовать SSH": "Use SSH",
    "Заполнить": "Fill",
    "Изменить подключение…": "Edit connection…",
    "Изменить…": "Edit…",
    "Свернуть окно": "Minimize window",
    "Все окна на передний план": "Bring all windows to front",
    "Во весь экран": "Full screen",
    "В названии столбца": "In column header",
    "Данные в результате": "Result data",
    "Загрузка данных": "Loading data",

    # Copy dialog.
    "Display (по умолчанию)": "Display (default)",
    "Редактируемое": "Editable",
    "Как в базе": "Database native",
}

# Strings produced by computed properties rather than literal views.
EXTRA_KEYS = ["1 неделя", "1 месяц", "3 месяца", "6 месяцев", "1 год", "Бессрочно"]

# Every Cyrillic string literal is a potential UI string: SwiftUI literals
# are looked up automatically, AppKit strings go through `L10n.tr`, and the
# rest are keys of `L10n.fmt`. Interpolated strings produce a different
# runtime key, so they are skipped (their templates use `%@` instead).
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}


def unescape(value: str) -> str:
    out = []
    i = 0
    while i < len(value):
        c = value[i]
        if c == "\\" and i + 1 < len(value):
            out.append(ESCAPES.get(value[i + 1], value[i + 1]))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def normalize(value: str) -> str:
    """Some translators return fullwidth `％`/`＠`, which String(format:)
    would treat as plain text."""
    return value.replace("％", "%").replace("＠", "@")


def strings_escape(value: str) -> str:
    return (value.replace("\\", "\\\\").replace('"', '\\"')
            .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r"))


def collect() -> list[str]:
    found: set[str] = set()
    for path in (ROOT / "Sources").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for match in LITERAL.finditer(text):
            raw = match.group(1)
            if "\\(" in raw:
                continue
            value = unescape(raw)
            if not value.strip():
                continue
            if not re.search(r"[А-Яа-яЁё]", value):
                continue
            found.add(value)
    for key in EXTRA_KEYS:
        found.add(key)
    return sorted(found)


# Short labels where no single English phrase gives the right sense in every
# language. Kept explicit so the packs read naturally.
MANUAL = {
    "de": {"История": "Verlauf", "История пуста": "Der Verlauf ist leer"},
    "fr": {"История": "Historique", "История пуста": "L’historique est vide"},
    "es": {"История": "Historial", "История пуста": "El historial está vacío"},
    "it": {"История": "Cronologia", "История пуста": "La cronologia è vuota"},
    "nl": {"История": "Geschiedenis", "История пуста": "De geschiedenis is leeg"},
    "pl": {"История": "Historia", "История пуста": "Historia jest pusta"},
    "tr": {"История": "Geçmiş", "История пуста": "Geçmiş boş"},
    "ar": {"История": "السجل", "История пуста": "السجل فارغ"},
    "hi": {"История": "इतिहास", "История пуста": "इतिहास खाली है"},
    "zh-Hans": {"История": "历史", "История пуста": "历史为空"},
    "zh-Hant": {"История": "歷史", "История пуста": "歷史是空的"},
    "ja": {"История": "履歴", "История пуста": "履歴は空です"},
    "ko": {"История": "기록", "История пуста": "기록이 비어 있습니다"},
    "id": {"История": "Riwayat", "История пуста": "Riwayat kosong"},
    "vi": {"История": "Lịch sử", "История пуста": "Lịch sử trống"},
    "th": {"История": "ประวัติ", "История пуста": "ประวัติว่างเปล่า"},
    "sv": {"История": "Historik", "История пуста": "Historiken är tom"},
    "cs": {"История": "Historie", "История пуста": "Historie je prázdná"},
    "en": {"История": "History", "История пуста": "History is empty"},
}

# Run / stop shortcut wording. Machine translation turns "запрос" into
# "request" and "выполнить" into "drive", so these four strings are fixed
# by hand.
RUN_STOP = {
    "Выполнить / остановить": {
        "en": "Run / Stop", "es": "Ejecutar / Detener",
        "pt": "Executar / Parar", "fr": "Exécuter / Arrêter",
        "de": "Ausführen / Stoppen", "it": "Esegui / Interrompi",
        "nl": "Uitvoeren / Stoppen", "pl": "Uruchom / Zatrzymaj",
        "tr": "Çalıştır / Durdur", "ar": "تشغيل / إيقاف",
        "hi": "चलाएँ / रोकें", "zh-Hans": "运行 / 停止",
        "zh-Hant": "執行 / 停止", "ja": "実行 / 停止",
        "ko": "실행 / 중지", "id": "Jalankan / Hentikan",
        "vi": "Chạy / Dừng", "th": "เรียกใช้ / หยุด",
        "sv": "Kör / Stoppa", "cs": "Spustit / Zastavit",
    },
    "Отменить запрос (⌘R)": {
        "en": "Cancel query (⌘R)", "es": "Cancelar consulta (⌘R)",
        "pt": "Cancelar consulta (⌘R)", "fr": "Annuler la requête (⌘R)",
        "de": "Abfrage abbrechen (⌘R)", "it": "Annulla query (⌘R)",
        "nl": "Query annuleren (⌘R)", "pl": "Anuluj zapytanie (⌘R)",
        "tr": "Sorguyu iptal et (⌘R)", "ar": "إلغاء الاستعلام (⌘R)",
        "hi": "क्वेरी रद्द करें (⌘R)", "zh-Hans": "取消查询 (⌘R)",
        "zh-Hant": "取消查詢 (⌘R)", "ja": "クエリをキャンセル (⌘R)",
        "ko": "쿼리 취소 (⌘R)", "id": "Batalkan kueri (⌘R)",
        "vi": "Hủy truy vấn (⌘R)", "th": "ยกเลิกคำค้นหา (⌘R)",
        "sv": "Avbryt frågan (⌘R)", "cs": "Zrušit dotaz (⌘R)",
    },
    "Выполнить выделение или весь скрипт (⌘R, ⌘↩)": {
        "en": "Run selection or entire script (⌘R, ⌘↩)",
        "es": "Ejecutar selección o script completo (⌘R, ⌘↩)",
        "pt": "Executar seleção ou script inteiro (⌘R, ⌘↩)",
        "fr": "Exécuter la sélection ou tout le script (⌘R, ⌘↩)",
        "de": "Auswahl oder gesamtes Skript ausführen (⌘R, ⌘↩)",
        "it": "Esegui selezione o intero script (⌘R, ⌘↩)",
        "nl": "Selectie of volledig script uitvoeren (⌘R, ⌘↩)",
        "pl": "Wykonaj zaznaczenie lub cały skrypt (⌘R, ⌘↩)",
        "tr": "Seçimi veya tüm betiği çalıştır (⌘R, ⌘↩)",
        "ar": "تنفيذ التحديد أو النص بأكمله (⌘R، ⌘↩)",
        "hi": "चयन या पूरी स्क्रिप्ट चलाएँ (⌘R, ⌘↩)",
        "zh-Hans": "运行所选内容或整个脚本（⌘R、⌘↩）",
        "zh-Hant": "執行選取範圍或整個指令碼（⌘R、⌘↩）",
        "ja": "選択範囲またはスクリプト全体を実行 (⌘R, ⌘↩)",
        "ko": "선택 영역 또는 전체 스크립트 실행(⌘R, ⌘↩)",
        "id": "Jalankan pilihan atau seluruh skrip (⌘R, ⌘↩)",
        "vi": "Chạy phần đã chọn hoặc toàn bộ tập lệnh (⌘R, ⌘↩)",
        "th": "เรียกใช้ส่วนที่เลือกหรือทั้งสคริปต์ (⌘R, ⌘↩)",
        "sv": "Kör markering eller hela skriptet (⌘R, ⌘↩)",
        "cs": "Spustit výběr nebo celý skript (⌘R, ⌘↩)",
    },
    "Выполните запрос: ⌘R или ⌘↩ (выделение или весь скрипт)": {
        "en": "Run the query: ⌘R or ⌘↩ (selection or entire script)",
        "es": "Ejecute la consulta: ⌘R o ⌘↩ (selección o script completo)",
        "pt": "Execute a consulta: ⌘R ou ⌘↩ (seleção ou script inteiro)",
        "fr": "Exécutez la requête : ⌘R ou ⌘↩ (sélection ou script entier)",
        "de": "Führen Sie die Abfrage aus: ⌘R oder ⌘↩ (Auswahl oder gesamtes Skript)",
        "it": "Esegui la query: ⌘R o ⌘↩ (selezione o script intero)",
        "nl": "Voer de query uit: ⌘R of ⌘↩ (selectie of volledig script)",
        "pl": "Wykonaj zapytanie: ⌘R lub ⌘↩ (zaznaczenie lub cały skrypt)",
        "tr": "Sorguyu çalıştırın: ⌘R veya ⌘↩ (seçim veya tüm betik)",
        "ar": "نفّذ الاستعلام: ⌘R أو ⌘↩ (التحديد أو النص بأكمله)",
        "hi": "क्वेरी चलाएँ: ⌘R या ⌘↩ (चयन या पूरी स्क्रिप्ट)",
        "zh-Hans": "运行查询：⌘R 或 ⌘↩（所选内容或整个脚本）",
        "zh-Hant": "執行查詢：⌘R 或 ⌘↩（選取範圍或整個指令碼）",
        "ja": "クエリを実行: ⌘R または ⌘↩ (選択範囲またはスクリプト全体)",
        "ko": "쿼리 실행: ⌘R 또는 ⌘↩(선택 영역 또는 전체 스크립트)",
        "id": "Jalankan kueri: ⌘R atau ⌘↩ (pilihan atau seluruh skrip)",
        "vi": "Chạy truy vấn: ⌘R hoặc ⌘↩ (phần đã chọn hoặc toàn bộ tập lệnh)",
        "th": "เรียกใช้คำค้นหา: ⌘R หรือ ⌘↩ (ส่วนที่เลือกหรือทั้งสคริปต์)",
        "sv": "Kör frågan: ⌘R eller ⌘↩ (markering eller hela skriptet)",
        "cs": "Spusťte dotaz: ⌘R nebo ⌘↩ (výběr nebo celý skript)",
    },
}
for _lang, _items in ((lang, {key: table[lang] for key, table in RUN_STOP.items() if lang in table})
                      for lang in {l for t in RUN_STOP.values() for l in t}):
    MANUAL.setdefault(_lang, {}).update(_items)

# The Space key is translated as outer space by machine translation, and a few
# button labels need the shorter form.
SHORTCUT_MANUAL = {
    "en": {"Пробел": "Space"},
    "es": {"Пробел": "Espacio"},
    "pt": {"Пробел": "Espaço"},
    "fr": {"Пробел": "Espace"},
    "de": {"Пробел": "Leertaste", "По умолчанию": "Standard",
           "Нажмите сочетание…": "Tastenkürzel drücken…"},
    "it": {"Пробел": "Spazio", "Вернуть по умолчанию": "Ripristina valore predefinito"},
    "nl": {"Пробел": "Spatie"},
    "pl": {"Пробел": "Spacja"},
    "tr": {"Пробел": "Boşluk"},
    "ar": {"Пробел": "مسافة"},
    "hi": {"Пробел": "स्पेस"},
    "zh-Hans": {"Пробел": "空格"},
    "zh-Hant": {"Пробел": "空格"},
    "ja": {"Пробел": "スペース", "Нажмите сочетание…": "キーを押してください…"},
    "ko": {"Пробел": "스페이스"},
    "id": {"Пробел": "Spasi"},
    "vi": {"Пробел": "Dấu cách"},
    "th": {"Пробел": "สเปซ"},
    "sv": {"Пробел": "Mellanslag"},
    "cs": {"Пробел": "Mezerník"},
}
for _lang, _items in SHORTCUT_MANUAL.items():
    MANUAL.setdefault(_lang, {}).update(_items)

# SQL text must stay SQL in every language.
VERBATIM = {"SELECT таблицы"}


def translate_batch(texts: list[str], lang: str, source: str = "ru") -> list[str] | None:
    separator = "\n␞\n"
    query = separator.join(texts)
    url = ("https://translate.googleapis.com/translate_a/single?client=gtx"
           f"&sl={source}&tl={lang}&dt=t&q=" + urllib.parse.quote(query))
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                data = json.load(response)
            joined = "".join(seg[0] for seg in data[0] if seg and seg[0])
            parts = joined.split("␞")
            if len(parts) != len(texts):
                return None
            return [normalize(part.strip("\n")) for part in parts]
        except Exception as error:  # noqa: BLE001 - retry any network failure
            if attempt == 3:
                print(f"  ! {lang}: {error}", file=sys.stderr)
                return None
            time.sleep(1.5 * (attempt + 1))
    return None


def main() -> int:
    keys = collect()
    print(f"UI strings: {len(keys)}")

    cache: dict[str, dict[str, str]] = {}
    if CACHE.exists():
        cache = json.loads(CACHE.read_text(encoding="utf-8"))

    for code, google in LANGS.items():
        if code in ("ru", "uk"):
            continue
        table = cache.setdefault(code, {})
        missing = [k for k in keys if k not in table]
        if not missing:
            print(f"{code}: cached")
            continue
        batches = [missing[i:i + 20] for i in range(0, len(missing), 20)]
        print(f"{code}: {len(missing)} strings, {len(batches)} requests")

        def work(batch: list[str]):
            result = translate_batch(batch, google)
            if result is None:
                # One bad string must not drop the whole batch.
                for single in batch:
                    one = translate_batch([single], google)
                    if one:
                        with_lock(one[0], single)
            else:
                for source, translated in zip(batch, result):
                    with_lock(translated, source)

        import threading
        lock = threading.Lock()

        def with_lock(translated: str, source: str):
            with lock:
                table[source] = translated

        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(work, batches))

        CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=1) + "\n",
                         encoding="utf-8")

    # Second pass: short UI terms translated from explicit English phrases.
    en_cache = cache.setdefault("_en", {})
    for code, google in LANGS.items():
        if code in ("ru", "uk"):
            continue
        table = en_cache.setdefault(code, {})
        needed = [k for k in EN_OVERRIDES if k in keys and k not in table]
        if not needed:
            continue
        batches = [needed[i:i + 20] for i in range(0, len(needed), 20)]
        print(f"{code}: {len(needed)} refined terms")

        def refine(batch: list[str]):
            english = [EN_OVERRIDES[k] for k in batch]
            result = translate_batch(english, google, source="en")
            if result is None:
                return
            with lock2:
                for key, value in zip(batch, result):
                    table[key] = normalize(value)

        import threading
        lock2 = threading.Lock()
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(refine, batches))
        CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=1) + "\n",
                         encoding="utf-8")

    # Write the packs.
    for code in LANGS:
        folder = RESOURCES / f"{code}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        lines = ['/* Generated by Scripts/localize.py — do not edit by hand. */', ""]
        for key in keys:
            if code == "ru":
                value = key
            elif code == "uk":
                value = key
            else:
                value = MANUAL.get(code, {}).get(key) \
                    or cache.get("_en", {}).get(code, {}).get(key) \
                    or cache.get(code, {}).get(key)
            if value is None:
                continue
            if key in VERBATIM:
                value = EN_OVERRIDES.get(key, key)
            if key[:1].isupper() and value[:1].islower():
                value = value[:1].upper() + value[1:]
            lines.append(f'"{strings_escape(key)}" = "{strings_escape(value)}";')
        (folder / "Localizable.strings").write_text("\n".join(lines) + "\n",
                                                   encoding="utf-8")
        print(f"{code}: {len(keys)} strings -> {folder.name}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
