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
import unicodedata
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
    "Найти в результате": "Search in result",
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
    "Загружено %@ строк…": "%@ rows loaded…",
    "Загрузка всех строк…": "Loading all rows…",
    "Загружены не все данные": "Not all data is loaded",
    "Загрузить полностью": "Load all rows",
    "Загрузить все": "Load all",
    "Догрузить следующую страницу строк": "Load the next page of rows",
    "Загрузить все оставшиеся строки": "Load all remaining rows",
    "Экспортировать имеющиеся": "Export loaded rows",
    "Загружено %@ строк из %@. Загрузить полностью или экспортировать имеющиеся?": "%@ of %@ rows loaded. Load all rows or export the loaded ones?",
    "Выделена часть данных": "Part of the data is selected",
    "Экспортировать выделенный фрагмент?": "Export the selected fragment?",
    "Экспортировать выделенное": "Export selection",
    "Нет": "No",
    "Загружено %@ строк, но не все. Загрузить полностью или экспортировать имеющиеся?": "%@ rows loaded, but not all. Load all rows or export the loaded ones?",
    "Экспорт XLSX…": "Export XLSX…",
    "Экспорт в XLSX (⌃⇧⌘E)": "Export to XLSX (⌃⇧⌘E)",
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
    "Готово. %@ · %@ мс": "Done. %@ · %@ ms",
    "Строк: %@ из %@": "Rows: %@ of %@",
    "Строк: %@%@": "Rows: %@%@",
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
    "Управление": "Controls",

    # Copy dialog.
    "Display (по умолчанию)": "Display (default)",
    "Редактируемое": "Editable",
    "Как в базе": "Database native",
    # Time zone cities: the picker shows the place name, so it has to be a
    # real English name rather than a transliteration of the Russian one.
    "Гонолулу": "Honolulu",
    "Анкоридж": "Anchorage",
    "Лос-Анджелес": "Los Angeles",
    "Денвер": "Denver",
    "Чикаго": "Chicago",
    "Нью-Йорк": "New York",
    "Каракас": "Caracas",
    "Буэнос-Айрес": "Buenos Aires",
    "Лондон": "London",
    "Берлин": "Berlin",
    "Каир": "Cairo",
    "Калининград": "Kaliningrad",
    "Москва": "Moscow",
    "Стамбул": "Istanbul",
    "Дубай": "Dubai",
    "Самара": "Samara",
    "Екатеринбург": "Yekaterinburg",
    "Дели": "Delhi",
    "Омск": "Omsk",
    "Новосибирск": "Novosibirsk",
    "Бангкок": "Bangkok",
    "Красноярск": "Krasnoyarsk",
    "Иркутск": "Irkutsk",
    "Пекин": "Beijing",
    "Якутск": "Yakutsk",
    "Токио": "Tokyo",
    "Владивосток": "Vladivostok",
    "Магадан": "Magadan",
    "Камчатка": "Kamchatka",
    "Апиа": "Apia",
    "Киритимати": "Kiritimati",

    # Tooltips.
    "Создать новое подключение": "Create a new connection",
    "Подключение к базе: зелёный — активно, серый — нет": "Database connection: green — active, grey — none",
    "Состояние выполнения: готово, выполняется, ошибка": "Run state: ready, running, error",
    "Загрузить все строки": "Load all rows",
    "Текущее подключение скрипта: имя и тип базы": "Current script connection: name and database type",
    "Искать по тексту запроса или имени подключения": "Search by query text or connection name",
    "Открыть запрос в редакторе": "Open the query in the editor",
    "Выделить весь результат": "Select the whole result",
    "Нажмите, чтобы выделить строку; ⌘ — добавить, ⇧ — диапазон": "Click to select a row; ⌘ — add, ⇧ — range",
    "Открыть вкладку": "Open the tab",
    "Язык интерфейса; применяется после перезапуска": "Interface language; applies after restart",
    "Размер шрифта в редакторе SQL": "Font size in the SQL editor",
    "Автоматически выделять первый параметр в WHERE при открытии скрипта": "Automatically select the first WHERE parameter when a script opens",
    "Выделять параметр только при открытии через поиск (⌘E)": "Select the parameter only when opened via search (⌘E)",
    "Включает комментирование строк по ключу в конце строки": "Enables commenting lines by a key at the end of the line",
    "Продолжение ключа после «--»; пустое значение отключает комбинацию": "Key suffix after «--»; an empty value disables the shortcut",
    "Следить за изменениями открытых файлов и предлагать перезагрузить версию с диска": "Watch open files and offer to reload the version from disk",
    "Шрифт таблицы результатов": "Result grid font",
    "Размер шрифта таблицы результатов": "Result grid font size",
    "Показывать тип данных рядом с именем столбца": "Show the data type next to the column name",
    "Показывать тип данных во всплывающей подсказке заголовка": "Show the data type in the column header tooltip",
    "Подбирать ширину столбцов по содержимому": "Fit column widths to their content",
    "Предел автоматической ширины столбца в pt": "Automatic column width limit in pt",
    "Изменить предел ширины столбца": "Change the column width limit",
    "Пояс, в котором показываются значения timestamp": "Time zone used for timestamp values",
    "Сколько строк запрашивать за один раз": "How many rows to fetch at a time",
    "Изменить размер страницы": "Change the page size",
    "Сохранять вкладки и их текст в tabs.json между запусками": "Save tabs and their text to tabs.json between launches",
    "Срок хранения истории запросов": "Query history retention period",
    "Каталог с файлом config для SSH-подключений": "Directory with the config file for SSH connections",
    "Тип базы данных": "Database type",
    "EZ Connect, TNS или LDAP": "EZ Connect, TNS or LDAP",
    "Хранить пароль в зашифрованном виде в связке ключей": "Store the password encrypted in the keychain",
    "Использовать SID вместо имени сервиса": "Use SID instead of the service name",
    "Подключаться к базе через SSH-туннель": "Connect to the database through an SSH tunnel",
    "Выбрать файл приватного ключа SSH": "Choose the SSH private key file",
    "Использовать SSL для LDAP": "Use SSL for LDAP",
    "Порт сервера базы данных": "Database server port",
    "Имя пользователя базы данных": "Database user name",
    "Пароль пользователя базы данных": "Database user password",
    "Добавлять строку с именами столбцов": "Add a row with column names",
    "Добавлять номера строк результата": "Add result row numbers",
    "Оборачивать значения в кавычки при необходимости": "Quote values when needed",
    "Оборачивать в кавычки все значения без исключения": "Quote every value without exception",
    "Копировать в формате HTML для вставки в таблицы": "Copy as HTML for pasting into tables",
    "Как форматировать NULL и пустые значения": "How to format NULL and empty values",
    "Скопировать выделение с этими настройками": "Copy the selection with these settings",
    "Разрешить вставку нескольких строк за один раз": "Allow inserting multiple rows at once",
    "Не считать кавычки частью значения": "Do not treat quotes as part of the value",
    "Пустые значения записывать как NULL": "Write empty values as NULL",
    "Вставить данные с этими настройками": "Paste data with these settings",
    "Сбросить все сочетания к стандартным": "Reset all shortcuts to defaults",
    "Кальк": "Calc",
    "Калькулятор": "Calculator",
    "Открыть калькулятор": "Open calculator",
    "Закрыть калькулятор": "Close calculator",
    "Выражение": "Expression",
    "Вычислить": "Calculate",
    "Вычислить выражение": "Evaluate the expression",
    "Вставить значение": "Insert value",
    "Добавить значение выбранной ячейки в выражение": "Add the selected cell value to the expression",
    "Очистить выражение и результат": "Clear the expression and result",
    "Удалить историю вычислений": "Clear the calculation history",
    "Подставить это выражение": "Use this expression",
    "Например: (12,5 + 3) * 2": "For example: (12.5 + 3) * 2",
    "Поддерживаются + − * / % ^, скобки, sqrt, abs, sin, cos, ln, log, min, max.": "Supports + − * / % ^, parentheses, sqrt, abs, sin, cos, ln, log, min, max.",
    "Деление на ноль": "Division by zero",
    "Ожидалось число": "A number was expected",
    "Не закрыта скобка": "Unclosed parenthesis",
    "Неизвестное имя: %@": "Unknown name: %@",
    "Неизвестная функция: %@": "Unknown function: %@",
    "Неверное число аргументов: %@": "Wrong number of arguments: %@",
    "Лишние символы в выражении": "Unexpected characters in the expression",
    "Результат не является числом": "The result is not a number",
    "Не удалось вычислить выражение": "Could not evaluate the expression",
    "Панель фильтра": "Filter panel",
    "Панель фильтра результата": "Result filter panel",
    "Показать или скрыть панель фильтра": "Show or hide the filter panel",
    "Показывать панель фильтра над таблицей результатов": "Show the filter panel above the result grid",
    "Панель фильтра показана": "Filter panel shown",
    "Панель фильтра скрыта": "Filter panel hidden",
    "Скрыть панель фильтра (включается в настройках)": "Hide the filter panel (enabled in Settings)",
    "Фильтр": "Filter",
    "Условие…": "Condition…",
    "Например: 42, > 10, LIKE '%text%', NULL. Пусто — без условия.": "For example: 42, > 10, LIKE '%text%', NULL. Empty means no condition.",
    "Снять все условия фильтра": "Remove all filter conditions",
    "Фильтры очищены": "Filters cleared",
    "· %@ из %@": "· %@ of %@",
    "Показать выбранную строку вертикально (Tab)": "Show the selected row vertically (Tab)",
    "Строка вертикально / таблица": "Row vertically / grid",
    "Строка №%@": "Row #%@",
    "из %@": "of %@",
    "Нет строк для показа": "No rows to show",
    "Вернуться к таблице результатов (Tab)": "Back to the result grid (Tab)",
    "Tab — вернуться к таблице": "Tab — back to the grid",
    "Уникальный ключ": "Unique key",
    "Уникальный ключ не определён": "Unique key not determined",
    "Уникальный ключ: %@(%@)": "Unique key: %@(%@)",
}

