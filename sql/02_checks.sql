-- =====================================================================
-- Olist: проверочные запросы по сырому слою
-- =====================================================================
-- Запуск: python src/build_features.py --checks
--         (или по одному запросу руками в DB Browser)
--
-- Задача файла — не аналитика, а контроль допущений, на которых
-- построена витрина order_features: сколько заказов доходит до выборки,
-- где пропуски, нет ли нарушений временной логики и дублей.
--
-- Формат: каждый запрос предваряется строкой-маркером
--   -- [Qn] Название
-- Раннер в src/build_features.py разбивает файл по этим маркерам,
-- поэтому один блок = ровно один SELECT.
-- =====================================================================


-- [Q1] Воронка выборки: от всех заказов до строк модели
-- Ожидается: 99 441 -> 96 478 -> 96 470 -> 95 824 (раздел 2 плана).
-- Последняя строка — это и есть будущее число строк в order_features.
SELECT 'всего заказов'                  AS step, COUNT(*) AS orders FROM orders
UNION ALL
SELECT 'статус delivered',              COUNT(*) FROM orders
    WHERE order_status = 'delivered'
UNION ALL
SELECT 'delivered + дата вручения',     COUNT(*) FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
UNION ALL
SELECT 'то же + есть отзыв',            COUNT(*) FROM orders o
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND EXISTS (SELECT 1 FROM order_reviews r WHERE r.order_id = o.order_id);


-- [Q2] Дубли отзывов и результат дедупликации
-- На заказ может приходиться несколько отзывов. Витрина берёт первый
-- по (review_creation_date, review_id); здесь проверяем масштаб явления
-- и что после дедупликации остаётся ровно один отзыв на заказ.
WITH per_order AS (
    SELECT order_id, COUNT(*) AS n
    FROM order_reviews
    GROUP BY order_id
),
first_review AS (
    SELECT order_id
    FROM (
        SELECT order_id,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY review_creation_date, review_id
               ) AS rn
        FROM order_reviews
    )
    WHERE rn = 1
)
SELECT (SELECT COUNT(*) FROM order_reviews)                  AS review_rows,
       (SELECT COUNT(*) FROM per_order)                      AS orders_with_review,
       (SELECT COUNT(*) FROM per_order WHERE n > 1)          AS orders_with_duplicates,
       (SELECT COUNT(*) FROM first_review)                   AS rows_after_dedup;


-- [Q3] Распределение оценок и доля целевого класса
-- Контроль факта из раздела 2: 5* ~59 %, доля оценок 1-2 ~12,8 %.
-- Считается по дедуплицированным отзывам заказов, дошедших до выборки.
WITH sample AS (
    SELECT r.review_score
    FROM orders o
    JOIN (
        SELECT order_id, review_score,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY review_creation_date, review_id
               ) AS rn
        FROM order_reviews
    ) r ON r.order_id = o.order_id AND r.rn = 1
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
)
SELECT review_score,
       COUNT(*)                                                   AS orders,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM sample), 1) AS pct
FROM sample
GROUP BY review_score
ORDER BY review_score;


-- [Q4] Пропуски в полях, из которых считаются признаки
-- Считаем только по будущей выборке: пропуск в недоставленном заказе
-- нам безразличен, он и так отсеян.
WITH sample AS (
    SELECT * FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
)
SELECT 'orders.order_approved_at'             AS field,
       SUM(order_approved_at IS NULL)         AS nulls,
       COUNT(*)                               AS rows
FROM sample
UNION ALL
SELECT 'orders.order_delivered_carrier_date',
       SUM(order_delivered_carrier_date IS NULL), COUNT(*) FROM sample
UNION ALL
SELECT 'products.product_category_name',
       SUM(product_category_name IS NULL), COUNT(*) FROM products
UNION ALL
SELECT 'products.product_weight_g',
       SUM(product_weight_g IS NULL), COUNT(*) FROM products
UNION ALL
SELECT 'order_items.freight_value',
       SUM(freight_value IS NULL), COUNT(*) FROM order_items;


-- [Q5] Заказы без позиций и без платежей
-- Витрина соединяет заказ с агрегатами позиций через INNER JOIN, с
-- платежами — через LEFT JOIN. Запрос показывает, скольких строк это
-- стоит: позиции есть у всех доставленных заказов, платёжных данных
-- нет ровно у одного.
WITH sample AS (
    SELECT order_id FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
)
SELECT SUM(NOT EXISTS (SELECT 1 FROM order_items   i WHERE i.order_id = s.order_id)) AS no_items,
       SUM(NOT EXISTS (SELECT 1 FROM order_payments p WHERE p.order_id = s.order_id)) AS no_payments,
       COUNT(*)                                                                       AS rows
