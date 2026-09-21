-- =====================================================================
-- Olist e-commerce: схема базы данных (SQLite)
-- =====================================================================
-- Применяется скриптом src/build_db.py перед загрузкой CSV.
--
-- Соглашения:
--   * даты хранятся как TEXT в формате 'YYYY-MM-DD HH:MM:SS' (ISO-8601).
--     В таком виде работают лексикографические сравнения (<, >, BETWEEN),
--     julianday() и strftime() — то есть вся арифметика дат в SQL;
--   * деньги и координаты — REAL, счётчики — INTEGER;
--   * FK объявлены явно, но в SQLite проверяются только при
--     PRAGMA foreign_keys = ON (включается в build_db.py).
-- =====================================================================

DROP TABLE IF EXISTS order_reviews;
DROP TABLE IF EXISTS order_payments;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS sellers;
DROP TABLE IF EXISTS geolocation;
DROP TABLE IF EXISTS category_translation;


-- ---------------------------------------------------------------------
-- Справочник переводов категорий (загружается первым: на него ссылается products)
-- ---------------------------------------------------------------------
CREATE TABLE category_translation (
    product_category_name         TEXT PRIMARY KEY,
    product_category_name_english TEXT NOT NULL
);


-- ---------------------------------------------------------------------
-- Покупатели
-- ---------------------------------------------------------------------
-- customer_id     — идентификатор покупателя В РАМКАХ ОДНОГО ЗАКАЗА (1:1 с orders);
-- customer_unique_id — сквозной идентификатор человека, по нему считаются
--                   повторные покупки. Путать их нельзя.
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id              TEXT PRIMARY KEY,
    customer_unique_id       TEXT NOT NULL,
    customer_zip_code_prefix TEXT,
    customer_city            TEXT,
    customer_state           TEXT
);


-- ---------------------------------------------------------------------
-- Продавцы
-- ---------------------------------------------------------------------
CREATE TABLE sellers (
    seller_id              TEXT PRIMARY KEY,
    seller_zip_code_prefix TEXT,
    seller_city            TEXT,
    seller_state           TEXT
);


-- ---------------------------------------------------------------------
-- Товары
-- ---------------------------------------------------------------------
-- product_category_name пуста у 610 товаров; ещё у 13 товаров встречаются
-- две категории, отсутствующие в исходном файле переводов
-- (pc_gamer, portateis_cozinha_e_preparadores_de_alimentos) — build_db.py
-- дописывает их в category_translation, поэтому FK ниже выполняется.
-- ---------------------------------------------------------------------
CREATE TABLE products (
    product_id                 TEXT PRIMARY KEY,
    product_category_name      TEXT,
    product_name_lenght        INTEGER,
    product_description_lenght INTEGER,
    product_photos_qty         INTEGER,
    product_weight_g           REAL,
    product_length_cm          REAL,
    product_height_cm          REAL,
    product_width_cm           REAL,
    FOREIGN KEY (product_category_name)
        REFERENCES category_translation (product_category_name)
);


-- ---------------------------------------------------------------------
-- Заказы
-- ---------------------------------------------------------------------
-- Ключевые для проекта поля — четыре временные метки жизненного цикла.
-- Точка отсечки модели: order_delivered_customer_date.
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    order_id                      TEXT PRIMARY KEY,
    customer_id                   TEXT NOT NULL,
    order_status                  TEXT NOT NULL,
    order_purchase_timestamp      TEXT NOT NULL,  -- покупка
    order_approved_at             TEXT,           -- подтверждение оплаты
    order_delivered_carrier_date  TEXT,           -- передача курьеру
    order_delivered_customer_date TEXT,           -- вручение клиенту (cut-off)
    order_estimated_delivery_date TEXT NOT NULL,  -- обещанная дата
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
);


-- ---------------------------------------------------------------------
-- Позиции заказа
-- ---------------------------------------------------------------------
-- Одна строка = один экземпляр товара в заказе. Два одинаковых товара
-- дают две строки с разными order_item_id, поэтому COUNT(*) — это число
-- позиций, а COUNT(DISTINCT product_id) — число разных товаров.
-- ---------------------------------------------------------------------
CREATE TABLE order_items (
    order_id            TEXT NOT NULL,
    order_item_id       INTEGER NOT NULL,
    product_id          TEXT NOT NULL,
    seller_id           TEXT NOT NULL,
    shipping_limit_date TEXT,
    price               REAL,
    freight_value       REAL,
    PRIMARY KEY (order_id, order_item_id),
    FOREIGN KEY (order_id)   REFERENCES orders (order_id),
    FOREIGN KEY (product_id) REFERENCES products (product_id),
    FOREIGN KEY (seller_id)  REFERENCES sellers (seller_id)
);


