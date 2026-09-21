-- =====================================================================
-- Olist: аналитические запросы для EDA
-- =====================================================================
-- Запуск: python src/build_features.py --analytics
--         (или по одному запросу руками в DB Browser)
--
-- Задача файла — посчитать в SQL всё, на чём строятся графики блока EDA
-- (notebooks/02_eda.ipynb). Pandas в ноутбуке ничего не агрегирует: он
-- читает готовый результат запроса и рисует его. Так требование ТЗ
-- «аналитические запросы тоже в SQL, а не в pandas» (раздел 5.3 плана)
-- выполняется буквально, а ноутбук остаётся читаемым.
--
-- Все запросы идут по витрине order_features (sql/03_features.sql):
-- 95 824 доставленных заказа с отзывом, доля целевого класса 12,8 %.
-- Целевая переменная target = 1, если оценка 1-2 звезды.
--
-- Формат: каждый запрос предваряется строкой-маркером
--   -- [An] Название
-- Раннер в src/build_features.py разбивает файл по этим маркерам,
-- поэтому один блок = ровно один SELECT.
-- =====================================================================


-- [A1] Распределение оценок и вклад каждой в целевой класс
-- База для первого графика: выборка перекошена в 5 звёзд (59 %),
-- а негатив почти весь состоит из единиц, а не двоек.
SELECT review_score,
       COUNT(*)                                                           AS orders,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM order_features), 1) AS pct,
       MAX(target)                                                        AS is_target
FROM order_features
GROUP BY review_score
ORDER BY review_score;


-- [A2] ГЛАВНЫЙ РАЗРЕЗ: опоздание против обещанной даты -> доля негатива
-- Ожидание раздела 6 плана: самая сильная зависимость в данных.
-- Бины несимметричны намеренно: слева «раньше срока» интересно крупными
-- группами, справа важен почти каждый день опоздания.
SELECT CASE
           WHEN delay_vs_estimate_days <= -16 THEN 'a) раньше на 16+ дней'
           WHEN delay_vs_estimate_days <=  -8 THEN 'b) раньше на 8-15 дней'
           WHEN delay_vs_estimate_days <=  -4 THEN 'c) раньше на 4-7 дней'
           WHEN delay_vs_estimate_days <=  -1 THEN 'd) раньше на 1-3 дня'
           WHEN delay_vs_estimate_days  =   0 THEN 'e) день в день'
           WHEN delay_vs_estimate_days <=   3 THEN 'f) опоздал на 1-3 дня'
           WHEN delay_vs_estimate_days <=   7 THEN 'g) опоздал на 4-7 дней'
           WHEN delay_vs_estimate_days <=  14 THEN 'h) опоздал на 8-14 дней'
           ELSE                                    'i) опоздал на 15+ дней'
       END                                              AS delay_bucket,
       COUNT(*)                                         AS orders,
       ROUND(100.0 * COUNT(*)
             / (SELECT COUNT(*) FROM order_features), 1) AS share_pct,
       ROUND(100.0 * AVG(target), 1)                    AS bad_review_pct
FROM order_features
GROUP BY delay_bucket
ORDER BY delay_bucket;


-- [A3] Срок доставки в днях -> доля негатива
-- Второй логистический срез. Отличается от [A2] тем, что здесь нет
-- обещания: просто «сколько ждали». Нужен, чтобы показать, что дело
-- не только в нарушенном обещании, но и в абсолютном времени ожидания.
SELECT CASE
           WHEN delivery_days <   4 THEN 'a) до 3 дней'
           WHEN delivery_days <   8 THEN 'b) 4-7 дней'
           WHEN delivery_days <  15 THEN 'c) 8-14 дней'
           WHEN delivery_days <  22 THEN 'd) 15-21 день'
           WHEN delivery_days <  31 THEN 'e) 22-30 дней'
           ELSE                          'f) 31+ дней'
       END                                              AS delivery_bucket,
       COUNT(*)                                         AS orders,
       ROUND(100.0 * AVG(target), 1)                    AS bad_review_pct,
       ROUND(100.0 * AVG(is_late), 1)                   AS late_pct
FROM order_features
GROUP BY delivery_bucket
ORDER BY delivery_bucket;


