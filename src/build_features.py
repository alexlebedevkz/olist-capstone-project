"""Сборка витрины признаков order_features и проверки по ней.

Запуск из корня проекта:

    python src/build_features.py              # пересобрать витрину и проверить
    python src/build_features.py --check-only # только проверки готовой витрины
    python src/build_features.py --checks     # выполнить sql/02_checks.sql
                                              # (проверочные запросы по сырому слою)

Скрипт идемпотентен: sql/03_features.sql начинается с DROP TABLE.
Вся логика витрины живёт в SQL — здесь только запуск, контроль и вывод.
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DB_PATH = PROJECT_ROOT / "db" / "olist.db"
FEATURES_SQL = PROJECT_ROOT / "sql" / "03_features.sql"
CHECKS_SQL = PROJECT_ROOT / "sql" / "02_checks.sql"

# Факты из раздела 2 плана. Витрина должна воспроизводить их точно,
# иначе где-то потерялись или задвоились заказы.
EXPECTED_ROWS = 95_824
EXPECTED_TARGET_PCT = 12.8
TARGET_PCT_TOLERANCE = 0.2

# Поля, возникающие ПОСЛЕ точки отсечки. Если любое из них окажется
# в витрине — это утечка, и модель на ней не имеет смысла (раздел 1).
FORBIDDEN_COLUMNS = {
    "review_id",
    "review_creation_date",
    "review_answer_timestamp",
    "review_comment_title",
    "review_comment_message",
}

# Колонки, в которых пропусков быть не должно: на них держится
# и целевая переменная, и основной блок признаков.
REQUIRED_NOT_NULL = (
    "order_id",
    "target",
    "review_score",
    "delivery_days",
    "delay_vs_estimate_days",
    "is_late",
    "promised_window_days",
    "items_count",
    "items_price_total",
    "freight_total",
    "main_category",
    "customer_state",
)

# Маркер запроса в sql/02_checks.sql: "-- [Q1] Название"
QUERY_MARKER = re.compile(r"^--\s*\[(Q\d+)\]\s*(.*)$", re.MULTILINE)


def log(message: str) -> None:
    # Та же защита от cp1251-консоли Windows, что и в build_db.py:
    # символ вне кодовой страницы не должен ронять скрипт.
    try:
        print(message, flush=True)
    except UnicodeEncodeError:
        encoding = sys.stdout.encoding or "ascii"
        print(message.encode(encoding, "replace").decode(encoding), flush=True)


def connect(db_path: Path) -> sqlite3.Connection:
    if not db_path.exists():
        raise FileNotFoundError(
            f"нет базы {db_path} — сначала соберите её: python src/build_db.py"
        )
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def build_features(conn: sqlite3.Connection) -> None:
    if not FEATURES_SQL.exists():
        raise FileNotFoundError(f"нет файла {FEATURES_SQL}")
    log(f"Применяю {FEATURES_SQL.relative_to(PROJECT_ROOT)}")
    started = time.perf_counter()
    conn.executescript(FEATURES_SQL.read_text(encoding="utf-8"))
    conn.commit()
    conn.execute("ANALYZE")
    conn.commit()
    rows = conn.execute("SELECT COUNT(*) FROM order_features").fetchone()[0]
    cols = len(conn.execute("PRAGMA table_info(order_features)").fetchall())
    log(
        f"  order_features {rows:,} строк x {cols} колонок   "
        f"{time.perf_counter() - started:.1f} с"
    )


def split_named_queries(sql_text: str) -> list[tuple[str, str, str]]:
    """Разбивает файл проверок на блоки по маркерам '-- [Qn] Название'."""
    markers = list(QUERY_MARKER.finditer(sql_text))
    blocks = []
    for pos, marker in enumerate(markers):
        end = markers[pos + 1].start() if pos + 1 < len(markers) else len(sql_text)
        body = sql_text[marker.end() : end].strip().rstrip(";")
        if body:
            blocks.append((marker.group(1), marker.group(2).strip(), body))
    return blocks


def print_table(cursor: sqlite3.Cursor) -> None:
    """Печатает результат запроса выровненной таблицей."""
    rows = cursor.fetchall()
    headers = [d[0] for d in cursor.description]
    if not rows:
        log("    (пусто)")
        return

    table = [headers] + [["" if v is None else str(v) for v in row] for row in rows]
    widths = [max(len(row[col]) for row in table) for col in range(len(headers))]
    for pos, row in enumerate(table):
        log("    " + "  ".join(value.ljust(widths[i]) for i, value in enumerate(row)))
        if pos == 0:
            log("    " + "  ".join("-" * width for width in widths))


def run_raw_checks(conn: sqlite3.Connection) -> None:
    """Выполняет sql/02_checks.sql и печатает результаты."""
    if not CHECKS_SQL.exists():
        raise FileNotFoundError(f"нет файла {CHECKS_SQL}")
    blocks = split_named_queries(CHECKS_SQL.read_text(encoding="utf-8"))
    log(f"Проверочные запросы по сырому слою ({CHECKS_SQL.name}): {len(blocks)} шт.\n")
    for code, title, body in blocks:
        log(f"  [{code}] {title}")
        print_table(conn.execute(body))
        log("")


def check(ok: bool, passed: bool, message: str) -> bool:
    """Печатает строку отчёта и возвращает обновлённый общий флаг."""
    log(f"  {'ok        ' if passed else 'РАСХОЖДЕНИЕ'} {message}")
    return ok and passed


def run_feature_checks(conn: sqlite3.Connection) -> bool:
    """Проверяет витрину. True — всё сошлось."""
    exists = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'order_features'"
    ).fetchone()
    if not exists:
        log("Витрины order_features нет — запустите без --check-only")
        return False

    ok = True
    log("\nПроверки витрины:")

    # 1. Число строк совпадает с зафиксированным в плане
    rows = conn.execute("SELECT COUNT(*) FROM order_features").fetchone()[0]
    ok = check(
        ok,
        rows == EXPECTED_ROWS,
        f"строк {rows:,} (ожидалось {EXPECTED_ROWS:,})",
    )

    # 2. Одна строка на заказ
    unique = conn.execute(
        "SELECT COUNT(DISTINCT order_id) FROM order_features"
    ).fetchone()[0]
    ok = check(ok, unique == rows, f"уникальных order_id {unique:,} из {rows:,}")

    # 3. Витрина покрывает всю популяцию: заказ выпал только если нет отзыва
    lost = conn.execute(
        """
        SELECT COUNT(*) FROM orders o
        WHERE o.order_status = 'delivered'
          AND o.order_delivered_customer_date IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM order_features f WHERE f.order_id = o.order_id)
          AND EXISTS (SELECT 1 FROM order_reviews r WHERE r.order_id = o.order_id)
        """
    ).fetchone()[0]
    ok = check(ok, lost == 0, f"заказов с отзывом, потерянных на JOIN: {lost}")

    # 4. Доля целевого класса
    target_pct = conn.execute(
        "SELECT ROUND(100.0 * AVG(target), 1) FROM order_features"
    ).fetchone()[0]
    ok = check(
        ok,
        abs(target_pct - EXPECTED_TARGET_PCT) <= TARGET_PCT_TOLERANCE,
        f"доля класса 1 (оценка 1-2 звезды): {target_pct} % "
        f"(ожидалось {EXPECTED_TARGET_PCT} %)",
    )

    # 5. target согласован с review_score
    mismatch = conn.execute(
        """
        SELECT COUNT(*) FROM order_features
        WHERE target <> (CASE WHEN review_score <= 2 THEN 1 ELSE 0 END)
        """
    ).fetchone()[0]
    ok = check(ok, mismatch == 0, f"рассогласований target и review_score: {mismatch}")

    # 6. Запрет на признаки из будущего
    columns = {row[1] for row in conn.execute("PRAGMA table_info(order_features)")}
    leaks = sorted(columns & FORBIDDEN_COLUMNS)
    ok = check(
        ok,
        not leaks,
        "полей после точки отсечки нет" if not leaks else f"утечка: {', '.join(leaks)}",
    )

    # 7. Обязательные поля без пропусков
    null_counts = conn.execute(
        "SELECT "
        + ", ".join(f"SUM({col} IS NULL)" for col in REQUIRED_NOT_NULL)
        + " FROM order_features"
    ).fetchone()
    bad = [
        f"{col}={count}"
        for col, count in zip(REQUIRED_NOT_NULL, null_counts)
        if count
    ]
    ok = check(
        ok,
        not bad,
        "обязательные поля заполнены" if not bad else f"пропуски: {', '.join(bad)}",
    )

    # 8. Арифметика дат осмысленна: срок доставки положителен,
    #    а согласие is_late с delay_vs_estimate_days полное
    bad_delivery, late_mismatch = conn.execute(
        """
        SELECT SUM(delivery_days <= 0),
               SUM(is_late <> (delay_vs_estimate_days > 0))
        FROM order_features
        """
    ).fetchone()
    ok = check(ok, bad_delivery == 0, f"заказов с неположительным сроком доставки: {bad_delivery}")
    ok = check(ok, late_mismatch == 0, f"рассогласований is_late и опоздания: {late_mismatch}")

    # 9. Сводка по витрине — не проверка, а глазная сверка
    late_pct, avg_delivery, categories, months = conn.execute(
        """
        SELECT ROUND(100.0 * AVG(is_late), 1),
               ROUND(AVG(delivery_days), 1),
               COUNT(DISTINCT main_category),
               COUNT(DISTINCT purchase_year_month)
        FROM order_features
        """
    ).fetchone()
    log(
        f"  сводка      опоздавших {late_pct} %, средний срок доставки "
        f"{avg_delivery} дн., категорий {categories}, месяцев {months}"
    )

    # 10. Ключевая зависимость проекта: у опоздавших негатива кратно больше
    on_time_pct, late_target_pct = conn.execute(
        """
        SELECT ROUND(100.0 * AVG(CASE WHEN is_late = 0 THEN target END), 1),
               ROUND(100.0 * AVG(CASE WHEN is_late = 1 THEN target END), 1)
        FROM order_features
        """
    ).fetchone()
    ok = check(
        ok,
        late_target_pct > on_time_pct,
        f"негатив: в срок {on_time_pct} %, с опозданием {late_target_pct} %",
    )

    return ok


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Собирает витрину order_features в db/olist.db"
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=DB_PATH,
        help=f"путь к базе (по умолчанию {DB_PATH.relative_to(PROJECT_ROOT)})",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="не пересобирать витрину, только прогнать проверки",
    )
    parser.add_argument(
        "--checks",
        action="store_true",
        help="выполнить проверочные запросы sql/02_checks.sql и выйти",
    )
    args = parser.parse_args()

    started = time.perf_counter()
    conn = connect(args.db)
    try:
        if args.checks:
            run_raw_checks(conn)
            return 0

        if not args.check_only:
            build_features(conn)
        ok = run_feature_checks(conn)
    finally:
        conn.close()

    log(f"\nГотово за {time.perf_counter() - started:.1f} с.")
    if not ok:
        log("ВНИМАНИЕ: часть проверок не прошла — смотрите пометки выше.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