-- ---------------------------------------------------------------------
-- Платежи
-- ---------------------------------------------------------------------
-- Заказ может быть оплачен несколькими способами (ваучер + карта и т.п.),
-- отсюда payment_sequential в составном ключе.
-- ---------------------------------------------------------------------
CREATE TABLE order_payments (
    order_id             TEXT NOT NULL,
    payment_sequential   INTEGER NOT NULL,
    payment_type         TEXT,
    payment_installments INTEGER,
    payment_value        REAL,
    PRIMARY KEY (order_id, payment_sequential),
    FOREIGN KEY (order_id) REFERENCES orders (order_id)
);


-- ---------------------------------------------------------------------
-- Отзывы
-- ---------------------------------------------------------------------
-- ВАЖНО: review_id сам по себе НЕ уникален (99 224 строки на 98 410
-- review_id), и order_id тоже не уникален (98 673) — часть заказов
-- получила по два отзыва. Уникальна только пара (review_id, order_id),
-- она и взята в PK. Дедупликация до одного отзыва на заказ выполняется
-- позже, на витрине признаков, а не при загрузке — сырой слой должен
-- оставаться сырым.
--
-- Поля review_comment_* и review_answer_timestamp возникают ПОСЛЕ точки
-- отсечки и в признаки модели не попадают (см. раздел 1 плана).
-- ---------------------------------------------------------------------
CREATE TABLE order_reviews (
    review_id               TEXT NOT NULL,
    order_id                TEXT NOT NULL,
    review_score            INTEGER NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TEXT,
    review_answer_timestamp TEXT,
    PRIMARY KEY (review_id, order_id),
    FOREIGN KEY (order_id) REFERENCES orders (order_id)
);


-- ---------------------------------------------------------------------
-- Геолокация
-- ---------------------------------------------------------------------
-- Единственная таблица без первичного ключа: на один zip-префикс
-- приходятся тысячи точек. Перед использованием агрегируется до среднего
-- lat/lng на префикс (см. раздел 12 плана).
-- ---------------------------------------------------------------------
CREATE TABLE geolocation (
    geolocation_zip_code_prefix TEXT,
    geolocation_lat             REAL,
    geolocation_lng             REAL,
    geolocation_city            TEXT,
    geolocation_state           TEXT
);


-- =====================================================================
-- Индексы
-- =====================================================================
-- PK-колонки уже проиндексированы, поэтому здесь только внешние ключи
-- и поля, по которым реально идут JOIN, фильтры и группировки.
-- =====================================================================

-- JOIN-и от заказа
CREATE INDEX idx_orders_customer         ON orders (customer_id);
CREATE INDEX idx_orders_status           ON orders (order_status);
-- временное разбиение train/test и фильтр по точке отсечки
CREATE INDEX idx_orders_purchase_ts      ON orders (order_purchase_timestamp);
CREATE INDEX idx_orders_delivered_ts     ON orders (order_delivered_customer_date);

CREATE INDEX idx_items_product           ON order_items (product_id);
CREATE INDEX idx_items_seller            ON order_items (seller_id);

CREATE INDEX idx_reviews_order           ON order_reviews (order_id);
-- дедупликация «первый отзыв по заказу» и агрегаты по оценке
CREATE INDEX idx_reviews_order_created   ON order_reviews (order_id, review_creation_date);
CREATE INDEX idx_reviews_score           ON order_reviews (review_score);

CREATE INDEX idx_products_category       ON products (product_category_name);

-- разрезы EDA по географии
CREATE INDEX idx_customers_state         ON customers (customer_state);
CREATE INDEX idx_customers_zip           ON customers (customer_zip_code_prefix);
CREATE INDEX idx_sellers_state           ON sellers (seller_state);
CREATE INDEX idx_sellers_zip             ON sellers (seller_zip_code_prefix);

CREATE INDEX idx_geolocation_zip         ON geolocation (geolocation_zip_code_prefix);