-- [A4] Категории товара: топ-15 по объёму заказов
-- Категорий 74, хвост из редких даёт неустойчивые доли, поэтому берём
-- только крупные. Рядом с долей негатива — срок доставки и доля
-- опозданий: чтобы увидеть, объясняется ли разброс логистикой.
SELECT main_category,
       COUNT(*)                                         AS orders,
       ROUND(100.0 * AVG(target), 1)                    AS bad_review_pct,
       ROUND(AVG(delivery_days), 1)                     AS avg_delivery_days,
       ROUND(100.0 * AVG(is_late), 1)                   AS late_pct,
       ROUND(AVG(main_item_price), 0)                   AS avg_item_price
FROM order_features
GROUP BY main_category
ORDER BY orders DESC
LIMIT 15;


-- [A5] Штаты покупателя: объём, негатив, логистика
-- Все 27 штатов. SP (Сан-Паулу) — почти половина выборки, северные
-- штаты дают сотни заказов, но самые долгие сроки. Сортировка по
-- объёму, чтобы на графике было видно, какие точки статистически весомы.
SELECT customer_state,
       COUNT(*)                                         AS orders,
       ROUND(100.0 * AVG(target), 1)                    AS bad_review_pct,
       ROUND(AVG(delivery_days), 1)                     AS avg_delivery_days,
       ROUND(100.0 * AVG(is_late), 1)                   AS late_pct,
       ROUND(AVG(freight_total), 2)                     AS avg_freight
FROM order_features
GROUP BY customer_state
ORDER BY orders DESC;


-- [A6] Карта пропусков по витрине
-- Перечислены только колонки, где пропуски вообще есть: остальные
-- заполнены полностью (проверяется в build_features.py). Значения нужны
-- для раздела «обработка пропусков»: где медиана по категории, где
-- отдельный флаг, а где заказ просто выпадает.
SELECT 'main_product_photos_qty'                              AS column_name,
       SUM(main_product_photos_qty IS NULL)                   AS nulls,
       ROUND(100.0 * AVG(main_product_photos_qty IS NULL), 2) AS null_pct
FROM order_features
UNION ALL SELECT 'main_product_description_length',
       SUM(main_product_description_length IS NULL),
       ROUND(100.0 * AVG(main_product_description_length IS NULL), 2) FROM order_features
UNION ALL SELECT 'avg_photos_qty',
       SUM(avg_photos_qty IS NULL),
       ROUND(100.0 * AVG(avg_photos_qty IS NULL), 2) FROM order_features
UNION ALL SELECT 'avg_description_length',
       SUM(avg_description_length IS NULL),
       ROUND(100.0 * AVG(avg_description_length IS NULL), 2) FROM order_features
UNION ALL SELECT 'main_product_weight_g',
       SUM(main_product_weight_g IS NULL),
       ROUND(100.0 * AVG(main_product_weight_g IS NULL), 2) FROM order_features
UNION ALL SELECT 'main_product_volume_cm3',
       SUM(main_product_volume_cm3 IS NULL),
       ROUND(100.0 * AVG(main_product_volume_cm3 IS NULL), 2) FROM order_features
UNION ALL SELECT 'total_weight_g',
       SUM(total_weight_g IS NULL),
       ROUND(100.0 * AVG(total_weight_g IS NULL), 2) FROM order_features
UNION ALL SELECT 'total_volume_cm3',
       SUM(total_volume_cm3 IS NULL),
       ROUND(100.0 * AVG(total_volume_cm3 IS NULL), 2) FROM order_features
UNION ALL SELECT 'carrier_handover_days',
       SUM(carrier_handover_days IS NULL),
       ROUND(100.0 * AVG(carrier_handover_days IS NULL), 2) FROM order_features
UNION ALL SELECT 'approval_hours',
       SUM(approval_hours IS NULL),
       ROUND(100.0 * AVG(approval_hours IS NULL), 2) FROM order_features
UNION ALL SELECT 'carrier_vs_limit_days',
       SUM(carrier_vs_limit_days IS NULL),
       ROUND(100.0 * AVG(carrier_vs_limit_days IS NULL), 2) FROM order_features
UNION ALL SELECT 'main_payment_type + агрегаты платежей',
       SUM(main_payment_type IS NULL),
       ROUND(100.0 * AVG(main_payment_type IS NULL), 2) FROM order_features