# Strings produced by computed properties rather than literal views.
EXTRA_KEYS = ["1 неделя", "1 месяц", "3 месяца", "6 месяцев", "1 год", "Бессрочно"]

# Time-zone codes from TimeZones.swift mapped to the Russian city name they
# abbreviate. The code is a localization key: the pack for every language
# holds the abbreviation of that language's city name.
ZONE_CODES = {
    "ГОН": "Гонолулу", "АНК": "Анкоридж", "ЛОС": "Лос-Анджелес",
    "ДЕН": "Денвер", "ЧИК": "Чикаго", "НЬЮ": "Нью-Йорк",
    "КАР": "Каракас", "БУЭ": "Буэнос-Айрес", "ЛОН": "Лондон",
    "БЕР": "Берлин", "КАИ": "Каир", "КЛГ": "Калининград",
    "МСК": "Москва", "СТА": "Стамбул", "ДУБ": "Дубай",
    "САМ": "Самара", "ЕКБ": "Екатеринбург", "ДЕЛ": "Дели",
    "ОМС": "Омск", "НСК": "Новосибирск", "БАН": "Бангкок",
    "КРС": "Красноярск", "ИРК": "Иркутск", "ПЕК": "Пекин",
    "ЯКТ": "Якутск", "ТОК": "Токио", "ВЛД": "Владивосток",
    "МАГ": "Магадан", "КАМ": "Камчатка", "АПИ": "Апиа",
    "КИР": "Киритимати",
}
EXTRA_KEYS += list(ZONE_CODES)

