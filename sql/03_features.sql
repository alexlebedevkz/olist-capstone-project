-- =====================================================================
-- Olist: витрина признаков order_features (одна строка = один заказ)
-- =====================================================================
-- Запуск: python src/build_features.py
--
-- Что это. Материализованная таблица, из которой pandas читает данные
-- одним `SELECT * FROM order_features`. Вся тяжёлая работа — соединения
-- девяти таблиц, агрегаты по позициям и платежам, арифметика дат —
-- сделана здесь, в SQL, а не в ноутбуке.
--
-- Главное правило (раздел 1 плана): точка отсечки — момент вручения
-- заказа клиенту. В витрину попадает только то, что известно на этот
-- момент. Из таблицы отзывов берётся единственное поле review_score
-- (из него считается target); review_id, даты отзыва и текст
-- комментария не попадают сюда сознательно.
--
-- Состав выборки:
--   order_status = 'delivered'  И  есть дата вручения  И  есть отзыв
--   -> 95 824 строки, доля целевого класса ~12,8 %.
--
-- Соглашение о единицах:
--   * *_days с точностью до долей суток считаются по полным меткам
--     времени (у обеих меток есть время);
--   * delay_vs_estimate_days и promised_window_days — целые сутки:
--     у order_estimated_delivery_date время всегда 00:00:00, и сравнение
--     метки времени с полуночью давало бы систематический сдвиг.
--     Опоздание меряется календарными днями — так его и понимает бизнес.
-- =====================================================================

DROP TABLE IF EXISTS order_features;

CREATE TABLE order_features AS

-- Заказы, дошедшие до точки отсечки
WITH base AS (
    SELECT order_id,
           customer_id,
           order_purchase_timestamp,
           order_approved_at,
           order_delivered_carrier_date,
           order_delivered_customer_date,
           order_estimated_delivery_date
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
),

-- Дедупликация отзывов: 547 заказов имеют больше одного отзыва,
-- оставляем первый по дате создания (review_id — тай-брейк для
-- воспроизводимости).
first_review AS (
    SELECT order_id, review_score
    FROM (
        SELECT order_id,
               review_score,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY review_creation_date, review_id
               ) AS rn
        FROM order_reviews
    )
    WHERE rn = 1
),

-- Агрегаты по позициям заказа.
-- COUNT(*) — число позиций (два одинаковых товара = две строки),
-- COUNT(DISTINCT product_id) — число разных товаров.
items_agg AS (
    SELECT order_id,
           COUNT(*)                          AS items_count,
           COUNT(DISTINCT product_id)        AS distinct_products,
           COUNT(DISTINCT seller_id)         AS distinct_sellers,
           ROUND(SUM(price), 2)              AS items_price_total,
           ROUND(SUM(freight_value), 2)      AS freight_total,
           MAX(shipping_limit_date)          AS shipping_limit_last
    FROM order_items
    GROUP BY order_id
),

-- Характеристики товаров заказа (вес, объём, фото, описание).
-- LEFT JOIN не нужен: product_id в позициях всегда есть в products
-- (проверено FK при сборке базы).
items_product_agg AS (
    SELECT i.order_id,
           ROUND(SUM(p.product_weight_g), 1)                          AS total_weight_g,
           ROUND(SUM(p.product_length_cm
                     * p.product_height_cm
                     * p.product_width_cm), 1)                        AS total_volume_cm3,
           ROUND(AVG(p.product_photos_qty), 2)                        AS avg_photos_qty,
           ROUND(AVG(p.product_description_lenght), 1)                AS avg_description_length
    FROM order_items i
    JOIN products p ON p.product_id = i.product_id
    GROUP BY i.order_id
),

-- Главная позиция заказа — самая дорогая. По ней берутся категория,
-- продавец и габариты: у 90 % заказов позиция всего одна, а у 98,7 %
-- заказов продавец единственный, так что «главная позиция» почти
-- всегда и есть весь заказ.
main_item AS (
    SELECT order_id, product_id, seller_id, price AS main_item_price
    FROM (
        SELECT order_id,
               product_id,
               seller_id,
               price,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY price DESC, order_item_id
               ) AS rn
        FROM order_items
    )
    WHERE rn = 1
),

-- Агрегаты по платежам. Заказ может быть оплачен несколькими способами.
payments_agg AS (
    SELECT order_id,
           COUNT(*)                        AS payment_count,
           MAX(payment_installments)       AS max_installments,
           ROUND(SUM(payment_value), 2)    AS payment_total
    FROM order_payments
    GROUP BY order_id
),

-- Основной способ оплаты — тот, на который пришлась большая сумма.
main_payment AS (
    SELECT order_id, payment_type
    FROM (
        SELECT order_id,
               payment_type,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY payment_value DESC, payment_sequential
               ) AS rn
        FROM order_payments
    )
    WHERE rn = 1
)

