CREATE OR REPLACE VIEW "kpi_ebs_storage_all" AS 
WITH
  ebs_all AS (
   SELECT
     bill_billing_period_start_date
   , line_item_usage_start_date
   , bill_payer_account_id
   , line_item_usage_account_id
   , '{}' tags_json
   , line_item_resource_id
   , product['volume_api_name'] product_volume_api_name
   , line_item_usage_type
   , pricing_unit
   , line_item_unblended_cost
   , line_item_usage_amount
   FROM
     CUR
   WHERE ((line_item_product_code = 'AmazonEC2') AND (line_item_line_item_type = 'Usage') AND (COALESCE(bill_payer_account_id, '') <> '') AND (COALESCE(line_item_usage_account_id, '') <> '') AND (CAST("concat"("billing_period", '-01') AS date) >= ("date_trunc"('month', current_date) - INTERVAL  '3' MONTH)) AND (COALESCE(product['volume_api_name'], '') <> '') AND (NOT (COALESCE(line_item_usage_type, '') LIKE '%Snap%')) AND (line_item_usage_type LIKE '%EBS%'))
) 
, ebs_spend AS (
   SELECT DISTINCT
     bill_billing_period_start_date billing_period
   , date_trunc('month', line_item_usage_start_date) usage_date
   , bill_payer_account_id payer_account_id
   , line_item_usage_account_id linked_account_id
   , tags_json
   , line_item_resource_id resource_id
   , COALESCE(product_volume_api_name, '') volume_api_name
   , SUM((CASE WHEN ((((pricing_unit = 'GB-Mo') OR (pricing_unit = 'GB-month')) OR (pricing_unit = 'GB-month')) AND (line_item_usage_type LIKE '%EBS:VolumeUsage%')) THEN line_item_usage_amount ELSE 0 END)) "usage_storage_gb_mo"
   , SUM((CASE WHEN ((pricing_unit = 'IOPS-Mo') AND (line_item_usage_type LIKE '%IOPS%')) THEN line_item_usage_amount ELSE 0 END)) "usage_iops_mo"
   , SUM((CASE WHEN ((pricing_unit = 'GiBps-mo') AND (line_item_usage_type LIKE '%Throughput%')) THEN line_item_usage_amount ELSE 0 END)) "usage_throughput_gibps_mo"
   , SUM((CASE WHEN (((pricing_unit = 'GB-Mo') OR (pricing_unit = 'GB-month')) AND (line_item_usage_type LIKE '%EBS:VolumeUsage%')) THEN line_item_unblended_cost ELSE 0 END)) "cost_storage_gb_mo"
   , SUM((CASE WHEN ((pricing_unit = 'IOPS-Mo') AND (line_item_usage_type LIKE '%IOPS%')) THEN line_item_unblended_cost ELSE 0 END)) "cost_iops_mo"
   , SUM((CASE WHEN ((pricing_unit = 'GiBps-mo') AND (line_item_usage_type LIKE '%Throughput%')) THEN line_item_unblended_cost ELSE 0 END)) "cost_throughput_gibps_mo"
   FROM
     ebs_all
   GROUP BY 1, 2, 3, 4, 5, 6, 7
) 
, ebs_spend_with_unit_cost AS (
   SELECT
     *
   , (cost_storage_gb_mo / usage_storage_gb_mo) "current_unit_cost"
   , (CASE WHEN (usage_storage_gb_mo <= 150) THEN 'under 150GB-Mo' WHEN ((usage_storage_gb_mo > 150) AND (usage_storage_gb_mo <= 1000)) THEN 'between 150-1000GB-Mo' ELSE 'over 1000GB-Mo' END) storage_summary
   , (CASE WHEN (volume_api_name <> 'gp2') THEN 0 WHEN ((usage_storage_gb_mo * 3) < 3000) THEN (3000 - 3000) WHEN ((usage_storage_gb_mo * 3) > 16000) THEN (16000 - 3000) ELSE ((usage_storage_gb_mo * 3) - 3000) END) gp2_usage_added_iops_mo
   , (CASE WHEN (volume_api_name <> 'gp2') THEN 0 WHEN (usage_storage_gb_mo <= 150) THEN 0 ELSE 125 END) gp2_usage_added_throughput_gibps_mo
   , ((cost_storage_gb_mo + cost_iops_mo) + cost_throughput_gibps_mo) ebs_all_cost
   , (CASE WHEN (volume_api_name = 'sc1') THEN ((cost_iops_mo + cost_throughput_gibps_mo) + cost_storage_gb_mo) ELSE 0 END) "ebs_sc1_cost"
   , (CASE WHEN (volume_api_name = 'st1') THEN ((cost_iops_mo + cost_throughput_gibps_mo) + cost_storage_gb_mo) ELSE 0 END) "ebs_st1_cost"
   , (CASE WHEN (volume_api_name = 'standard') THEN ((cost_iops_mo + cost_throughput_gibps_mo) + cost_storage_gb_mo) ELSE 0 END) "ebs_standard_cost"
   , (CASE WHEN (volume_api_name = 'io1') THEN ((cost_iops_mo + cost_throughput_gibps_mo) + cost_storage_gb_mo) ELSE 0 END) "ebs_io1_cost"
   , (CASE WHEN (volume_api_name = 'io2') THEN ((cost_iops_mo + cost_throughput_gibps_mo) + cost_storage_gb_mo) ELSE 0 END) "ebs_io2_cost"
   , (CASE WHEN (volume_api_name = 'gp2') THEN ((cost_iops_mo + cost_throughput_gibps_mo) + cost_storage_gb_mo) ELSE 0 END) "ebs_gp2_cost"
   , (CASE WHEN (volume_api_name = 'gp3') THEN ((cost_iops_mo + cost_throughput_gibps_mo) + cost_storage_gb_mo) ELSE 0 END) "ebs_gp3_cost"
   , (CASE WHEN (volume_api_name = 'gp2') THEN ((cost_storage_gb_mo * 8E-1) / usage_storage_gb_mo) ELSE 0 END) "estimated_gp3_unit_cost"
   FROM
     ebs_spend
) 
SELECT DISTINCT
  billing_period
, payer_account_id
, linked_account_id
, tags_json
, resource_id
, volume_api_name
, storage_summary
, sum(usage_storage_gb_mo) usage_storage_gb_mo
, sum(usage_iops_mo) usage_iops_mo
, sum(usage_throughput_gibps_mo) usage_throughput_gibps_mo
, sum(gp2_usage_added_iops_mo) gp2_usage_added_iops_mo
, sum(gp2_usage_added_throughput_gibps_mo) gp2_usage_added_throughput_gibps_mo
, sum(ebs_all_cost) ebs_all_cost
, sum(ebs_sc1_cost) ebs_sc1_cost
, sum(ebs_st1_cost) ebs_st1_cost
, sum(ebs_standard_cost) ebs_standard_cost
, sum(ebs_io1_cost) ebs_io1_cost
, sum(ebs_io2_cost) ebs_io2_cost
, sum(ebs_gp2_cost) ebs_gp2_cost
, sum(ebs_gp3_cost) ebs_gp3_cost
, sum((CASE WHEN (volume_api_name = 'gp2') THEN (ebs_gp2_cost - (((cost_storage_gb_mo * 8E-1) + ((estimated_gp3_unit_cost * 5E-1) * gp2_usage_added_throughput_gibps_mo)) + ((estimated_gp3_unit_cost * 6E-2) * gp2_usage_added_iops_mo))) ELSE 0 END)) ebs_gp3_potential_savings
FROM
  ebs_spend_with_unit_cost
GROUP BY 1, 2, 3, 4, 5, 6, 7
