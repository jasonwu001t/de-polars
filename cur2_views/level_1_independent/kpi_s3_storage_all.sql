-- View: kpi_s3_storage_all
-- Dependencies: CUR
-- Description: S3 storage KPIs with optimization recommendations
-- Output: cur2_view/09_kpi_s3_storage_all.parquet

-- CREATE OR REPLACE VIEW kpi_s3_storage_all AS 
WITH
  inputs AS (
   SELECT *
   FROM
     (VALUES (0.3)) AS t (s3_standard_savings)
) 
, s3_usage_all_time AS (
   SELECT
     SPLIT_PART(billing_period, '-', 1) AS year,
     SPLIT_PART(billing_period, '-', 2) AS month,
     bill_billing_period_start_date AS billing_period,
     line_item_usage_start_date AS usage_start_date,
     bill_payer_account_id AS payer_account_id,
     line_item_usage_account_id AS linked_account_id,
     '{}' AS tags_json,
     line_item_resource_id AS resource_id,
     s3_standard_savings,
     line_item_operation AS operation,
     line_item_usage_type AS usage_type,
     (CASE WHEN (line_item_usage_type LIKE '%EarlyDelete%') THEN 'EarlyDelete' ELSE line_item_operation END) AS early_delete_adjusted_operation,
     (CASE WHEN ((line_item_product_code = 'AmazonGlacier') AND (line_item_operation = 'Storage')) THEN 'Amazon Glacier' 
           WHEN ((line_item_product_code = 'AmazonS3') AND (product['volume_type'] LIKE '%Intelligent%') AND (line_item_operation LIKE '%IntelligentTiering%')) THEN 'Intelligent-Tiering' 
           ELSE COALESCE(product['volume_type'], '') END) AS storage_class_type,
     pricing_unit,
     SUM(line_item_usage_amount) AS usage_quantity,
     SUM(line_item_unblended_cost) AS unblended_cost,
     SUM((CASE WHEN ((pricing_unit = 'GB-Mo') AND (line_item_operation LIKE '%Storage%') AND (product['volume_type'] LIKE '%Glacier Deep Archive%')) THEN line_item_unblended_cost 
               WHEN ((pricing_unit = 'GB-Mo') AND (line_item_operation LIKE '%Storage%')) THEN line_item_unblended_cost 
               ELSE 0 END)) AS s3_all_storage_cost,
     SUM((CASE WHEN ((pricing_unit = 'GB-Mo') AND (line_item_operation LIKE '%Storage%')) THEN line_item_usage_amount ELSE 0 END)) AS s3_all_storage_usage_quantity
   FROM
     CUR
   CROSS JOIN inputs
   WHERE ((COALESCE(bill_payer_account_id, '') <> '') 
          AND (COALESCE(line_item_resource_id, '') <> '') 
          AND (line_item_line_item_type LIKE '%Usage%') 
          AND ((line_item_product_code LIKE '%AmazonGlacier%') OR (line_item_product_code LIKE '%AmazonS3%')))
   GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
) 
, most_recent_request AS (
   SELECT DISTINCT
     resource_id,
     MAX(usage_start_date) AS last_request_date
   FROM
     s3_usage_all_time
   WHERE ((usage_quantity > 0) 
          AND (operation IN ('PutObject', 'PutObjectForRepl', 'GetObject', 'CopyObject')) 
          AND (pricing_unit = 'Requests'))
   GROUP BY 1
) 
, month_usage AS (
   SELECT DISTINCT
     billing_period,
     DATE_TRUNC('month', usage_start_date) AS usage_date,
     payer_account_id,
     linked_account_id,
     tags_json,
     s3.resource_id,
     most_recent_request.last_request_date AS last_requests,
     s3_standard_savings,
     SUM(unblended_cost) AS s3_all_cost,
     SUM(s3_all_storage_cost) AS s3_all_storage_cost,
     SUM(s3_all_storage_usage_quantity) AS s3_all_storage_usage_quantity,
     SUM((CASE WHEN (storage_class_type = 'Standard') THEN s3_all_storage_cost ELSE 0 END)) AS s3_standard_storage_cost,
     SUM((CASE WHEN (storage_class_type = 'Standard') THEN s3_all_storage_usage_quantity ELSE 0 END)) AS s3_standard_storage_usage_quantity,
     SUM((CASE WHEN (storage_class_type = 'Standard - Infrequent Access') THEN s3_all_storage_cost ELSE 0 END)) AS "s3_standard-ia_storage_cost",
     SUM((CASE WHEN (storage_class_type = 'Standard - Infrequent Access') THEN s3_all_storage_usage_quantity ELSE 0 END)) AS "s3_standard-ia_storage_usage_quantity",
     SUM((CASE WHEN (usage_type LIKE '%Requests-SIA-Tier1%') THEN unblended_cost ELSE 0 END)) AS "s3_standard-ia_tier1_cost",
     SUM((CASE WHEN (usage_type LIKE '%Requests-SIA-Tier2%') THEN unblended_cost ELSE 0 END)) AS "s3_standard-ia_tier2_cost",
     SUM((CASE WHEN (usage_type LIKE '%Retrieval-SIA%') THEN unblended_cost ELSE 0 END)) AS "s3_standard-ia_retrieval_cost",
     SUM((CASE WHEN (storage_class_type = 'One Zone - Infrequent Access') THEN s3_all_storage_cost ELSE 0 END)) AS "s3_onezone-ia_storage_cost",
     SUM((CASE WHEN (storage_class_type = 'One Zone - Infrequent Access') THEN s3_all_storage_usage_quantity ELSE 0 END)) AS "s3_onezone-ia_storage_usage_quantity",
     SUM((CASE WHEN (storage_class_type = 'Reduced Redundancy') THEN s3_all_storage_cost ELSE 0 END)) AS s3_reduced_redundancy_storage_cost,
     SUM((CASE WHEN (storage_class_type = 'Reduced Redundancy') THEN s3_all_storage_usage_quantity ELSE 0 END)) AS s3_reduced_redundancy_storage_usage_quantity,
     SUM((CASE WHEN (storage_class_type LIKE '%Intelligent%') THEN s3_all_storage_cost ELSE 0 END)) AS "s3_intelligent-tiering_storage_cost",
     SUM((CASE WHEN (storage_class_type LIKE '%Intelligent%') THEN s3_all_storage_usage_quantity ELSE 0 END)) AS "s3_intelligent-tiering_storage_usage_quantity",
     SUM((CASE WHEN ((storage_class_type LIKE '%Instant%') AND (NOT (storage_class_type LIKE '%Intelligent%'))) THEN s3_all_storage_cost ELSE 0 END)) AS s3_glacier_instant_retrieval_storage_cost,
     SUM((CASE WHEN ((storage_class_type LIKE '%Instant%') AND (NOT (storage_class_type LIKE '%Intelligent%'))) THEN s3_all_storage_usage_quantity ELSE 0 END)) AS s3_glacier_instant_retrieval_storage_usage_quantity,
     SUM((CASE WHEN (usage_type LIKE '%Requests-GIR-Tier1%') THEN unblended_cost ELSE 0 END)) AS s3_glacier_instant_retrieval_tier1_cost,
     SUM((CASE WHEN (usage_type LIKE '%Requests-GIR-Tier2%') THEN unblended_cost ELSE 0 END)) AS s3_glacier_instant_retrieval_tier2_cost,
     SUM((CASE WHEN (usage_type LIKE '%Retrieval-SIA-GIR%') THEN unblended_cost ELSE 0 END)) AS s3_glacier_instant_retrieval_retrieval_cost,
     SUM((CASE WHEN (storage_class_type = 'Amazon Glacier') THEN s3_all_storage_cost ELSE 0 END)) AS s3_glacier_flexible_retrieval_storage_cost,
     SUM((CASE WHEN (storage_class_type = 'Amazon Glacier') THEN s3_all_storage_usage_quantity ELSE 0 END)) AS s3_glacier_flexible_retrieval_storage_usage_quantity,
     SUM((CASE WHEN (storage_class_type = 'Glacier Deep Archive') THEN s3_all_storage_cost ELSE 0 END)) AS s3_glacier_deep_archive_storage_storage_cost,
     SUM((CASE WHEN (storage_class_type = 'Glacier Deep Archive') THEN s3_all_storage_usage_quantity ELSE 0 END)) AS s3_glacier_deep_archive_storage_usage_quantity,
     SUM((CASE WHEN ((operation = 'PutObject') AND (pricing_unit = 'Requests')) THEN usage_quantity ELSE 0 END)) AS s3_put_object_usage_quantity,
     SUM((CASE WHEN ((operation = 'PutObjectForRepl') AND (pricing_unit = 'Requests')) THEN usage_quantity ELSE 0 END)) AS s3_put_object_replication_usage_quantity,
     SUM((CASE WHEN ((operation = 'GetObject') AND (pricing_unit = 'Requests')) THEN usage_quantity ELSE 0 END)) AS s3_get_object_usage_quantity,
     SUM((CASE WHEN ((operation = 'CopyObject') AND (pricing_unit = 'Requests')) THEN usage_quantity ELSE 0 END)) AS s3_copy_object_usage_quantity,
     SUM((CASE WHEN (operation = 'Inventory') THEN usage_quantity ELSE 0 END)) AS s3_inventory_usage_quantity,
     SUM((CASE WHEN (operation = 'S3.STORAGE_CLASS_ANALYSIS.OBJECT') THEN usage_quantity ELSE 0 END)) AS s3_analytics_usage_quantity,
     SUM((CASE WHEN (operation LIKE '%Transition%') THEN usage_quantity ELSE 0 END)) AS s3_transition_usage_quantity,
     SUM((CASE WHEN (early_delete_adjusted_operation = 'EarlyDelete') THEN unblended_cost ELSE 0 END)) AS s3_early_delete_cost
   FROM
     (s3_usage_all_time s3
   LEFT JOIN most_recent_request ON (most_recent_request.resource_id = s3.resource_id))
   WHERE (CAST(CONCAT(s3.year, '-', s3.month, '-01') AS DATE) >= (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL 3 MONTH))
   GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
) 
SELECT DISTINCT
  billing_period,
  usage_date,
  payer_account_id,
  linked_account_id,
  tags_json,
  resource_id,
  (CASE WHEN (resource_id LIKE '%backup%') THEN 'backup' 
        WHEN (resource_id LIKE '%archive%') THEN 'archive' 
        WHEN (resource_id LIKE '%historical%') THEN 'historical' 
        WHEN (resource_id LIKE '%log%') THEN 'log' 
        WHEN (resource_id LIKE '%compliance%') THEN 'compliance' 
        ELSE 'Other' END) AS bucket_name_keywords,
  last_requests,
  (CASE WHEN (last_requests >= (usage_date - INTERVAL 2 MONTH)) THEN 'No Action' 
        WHEN (s3_all_storage_cost = s3_standard_storage_cost) THEN 'Potential Action' 
        ELSE 'No Action' END) AS s3_standard_underutilized_optimization,
  (CASE WHEN ((s3_transition_usage_quantity > 0) AND (last_requests >= (usage_date - INTERVAL 1 MONTH))) THEN 'No Action' 
        WHEN (s3_put_object_replication_usage_quantity > 0) THEN 'Potential Action' 
        ELSE 'No Action' END) AS s3_replication_bucket_optimization,
  (CASE WHEN (s3_all_storage_cost = s3_standard_storage_cost) THEN 'Yes' ELSE 'No' END) AS s3_standard_only_bucket,
  (CASE WHEN (s3_glacier_deep_archive_storage_storage_cost > 0) THEN 'in use' 
        WHEN (s3_glacier_flexible_retrieval_storage_cost > 0) THEN 'in use' 
        WHEN (s3_glacier_instant_retrieval_storage_cost > 0) THEN 'in use' 
        ELSE 'not in use' END) AS s3_archive_in_use,
  (CASE WHEN (s3_inventory_usage_quantity > 0) THEN 'in use' ELSE 'not in use' END) AS s3_inventory_in_use,
  (CASE WHEN (s3_analytics_usage_quantity > 0) THEN 'in use' ELSE 'not in use' END) AS s3_analytics_in_use,
  (CASE WHEN ("s3_intelligent-tiering_storage_usage_quantity" > 0) THEN 'in use' ELSE 'not in use' END) AS s3_int_in_use,
  (s3_standard_storage_cost * s3_standard_savings) AS s3_standard_storage_potential_savings,
  s3_all_cost,
  s3_all_storage_cost,
  s3_all_storage_usage_quantity,
  s3_standard_storage_cost,
  s3_standard_storage_usage_quantity,
  "s3_intelligent-tiering_storage_cost",
  "s3_intelligent-tiering_storage_usage_quantity",
  "s3_standard-ia_storage_cost",
  "s3_standard-ia_storage_usage_quantity",
  "s3_standard-ia_tier1_cost",
  "s3_standard-ia_tier2_cost",
  "s3_standard-ia_retrieval_cost",
  "s3_onezone-ia_storage_cost",
  "s3_onezone-ia_storage_usage_quantity",
  s3_reduced_redundancy_storage_cost,
  s3_reduced_redundancy_storage_usage_quantity,
  s3_glacier_instant_retrieval_storage_cost,
  s3_glacier_instant_retrieval_storage_usage_quantity,
  s3_glacier_instant_retrieval_tier1_cost,
  s3_glacier_instant_retrieval_tier2_cost,
  s3_glacier_instant_retrieval_retrieval_cost,
  s3_glacier_flexible_retrieval_storage_cost,
  s3_glacier_flexible_retrieval_storage_usage_quantity,
  s3_glacier_deep_archive_storage_storage_cost,
  s3_glacier_deep_archive_storage_usage_quantity,
  s3_early_delete_cost,
  s3_transition_usage_quantity,
  s3_put_object_usage_quantity,
  s3_put_object_replication_usage_quantity,
  s3_get_object_usage_quantity,
  s3_copy_object_usage_quantity
FROM
  month_usage