UNION ALL SELECT 'main_category = unknown (не пропуск, а заплатка)',
       SUM(main_category = 'unknown'),
       ROUND(100.0 * AVG(main_category = 'unknown'), 2) FROM order_features
ORDER BY nulls DESC;


-- [A7] Состав заказа: число позиций и число продавцов
-- Два разреза в одном результате (колонка dim), чтобы нарисовать их
-- парой панелей. Гипотеза: чем больше посылок и продавцов, тем выше
-- шанс, что хоть что-то приедет не вовремя.
SELECT 'позиций в заказе' AS dim,
       CASE WHEN items_count >= 4 THEN '4+'
            ELSE CAST(items_count AS TEXT) END          AS bucket,
       COUNT(*)                                         AS orders,
       ROUND(100.0 * AVG(target), 1)                    AS bad_review_pct,
       ROUND(100.0 * AVG(is_late), 1)                   AS late_pct
FROM order_features
GROUP BY bucket
UNION ALL
SELECT 'продавцов в заказе',
       CASE WHEN distinct_sellers >= 3 THEN '3+'
            ELSE CAST(distinct_sellers AS TEXT) END,
       COUNT(*),
       ROUND(100.0 * AVG(target), 1),
       ROUND(100.0 * AVG(is_late), 1)
FROM order_features
GROUP BY 2
ORDER BY dim, bucket;


-- [A8] Оплата: способ и рассрочка
-- Тот же приём с колонкой dim. Рассрочка интересна не сама по себе,
-- а как прокси на цену заказа и на тип покупателя.
SELECT 'способ оплаты' AS dim,
       COALESCE(main_payment_type, 'нет данных')        AS bucket,
       COUNT(*)                                         AS orders,
       ROUND(100.0 * AVG(target), 1)                    AS bad_review_pct,
       ROUND(AVG(payment_total), 0)                     AS avg_payment
FROM order_features
GROUP BY bucket
UNION ALL
SELECT 'рассрочка (макс. число платежей)',
       CASE WHEN max_installments IS NULL  THEN 'нет данных'
            WHEN max_installments <= 1     THEN '1 (без рассрочки)'
            WHEN max_installments <= 3     THEN '2-3'
            WHEN max_installments <= 6     THEN '4-6'
            ELSE                                '7+' END,
       COUNT(*),
       ROUND(100.0 * AVG(target), 1),
       ROUND(AVG(payment_total), 0)
FROM order_features
GROUP BY 2
ORDER BY dim, orders DESC;


-- [A9] Динамика по месяцам покупки
-- Нужна дважды: как EDA (есть ли тренд и сезонность) и как основание
-- для разбиения train/test по времени (раздел 7.2 плана). Видно, что
-- 2016 год почти пуст, а последний месяц выборки обрезан выгрузкой.
SELECT purchase_year_month,
       COUNT(*)                                         AS orders,
       ROUND(100.0 * AVG(target), 1)                    AS bad_review_pct,
       ROUND(100.0 * AVG(is_late), 1)                   AS late_pct,
       ROUND(AVG(delivery_days), 1)                     AS avg_delivery_days
FROM order_features
GROUP BY purchase_year_month
ORDER BY purchase_year_month;


-- [A10] Контроль главного фактора: штаты в разрезе «в срок / опоздал»
-- Проверка того, что региональные различия из [A5] — это логистика,
-- а не «характер покупателей». Если внутри групп «в срок» и «опоздал»
-- доли негатива по штатам сближаются, значит штат влияет через срок
-- доставки, и собственного эффекта региона почти нет.
SELECT customer_state,
       COUNT(*)                                                       AS orders,
       ROUND(100.0 * AVG(is_late), 1)                                 AS late_pct,
       ROUND(100.0 * AVG(CASE WHEN is_late = 0 THEN target END), 1)   AS bad_pct_on_time,
       ROUND(100.0 * AVG(CASE WHEN is_late = 1 THEN target END), 1)   AS bad_pct_late,
       ROUND(100.0 * AVG(target), 1)                                  AS bad_pct_total
FROM order_features
GROUP BY customer_state
HAVING COUNT(*) >= 500
ORDER BY orders DESC;
