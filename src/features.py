"""Признаки для блока ML, которые неудобно или нельзя посчитать в SQL.

Всё, что выражается декларативным SQL без риска утечки, уже сделано в
sql/03_features.sql (витрина order_features). Здесь — то, что требует
порядка по времени и раздельной статистики train/test:

* история продавца («прошлая доля негатива») — раздел 7.1 плана прямо
  предупреждает, что это сильный, но опасный признак: считать его можно
  только по заказам, предшествующим текущему, иначе утечка;
* заполнение пропусков медианой по категории и медианой по train —
  статистики должны считаться на train и применяться к test как есть,
  иначе test незаметно подсматривает train+test вместе;
* сведение `main_category` к топ-N + "other" — список топ-N тоже нужно
  фиксировать по train, чтобы состав признаков не зависел от test.

Модуль не запускается напрямую — импортируется из notebooks/03_modeling.ipynb.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import numpy as np
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DB_PATH = PROJECT_ROOT / "db" / "olist.db"

# Зафиксировано по итогам EDA (PLAN.md, п.13, шаг 5): тест — июнь-август
# 2018, 18 520 заказов, 19,3 % выборки; всё, что раньше, — train.
TEST_MONTH_START = "2018-06"

# Столько категорий товара оставляем как есть, остальное схлопывается в
# "other" — тот же порог, что и в EDA ("топ-15 по объёму", раздел 6 плана).
TOP_CATEGORIES_N = 15

# Числовые признаки товара, где источник пропусков — карточки без
# category/photos_qty/description_lenght или без веса и габаритов
# (610 + 2 товара, см. PLAN.md раздел 2). Заполняются медианой по
# main_category, посчитанной на train.
CATEGORY_MEDIAN_COLS = (
    "main_product_weight_g",
    "main_product_volume_cm3",
    "main_product_photos_qty",
    "main_product_description_length",
    "total_weight_g",
    "total_volume_cm3",
    "avg_photos_qty",
    "avg_description_length",
)

# Единичные пропуски-дефекты данных (FEATURES.md, разделы 3 и 5) —
# не связаны с категорией товара, заполняются медианой по train целиком.
GLOBAL_MEDIAN_COLS = (
    "approval_hours",
    "carrier_handover_days",
    "carrier_vs_limit_days",
    "payment_count",
    "max_installments",
    "payment_total",
)

NUMERIC_FEATURES = (
    "delivery_days",
    "delay_vs_estimate_days",
    "is_late",
    "promised_window_days",
    "approval_hours",
    "carrier_handover_days",
    "carrier_vs_limit_days",
    "items_count",
    "distinct_products",
    "distinct_sellers",
    "items_price_total",
    "freight_total",
    "order_total",
    "freight_ratio",
    "payment_count",
    "max_installments",
    "payment_total",
    "main_item_price",
    "main_product_weight_g",
    "main_product_volume_cm3",
    "main_product_photos_qty",
    "main_product_description_length",
    "total_weight_g",
    "total_volume_cm3",
    "avg_photos_qty",
    "avg_description_length",
    "is_cross_state",
    "purchase_hour",
    "seller_negative_rate_prior",
    "seller_orders_prior",
)

CATEGORICAL_FEATURES = (
    "main_payment_type",
    "main_category_top",
    "customer_state",
    "main_seller_state",
    "purchase_dow",
    "purchase_month",
)


def load_order_features(conn: sqlite3.Connection | None = None) -> pd.DataFrame:
    """Читает витрину order_features целиком."""
    own_conn = conn is None
    conn = conn or sqlite3.connect(DB_PATH)
    try:
        return pd.read_sql_query("SELECT * FROM order_features", conn)
    finally:
        if own_conn:
            conn.close()


def load_main_seller_ids(conn: sqlite3.Connection | None = None) -> pd.DataFrame:
    """order_id -> seller_id главной (самой дорогой) позиции заказа.

    Та же логика, что и main_item в sql/03_features.sql (самая дорогая
    позиция, тай-брейк order_item_id), но seller_id сознательно не попал
    в саму витрину (см. FEATURES.md, "Не вошло в витрину сознательно") —
    он нужен только здесь, как промежуточный ключ для истории продавца,
    и не годится в модель напрямую (3 095 значений, идентификатор, не признак).
    """
    own_conn = conn is None
    conn = conn or sqlite3.connect(DB_PATH)
    try:
        query = """
            SELECT order_id, seller_id
            FROM (
                SELECT order_id, seller_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY order_id ORDER BY price DESC, order_item_id
                       ) AS rn
                FROM order_items
            )
            WHERE rn = 1
        """
        return pd.read_sql_query(query, conn)
    finally:
        if own_conn:
            conn.close()


def add_seller_history(df: pd.DataFrame, seller_ids: pd.DataFrame) -> pd.DataFrame:
    """Добавляет seller_negative_rate_prior и seller_orders_prior.

    Считается на всей витрине сразу (train+test), но строго causal:
    заказы сортируются по order_purchase_timestamp, и для каждого заказа
    берётся expanding-среднее target внутри продавца со сдвигом на 1 —
    то есть только заказы, оформленные раньше текущего. Для тестового
    периода в эту историю попадают и train-заказы того же продавца, но
    это не утечка: они физически произошли раньше и на практике были бы
    известны в момент предсказания.

    Холодный старт (у продавца ещё нет собственной истории) закрывается
    expanding-средней долей негатива по всем продавцам до этого момента,
    а не константой вроде глобального train rate — так признак не
    "подсматривает" будущее даже в фолбэке. Самые первые заказы во всей
    витрине, где нет вообще никакой предыстории, получают долю негатива
    по всей витрине (единственный статистически нейтральный вариант).
    """
    merged = df.merge(seller_ids, on="order_id", how="left", validate="one_to_one")
    merged = merged.sort_values(["order_purchase_timestamp", "order_id"]).reset_index(drop=True)

    by_seller = merged.groupby("seller_id")["target"]
    own_history = by_seller.transform(lambda s: s.expanding().mean().shift(1))
    seller_orders_prior = by_seller.cumcount()

    overall_history = merged["target"].expanding().mean().shift(1)

    seller_negative_rate_prior = own_history.fillna(overall_history).fillna(merged["target"].mean())

    merged["seller_negative_rate_prior"] = seller_negative_rate_prior
    merged["seller_orders_prior"] = seller_orders_prior
    return merged.drop(columns="seller_id")


def time_split(df: pd.DataFrame, test_month_start: str = TEST_MONTH_START) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Делит витрину по времени покупки: train — раньше test_month_start, test — начиная с него."""
    train = df[df["purchase_year_month"] < test_month_start].copy()
    test = df[df["purchase_year_month"] >= test_month_start].copy()
    return train, test