# Names that are already abbreviations or proper names should not be
# abbreviated from the first three letters.
ZONE_ABBREV_OVERRIDES = {
    # An article in the city name would otherwise leak into the code.
    "es": {"КАИ": "CAI"},
    "fr": {"КАИ": "CAI"},
    "it": {"КАИ": "CAI"},
    "ar": {"КАИ": "قاه"},
    # Two cities in one language start with the same three letters.
    "pl": {"НСК": "NWS"},
    "pt": {"НЬЮ": "NYC"},
    "vi": {"ЛОН": "LON"},
    "ja": {"КЛГ": "カリ"},
    # Thai clusters are not three code points long; the codes are written
    # the way the city is shortened in Thai.
    "th": {
        "ГОН": "โฮน", "АНК": "แอง", "ЛОС": "ลอส", "ДЕН": "เดน",
        "ЧИК": "ชิค", "НЬЮ": "นิว", "КАР": "คาร", "БУЭ": "บัว",
        "ЛОН": "ลอน", "БЕР": "เบอ", "КАИ": "ไคร", "КЛГ": "คาล",
        "МСК": "มอส", "СТА": "อิส", "ДУБ": "ดูไบ", "САМ": "ซาม",
        "ЕКБ": "เยค", "ДЕЛ": "เดล", "ОМС": "ออม", "НСК": "โนโว",
        "БАН": "กทม", "КРС": "ครส", "ИРК": "อีร์", "ПЕК": "ปัก",
        "ЯКТ": "ยาค", "ТОК": "โตก", "ВЛД": "วลา", "МАГ": "มาก",
        "КАМ": "คัม", "АПИ": "อาป", "КИР": "คีร",
    },
}

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


