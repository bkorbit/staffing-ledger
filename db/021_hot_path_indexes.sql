-- ============================================================================
--  021 — indexes for the paths the app actually walks.
--
--  forecast_page() and the editor read: invoices by project and by issue month,
--  cost lines through bills by issue date, invoice lines by invoice, projects by
--  parent. None of those had an index; every page load was sequential-scanning
--  the biggest tables. deal_line_months is already covered by its primary key.
-- ============================================================================

create index if not exists invoices_project_idx   on invoices (qbo_project_id, issued_on);
create index if not exists invoices_issued_idx    on invoices (issued_on);
create index if not exists bills_issued_idx       on bills (issued_on);
create index if not exists bill_lines_bill_idx    on bill_lines (bill_id);
create index if not exists bill_lines_project_idx on bill_lines (qbo_project_id);
create index if not exists invoice_lines_inv_idx  on invoice_lines (invoice_id);
create index if not exists qbo_projects_parent_idx on qbo_projects (parent_id);
create index if not exists pipeline_deals_name_idx on pipeline_deals (lower(name));

analyze invoices; analyze bills; analyze bill_lines; analyze invoice_lines; analyze qbo_projects;
