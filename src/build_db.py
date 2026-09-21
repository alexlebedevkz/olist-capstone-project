"""Воспроизводимая сборка SQLite-базы Olist из сырых CSV.

Запуск из корня проекта:

    python src/build_db.py                 # собрать db/olist.db заново
    python src/build_db.py --check-only    # только проверки на готовой базе

Скрипт идемпотентен: sql/01_schema.sql начинается с DROP TABLE, поэтому
повторный запуск даёт ту же базу, а не удваивает строки.

Что здесь делается руками, а не средствами pandas.to_sql по умолчанию:

* таблицы создаются из sql/01_schema.sql, то есть с PK, FK и индексами —
  to_sql без схемы создал бы плоские таблицы без ключей;
* все идентификаторы и zip-префиксы читаются как строки: zip-коды Бразилии
  имеют ведущие нули (01037), и автоопределение типов превратило бы их
  в 1037;
* даты нормализуются к 'YYYY-MM-DD HH:MM:SS' — в этом виде в SQLite
  работают сравнения, julianday() и strftime();
* порядок загрузки учитывает внешние ключи, а FK-контроль включён,
  так что нарушение связей упадёт здесь, а не всплывёт на витрине.
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import time
from pathlib import Path

import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"
DB_PATH = PROJECT_ROOT / "db" / "olist.db"
SCHEMA_PATH = PROJECT_ROOT / "sql" / "01_schema.sql"

# Категории, встречающиеся в products, но отсутствующие в исходном файле
# переводов. Известный дефект датасета: без этих двух строк ломается FK
# products -> category_translation и «теряются» 13 товаров.
MISSING_TRANSLATIONS = {
    "pc_gamer": "pc_gamer",
    "portateis_cozinha_e_preparadores_de_alimentos": (
        "portable_kitchen_and_food_preparers"
    ),
}


class TableSpec:
    """Описание одной таблицы: откуда читать, как типизировать, куда класть."""

    def __init__(
        self,
        table: str,
        csv_name: str,
        *,
        text_cols: tuple[str, ...] = (),
        int_cols: tuple[str, ...] = (),
        float_cols: tuple[str, ...] = (),
        date_cols: tuple[str, ...] = (),
        encoding: str = "utf-8",
    ) -> None:
        self.table = table
        self.csv_name = csv_name
        self.text_cols = text_cols
        self.int_cols = int_cols
        self.float_cols = float_cols
        self.date_cols = date_cols
        self.encoding = encoding


# Порядок важен: родительские таблицы грузятся раньше дочерних,
# иначе FK-проверка отвергнет вставку.
TABLES: list[TableSpec] = [
    TableSpec(
        "category_translation",
        "product_category_name_translation.csv",
        text_cols=("product_category_name", "product_category_name_english"),
        # у файла переводов BOM в начале — без utf-8-sig первая колонка
        # получает имя '﻿product_category_name'
        encoding="utf-8-sig",
    ),
    TableSpec(
        "customers",
        "olist_customers_dataset.csv",
        text_cols=(
            "customer_id",
            "customer_unique_id",
            "customer_zip_code_prefix",
            "customer_city",
            "customer_state",
        ),
    ),
    TableSpec(
        "sellers",
        "olist_sellers_dataset.csv",
        text_cols=(
            "seller_id",
            "seller_zip_code_prefix",
            "seller_city",
            "seller_state",
        ),
    ),
    TableSpec(
        "products",
        "olist_products_dataset.csv",
        text_cols=("product_id", "product_category_name"),
        int_cols=(
            "product_name_lenght",
            "product_description_lenght",
            "product_photos_qty",
        ),
        float_cols=(
            "product_weight_g",
            "product_length_cm",
            "product_height_cm",
            "product_width_cm",
        ),
    ),
    TableSpec(
        "orders",
        "olist_orders_dataset.csv",
        text_cols=("order_id", "customer_id", "order_status"),
        date_cols=(
            "order_purchase_timestamp",
            "order_approved_at",
            "order_delivered_carrier_date",
            "order_delivered_customer_date",
            "order_estimated_delivery_date",
        ),
    ),
    TableSpec(
        "order_items",
        "olist_order_items_dataset.csv",
        text_cols=("order_id", "product_id", "seller_id"),
        int_cols=("order_item_id",),
        float_cols=("price", "freight_value"),
        date_cols=("shipping_limit_date",),
    ),
    TableSpec(
        "order_payments",
        "olist_order_payments_dataset.csv",
        text_cols=("order_id", "payment_type"),
        int_cols=("payment_sequential", "payment_installments"),
        float_cols=("payment_value",),
    ),
    TableSpec(
        "order_reviews",
        "olist_order_reviews_dataset.csv",
        text_cols=(
            "review_id",
            "order_id",
            "review_comment_title",
            "review_comment_message",
        ),
        int_cols=("review_score",),
        date_cols=("review_creation_date", "review_answer_timestamp"),
    ),
    TableSpec(
        "geolocation",
        "olist_geolocation_dataset.csv",
        text_cols=(
            "geolocation_zip_code_prefix",
            "geolocation_city",
            "geolocation_state",
        ),
        float_cols=("geolocation_lat", "geolocation_lng"),
    ),
]

# Ожидаемое число строк в каждой таблице — фиксируем факты из раздела 2
# плана, чтобы молча испорченная загрузка не прошла незамеченной.
EXPECTED_ROWS = {
    "category_translation": 71,
    "customers": 99_441,
    "sellers": 3_095,
    "products": 32_951,
    "orders": 99_441,
    "order_items": 112_650,
    "order_payments": 103_886,
    "order_reviews": 99_224,
    "geolocation": 1_000_163,
}


def log(message: str) -> None:
    # Консоль Windows живёт в cp1251/cp866: символ, которого нет в кодовой
    # странице, роняет print. Терять из-за этого собранную базу нельзя.
    try:
        print(message, flush=True)
    except UnicodeEncodeError:
        encoding = sys.stdout.encoding or "ascii"
        print(message.encode(encoding, "replace").decode(encoding), flush=True)


def read_table(spec: TableSpec) -> pd.DataFrame:
    """Читает CSV в строковом виде и приводит колонки к целевым типам."""
    csv_path = RAW_DIR / spec.csv_name
    if not csv_path.exists():
        raise FileNotFoundError(
            f"нет файла {csv_path}. Положите 9 CSV датасета Olist в data/raw/"
        )

    # dtype=str на чтении — единственный способ не потерять ведущие нули
    # в zip-префиксах и не превратить id в числа с плавающей точкой.
    df = pd.read_csv(csv_path, dtype=str, encoding=spec.encoding)

    for col in spec.text_cols:
        # пустая строка и строка из пробелов — это отсутствие значения,
        # а не значение: в базе должен быть NULL
        df[col] = df[col].str.strip().replace("", None)

    for col in spec.int_cols:
        df[col] = pd.to_numeric(df[col], errors="raise").astype("Int64")

    for col in spec.float_cols:
        df[col] = pd.to_numeric(df[col], errors="raise").astype("float64")

    for col in spec.date_cols:
        df[col] = normalize_dates(df[col], f"{spec.table}.{col}")

    return df


def normalize_dates(series: pd.Series, label: str) -> pd.Series:
    """Приводит колонку дат к ISO-строкам 'YYYY-MM-DD HH:MM:SS'.

    errors='raise' намеренно: молча превратить нераспознанную дату в NaT —
    значит потерять заказ на витрине и не узнать об этом.
    """
    parsed = pd.to_datetime(series, errors="raise")
    non_null_before = series.notna().sum()
    if parsed.notna().sum() != non_null_before:
        raise ValueError(f"{label}: часть дат не распозналась")
    # .dt.strftime сохраняет NaT как NaN -> в SQLite уйдёт NULL
    return parsed.dt.strftime("%Y-%m-%d %H:%M:%S")


def patch_translations(df: pd.DataFrame) -> pd.DataFrame:
    """Дописывает категории, которых нет в исходном файле переводов."""
    known = set(df["product_category_name"])
    additions = [
        {"product_category_name": name, "product_category_name_english": english}
        for name, english in MISSING_TRANSLATIONS.items()
        if name not in known
    ]
    if not additions:
        return df
    log(f"  + дописано категорий в справочник переводов: {len(additions)}")
    return pd.concat([df, pd.DataFrame(additions)], ignore_index=True)


def create_schema(conn: sqlite3.Connection) -> None:
    if not SCHEMA_PATH.exists():
        raise FileNotFoundError(f"нет файла схемы {SCHEMA_PATH}")
    log(f"Применяю схему {SCHEMA_PATH.relative_to(PROJECT_ROOT)}")
    conn.executescript(SCHEMA_PATH.read_text(encoding="utf-8"))
    conn.commit()


def load_tables(conn: sqlite3.Connection) -> None:
    for spec in TABLES:
        started = time.perf_counter()
        df = read_table(spec)
        if spec.table == "category_translation":
            df = patch_translations(df)

        df.to_sql(spec.table, conn, if_exists="append", index=False, chunksize=10_000)
        conn.commit()

        elapsed = time.perf_counter() - started
        log(f"  {spec.table:<22} {len(df):>9,} строк   {elapsed:>5.1f} с")


def run_checks(conn: sqlite3.Connection) -> bool:
    """Проверяет, что база собралась корректно. True — всё сошлось."""
    ok = True
    log("\nПроверки:")

    # 1. Число строк по таблицам
    for table, expected in EXPECTED_ROWS.items():
        actual = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        # справочник переводов дополняется на 2 строки сознательно
        expected_adj = expected + (
            len(MISSING_TRANSLATIONS) if table == "category_translation" else 0
        )
        mark = "ok" if actual == expected_adj else "РАСХОЖДЕНИЕ"
        if actual != expected_adj:
            ok = False
        log(f"  {table:<22} {actual:>9,}  (ожидалось {expected_adj:,})  {mark}")

    # 2. Целостность внешних ключей — сама СУБД, а не наши SELECT-ы
    violations = conn.execute("PRAGMA foreign_key_check").fetchall()
    if violations:
        ok = False
        log(f"  FK-нарушений: {len(violations)}  РАСХОЖДЕНИЕ")
        for row in violations[:5]:
            log(f"    {row}")
    else:
        log("  внешние ключи           без нарушений  ok")

    # 3. Даты читаются как даты: если формат хранения сломан,
    #    julianday() вернёт NULL и разница дат окажется пустой
    delivery = conn.execute(
        """
        SELECT COUNT(*),
               ROUND(AVG(julianday(order_delivered_customer_date)
                         - julianday(order_purchase_timestamp)), 2)
        FROM orders
        WHERE order_status = 'delivered'
          AND order_delivered_customer_date IS NOT NULL
        """
    ).fetchone()
    if delivery[1] is None:
        ok = False
        log("  арифметика дат           не работает  РАСХОЖДЕНИЕ")
    else:
        log(
            f"  доставленных заказов    {delivery[0]:>9,}  "
            f"средний срок доставки {delivery[1]} дн.  ok"
        )

    # 4. Целевая переменная: доля оценок 1-2 должна быть около 12,8 %
    #    (раздел 2 плана)
    target = conn.execute(
        """
        WITH first_review AS (
            SELECT order_id,
                   review_score,
                   ROW_NUMBER() OVER (
                       PARTITION BY order_id
                       ORDER BY review_creation_date, review_id
                   ) AS rn
            FROM order_reviews
        )
        SELECT COUNT(*),
               ROUND(100.0 * AVG(CASE WHEN r.review_score <= 2 THEN 1 ELSE 0 END), 1)
        FROM orders o
        JOIN first_review r ON r.order_id = o.order_id AND r.rn = 1
        WHERE o.order_status = 'delivered'
          AND o.order_delivered_customer_date IS NOT NULL
        """
    ).fetchone()
    log(
        f"  выборка для модели      {target[0]:>9,}  "
        f"доля оценок 1-2 звезды {target[1]} %"
    )

    # 5. Ведущие нули в zip-префиксах пережили загрузку
    zeros = conn.execute(
        "SELECT COUNT(*) FROM customers WHERE customer_zip_code_prefix LIKE '0%'"
    ).fetchone()[0]
    if zeros == 0:
        ok = False
        log("  ведущие нули в zip      потеряны  РАСХОЖДЕНИЕ")
    else:
        log(f"  zip с ведущим нулём     {zeros:>9,}  ok")

    return ok


def build(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if db_path.exists():
        log(f"Удаляю прежнюю базу {db_path.relative_to(PROJECT_ROOT)}")
        db_path.unlink()

    conn = sqlite3.connect(db_path)
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        # journal_mode/synchronous — только ради скорости разовой загрузки
        # миллиона строк geolocation; на аналитику они не влияют
        conn.execute("PRAGMA journal_mode = MEMORY")
        conn.execute("PRAGMA synchronous = OFF")

        create_schema(conn)
        log("Загружаю таблицы:")
        load_tables(conn)

        log("\nVACUUM + ANALYZE")
        conn.execute("ANALYZE")
        conn.commit()
        conn.execute("VACUUM")
    finally:
        conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Собирает db/olist.db из CSV в data/raw/"
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
        help="не пересобирать базу, только прогнать проверки",
    )
    args = parser.parse_args()

    started = time.perf_counter()

    if not args.check_only:
        build(args.db)
    elif not args.db.exists():
        log(f"Базы {args.db} нет — сначала запустите без --check-only")
        return 1

    conn = sqlite3.connect(args.db)
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        ok = run_checks(conn)
    finally:
        conn.close()

    size_mb = args.db.stat().st_size / 1024 / 1024
    log(
        f"\nГотово за {time.perf_counter() - started:.1f} с. "
        f"База: {args.db} ({size_mb:.1f} МБ)"
    )
    if not ok:
        log("ВНИМАНИЕ: часть проверок не прошла — смотрите пометки выше.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