def zone_abbrev(name: str, lang: str) -> str:
    """Three-character code made from the city name in this language.

    Latin and Cyrillic names use their first three letters, CJK and Arabic
    their first three characters, Devanagari its first two syllables. Latin
    diacritics are dropped: a status-bar code reads better as `PEK` than as
    `PÉK`.
    """
    name = name.split(" (")[0].strip()
    if any(unicodedata.name(c, "").startswith("DEVANAGARI") for c in name):
        clusters = []
        i = 0
        while i < len(name):
            char = name[i]
            if not (char.isalpha() or unicodedata.category(char).startswith("M")):
                i += 1
                continue
            cluster = char
            i += 1
            while i < len(name):
                category = unicodedata.category(name[i])
                if not category.startswith("M"):
                    break
                cluster += name[i]
                i += 1
                # A virama joins the next consonant into the same syllable.
                if name[i - 1] == "\u094d" and i < len(name) and name[i].isalpha():
                    cluster += name[i]
                    i += 1
            clusters.append(cluster)
        return "".join(clusters[:2]).rstrip("\u094d").upper()
    chars = [c for c in name if c.isalpha()
             or unicodedata.category(c).startswith("M")]
    code = "".join(chars[:3]).upper()
    if lang == "th":
        return code
    out = []
    for char in code:
        if unicodedata.name(char, "").startswith("LATIN"):
            base = "".join(x for x in unicodedata.normalize("NFD", char)
                           if not unicodedata.combining(x))
            out.append({"Đ": "D", "Ł": "L", "Ø": "O", "Æ": "AE"}.get(base, base))
        else:
            out.append(char)
    return "".join(out)


