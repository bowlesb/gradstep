-- The Cloud Run worker deliberately holds the HTTP request open until its
-- bounded worker thread joins. The original Edge function returned a 202 in
-- about a second, so the scheduler's 5 s timeout was sufficient then; it
-- turns every normal Cloud Run run into a pg_net timeout now. Keep the
-- scheduler request below the worker's 840 s hard limit while preserving the
-- existing one-minute recovery wakeup.
begin;

do $migration$
begin
  if to_regprocedure('cron.schedule(text,text,text)') is not null then
    -- Recreate the named job rather than updating cron.job directly; the
    -- extension owns that table and only exposes schedule/unschedule safely.
    perform cron.unschedule('science-reader-pipeline');
    perform cron.schedule('science-reader-pipeline','* * * * *',$cron$
      select net.http_post(url:=(select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_url'),
        body:='{"reason":"cron"}'::jsonb,
        headers:=jsonb_build_object('content-type','application/json','x-pipeline-secret',
          (select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_secret')),
        timeout_milliseconds:=600000)
    $cron$);
  end if;
end
$migration$;

commit;