SELECT
    -- --- идентификаторы и метки времени (не признаки: ключи, разбиение) ---
    b.order_id,
    c.customer_unique_id,
    b.order_purchase_timestamp,
    b.order_delivered_customer_date,

    -- --- целевая переменная ---
    r.review_score,
    CASE WHEN r.review_score <= 2 THEN 1 ELSE 0 END               AS target,

    -- --- логистика: ожидаемо самый сильный блок признаков ---
    ROUND(julianday(b.order_delivered_customer_date)
          - julianday(b.order_purchase_timestamp), 3)             AS delivery_days,
    CAST(julianday(DATE(b.order_delivered_customer_date))
         - julianday(DATE(b.order_estimated_delivery_date))
         AS INTEGER)                                              AS delay_vs_estimate_days,
    CASE WHEN DATE(b.order_delivered_customer_date)
              > DATE(b.order_estimated_delivery_date)
         THEN 1 ELSE 0 END                                        AS is_late,
    CAST(julianday(DATE(b.order_estimated_delivery_date))
         - julianday(DATE(b.order_purchase_timestamp))
         AS INTEGER)                                              AS promised_window_days,
    ROUND((julianday(b.order_approved_at)
           - julianday(b.order_purchase_timestamp)) * 24, 2)      AS approval_hours,
    -- у 1 342 заказов отрицателен: курьеру передали раньше, чем прошла
    -- оплата. Дефект данных (см. Q6 в sql/02_checks.sql), значение
    -- оставлено как есть — обрезать его значило бы стереть сигнал
    ROUND(julianday(b.order_delivered_carrier_date)
          - julianday(b.order_approved_at), 3)                    AS carrier_handover_days,
    -- просрочка передачи курьеру относительно обещанного продавцом срока
    -- (shipping_limit_date последней позиции): видна до вручения заказа
    ROUND(julianday(b.order_delivered_carrier_date)
          - julianday(i.shipping_limit_last), 3)                  AS carrier_vs_limit_days,

    -- --- состав заказа ---
    i.items_count,
    i.distinct_products,
    i.distinct_sellers,
    i.items_price_total,
    i.freight_total,
    ROUND(i.items_price_total + i.freight_total, 2)               AS order_total,
    ROUND(i.freight_total
          / NULLIF(i.items_price_total + i.freight_total, 0), 4)  AS freight_ratio,

    -- --- оплата ---
    mp.payment_type                                               AS main_payment_type,
    pa.payment_count,
    pa.max_installments,
    pa.payment_total,

    -- --- товар (главная позиция + агрегаты по заказу) ---
    COALESCE(ct.product_category_name_english, 'unknown')         AS main_category,
    mi.main_item_price,
    p.product_weight_g                                            AS main_product_weight_g,
    ROUND(p.product_length_cm
          * p.product_height_cm
          * p.product_width_cm, 1)                                AS main_product_volume_cm3,
    p.product_photos_qty                                          AS main_product_photos_qty,
    p.product_description_lenght                                  AS main_product_description_length,
    ip.total_weight_g,
    ip.total_volume_cm3,
    ip.avg_photos_qty,
    ip.avg_description_length,

    -- --- география ---
    c.customer_state,
    c.customer_zip_code_prefix,
    s.seller_state                                                AS main_seller_state,
    CASE WHEN s.seller_state IS NULL THEN NULL
         WHEN s.seller_state = c.customer_state THEN 0
         ELSE 1 END                                               AS is_cross_state,

    -- --- время покупки ---
    CAST(strftime('%Y', b.order_purchase_timestamp) AS INTEGER)   AS purchase_year,
    CAST(strftime('%m', b.order_purchase_timestamp) AS INTEGER)   AS purchase_month,
    strftime('%Y-%m', b.order_purchase_timestamp)                 AS purchase_year_month,
    -- strftime('%w') даёт 0 = воскресенье
    CAST(strftime('%w', b.order_purchase_timestamp) AS INTEGER)   AS purchase_dow,
    CAST(strftime('%H', b.order_purchase_timestamp) AS INTEGER)   AS purchase_hour

FROM base b
JOIN first_review     r  ON r.order_id  = b.order_id          -- без отзыва нет target
JOIN items_agg        i  ON i.order_id  = b.order_id          -- позиции есть у всех доставленных
JOIN items_product_agg ip ON ip.order_id = b.order_id
JOIN main_item        mi ON mi.order_id = b.order_id
JOIN customers        c  ON c.customer_id = b.customer_id
LEFT JOIN products    p  ON p.product_id  = mi.product_id
LEFT JOIN category_translation ct
                         ON ct.product_category_name = p.product_category_name
LEFT JOIN sellers     s  ON s.seller_id   = mi.seller_id
LEFT JOIN payments_agg  pa ON pa.order_id = b.order_id        -- один заказ без платежей
LEFT JOIN main_payment  mp ON mp.order_id = b.order_id;


-- ---------------------------------------------------------------------
-- Индексы витрины
-- ---------------------------------------------------------------------
-- order_id уникален, но CREATE TABLE AS не переносит ключи — уникальность
-- задаётся индексом и заодно проверяется им при создании.
CREATE UNIQUE INDEX idx_order_features_order ON order_features (order_id);
-- разбиение train/test по времени
CREATE INDEX idx_order_features_purchase ON order_features (order_purchase_timestamp);
-- частые разрезы EDA
CREATE INDEX idx_order_features_target   ON order_features (target);
CREATE INDEX idx_order_features_category ON order_features (main_category);
CREATE INDEX idx_order_features_state    ON order_features (customer_state);