def collect() -> list[str]:
    found: set[str] = set()
    for path in (ROOT / "Sources").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        # Comments contain example strings such as `"ghbkf" finds "Прила"`;
        # they are documentation, not UI, and must not reach the packs.
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"(?m)^\s*//.*$", "", text)
        for match in LITERAL.finditer(text):
            raw = match.group(1)
            if "\\(" in raw:
                continue
            value = unescape(raw)
            # One-character literals are the keyboard-layout tables in
            # SearchMatcher, not labels.
            if len(value.strip()) <= 1:
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
    "de": {
        "История": "Verlauf", "История пуста": "Der Verlauf ist leer",
        "Комментирование по специальному ключу": "Kommentieren mit einem Sonderschlüssel",
        "Комментирование по специальному ключу включено": "Kommentieren mit einem Sonderschlüssel ist aktiviert",
        "Комментирование по специальному ключу выключено": "Kommentieren mit einem Sonderschlüssel ist deaktiviert",
        "Комментировать по специальному ключу": "Mit einem Sonderschlüssel kommentieren",
        "Ключ состоит из фиксированного «--» и любого продолжения. Строка считается помеченной, если ключ стоит в самом конце строки; пустое продолжение отключает сочетание.": "Der Schlüssel besteht aus einem festen „--“ und einer beliebigen Fortsetzung. Eine Zeile gilt als markiert, wenn der Schlüssel ganz am Ende der Zeile steht; eine leere Fortsetzung deaktiviert die Kombination.",
    },
    "fr": {"История": "Historique", "История пуста": "L’historique est vide"},
    "es": {"История": "Historial", "История пуста": "El historial está vacío",
           "Найти в результате": "Buscar en el resultado"},
    "it": {"История": "Cronologia", "История пуста": "La cronologia è vuota"},
    "nl": {"История": "Geschiedenis", "История пуста": "De geschiedenis is leeg"},
    "pl": {"История": "Historia", "История пуста": "Historia jest pusta"},
    "tr": {"История": "Geçmiş", "История пуста": "Geçmiş boş"},
    "ar": {"История": "السجل", "История пуста": "السجل فارغ"},
    "hi": {"История": "इतिहास", "История пуста": "इतिहास खाली है"},
    "zh-Hans": {
        "История": "历史", "История пуста": "历史为空",
        "Комментирование по специальному ключу": "按特殊键注释",
        "Комментирование по специальному ключу включено": "已启用按特殊键注释",
        "Комментирование по специальному ключу выключено": "已关闭按特殊键注释",
        "Комментировать по специальному ключу": "按特殊键注释",
        "Ключ:": "键：",
        "Специальным ключом можно пометить строку или строки: сочетание %@ комментирует и раскомментирует все такие строки сразу, не трогая остальной скрипт.": "可以用特殊键标记一行或多行：%@ 组合会一次性注释或取消注释所有这些行，而不影响脚本的其余部分。",
        "Ключ состоит из фиксированного «--» и любого продолжения. Строка считается помеченной, если ключ стоит в самом конце строки; пустое продолжение отключает сочетание.": "键由固定的“--”和任意后续内容组成。如果键位于行末，则该行被视为已标记；后续内容为空时会禁用该组合。",
    },
    "zh-Hant": {
        "История": "歷史", "История пуста": "歷史是空的",
        "Комментирование по специальному ключу": "使用特殊鍵加入註解",
        "Комментирование по специальному ключу включено": "已啟用使用特殊鍵加入註解",
        "Комментирование по специальному ключу выключено": "已關閉使用特殊鍵加入註解",
        "Комментировать по специальному ключу": "使用特殊鍵加入註解",
        "Ключ:": "鍵：",
        "Специальным ключом можно пометить строку или строки: сочетание %@ комментирует и раскомментирует все такие строки сразу, не трогая остальной скрипт.": "您可以使用特殊鍵標記一行或多行：%@ 組合會一次註解或取消註解所有這些行，而不影響指令碼的其餘部分。",
        "Ключ состоит из фиксированного «--» и любого продолжения. Строка считается помеченной, если ключ стоит в самом конце строки; пустое продолжение отключает сочетание.": "鍵由固定的「--」和任意後續內容組成。如果鍵位於行尾，則該行視為已標記；後續內容為空時會停用該組合。",
    },
    "ja": {"История": "履歴", "История пуста": "履歴は空です",
           "Найти в результате": "結果内を検索"},
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

# "Controls" is machine-translated as "checks" or "UI widgets" in some
# languages; the settings section needs the "operation" sense.
SECTION_MANUAL = {
    "de": {"Управление": "Bedienung"},
    "pl": {"Управление": "Sterowanie"},
    "cs": {"Управление": "Ovládání"},
    "ko": {"Управление": "제어"},
    "sv": {"Управление": "Styrning"},
    "tr": {"Управление": "Denetim"},
}
for _lang, _items in SECTION_MANUAL.items():
    MANUAL.setdefault(_lang, {}).update(_items)

