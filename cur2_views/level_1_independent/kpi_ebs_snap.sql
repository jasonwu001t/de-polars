-- CREATE OR REPLACE VIEW "kpi_ebs_snap" AS 
WITH
  snapshot_usage_all_time AS (
   SELECT
     list_element(split(billing_period, '-'), 1) AS "year"
   , list_element(split(billing_period, '-'), 2) AS "month"
   , bill_billing_period_start_date billing_period
   , line_item_usage_start_date usage_start_date
   , bill_payer_account_id payer_account_id
   , line_item_usage_account_id linked_account_id
   , '{}' tags_json
   , line_item_resource_id resource_id
   , (CASE WHEN (line_item_usage_type LIKE '%EBS:SnapshotArchive%') THEN 'Snapshot_Archive' WHEN (line_item_usage_type LIKE '%EBS:Snapshot%') THEN 'Snapshot' ELSE line_item_operation END) snapshot_type
   , line_item_usage_amount
   , line_item_unblended_cost
   , pricing_public_on_demand_cost
   FROM
     CUR
   WHERE (((((bill_payer_account_id <> '') AND (line_item_resource_id <> '')) AND (line_item_line_item_type LIKE '%Usage%')) AND (line_item_product_code = 'AmazonEC2')) AND (line_item_usage_type LIKE '%EBS:Snapshot%'))
) 
, request_dates AS (
   SELECT DISTINCT
     resource_id request_dates_resource_id
   , min(usage_start_date) start_date
   FROM
     snapshot_usage_all_time
   WHERE (snapshot_type = 'Snapshot')
   GROUP BY 1
) 
(
    SELECT DISTINCT
     billing_period
   , request_dates.start_date
   , payer_account_id
   , linked_account_id
   , tags_json
   , snapshot_type
   , resource_id
   , sum(line_item_usage_amount) usage_quantity
   , sum(line_item_unblended_cost) ebs_snapshot_cost
   , sum(pricing_public_on_demand_cost) public_cost
   , sum((CASE WHEN ((request_dates.start_date > (billing_period - INTERVAL  '12' MONTH)) AND (snapshot_type = 'Snapshot')) THEN line_item_unblended_cost ELSE 0 END)) "ebs_snapshots_under_1yr_cost"
   , sum((CASE WHEN ((request_dates.start_date <= (billing_period - INTERVAL  '12' MONTH)) AND (snapshot_type = 'Snapshot')) THEN line_item_unblended_cost ELSE 0 END)) "ebs_snapshots_over_1yr_cost"
   FROM
     (snapshot_usage_all_time snapshot
   LEFT JOIN request_dates ON (request_dates.request_dates_resource_id = snapshot.resource_id))
   WHERE (CAST(concat(snapshot."year", '-', snapshot."month", '-01') AS date) >= (date_trunc('month', current_date) - INTERVAL  '3' MONTH))
   GROUP BY 1, 2, 3, 4, 5, 6, 7
) 