def _top_values(train: pd.DataFrame, col: str, n: int) -> set:
    return set(train[col].value_counts().head(n).index)


def _collapse_rare(df: pd.DataFrame, col: str, keep: set, other_label: str = "other") -> pd.Series:
    return df[col].where(df[col].isin(keep), other_label)


def fit_preprocessing(train: pd.DataFrame) -> dict:
    """Считает по train все статистики, нужные для заполнения пропусков и кодирования категорий."""
    return {
        "top_categories": _top_values(train, "main_category", TOP_CATEGORIES_N),
        "category_medians": {col: train.groupby("main_category")[col].median() for col in CATEGORY_MEDIAN_COLS},
        "global_medians": {col: train[col].median() for col in CATEGORY_MEDIAN_COLS + GLOBAL_MEDIAN_COLS},
    }


def apply_preprocessing(df: pd.DataFrame, stats: dict) -> pd.DataFrame:
    """Применяет статистики, посчитанные на train, к любому набору (train или test)."""
    df = df.copy()

    df["main_category_top"] = _collapse_rare(df, "main_category", stats["top_categories"])
    df["main_payment_type"] = df["main_payment_type"].fillna("unknown")

    for col in CATEGORY_MEDIAN_COLS:
        by_category = df["main_category"].map(stats["category_medians"][col])
        df[col] = df[col].fillna(by_category).fillna(stats["global_medians"][col])

    for col in GLOBAL_MEDIAN_COLS:
        df[col] = df[col].fillna(stats["global_medians"][col])

    return df


def prepare_train_test(conn: sqlite3.Connection | None = None) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Собирает готовые к обучению train/test поверх order_features.

    Порядок важен: история продавца считается на полной, ещё не разбитой
    витрине (ей нужен весь временной ряд), а разбиение и заполнение
    пропусков — уже отдельно, со статистиками, посчитанными строго на train.
    """
    own_conn = conn is None
    conn = conn or sqlite3.connect(DB_PATH)
    try:
        df = load_order_features(conn)
        seller_ids = load_main_seller_ids(conn)
    finally:
        if own_conn:
            conn.close()

    df = add_seller_history(df, seller_ids)
    train, test = time_split(df)

    stats = fit_preprocessing(train)
    train = apply_preprocessing(train, stats)
    test = apply_preprocessing(test, stats)
    return train, test


def scale_pos_weight(y: pd.Series) -> float:
    """neg/pos на train — прямой вход в XGBClassifier(scale_pos_weight=...)."""
    positives = int(y.sum())
    return (len(y) - positives) / positives