# City names where the machine translation picked a common noun ("anchorage"
# → "Ankerplatz") or a grammatical case ("Berlinie"). Proper place names are
# spelled the way each language's maps spell them.
CITY_FIXES = {
    "ar": {"Анкоридж": "أنكوريج"},
    "cs": {"Анкоридж": "Anchorage"},
    "de": {"Анкоридж": "Anchorage"},
    "es": {"Анкоридж": "Anchorage", "Буэнос-Айрес": "Buenos Aires",
           "Самара": "Samara"},
    "fr": {"Анкоридж": "Anchorage"},
    "id": {"Анкоридж": "Anchorage", "Москва": "Moskwa", "Стамбул": "Istanbul"},
    "it": {"Анкоридж": "Anchorage"},
    "nl": {"Анкоридж": "Anchorage"},
    "pl": {"Анкоридж": "Anchorage", "Берлин": "Berlin"},
    "pt": {"Анкоридж": "Anchorage"},
    "sv": {"Анкоридж": "Anchorage"},
    "tr": {"Анкоридж": "Anchorage", "Гонолулу": "Honolulu"},
    "vi": {"Анкоридж": "Anchorage"},
    "zh-Hans": {"Камчатка": "堪察加", "Владивосток": "符拉迪沃斯托克"},
    "zh-Hant": {"Камчатка": "堪察加", "Владивосток": "符拉迪沃斯托克"},
}
for _lang, _items in CITY_FIXES.items():
    MANUAL.setdefault(_lang, {}).update(_items)

# "Monospaced" is a typography term machine translation renders as "equal
# space" or "single space" in several languages.
FONT_MANUAL = {
    "ar": {"Системный моноширинный": "خط النظام أحادي المسافة",
           "системный моноширинный": "خط النظام أحادي المسافة"},
    "ja": {"Системный моноширинный": "システム等幅",
           "системный моноширинный": "システム等幅"},
    "pl": {"Системный моноширинный": "Systemowa czcionka o stałej szerokości",
           "системный моноширинный": "systemowa czcionka o stałej szerokości"},
    "th": {"Системный моноширинный": "โมโนสเปซของระบบ",
           "системный моноширинный": "โมโนสเปซของระบบ"},
    "tr": {"Системный моноширинный": "Sistem tek aralıklı yazı tipi",
           "системный моноширинный": "sistem tek aralıklı yazı tipi"},
    "vi": {"Системный моноширинный": "Monospace hệ thống",
           "системный моноширинный": "monospace hệ thống"},
    "sv": {"Системный моноширинный": "Systemets monospace",
           "системный моноширинный": "systemets monospace"},
}
for _lang, _items in FONT_MANUAL.items():
    MANUAL.setdefault(_lang, {}).update(_items)

# SQL text must stay SQL in every language.
# Strings that are identical in every language.
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
        missing = [k for k in keys if k not in table
                   and k not in ZONE_CODES and k not in VERBATIM]
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
        resolved: dict[str, str | None] = {}
        for key in keys:
            if code in ("ru", "uk"):
                value = key
            else:
                value = MANUAL.get(code, {}).get(key) \
                    or cache.get("_en", {}).get(code, {}).get(key) \
                    or cache.get(code, {}).get(key)
            if key in VERBATIM:
                value = EN_OVERRIDES.get(key, key)
            if value is not None and key[:1].isupper() and value[:1].islower():
                value = value[:1].upper() + value[1:]
            resolved[key] = value
        # The city codes abbreviate the city name in the same language, so
        # they are computed after all names are resolved.
        for ru_code, city_key in ZONE_CODES.items():
            if code in ("ru", "uk"):
                resolved[ru_code] = ru_code
                continue
            city = resolved.get(city_key)
            resolved[ru_code] = (ZONE_ABBREV_OVERRIDES.get(code, {}).get(ru_code)
                                 or (zone_abbrev(city, code) if city else None))
        for key in keys:
            value = resolved.get(key)
            if value is None:
                continue
            lines.append(f'"{strings_escape(key)}" = "{strings_escape(value)}";')
        (folder / "Localizable.strings").write_text("\n".join(lines) + "\n",
                                                   encoding="utf-8")
        print(f"{code}: {len(keys)} strings -> {folder.name}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
