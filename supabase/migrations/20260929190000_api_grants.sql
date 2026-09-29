-- Final grant sweep: runs after every feature migration in this batch.
select hrms.apply_api_grants();
