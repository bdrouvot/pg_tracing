-- Only trace queries with sample flag
SET pg_tracing.sample_rate = 0.0;
SET pg_tracing.caller_sample_rate = 1.0;

-- Run a simple query
/*dddbs='postgres.db',traceparent='00-00000000000000000000000000000001-0000000000000001-01'*/ SELECT 1;
-- Get top span id
SELECT span_id AS top_span_id from pg_tracing_peek_spans where parent_id='0000000000000001' and span_type!='Parse' \gset
-- Check parameters
SELECT parameters from pg_tracing_peek_spans where span_id=:'top_span_id';
-- Check the number of children
SELECT count(*) from pg_tracing_peek_spans where parent_id=:'top_span_id';
-- Check span_operation
SELECT span_type, span_operation from pg_tracing_peek_spans where trace_id='00000000000000000000000000000001' order by span_start, span_end desc;
-- Check userid
SELECT userid = (SELECT usesysid FROM pg_user WHERE usename = current_user) FROM pg_tracing_peek_spans GROUP BY userid;
-- Check dbid
SELECT dbid = (SELECT oid FROM pg_database WHERE datname = (SELECT current_database())) FROM pg_tracing_peek_spans GROUP BY dbid;

-- Check count of query_id
SELECT count(distinct query_id) from pg_tracing_consume_spans where trace_id='00000000000000000000000000000001';

-- Get initial number of traces reported
SELECT processed_traces from pg_tracing_info \gset

-- Trace a statement with function call
/*dddbs='postgres.db',traceparent='00-00000000000000000000000000000003-0000000000000003-01'*/ SELECT count(*) from current_database();
-- Check the generated span span_type, span_operation and order of function call
SELECT span_type, span_operation, lvl FROM peek_ordered_spans where trace_id='00000000000000000000000000000003';

-- Check expected reported number of trace
SELECT processed_traces = :processed_traces + 1 from pg_tracing_info;

-- Trace a more complex query with multiple function calls
/*dddbs='postgres.db',traceparent='00-00000000000000000000000000000004-0000000000000004-01'*/ SELECT s.relation_size + s.index_size
FROM (SELECT
      pg_relation_size(C.oid) as relation_size,
      pg_indexes_size(C.oid) as index_size
    FROM pg_class C) as s limit 1;
-- Check the nested level of spans for a query with multiple function calls
SELECT span_type, span_operation, lvl FROM peek_ordered_spans where trace_id='00000000000000000000000000000004';

-- Check that we're in a correct state after a timeout
set statement_timeout=200;
-- Trace query triggering a statement timeout
/*dddbs='postgres.db',traceparent='00-00000000000000000000000000000007-0000000000000007-01'*/ select * from pg_sleep(10);
SELECT span_type, span_operation, sql_error_code, lvl FROM peek_ordered_spans where trace_id='00000000000000000000000000000007';
-- Cleanup statement setting
set statement_timeout=0;

-- Trace a working query after the timeout to check we're in a consistent state
/*dddbs='postgres.db',traceparent='00-00000000000000000000000000000008-0000000000000008-01'*/ select 1;
-- Check the spans order and error code
SELECT span_type, span_operation, sql_error_code, lvl FROM peek_ordered_spans where trace_id='00000000000000000000000000000008';

-- Cleanup
SET plan_cache_mode='auto';

-- Run a statement with node not executed
/*dddbs='postgres.db',traceparent='00-0000000000000000000000000000000b-000000000000000b-01'*/ select 1 limit 0;
SELECT span_operation, parameters, lvl from peek_ordered_spans where trace_id='0000000000000000000000000000000b';

-- Test multiple statements in a single query
/*dddbs='postgres.db',traceparent='00-0000000000000000000000000000000c-000000000000000c-01'*/ select 1; select 2;
SELECT span_operation, parameters, lvl from peek_ordered_spans where trace_id='0000000000000000000000000000000c';

-- Check that parameters are not exported when disabled
SET pg_tracing.export_parameters=false;
/*dddbs='postgres.db',traceparent='00-0000000000000000000000000000000d-000000000000000d-01'*/ select 1, 2, 3;
SELECT span_operation, parameters, lvl from peek_ordered_spans where trace_id='0000000000000000000000000000000d';
SET pg_tracing.export_parameters=true;

-- Check multi statement query
CALL clean_spans();
SET pg_tracing.sample_rate = 1.0;
-- Force a multi-query statement with \;
SELECT 1\; SELECT 1, 2;
SELECT span_type, span_operation, parameters, lvl from peek_ordered_spans;
CALL clean_spans();

-- Check standalone trace
SELECT 1;
-- Make sure we have unique span ids
SELECT count(span_id) from pg_tracing_consume_spans group by span_id;

-- Trigger a planner error
SELECT '\xDEADBEEF'::bytea::text::int;
-- Check planner error
SELECT span_type, span_operation, parameters, sql_error_code, lvl from peek_ordered_spans;
CALL clean_spans();

-- Check spans generated by lazy functions
CREATE OR REPLACE FUNCTION lazy_function(IN anyarray, OUT x anyelement)
    RETURNS SETOF anyelement
    LANGUAGE sql
    AS 'select * from pg_catalog.generate_series(array_lower($1, 1), array_upper($1, 1), 1)';
SELECT lazy_function('{1,2,3,4}'::int[]) FROM (VALUES (1,2)) as t;
-- Check lazy function spans
SELECT span_type, span_operation, parameters, lvl from peek_ordered_spans;

-- Cleanup
SET pg_tracing.sample_rate = 0.0;
CALL clean_spans();