FROM sample s;


-- [Q6] Нарушения временной логики жизненного цикла заказа
-- Порядок меток должен быть: покупка -> подтверждение -> курьер -> клиент.
-- Данные это нарушают: 1 350 заказов переданы курьеру раньше, чем
-- прошла оплата (из-за чего carrier_handover_days отрицателен), и ещё
-- 23 доставлены раньше, чем переданы курьеру. Признаки оставляем как
-- есть, но знаем об этом и пишем в README.
SELECT SUM(order_approved_at             < order_purchase_timestamp)     AS approved_before_purchase,
       SUM(order_delivered_carrier_date  < order_approved_at)            AS carrier_before_approved,
       SUM(order_delivered_customer_date < order_delivered_carrier_date) AS delivered_before_carrier,
       SUM(order_estimated_delivery_date < DATE(order_purchase_timestamp)) AS estimate_before_purchase
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL;


-- [Q7] Логистика против оценки — главная гипотеза проекта
-- Если зависимость «опоздание -> негатив» здесь не видна, дальше идти
-- незачем. Ожидание: в группе «опоздал больше недели» доля оценок 1-2
-- кратно выше средних 12,8 %.
WITH sample AS (
    SELECT CAST(julianday(DATE(o.order_delivered_customer_date))
                - julianday(DATE(o.order_estimated_delivery_date)) AS INTEGER) AS delay_days,
           r.review_score
    FROM orders o
    JOIN (
        SELECT order_id, review_score,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY review_creation_date, review_id
               ) AS rn
        FROM order_reviews
    ) r ON r.order_id = o.order_id AND r.rn = 1
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
)
SELECT CASE
           WHEN delay_days <= -8 THEN 'a) раньше срока 8+ дней'
           WHEN delay_days <= -1 THEN 'b) раньше срока 1-7 дней'
           WHEN delay_days <=  0 THEN 'c) день в день'
           WHEN delay_days <=  7 THEN 'd) опоздал 1-7 дней'
           ELSE                       'e) опоздал 8+ дней'
       END                                                                   AS delay_bucket,
       COUNT(*)                                                              AS orders,
       ROUND(100.0 * AVG(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END), 1)  AS bad_review_pct
FROM sample
GROUP BY delay_bucket
ORDER BY delay_bucket;


-- [Q8] Объём выборки по месяцам покупки
-- Нужен для разбиения train/test по времени (раздел 7.2): смотрим,
-- где заканчиваются полные месяцы и сколько заказов даёт хвост.
-- 2016 год почти пуст, последние месяцы 2018 обрезаны выгрузкой.
SELECT strftime('%Y-%m', o.order_purchase_timestamp) AS purchase_month,
       COUNT(*)                                      AS orders
FROM orders o
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY purchase_month
ORDER BY purchase_month;


-- [Q9] Сходимость денег: платежи против суммы позиций
-- Платёж должен примерно равняться price + freight. Расхождения
-- существуют (ваучеры, округления), но не должны быть массовыми:
-- иначе payment_total как признак бессмысленен.
WITH totals AS (
    SELECT o.order_id,
           (SELECT ROUND(SUM(price + freight_value), 2) FROM order_items i
             WHERE i.order_id = o.order_id) AS items_total,
           (SELECT ROUND(SUM(payment_value), 2)         FROM order_payments p
             WHERE p.order_id = o.order_id) AS payment_total
    FROM orders o
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
)
SELECT COUNT(*)                                             AS rows,
       SUM(payment_total IS NULL)                           AS no_payment,
       SUM(ABS(payment_total - items_total) <= 0.01)        AS match_exact,
       SUM(ABS(payment_total - items_total) > 1.0)          AS diff_over_1,
       ROUND(MAX(ABS(payment_total - items_total)), 2)      AS max_abs_diff
FROM totals;


-- [Q10] Справочники: категории без перевода и товары без категории
-- Контроль заплатки из build_db.py (pc_gamer и ещё одна категория
-- дописываются в справочник) и оценка масштаба категории 'unknown'.
SELECT (SELECT COUNT(*) FROM category_translation)                       AS translations,
       (SELECT COUNT(DISTINCT product_category_name) FROM products
         WHERE product_category_name IS NOT NULL)                        AS categories_in_products,
       (SELECT COUNT(*) FROM products p
         WHERE p.product_category_name IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM category_translation t
                            WHERE t.product_category_name = p.product_category_name))
                                                                         AS products_without_translation,
       (SELECT COUNT(*) FROM products WHERE product_category_name IS NULL)
                                                                         AS products_without_category;
