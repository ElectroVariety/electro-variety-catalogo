drop function if exists public.admin_set_catalog_failure_test_account(uuid, boolean);
drop function if exists public.admin_set_catalog_failure_test_scenario(uuid, boolean, integer, text);
drop function if exists public.admin_list_catalog_failure_test_accounts();
drop function if exists public.get_my_catalog_failure_test_scenario();
drop table if exists public.catalog_failure_test_accounts;
