-- Applied between migrations 074 and 075 (scripts/test-database.py): an owner account, so 075's switch has someone
-- to record it against, and 074 by itself changes nothing (the Feed still reads arXiv's RSS). Synthetic local SQL.
insert into auth.users(id,email) values('74000000-0000-0000-0000-00000000000a','owner@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values('74000000-0000-0000-0000-00000000000a','owner');
do $$ begin
 if (select feed_source from app_private.pipeline_policy where singleton) is distinct from 'arxiv_rss'
  or app_private.feed_active_source() is distinct from 'arxiv-ml' then raise exception 'ASSERTION FAILED: 074 keeps arXiv''s RSS until switched'; end if;
end $$;
